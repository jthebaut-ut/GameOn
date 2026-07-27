-- =============================================================================
-- 20260872 — Harden user_profiles FanGeo+ / privileged column protections
-- =============================================================================
--
-- Live production baseline (read-only audit, linked project srizbpfkigidsjxvpnkt):
--
--   UPDATE path (stated self-grant exploit):
--     SAFE — trg_user_profiles_privileged_columns + enforce_user_profiles_privileged_columns()
--     already blocks authenticated/anon changes to ad_free_*, admin_*, deletion_*,
--     is_business_account, nearby_coarse_* unless a trusted GUC is set
--     (deployed body matches 20260865).
--
--   Remaining gaps this migration closes:
--     1) No BEFORE INSERT guard — authenticated INSERT RLS allows own-row insert with
--        client-supplied ad_free_enabled / admin_status / is_deleted / etc.
--        Combined with table DELETE privilege, an owner could DELETE + re-INSERT to
--        self-grant FanGeo+ (UPDATE trigger does not cover INSERT).
--     2) Over-broad table privileges — anon has INSERT/DELETE/TRUNCATE/TRIGGER/REFERENCES;
--        authenticated has DELETE/TRUNCATE/TRIGGER/REFERENCES (iOS never hard-deletes
--        user_profiles; soft-delete uses RPCs).
--     3) gameon_account_deletion_soft_delete_core(uuid,text) is SECURITY DEFINER,
--        clears ad_free_*, sets deletion GUC, and has NO caller auth gate, yet
--        authenticated has EXECUTE — revoke client EXECUTE (callers remain DEFINER owners).
--     4) queue_fangeo_plus_award_push_notification(uuid) — revoke client EXECUTE;
--        only admin_set_user_fangeo_plus (DEFINER) should enqueue.
--
-- Does NOT:
--   - reset existing FanGeo+ entitlements
--   - rewrite profile rows
--   - delete / suspend / reactivate accounts
--   - change released iOS profile-edit column set
--
-- Do NOT apply from the agent; review and apply deliberately.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Preflight — fail before persistent mutation if dependencies are missing
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
  v_col text;
  v_required_cols text[] := ARRAY[
    'id',
    'email',
    'ad_free_enabled',
    'ad_free_expires_at',
    'admin_status',
    'admin_disabled_at',
    'admin_disabled_by',
    'admin_disabled_reason',
    'is_deleted',
    'deleted_at',
    'anonymized_at',
    'deletion_requested_at',
    'is_business_account',
    'nearby_coarse_lat',
    'nearby_coarse_lng',
    'nearby_location_updated_at',
    'created_at',
    'active_session_id',
    'active_session_updated_at'
  ];
BEGIN
  IF to_regclass('public.user_profiles') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.user_profiles'];
  END IF;

  IF to_regprocedure('public.enforce_user_profiles_privileged_columns()') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.enforce_user_profiles_privileged_columns()'];
  END IF;

  IF to_regprocedure('public.admin_set_user_fangeo_plus(uuid, boolean, text, timestamptz, text)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.admin_set_user_fangeo_plus(uuid,boolean,text,timestamptz,text)'];
  END IF;

  IF to_regprocedure('public.is_support_inbox_admin(text)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.is_support_inbox_admin(text)'];
  END IF;

  IF to_regprocedure('public.touch_user_nearby_location(double precision, double precision)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.touch_user_nearby_location(double precision,double precision)'];
  END IF;

  IF to_regclass('public.user_profiles') IS NOT NULL THEN
    FOREACH v_col IN ARRAY v_required_cols LOOP
      IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns c
        WHERE c.table_schema = 'public'
          AND c.table_name = 'user_profiles'
          AND c.column_name = v_col
      ) THEN
        v_missing := v_missing || ARRAY['column public.user_profiles.' || v_col];
      END IF;
    END LOOP;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'user_profiles'
      AND t.tgname = 'trg_user_profiles_privileged_columns'
      AND NOT t.tgisinternal
  ) THEN
    v_missing := v_missing || ARRAY['trigger trg_user_profiles_privileged_columns'];
  END IF;

  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION
      '20260872 preflight failed — missing required dependencies (no schema changes applied): %',
      array_to_string(v_missing, ', ')
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 1) Strengthen BEFORE UPDATE guard (add created_at freeze)
--     Retains GUC bypasses from 20260865:
--       gameon.user_profiles_privileged_write
--       gameon.account_deletion_anonymize
--       gameon.account_reactivation_restore
--     active_session_* remain client-editable.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.enforce_user_profiles_privileged_columns()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text := coalesce(auth.role(), '');
  v_priv_bypass text := nullif(btrim(current_setting('gameon.user_profiles_privileged_write', true)), '');
  v_deletion_bypass text := nullif(btrim(current_setting('gameon.account_deletion_anonymize', true)), '');
  v_reactivation_bypass text := nullif(btrim(current_setting('gameon.account_reactivation_restore', true)), '');
  v_changed text[] := ARRAY[]::text[];
