-- =============================================================================
-- 20260865 — Protect privileged user_profiles columns from direct client UPDATE
-- =============================================================================
--
-- IMPORTANT — PRODUCTION HISTORY (READ BEFORE APPLYING ANY RELATED MIGRATION):
--
--   The earlier full migration
--     supabase/migrations/20260864_0001_fix_support_inbox_admin_auth_spoof.sql
--   was NOT applied to production.
--
--   Only a small emergency hotfix for public.is_support_inbox_admin(text) was
--   applied manually (JWT / service_role auth; p_admin_email ignored).
--
--   Do NOT apply the old full 20260864 migration after this migration without a
--   separate deliberate review. Full 20260864 replaces multiple complete admin
--   RPC bodies (support inbox list/fetch/reply, announcement push, business-pro
--   award enqueue, etc.) and can overwrite the production-safe definitions this
--   migration and the emergency hotfix establish.
--
-- Live production confirmed anon + authenticated table/column UPDATE on
-- entitlement, admin, deletion, business-flag, and nearby-coarse fields, while
-- existing triggers only guard id/email and handle/username.
--
-- Production state this migration assumes:
--   - Minimal emergency admin-auth hotfix already applied to
--     public.is_support_inbox_admin(text) (JWT/service_role only; p_admin_email ignored).
--   - Full 20260864 NOT applied.
--   - admin_set_user_fangeo_plus body is still 20260841 (audit + award queue + push notify).
--
-- This migration is self-contained and atomic (BEGIN … COMMIT):
--   - preflight dependency checks abort before any schema change
--   - reasserts secure is_support_inbox_admin (idempotent with the hotfix)
--   - defines support_inbox_admin_actor_email as an INTERNAL helper (not granted to clients)
--   - recreates admin_set_user_fangeo_plus from the 20260841 production body with:
--       * JWT/service_role auth (no email spoof)
--       * JWT-derived audit actor email (never p_admin_email)
--       * privileged-write GUC before entitlement UPDATE
--
-- Design:
--   BEFORE UPDATE trigger freezes privileged columns for roles authenticated/anon
--   unless a trusted transaction-local GUC is set by an approved SECURITY DEFINER
--   path (or the caller's JWT role is service_role / non-client).
--
-- active_session_id / active_session_updated_at remain client-editable
-- (single-device login via PostgREST).
-- nearby_* must go through touch_user_nearby_location (snaps grid server-side).
--
-- Do NOT apply from the agent; review and apply deliberately.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Writer inventory (audit summary — comments only)
-- ---------------------------------------------------------------------------
-- ad_free_enabled / ad_free_expires_at:
--   RPC-only → admin_set_user_fangeo_plus; cleared by account deletion soft-delete.
-- admin_status / admin_disabled_at (+ by/reason):
--   server/RPC → reactivation restore; no iOS direct writes.
-- is_deleted / deleted_at / anonymized_at / deletion_requested_at:
--   RPC-only → account deletion / reactivation:
--     gameon.account_deletion_anonymize = p_user_id::text (20260845 soft-delete core)
--     gameon.account_reactivation_restore = p_user_id::text (20260846 reactivate core)
-- is_business_account:
--   server-only / rare ops; no iOS direct writes. Freeze.
-- nearby_coarse_lat/lng / nearby_location_updated_at:
--   RPC-only → touch_user_nearby_location (SECURITY DEFINER; GUC = auth.uid()).
-- active_session_id / active_session_updated_at:
--   client-editable → MapViewModel+SingleSession PostgREST update (preserve).
--
-- gameon.user_profiles_privileged_write:
--   Set only inside this migration's approved DEFINER RPCs:
--     touch_user_nearby_location → auth.uid() only
--     admin_set_user_fangeo_plus → p_user_id only after is_support_inbox_admin()
--   No client-callable helper exposes set_config for arbitrary users.

-- ---------------------------------------------------------------------------
-- PREFLIGHT — abort with zero schema changes if dependencies are missing
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
  v_col text;
  v_required_cols text[] := ARRAY[
    'id',
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
    'last_seen_at',
    'active_session_id',
    'active_session_updated_at'
  ];
BEGIN
  IF to_regclass('public.user_profiles') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.user_profiles'];
  END IF;
  IF to_regclass('public.admin_audit_logs') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.admin_audit_logs'];
  END IF;
  IF to_regclass('public.fangeo_plus_award_push_events') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fangeo_plus_award_push_events'];
  END IF;

  IF to_regclass('public.user_profiles') IS NOT NULL THEN
    FOREACH v_col IN ARRAY v_required_cols
    LOOP
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

  IF to_regprocedure('public.queue_fangeo_plus_award_push_notification(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.queue_fangeo_plus_award_push_notification(uuid)'];
  END IF;

  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION
      '20260865 preflight failed — missing required dependencies (no schema changes applied): %',
      array_to_string(v_missing, ', ')
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 0) Admin auth helpers — self-contained (no 20260864 dependency)
--     Reasserts the already-applied secure gate; does not restore spoofable logic.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.is_support_inbox_admin(p_admin_email text DEFAULT NULL)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  -- p_admin_email is intentionally unused (deprecated; client-spoofable).
  SELECT CASE
    WHEN COALESCE(auth.role(), '') = 'service_role' THEN true
    WHEN auth.uid() IS NULL THEN false
    ELSE (
      NULLIF(lower(btrim(coalesce(auth.jwt() ->> 'email', ''))), '')
        LIKE '%@fangeosports.com'
    )
  END;