BEGIN
  -- Non-client roles (service_role, postgres, unset) may update freely.
  IF v_role NOT IN ('authenticated', 'anon') THEN
    RETURN NEW;
  END IF;

  -- Approved SECURITY DEFINER paths set a transaction-local GUC to the subject user id.
  IF v_priv_bypass IS NOT NULL AND v_priv_bypass = NEW.id::text THEN
    RETURN NEW;
  END IF;
  IF v_deletion_bypass IS NOT NULL AND v_deletion_bypass = NEW.id::text THEN
    RETURN NEW;
  END IF;
  IF v_reactivation_bypass IS NOT NULL AND v_reactivation_bypass = NEW.id::text THEN
    RETURN NEW;
  END IF;

  -- FanGeo+ / entitlement
  IF NEW.ad_free_enabled IS DISTINCT FROM OLD.ad_free_enabled THEN
    v_changed := v_changed || ARRAY['ad_free_enabled'];
  END IF;
  IF NEW.ad_free_expires_at IS DISTINCT FROM OLD.ad_free_expires_at THEN
    v_changed := v_changed || ARRAY['ad_free_expires_at'];
  END IF;

  -- Administrative / moderation
  IF NEW.admin_status IS DISTINCT FROM OLD.admin_status THEN
    v_changed := v_changed || ARRAY['admin_status'];
  END IF;
  IF NEW.admin_disabled_at IS DISTINCT FROM OLD.admin_disabled_at THEN
    v_changed := v_changed || ARRAY['admin_disabled_at'];
  END IF;
  IF NEW.admin_disabled_by IS DISTINCT FROM OLD.admin_disabled_by THEN
    v_changed := v_changed || ARRAY['admin_disabled_by'];
  END IF;
  IF NEW.admin_disabled_reason IS DISTINCT FROM OLD.admin_disabled_reason THEN
    v_changed := v_changed || ARRAY['admin_disabled_reason'];
  END IF;

  -- Deletion / anonymization
  IF NEW.is_deleted IS DISTINCT FROM OLD.is_deleted THEN
    v_changed := v_changed || ARRAY['is_deleted'];
  END IF;
  IF NEW.deleted_at IS DISTINCT FROM OLD.deleted_at THEN
    v_changed := v_changed || ARRAY['deleted_at'];
  END IF;
  IF NEW.anonymized_at IS DISTINCT FROM OLD.anonymized_at THEN
    v_changed := v_changed || ARRAY['anonymized_at'];
  END IF;
  IF NEW.deletion_requested_at IS DISTINCT FROM OLD.deletion_requested_at THEN
    v_changed := v_changed || ARRAY['deletion_requested_at'];
  END IF;

  -- Business identity marker
  IF NEW.is_business_account IS DISTINCT FROM OLD.is_business_account THEN
    v_changed := v_changed || ARRAY['is_business_account'];
  END IF;

  -- Nearby coarse location (must use touch_user_nearby_location)
  IF NEW.nearby_coarse_lat IS DISTINCT FROM OLD.nearby_coarse_lat THEN
    v_changed := v_changed || ARRAY['nearby_coarse_lat'];
  END IF;
  IF NEW.nearby_coarse_lng IS DISTINCT FROM OLD.nearby_coarse_lng THEN
    v_changed := v_changed || ARRAY['nearby_coarse_lng'];
  END IF;
  IF NEW.nearby_location_updated_at IS DISTINCT FROM OLD.nearby_location_updated_at THEN
    v_changed := v_changed || ARRAY['nearby_location_updated_at'];
  END IF;

  -- Trusted creation timestamp (clients must not rewrite history)
  IF NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    v_changed := v_changed || ARRAY['created_at'];
  END IF;

  IF cardinality(v_changed) > 0 THEN
    RAISE EXCEPTION 'not allowed to update privileged profile columns: %', array_to_string(v_changed, ', ')
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.enforce_user_profiles_privileged_columns() IS
  'BEFORE UPDATE guard: blocks authenticated/anon from changing FanGeo+/admin/deletion/business/nearby/created_at '
  'unless a trusted transaction-local GUC is set by an approved SECURITY DEFINER RPC, or caller is service_role/non-client. '
  'active_session_id / active_session_updated_at remain client-editable.';

REVOKE ALL ON FUNCTION public.enforce_user_profiles_privileged_columns() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.enforce_user_profiles_privileged_columns() FROM anon;
REVOKE ALL ON FUNCTION public.enforce_user_profiles_privileged_columns() FROM authenticated;

DROP TRIGGER IF EXISTS trg_user_profiles_privileged_columns ON public.user_profiles;
CREATE TRIGGER trg_user_profiles_privileged_columns
  BEFORE UPDATE ON public.user_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_user_profiles_privileged_columns();

-- ---------------------------------------------------------------------------
-- 2) BEFORE INSERT — force safe privileged defaults for client-created rows
--     service_role / non-client inserts may set entitlements (ops / migrations).
--     Trusted GUC gameon.user_profiles_privileged_write = NEW.id also bypasses
--     (reserved for future DEFINER insert helpers; not granted to clients).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.enforce_user_profiles_privileged_insert_defaults()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text := coalesce(auth.role(), '');
  v_priv_bypass text := nullif(btrim(current_setting('gameon.user_profiles_privileged_write', true)), '');
BEGIN
  IF v_role NOT IN ('authenticated', 'anon') THEN
    RETURN NEW;
  END IF;

  IF v_priv_bypass IS NOT NULL AND v_priv_bypass = NEW.id::text THEN
    RETURN NEW;
  END IF;

  -- FanGeo+ disabled; no client-supplied expiration / premium metadata.
  NEW.ad_free_enabled := false;
  NEW.ad_free_expires_at := NULL;

  -- Normal non-admin lifecycle.
  NEW.admin_status := 'active';
  NEW.admin_disabled_at := NULL;
  NEW.admin_disabled_by := NULL;
  NEW.admin_disabled_reason := NULL;

  -- Not deleted / not anonymized.
  NEW.is_deleted := false;
  NEW.deleted_at := NULL;
  NEW.anonymized_at := NULL;
  NEW.deletion_requested_at := NULL;

  -- Fan profile insert path (identity guard claims fan).
  NEW.is_business_account := false;

  -- Coarse nearby must be established via touch_user_nearby_location.
  NEW.nearby_coarse_lat := NULL;
  NEW.nearby_coarse_lng := NULL;
  NEW.nearby_location_updated_at := NULL;

  -- Server creation timestamp (ignore any client-supplied value).
  NEW.created_at := now();

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.enforce_user_profiles_privileged_insert_defaults() IS
  'BEFORE INSERT guard: for authenticated/anon, forces FanGeo+ off, normal admin_status, clear deletion/moderation, '
  'non-business, null nearby coarse fields, and server created_at. service_role / privileged-write GUC bypass.';