$$;

COMMENT ON FUNCTION public.is_support_inbox_admin(text) IS
  'Returns true only for service_role or an authenticated JWT whose email ends with @fangeosports.com. '
  'Parameter p_admin_email is DEPRECATED and IGNORED for authorization (never trust client-supplied admin identity).';

REVOKE ALL ON FUNCTION public.is_support_inbox_admin(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_support_inbox_admin(text) FROM anon;
REVOKE ALL ON FUNCTION public.is_support_inbox_admin(text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.is_support_inbox_admin(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_support_inbox_admin(text) TO service_role;

-- Internal helper for audit / award metadata (JWT or service_role label).
-- NOT granted to authenticated/anon. Callable from SECURITY DEFINER admin RPCs
-- owned by the migration role (owner privilege), and from service_role if needed.
CREATE OR REPLACE FUNCTION public.support_inbox_admin_actor_email()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    NULLIF(lower(btrim(coalesce(auth.jwt() ->> 'email', ''))), ''),
    CASE WHEN COALESCE(auth.role(), '') = 'service_role' THEN 'service_role' ELSE NULL END
  );
$$;

COMMENT ON FUNCTION public.support_inbox_admin_actor_email() IS
  'INTERNAL trusted admin actor email from JWT (or service_role label). Never accepts client-supplied email. Not granted to authenticated/anon clients.';

REVOKE ALL ON FUNCTION public.support_inbox_admin_actor_email() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.support_inbox_admin_actor_email() FROM anon;
REVOKE ALL ON FUNCTION public.support_inbox_admin_actor_email() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.support_inbox_admin_actor_email() TO service_role;

-- ---------------------------------------------------------------------------
-- 1) Privileged-column freeze trigger
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

  -- Detect unauthorized privileged mutations.
  -- active_session_id / active_session_updated_at are intentionally NOT listed.
  IF NEW.ad_free_enabled IS DISTINCT FROM OLD.ad_free_enabled THEN
    v_changed := v_changed || ARRAY['ad_free_enabled'];
  END IF;
  IF NEW.ad_free_expires_at IS DISTINCT FROM OLD.ad_free_expires_at THEN
    v_changed := v_changed || ARRAY['ad_free_expires_at'];
  END IF;
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
  IF NEW.is_business_account IS DISTINCT FROM OLD.is_business_account THEN
    v_changed := v_changed || ARRAY['is_business_account'];
  END IF;
  IF NEW.nearby_coarse_lat IS DISTINCT FROM OLD.nearby_coarse_lat THEN
    v_changed := v_changed || ARRAY['nearby_coarse_lat'];
  END IF;
  IF NEW.nearby_coarse_lng IS DISTINCT FROM OLD.nearby_coarse_lng THEN
    v_changed := v_changed || ARRAY['nearby_coarse_lng'];
  END IF;
  IF NEW.nearby_location_updated_at IS DISTINCT FROM OLD.nearby_location_updated_at THEN
    v_changed := v_changed || ARRAY['nearby_location_updated_at'];
  END IF;

  IF cardinality(v_changed) > 0 THEN
    RAISE EXCEPTION 'not allowed to update privileged profile columns: %', array_to_string(v_changed, ', ')
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.enforce_user_profiles_privileged_columns() IS
  'BEFORE UPDATE guard: blocks authenticated/anon from changing entitlement, admin, deletion, business-flag, and nearby-coarse columns unless a trusted GUC bypass is set by an approved SECURITY DEFINER RPC or the caller is service_role/non-client. active_session_id remains client-editable.';

REVOKE ALL ON FUNCTION public.enforce_user_profiles_privileged_columns() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.enforce_user_profiles_privileged_columns() FROM anon;
REVOKE ALL ON FUNCTION public.enforce_user_profiles_privileged_columns() FROM authenticated;

DROP TRIGGER IF EXISTS trg_user_profiles_privileged_columns ON public.user_profiles;
CREATE TRIGGER trg_user_profiles_privileged_columns
  BEFORE UPDATE ON public.user_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_user_profiles_privileged_columns();

-- ---------------------------------------------------------------------------
-- 2) Approved RPC: touch_user_nearby_location (set GUC before privileged write)
--     Body matches 20260854 + privileged-write GUC for auth.uid() only.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.touch_user_nearby_location(
  p_lat double precision,
  p_lng double precision
)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_now timestamptz := now();
  v_lat double precision;
  v_lng double precision;
  -- ~0.05 degree grid (~3–3.5 miles latitude) — reduces precision before persistence.
  v_grid double precision := 0.05;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '28000';
  END IF;

  -- Allow this DEFINER path to update nearby_* for the caller only (never arbitrary id).
  PERFORM set_config('gameon.user_profiles_privileged_write', auth.uid()::text, true);

  IF p_lat IS NULL OR p_lng IS NULL
     OR p_lat < -90 OR p_lat > 90
     OR p_lng < -180 OR p_lng > 180 THEN
    -- Still refresh presence when coords are unusable.
    UPDATE public.user_profiles
    SET last_seen_at = v_now
    WHERE id = auth.uid();
    RETURN v_now;
  END IF;

  v_lat := round(p_lat / v_grid) * v_grid;
  v_lng := round(p_lng / v_grid) * v_grid;

  UPDATE public.user_profiles
  SET
    last_seen_at = v_now,
    nearby_coarse_lat = v_lat,
    nearby_coarse_lng = v_lng,
    nearby_location_updated_at = v_now
  WHERE id = auth.uid();

  RETURN v_now;