REVOKE ALL ON FUNCTION public.enforce_user_profiles_privileged_insert_defaults() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.enforce_user_profiles_privileged_insert_defaults() FROM anon;
REVOKE ALL ON FUNCTION public.enforce_user_profiles_privileged_insert_defaults() FROM authenticated;

DROP TRIGGER IF EXISTS trg_user_profiles_privileged_insert ON public.user_profiles;
CREATE TRIGGER trg_user_profiles_privileged_insert
  BEFORE INSERT ON public.user_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_user_profiles_privileged_insert_defaults();

-- ---------------------------------------------------------------------------
-- 3) Table privileges — least privilege for clients
--     Preserve authenticated SELECT/INSERT/UPDATE (released iOS profile bootstrap
--     + own-profile patches). Privileged columns remain trigger-guarded.
-- ---------------------------------------------------------------------------

REVOKE ALL ON TABLE public.user_profiles FROM PUBLIC;
REVOKE ALL ON TABLE public.user_profiles FROM anon;

-- anon: no direct profile access (public fan reads use SECURITY DEFINER RPCs).
-- Re-grant nothing to anon.

REVOKE ALL ON TABLE public.user_profiles FROM authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.user_profiles TO authenticated;

GRANT ALL ON TABLE public.user_profiles TO service_role;

COMMENT ON COLUMN public.user_profiles.ad_free_enabled IS
  'FanGeo+ entitlement. Client INSERT forced false; client UPDATE forbidden; mutate via admin_set_user_fangeo_plus or deletion/reactivation RPCs.';
COMMENT ON COLUMN public.user_profiles.ad_free_expires_at IS
  'Optional FanGeo+ expiration. Client INSERT forced NULL; client UPDATE forbidden; mutate via approved RPCs only.';
COMMENT ON COLUMN public.user_profiles.created_at IS
  'Trusted creation timestamp. Client INSERT forced to now(); client UPDATE forbidden.';

-- ---------------------------------------------------------------------------
-- 4) Revoke client EXECUTE on internal privileged writers
--     Parent SECURITY DEFINER RPCs retain owner EXECUTE and continue to work.
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  IF to_regprocedure('public.gameon_account_deletion_soft_delete_core(uuid, text)') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON FUNCTION public.gameon_account_deletion_soft_delete_core(uuid, text) FROM PUBLIC';
    EXECUTE 'REVOKE ALL ON FUNCTION public.gameon_account_deletion_soft_delete_core(uuid, text) FROM anon';
    EXECUTE 'REVOKE ALL ON FUNCTION public.gameon_account_deletion_soft_delete_core(uuid, text) FROM authenticated';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.gameon_account_deletion_soft_delete_core(uuid, text) TO service_role';
  END IF;

  IF to_regprocedure('public.queue_fangeo_plus_award_push_notification(uuid)') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON FUNCTION public.queue_fangeo_plus_award_push_notification(uuid) FROM PUBLIC';
    EXECUTE 'REVOKE ALL ON FUNCTION public.queue_fangeo_plus_award_push_notification(uuid) FROM anon';
    EXECUTE 'REVOKE ALL ON FUNCTION public.queue_fangeo_plus_award_push_notification(uuid) FROM authenticated';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.queue_fangeo_plus_award_push_notification(uuid) TO service_role';
  END IF;
END;
$$;