END;
$$;

COMMENT ON FUNCTION public.touch_user_nearby_location(double precision, double precision) IS
  'Authenticated heartbeat: updates last_seen_at and privacy-safe coarse nearby location (server-snapped). Sets gameon.user_profiles_privileged_write for the caller id only.';

REVOKE ALL ON FUNCTION public.touch_user_nearby_location(double precision, double precision) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.touch_user_nearby_location(double precision, double precision) FROM anon;
REVOKE ALL ON FUNCTION public.touch_user_nearby_location(double precision, double precision) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.touch_user_nearby_location(double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.touch_user_nearby_location(double precision, double precision) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Approved RPC: admin_set_user_fangeo_plus
--     Compared to deployed production (20260841):
--       KEEP: entitlement UPDATE, admin_audit_logs insert, fangeo_plus_award_push_events
--             insert, queue_fangeo_plus_award_push_notification, response jsonb shape,
--             no-op early return, grant/extension change_kind rules, default reasons.
--       CHANGE: auth via is_support_inbox_admin() (param ignored; JWT/service_role only);
--               audit actor from support_inbox_admin_actor_email() (JWT), never p_admin_email;
--               set gameon.user_profiles_privileged_write = p_user_id before UPDATE.
--     Note: support_inbox_admin_actor_email is not EXECUTE-granted to authenticated;
--     this SECURITY DEFINER RPC calls it under function-owner privileges.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_set_user_fangeo_plus(
  p_user_id uuid,
  p_enabled boolean,
  p_admin_email text DEFAULT NULL,
  p_expires_at timestamptz DEFAULT NULL,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_email text;
  v_before public.user_profiles%ROWTYPE;
  v_after public.user_profiles%ROWTYPE;
  v_before_enabled boolean;
  v_before_expires timestamptz;
  v_next_expires timestamptz;
  v_change_kind text;
  v_audit_id uuid;
  v_award_event_id uuid;
  v_action text;
  v_reason text;
BEGIN
  -- p_admin_email retained for iOS signature compatibility; ignored for auth + audit.
  IF NOT public.is_support_inbox_admin() THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'missing user id';
  END IF;

  IF p_enabled IS NULL THEN
    RAISE EXCEPTION 'missing enabled flag';
  END IF;

  -- Owner-privileged call into internal helper (not client-executable).
  v_admin_email := public.support_inbox_admin_actor_email();

  SELECT *
  INTO v_before
  FROM public.user_profiles
  WHERE id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'user profile was not found';
  END IF;

  v_before_enabled := coalesce(v_before.ad_free_enabled, false);
  v_before_expires := v_before.ad_free_expires_at;

  IF p_enabled THEN
    v_next_expires := p_expires_at;
  ELSE
    v_next_expires := NULL;
  END IF;

  -- No effective change: do not mutate, audit, or notify.
  IF v_before_enabled IS NOT DISTINCT FROM p_enabled
     AND v_before_expires IS NOT DISTINCT FROM v_next_expires THEN
    RETURN jsonb_build_object(
      'ok', true,
      'changed', false,
      'notified', false,
      'ad_free_enabled', v_before_enabled,
      'ad_free_expires_at', to_jsonb(v_before_expires),
      'change_kind', NULL,
      'award_event_id', NULL,
      'audit_log_id', NULL,
      'message', CASE
        WHEN p_enabled THEN 'This user already has FanGeo+ enabled with the same expiration.'
        ELSE 'This user is already a Regular user.'
      END
    );
  END IF;

  IF p_enabled AND NOT v_before_enabled THEN
    v_change_kind := 'grant';
  ELSIF p_enabled AND v_before_enabled AND v_before_expires IS DISTINCT FROM v_next_expires THEN
    v_change_kind := 'extension';
  ELSE
    v_change_kind := NULL;
  END IF;

  -- Trusted admin path may mutate entitlement columns for the target profile only.
  PERFORM set_config('gameon.user_profiles_privileged_write', p_user_id::text, true);

  UPDATE public.user_profiles
  SET
    ad_free_enabled = p_enabled,
    ad_free_expires_at = v_next_expires
  WHERE id = p_user_id
  RETURNING * INTO v_after;

  v_action := CASE
    WHEN p_enabled AND v_change_kind = 'extension' THEN 'extend_user_fangeo_plus'
    WHEN p_enabled THEN 'enable_user_fangeo_plus'
    ELSE 'disable_user_fangeo_plus'
  END;

  v_reason := NULLIF(btrim(coalesce(p_reason, '')), '');
  IF v_reason IS NULL THEN
    v_reason := CASE
      WHEN v_change_kind = 'extension' THEN 'Manual FanGeo+ extension'
      WHEN p_enabled THEN 'Manual FanGeo+ enable'
      ELSE 'Manual FanGeo+ removal'
    END;
  END IF;

  INSERT INTO public.admin_audit_logs (
    admin_email,
    action,
    target_type,
    target_id,
    before_data,
    after_data,
    reason
  )
  VALUES (
    coalesce(v_admin_email, 'unknown'),
    v_action,
    'user',
    p_user_id::text,
    jsonb_build_object(
      'user', jsonb_build_object(
        'id', v_before.id,
        'email', v_before.email,
        'display_name', v_before.display_name,
        'ad_free_enabled', v_before.ad_free_enabled,
        'ad_free_expires_at', v_before.ad_free_expires_at
      )
    ),
    jsonb_build_object(
      'user', jsonb_build_object(
        'id', v_after.id,
        'email', v_after.email,
        'display_name', v_after.display_name,
        'ad_free_enabled', v_after.ad_free_enabled,
        'ad_free_expires_at', v_after.ad_free_expires_at
      )
    ),
    v_reason
  )
  RETURNING id INTO v_audit_id;

  IF v_change_kind IS NOT NULL THEN
    INSERT INTO public.fangeo_plus_award_push_events (
      user_id,
      audit_log_id,
      change_kind,
      entitlement_source,
      expires_at,
      admin_email
    )
    VALUES (
      p_user_id,
      v_audit_id,
      v_change_kind,
      'admin_manual',
      v_after.ad_free_expires_at,
      v_admin_email
    )
    RETURNING id INTO v_award_event_id;

    PERFORM public.queue_fangeo_plus_award_push_notification(v_award_event_id);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'changed', true,
    'notified', v_award_event_id IS NOT NULL,
    'ad_free_enabled', v_after.ad_free_enabled,
    'ad_free_expires_at', to_jsonb(v_after.ad_free_expires_at),
    'change_kind', to_jsonb(v_change_kind),
    'award_event_id', to_jsonb(v_award_event_id),
    'audit_log_id', to_jsonb(v_audit_id),
    'message', CASE
      WHEN v_change_kind = 'extension' THEN 'FanGeo+ extended for this user. Award notification queued.'
      WHEN p_enabled THEN 'FanGeo+ enabled for this user. Award notification queued.'
      ELSE 'FanGeo+ removed from this user.'
    END
  );
END;
$$;

COMMENT ON FUNCTION public.admin_set_user_fangeo_plus(uuid, boolean, text, timestamptz, text) IS
  'Admin FanGeo+ grant/remove/extend. Auth via is_support_inbox_admin(); audit email from JWT via internal helper; sets gameon.user_profiles_privileged_write for target. p_admin_email deprecated/ignored.';

REVOKE ALL ON FUNCTION public.admin_set_user_fangeo_plus(uuid, boolean, text, timestamptz, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_set_user_fangeo_plus(uuid, boolean, text, timestamptz, text) FROM anon;
REVOKE ALL ON FUNCTION public.admin_set_user_fangeo_plus(uuid, boolean, text, timestamptz, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_user_fangeo_plus(uuid, boolean, text, timestamptz, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_user_fangeo_plus(uuid, boolean, text, timestamptz, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 4) Grants — revoke client UPDATE from anon
-- ---------------------------------------------------------------------------

REVOKE UPDATE ON TABLE public.user_profiles FROM anon;

-- authenticated retains table UPDATE for normal profile / session patches;
-- privileged columns are blocked by trg_user_profiles_privileged_columns.

COMMENT ON COLUMN public.user_profiles.ad_free_enabled IS
  'FanGeo+ entitlement. Client UPDATE forbidden; mutate via admin_set_user_fangeo_plus or deletion/reactivation RPCs.';
COMMENT ON COLUMN public.user_profiles.ad_free_expires_at IS
  'Optional FanGeo+ expiration. Client UPDATE forbidden; mutate via approved RPCs only.';
COMMENT ON COLUMN public.user_profiles.admin_status IS
  'Lifecycle status (active/disabled). Client UPDATE forbidden.';
COMMENT ON COLUMN public.user_profiles.admin_disabled_at IS
  'When admin disabled the account. Client UPDATE forbidden.';
COMMENT ON COLUMN public.user_profiles.is_deleted IS
  'Soft-deletion flag. Client UPDATE forbidden; mutate via account deletion/reactivation RPCs.';
COMMENT ON COLUMN public.user_profiles.deleted_at IS
  'Soft-deletion timestamp. Client UPDATE forbidden.';
COMMENT ON COLUMN public.user_profiles.is_business_account IS
  'Business identity marker. Client UPDATE forbidden.';
COMMENT ON COLUMN public.user_profiles.nearby_coarse_lat IS
  'Privacy-safe coarse lat. Client UPDATE forbidden; use touch_user_nearby_location.';
COMMENT ON COLUMN public.user_profiles.nearby_coarse_lng IS
  'Privacy-safe coarse lng. Client UPDATE forbidden; use touch_user_nearby_location.';
COMMENT ON COLUMN public.user_profiles.active_session_id IS
  'Fan single-device session id. Client may update own row via PostgREST (not frozen).';
COMMENT ON COLUMN public.user_profiles.active_session_updated_at IS
  'When active_session_id last changed. Client may update own row via PostgREST (not frozen).';

COMMIT;

-- =============================================================================
-- POST-APPLY READ-ONLY VALIDATION (run manually after apply; SELECT only)
-- =============================================================================
--
-- -- Trigger existence + definition
-- SELECT tgname, pg_get_triggerdef(t.oid) AS definition
-- FROM pg_trigger t
-- WHERE t.tgrelid = 'public.user_profiles'::regclass
--   AND NOT t.tgisinternal
--   AND t.tgname = 'trg_user_profiles_privileged_columns';
--
-- -- Function definitions
-- SELECT pg_get_functiondef('public.is_support_inbox_admin(text)'::regprocedure);
-- SELECT pg_get_functiondef('public.support_inbox_admin_actor_email()'::regprocedure);
-- SELECT pg_get_functiondef('public.enforce_user_profiles_privileged_columns()'::regprocedure);
-- SELECT pg_get_functiondef('public.touch_user_nearby_location(double precision, double precision)'::regprocedure);
-- SELECT pg_get_functiondef('public.admin_set_user_fangeo_plus(uuid, boolean, text, timestamptz, text)'::regprocedure);
--
-- -- Confirm admin gate ignores p_admin_email (JWT / service_role only)
-- SELECT
--   (pg_get_functiondef('public.is_support_inbox_admin(text)'::regprocedure)
--     ILIKE '%p_admin_email is intentionally unused%') AS documents_unused_param,
--   (pg_get_functiondef('public.is_support_inbox_admin(text)'::regprocedure)
--     ILIKE '%service_role%') AS allows_service_role,
--   (pg_get_functiondef('public.is_support_inbox_admin(text)'::regprocedure)
--     ILIKE '%auth.jwt() %>% ''email''%') AS uses_jwt_email,
--   (pg_get_functiondef('public.is_support_inbox_admin(text)'::regprocedure)
--     ILIKE '%auth.uid() IS NULL%') AS requires_uid_for_user_admins;
--
-- SELECT p.prosrc
-- FROM pg_proc p
-- JOIN pg_namespace n ON n.oid = p.pronamespace
-- WHERE n.nspname = 'public'
--   AND p.proname = 'is_support_inbox_admin'
--   AND pg_get_function_identity_arguments(p.oid) = 'p_admin_email text';
-- -- Expect: parameter mentioned only as intentionally unused; auth via auth.role()/auth.uid()/auth.jwt().
--
-- -- Routine EXECUTE grants
-- SELECT
--   r.routine_name,
--   r.specific_name,
--   p.grantee,
--   p.privilege_type
-- FROM information_schema.routine_privileges p
-- JOIN information_schema.routines r
--   ON r.specific_name = p.specific_name
--  AND r.specific_schema = p.specific_schema
-- WHERE p.specific_schema = 'public'
--   AND r.routine_name IN (
--     'is_support_inbox_admin',
--     'support_inbox_admin_actor_email',
--     'touch_user_nearby_location',
--     'admin_set_user_fangeo_plus',
--     'enforce_user_profiles_privileged_columns'
--   )
-- ORDER BY r.routine_name, p.grantee;
--
-- Expect:
--   is_support_inbox_admin          → authenticated, service_role (not anon)
--   support_inbox_admin_actor_email → service_role only (NOT authenticated, NOT anon)
--   touch_user_nearby_location      → authenticated, service_role (not anon)
--   admin_set_user_fangeo_plus      → authenticated, service_role (not anon)
--   enforce_…                       → no client EXECUTE
--
-- -- Table UPDATE grants (anon must be absent)
-- SELECT grantee, privilege_type
-- FROM information_schema.role_table_grants
-- WHERE table_schema = 'public'
--   AND table_name = 'user_profiles'
--   AND privilege_type = 'UPDATE'
-- ORDER BY grantee;
--
-- SELECT COUNT(*) AS anon_update_grants
-- FROM information_schema.role_table_grants
-- WHERE table_schema = 'public'
--   AND table_name = 'user_profiles'
--   AND privilege_type = 'UPDATE'
--   AND grantee = 'anon';
-- -- expect 0
--
-- =============================================================================
-- Staging behavioral tests (staging only — NOT production UPDATE tests):
-- A) Authed: UPDATE display_name / bio / privacy — OK
-- B) Authed: UPDATE ad_free_enabled — FAIL 42501
-- C) Authed: UPDATE admin_status / is_deleted / is_business_account / nearby_coarse_* — FAIL
-- D) Authed: UPDATE active_session_id / active_session_updated_at — OK
-- E) touch_user_nearby_location — OK
-- F) Admin JWT: admin_set_user_fangeo_plus — OK (audit + award queue)
-- G) Non-admin JWT: admin_set_user_fangeo_plus — not authorized
-- H) Direct RPC support_inbox_admin_actor_email as authenticated — permission denied
-- I) Deletion / reactivation smoke — OK
-- J) Anon UPDATE user_profiles — denied
-- K) service_role privileged UPDATE — OK
-- L) Released iOS profile save — OK
--
-- Rollback (manual; prefer forward-fix):
--   BEGIN;
--   DROP TRIGGER IF EXISTS trg_user_profiles_privileged_columns ON public.user_profiles;
--   DROP FUNCTION IF EXISTS public.enforce_user_profiles_privileged_columns();
--   -- Optionally restore prior touch_user_nearby_location / admin_set_user_fangeo_plus
--   -- from 20260854 / 20260841. Keep secure is_support_inbox_admin.
--   -- Do NOT re-apply full 20260864 without separate review.
--   COMMIT;
-- =============================================================================