-- Reaffirm admin FanGeo+ RPC grants (JWT admin / service_role only; p_admin_email ignored).
REVOKE ALL ON FUNCTION public.admin_set_user_fangeo_plus(uuid, boolean, text, timestamptz, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_set_user_fangeo_plus(uuid, boolean, text, timestamptz, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_set_user_fangeo_plus(uuid, boolean, text, timestamptz, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_user_fangeo_plus(uuid, boolean, text, timestamptz, text) TO service_role;

REVOKE ALL ON FUNCTION public.touch_user_nearby_location(double precision, double precision) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.touch_user_nearby_location(double precision, double precision) FROM anon;
GRANT EXECUTE ON FUNCTION public.touch_user_nearby_location(double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.touch_user_nearby_location(double precision, double precision) TO service_role;

COMMIT;

-- =============================================================================
-- POST-APPLY SELECT-ONLY VALIDATION (manual)
-- =============================================================================
-- SELECT tgname FROM pg_trigger t
--   JOIN pg_class c ON c.oid = t.tgrelid
--   JOIN pg_namespace n ON n.oid = c.relnamespace
--  WHERE n.nspname='public' AND c.relname='user_profiles' AND NOT tgisinternal
--  ORDER BY 1;
-- -- Expect trg_user_profiles_privileged_columns + trg_user_profiles_privileged_insert
--
-- SELECT grantee, privilege_type
-- FROM information_schema.role_table_grants
-- WHERE table_schema='public' AND table_name='user_profiles'
--   AND grantee IN ('anon','authenticated','service_role')
-- ORDER BY 1,2;
-- -- anon: none; authenticated: SELECT,INSERT,UPDATE only
--
-- SELECT has_function_privilege('authenticated',
--   'public.gameon_account_deletion_soft_delete_core(uuid,text)'::regprocedure, 'EXECUTE');
-- -- expect false
--
-- SELECT has_function_privilege('authenticated',
--   'public.queue_fangeo_plus_award_push_notification(uuid)'::regprocedure, 'EXECUTE');
-- -- expect false
--
-- SELECT (pg_get_functiondef('public.enforce_user_profiles_privileged_insert_defaults()'::regprocedure)
--   ILIKE '%ad_free_enabled := false%') AS insert_forces_ad_free_off;
-- SELECT (pg_get_functiondef('public.enforce_user_profiles_privileged_columns()'::regprocedure)
--   ILIKE '%created_at%') AS update_freezes_created_at;
--
-- SELECT COUNT(*) FILTER (WHERE ad_free_enabled) AS plus_users,
--        COUNT(*) FILTER (WHERE NOT ad_free_enabled) AS regular_users
-- FROM public.user_profiles;
-- -- counts should be unchanged by apply
--
-- =============================================================================
-- Staging security matrix
-- =============================================================================
-- 1-3 Owner edits display_name / handle / bio → OK
-- 4-5 Owner UPDATE ad_free_enabled / ad_free_expires_at → 42501
-- 6   Owner UPDATE admin_status → 42501
-- 7-8 Owner UPDATE is_deleted / admin_disabled_* → 42501
-- 9   Owner UPDATE created_at → 42501
-- 10  Owner UPDATE another user's row → denied by RLS
-- 11  Client INSERT with ad_free_enabled=true → stored false
-- 12  Client INSERT with admin_status=disabled / is_deleted=true → stored safe defaults
-- 13  Admin JWT admin_set_user_fangeo_plus → OK
-- 14  Normal user admin_set_user_fangeo_plus + forged p_admin_email → not authorized
-- 15  service_role admin_set_user_fangeo_plus → OK
-- 16  touch_user_nearby_location → OK
-- 17  request_delete_my_account / deletion job → OK (soft_delete via DEFINER)
-- 18  admin_reactivate_deleted_user → OK
-- 19  Existing FanGeo+ rows unchanged by migration apply
-- 20  Existing regular users remain regular
-- 21  Public profile RPCs still read
-- 22  Released iOS profile bootstrap INSERT + own-profile save → OK
--
-- Rollback (manual):
--   DROP TRIGGER IF EXISTS trg_user_profiles_privileged_insert ON public.user_profiles;
--   DROP FUNCTION IF EXISTS public.enforce_user_profiles_privileged_insert_defaults();
--   Restore enforce_user_profiles_privileged_columns body from 20260865 if needed.
--   Re-grant prior table privileges only if a released client regression is proven.
-- =============================================================================
