-- =============================================================================
-- 20260867 — Protect Business Pro entitlement / promotion columns on businesses
-- =============================================================================
--
-- Confirmed production issue:
--   Owner UPDATE policies (businesses_update_own, businesses_update_identity_by_owner)
--   authorize by ownership only and do not restrict columns. Table GRANT ALL to
--   anon + authenticated allows owners (and anon, if RLS were bypassed) to UPDATE
--   plan_type / plan_status / pro_expires_at / admin promo / venue-limit overrides.
--
-- Fix:
--   BEFORE UPDATE trigger blocks authenticated/anon changes to privileged columns
--   unless a trusted transaction-local GUC is set by an approved SECURITY DEFINER path
--   (or the JWT role is service_role / non-client).
--   BEFORE INSERT trigger forces Free/default entitlement values for client inserts
--   (entitlement_updated_at forced to now(); never preserves client-supplied timestamp).
--   Revoke broad anon table writes; keep authenticated SELECT/INSERT/UPDATE only.
--
-- Auth correction (critical):
--   Prior draft of admin_set_business_active_venue_limit_override /
--   admin_set_business_venue_activation set gameon.businesses_privileged_write without
--   authenticating the caller as an admin. Client-supplied p_admin_email is NOT authorization.
--   Both admin RPCs now require public.is_support_inbox_admin() (JWT @fangeosports.com or
--   service_role). Audit actor email is derived from auth.jwt() / service_role — never
--   from p_admin_email. p_admin_email is retained for iOS signature compatibility only
--   (deprecated / ignored for auth and audit).
--
-- Privileged-write RPC auth classes:
--   save_free_active_business_venues              → owner-authorized (ownership check)
--   admin_set_business_active_venue_limit_override → JWT admin / service_role
--   admin_set_business_venue_activation           → JWT admin / service_role
--   3-arg override + clear wrappers                → delegate to secured 6-arg (cannot bypass)
--
-- Do NOT apply from the agent; review and apply deliberately.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Preflight
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
  v_col text;
  v_required_cols text[] := ARRAY[
    'plan_type',
    'plan_status',
    'pro_expires_at',
    'entitlement_updated_at',
    'venue_limit',
    'monthly_host_limit',
    'statistics_enabled',
    'sponsored_enabled',
    'unlimited_venues',
    'unlimited_hosting',
    'admin_pro_promo_batch_id',
    'admin_pro_promo_starts_at',
    'admin_pro_promo_ends_at',
    'admin_pro_promo_reason',
    'admin_pro_promo_updated_at',
    'admin_pro_promo_updated_by',
    'exclude_from_global_business_pro_promo',
    'global_business_pro_promo_excluded_at',
    'global_business_pro_promo_excluded_by',
    'global_business_pro_promo_exclusion_reason',
    'admin_active_venue_limit_override',
    'admin_unlimited_active_venues_override',
    'admin_venue_override_expires_at',
    'admin_venue_override_reason',
    'admin_venue_override_updated_by',
    'admin_venue_override_updated_at'
  ];
  v_required_fns text[] := ARRAY[
    'save_free_active_business_venues',
    'admin_set_business_active_venue_limit_override',
    'admin_set_business_venue_activation',
    'gameon_business_deletion_soft_delete_core',
    'admin_reactivate_deleted_business',
    'is_support_inbox_admin'
  ];
  v_optional_fns text[] := ARRAY[
    'admin_apply_regular_business_promo_grant',
    'admin_apply_targeted_business_pro_grant',
    'admin_apply_existing_pro_business_extension',
    'admin_rollback_business_promotion_batch',
    'admin_set_business_global_pro_promo_exclusion',
    'admin_reopen_free_active_venue_selection'
  ];
  v_fn text;
BEGIN
  IF to_regclass('public.businesses') IS NULL THEN
    RAISE EXCEPTION 'preflight failed: public.businesses missing';
  END IF;

  -- Secure admin helper must exist (JWT / service_role only; p_admin_email ignored).
  IF to_regprocedure('public.is_support_inbox_admin(text)') IS NULL THEN
    RAISE EXCEPTION 'preflight failed: public.is_support_inbox_admin(text) missing';
  END IF;

  FOREACH v_col IN ARRAY v_required_cols LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'businesses'
        AND column_name = v_col
    ) THEN
      v_missing := v_missing || ARRAY[format('column businesses.%s', v_col)];
    END IF;
  END LOOP;

  FOREACH v_fn IN ARRAY v_required_fns LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
        AND p.proname = v_fn
    ) THEN
      v_missing := v_missing || ARRAY[format('function %s', v_fn)];
    END IF;
  END LOOP;

  FOREACH v_fn IN ARRAY v_optional_fns LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
        AND p.proname = v_fn
    ) THEN
      RAISE NOTICE 'preflight optional writer missing: % (service_role promo path)', v_fn;
    END IF;
  END LOOP;

  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION 'preflight failed: %', array_to_string(v_missing, ', ');
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 0) Ensure internal JWT audit-actor helper (idempotent with 20260864/20260865)
--    Not granted to authenticated/anon. SECURITY DEFINER admin RPCs call it
--    via owner privilege. Fallback path: inline auth.jwt() in each RPC if needed.
-- ---------------------------------------------------------------------------

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
-- 1) BEFORE UPDATE — freeze privileged entitlement / promotion columns
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.enforce_businesses_privileged_columns()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text := coalesce(auth.role(), '');
  v_priv_bypass text := nullif(btrim(current_setting('gameon.businesses_privileged_write', true)), '');
  v_deletion_bypass text := nullif(btrim(current_setting('gameon.business_account_deletion_anonymize', true)), '');
  v_reactivation_bypass text := nullif(btrim(current_setting('gameon.business_account_reactivation_restore', true)), '');
  v_changed text[] := ARRAY[]::text[];
BEGIN
  -- Non-client roles (service_role, postgres, unset) may update freely.
  IF v_role NOT IN ('authenticated', 'anon') THEN
    RETURN NEW;
  END IF;

  -- Approved SECURITY DEFINER paths set a transaction-local GUC to the business id.
  IF v_priv_bypass IS NOT NULL AND v_priv_bypass = NEW.id::text THEN
    RETURN NEW;
  END IF;
  IF v_deletion_bypass IS NOT NULL AND v_deletion_bypass = NEW.id::text THEN
    RETURN NEW;
  END IF;
  IF v_reactivation_bypass IS NOT NULL AND v_reactivation_bypass = NEW.id::text THEN
    RETURN NEW;
  END IF;

  IF NEW.plan_type IS DISTINCT FROM OLD.plan_type THEN
    v_changed := v_changed || ARRAY['plan_type'];
  END IF;
  IF NEW.plan_status IS DISTINCT FROM OLD.plan_status THEN
    v_changed := v_changed || ARRAY['plan_status'];
  END IF;
  IF NEW.pro_expires_at IS DISTINCT FROM OLD.pro_expires_at THEN
    v_changed := v_changed || ARRAY['pro_expires_at'];
  END IF;
  IF NEW.entitlement_updated_at IS DISTINCT FROM OLD.entitlement_updated_at THEN
    v_changed := v_changed || ARRAY['entitlement_updated_at'];
  END IF;
  IF NEW.venue_limit IS DISTINCT FROM OLD.venue_limit THEN
    v_changed := v_changed || ARRAY['venue_limit'];
  END IF;
  IF NEW.monthly_host_limit IS DISTINCT FROM OLD.monthly_host_limit THEN
    v_changed := v_changed || ARRAY['monthly_host_limit'];
  END IF;
  IF NEW.statistics_enabled IS DISTINCT FROM OLD.statistics_enabled THEN
    v_changed := v_changed || ARRAY['statistics_enabled'];
  END IF;
  IF NEW.sponsored_enabled IS DISTINCT FROM OLD.sponsored_enabled THEN
    v_changed := v_changed || ARRAY['sponsored_enabled'];
  END IF;
  IF NEW.unlimited_venues IS DISTINCT FROM OLD.unlimited_venues THEN
    v_changed := v_changed || ARRAY['unlimited_venues'];
  END IF;
  IF NEW.unlimited_hosting IS DISTINCT FROM OLD.unlimited_hosting THEN
    v_changed := v_changed || ARRAY['unlimited_hosting'];
  END IF;
  IF NEW.admin_pro_promo_batch_id IS DISTINCT FROM OLD.admin_pro_promo_batch_id THEN
    v_changed := v_changed || ARRAY['admin_pro_promo_batch_id'];
  END IF;
  IF NEW.admin_pro_promo_starts_at IS DISTINCT FROM OLD.admin_pro_promo_starts_at THEN
    v_changed := v_changed || ARRAY['admin_pro_promo_starts_at'];
  END IF;
  IF NEW.admin_pro_promo_ends_at IS DISTINCT FROM OLD.admin_pro_promo_ends_at THEN
    v_changed := v_changed || ARRAY['admin_pro_promo_ends_at'];
  END IF;
  IF NEW.admin_pro_promo_reason IS DISTINCT FROM OLD.admin_pro_promo_reason THEN
    v_changed := v_changed || ARRAY['admin_pro_promo_reason'];
  END IF;
  IF NEW.admin_pro_promo_updated_at IS DISTINCT FROM OLD.admin_pro_promo_updated_at THEN
    v_changed := v_changed || ARRAY['admin_pro_promo_updated_at'];
  END IF;
  IF NEW.admin_pro_promo_updated_by IS DISTINCT FROM OLD.admin_pro_promo_updated_by THEN
    v_changed := v_changed || ARRAY['admin_pro_promo_updated_by'];
  END IF;
  IF NEW.exclude_from_global_business_pro_promo IS DISTINCT FROM OLD.exclude_from_global_business_pro_promo THEN
    v_changed := v_changed || ARRAY['exclude_from_global_business_pro_promo'];
  END IF;
  IF NEW.global_business_pro_promo_excluded_at IS DISTINCT FROM OLD.global_business_pro_promo_excluded_at THEN
    v_changed := v_changed || ARRAY['global_business_pro_promo_excluded_at'];
  END IF;
  IF NEW.global_business_pro_promo_excluded_by IS DISTINCT FROM OLD.global_business_pro_promo_excluded_by THEN
    v_changed := v_changed || ARRAY['global_business_pro_promo_excluded_by'];
  END IF;
  IF NEW.global_business_pro_promo_exclusion_reason IS DISTINCT FROM OLD.global_business_pro_promo_exclusion_reason THEN
    v_changed := v_changed || ARRAY['global_business_pro_promo_exclusion_reason'];
  END IF;
  IF NEW.admin_active_venue_limit_override IS DISTINCT FROM OLD.admin_active_venue_limit_override THEN
    v_changed := v_changed || ARRAY['admin_active_venue_limit_override'];
  END IF;
  IF NEW.admin_unlimited_active_venues_override IS DISTINCT FROM OLD.admin_unlimited_active_venues_override THEN
    v_changed := v_changed || ARRAY['admin_unlimited_active_venues_override'];
  END IF;
  IF NEW.admin_venue_override_expires_at IS DISTINCT FROM OLD.admin_venue_override_expires_at THEN
    v_changed := v_changed || ARRAY['admin_venue_override_expires_at'];
  END IF;
  IF NEW.admin_venue_override_reason IS DISTINCT FROM OLD.admin_venue_override_reason THEN
    v_changed := v_changed || ARRAY['admin_venue_override_reason'];
  END IF;
  IF NEW.admin_venue_override_updated_by IS DISTINCT FROM OLD.admin_venue_override_updated_by THEN
    v_changed := v_changed || ARRAY['admin_venue_override_updated_by'];
  END IF;
  IF NEW.admin_venue_override_updated_at IS DISTINCT FROM OLD.admin_venue_override_updated_at THEN
    v_changed := v_changed || ARRAY['admin_venue_override_updated_at'];
  END IF;

  IF cardinality(v_changed) > 0 THEN
    RAISE EXCEPTION 'not allowed to update privileged business entitlement columns: %',
      array_to_string(v_changed, ', ')
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.enforce_businesses_privileged_columns() IS
  'BEFORE UPDATE guard: blocks authenticated/anon from changing Business Pro entitlement, promo, limit, and override columns unless gameon.businesses_privileged_write (or deletion/reactivation GUCs) is set for this business id, or caller is service_role/non-client.';

REVOKE ALL ON FUNCTION public.enforce_businesses_privileged_columns() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.enforce_businesses_privileged_columns() FROM anon;
REVOKE ALL ON FUNCTION public.enforce_businesses_privileged_columns() FROM authenticated;

DROP TRIGGER IF EXISTS trg_businesses_privileged_columns ON public.businesses;
CREATE TRIGGER trg_businesses_privileged_columns
  BEFORE UPDATE ON public.businesses
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_businesses_privileged_columns();

-- ---------------------------------------------------------------------------
-- 2) BEFORE INSERT — force Free/default entitlements for client-created rows
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.enforce_businesses_privileged_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text := coalesce(auth.role(), '');
BEGIN
  IF v_role NOT IN ('authenticated', 'anon') THEN
    RETURN NEW;
  END IF;

  -- Owners may create a business identity row only; entitlement is server-default Free.
  NEW.plan_type := 'free';
  NEW.plan_status := 'active';
  NEW.pro_expires_at := NULL;
  NEW.venue_limit := 5;
  NEW.monthly_host_limit := 5;
  NEW.statistics_enabled := false;
  NEW.sponsored_enabled := false;
  NEW.unlimited_venues := false;
  NEW.unlimited_hosting := false;
  -- Always server time; never preserve a client-supplied entitlement_updated_at.
  NEW.entitlement_updated_at := now();

  NEW.admin_pro_promo_batch_id := NULL;
  NEW.admin_pro_promo_starts_at := NULL;
  NEW.admin_pro_promo_ends_at := NULL;
  NEW.admin_pro_promo_reason := NULL;
  NEW.admin_pro_promo_updated_at := NULL;
  NEW.admin_pro_promo_updated_by := NULL;

  NEW.exclude_from_global_business_pro_promo := false;
  NEW.global_business_pro_promo_excluded_at := NULL;
  NEW.global_business_pro_promo_excluded_by := NULL;
  NEW.global_business_pro_promo_exclusion_reason := NULL;

  NEW.admin_active_venue_limit_override := NULL;
  NEW.admin_unlimited_active_venues_override := false;
  NEW.admin_venue_override_expires_at := NULL;
  NEW.admin_venue_override_reason := NULL;
  NEW.admin_venue_override_updated_by := NULL;
  NEW.admin_venue_override_updated_at := NULL;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.enforce_businesses_privileged_insert() IS
  'BEFORE INSERT guard: forces Free/default entitlement, forces entitlement_updated_at = now(), and clears promo/override fields for authenticated/anon inserts. service_role/non-client inserts are unchanged.';

REVOKE ALL ON FUNCTION public.enforce_businesses_privileged_insert() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.enforce_businesses_privileged_insert() FROM anon;
REVOKE ALL ON FUNCTION public.enforce_businesses_privileged_insert() FROM authenticated;

DROP TRIGGER IF EXISTS trg_businesses_privileged_insert ON public.businesses;
CREATE TRIGGER trg_businesses_privileged_insert
  BEFORE INSERT ON public.businesses
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_businesses_privileged_insert();

-- ---------------------------------------------------------------------------
-- 3) Patch authenticated-callable writers with privileged-write GUC
--     service_role-only promo RPCs do not require GUC (role bypass).
--     Deletion/reactivation already set business_* GUCs accepted above.
-- ---------------------------------------------------------------------------

-- 3a) Owner free active venue selection (writes entitlement_updated_at)
CREATE OR REPLACE FUNCTION public.save_free_active_business_venues(
  p_business_id uuid,
  p_active_venue_ids uuid[]
)
RETURNS TABLE (
  success boolean,
  active_count integer,
  locked_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
DECLARE
  v_business public.businesses%ROWTYPE;
  v_is_pro_active boolean;
  v_venue_limit integer;
  v_selected_count integer;
  v_invalid_count integer;
  v_locked_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  SELECT *
    INTO v_business
  FROM public.businesses
  WHERE id = p_business_id
    AND lower(btrim(coalesce(admin_status, ''))) = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'business_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT public.business_entitlement_caller_owns_business(p_business_id) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE = '42501';
  END IF;

  IF v_business.free_active_venues_selected_at IS NOT NULL THEN
    RAISE EXCEPTION 'active_venue_selection_already_completed' USING ERRCODE = 'P0001';
  END IF;

  v_is_pro_active := public.admin_venue_override_is_pro(v_business);
  IF v_is_pro_active THEN
    RAISE EXCEPTION 'business_is_pro' USING ERRCODE = 'P0001';
  END IF;

  v_venue_limit := public.business_effective_active_venue_limit(v_business);

  WITH selected AS (
    SELECT DISTINCT unnest(coalesce(p_active_venue_ids, ARRAY[]::uuid[])) AS venue_id
  )
  SELECT count(*)::integer
    INTO v_selected_count
  FROM selected
  WHERE venue_id IS NOT NULL;

  IF v_selected_count = 0 THEN
    RAISE EXCEPTION 'no_active_venues_selected' USING ERRCODE = '22023';
  END IF;

  IF v_venue_limit IS NOT NULL AND v_selected_count <> v_venue_limit THEN
    RAISE EXCEPTION 'active_venue_selection_count_mismatch' USING ERRCODE = 'P0001';
  END IF;

  WITH selected AS (
    SELECT DISTINCT unnest(coalesce(p_active_venue_ids, ARRAY[]::uuid[])) AS venue_id
  ),
  invalid_selected AS (
    SELECT s.venue_id
    FROM selected s
    LEFT JOIN public.admin_business_managed_venue_ids(p_business_id) mv ON mv.venue_id = s.venue_id
    WHERE s.venue_id IS NOT NULL
      AND mv.venue_id IS NULL
  )
  SELECT count(*)::integer
    INTO v_invalid_count
  FROM invalid_selected;

  IF v_invalid_count > 0 THEN
    RAISE EXCEPTION 'selected_venue_not_owned_by_business' USING ERRCODE = '42501';
  END IF;

  PERFORM set_config('app.business_plan_lock_enforcement', 'on', true);
  PERFORM set_config('gameon.businesses_privileged_write', p_business_id::text, true);

  WITH selected AS (
    SELECT DISTINCT unnest(coalesce(p_active_venue_ids, ARRAY[]::uuid[])) AS venue_id
  )
  UPDATE public.venues v
  SET admin_status = CASE
    WHEN EXISTS (SELECT 1 FROM selected s WHERE s.venue_id = v.id) THEN 'active'
    ELSE 'plan_locked'
  END
  WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id));

  UPDATE public.businesses
  SET
    free_active_venues_selected_at = now(),
    entitlement_updated_at = now()
  WHERE id = p_business_id
    AND free_active_venues_selected_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'active_venue_selection_already_completed' USING ERRCODE = 'P0001';
  END IF;

  SELECT
    count(*) FILTER (WHERE lower(btrim(coalesce(v.admin_status, 'active'))) = 'active')::integer,
    count(*) FILTER (WHERE lower(btrim(coalesce(v.admin_status, 'active'))) = 'plan_locked')::integer
    INTO v_selected_count, v_locked_count
  FROM public.venues v
  WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id));

  RETURN QUERY
  SELECT true, coalesce(v_selected_count, 0), coalesce(v_locked_count, 0);
END;
$$;

COMMENT ON FUNCTION public.save_free_active_business_venues(uuid, uuid[]) IS
  'Owner free active-venue selection. Requires auth.uid() + business_entitlement_caller_owns_business. '
  'Sets gameon.businesses_privileged_write only to allow entitlement_updated_at + free_active_venues_selected_at. '
  'Does not modify plan_type, promo, override, statistics, or sponsored columns.';

-- 3b) Admin venue limit override (authenticated AdminScreen + service_role)
--     p_admin_email: DEPRECATED — retained for iOS signature only; ignored for auth + audit.
CREATE OR REPLACE FUNCTION public.admin_set_business_active_venue_limit_override(
  p_business_id uuid,
  p_admin_email text,
  p_mode text,
  p_override integer DEFAULT NULL,
  p_expires_at timestamptz DEFAULT NULL,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
DECLARE
  v_before jsonb;
  v_after jsonb;
  v_mode text;
  v_reason text;
  v_override integer;
  v_unlimited boolean;
  v_before_limit integer;
  v_after_limit integer;
  v_active_count integer := 0;
  v_admin_email text;
BEGIN
  -- Trusted server-side admin gate. Never authorize from p_admin_email.
  IF NOT public.is_support_inbox_admin() THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  -- Audit actor from JWT / service_role (owner-privileged internal helper).
  v_admin_email := COALESCE(
    NULLIF(public.support_inbox_admin_actor_email(), ''),
    NULLIF(lower(btrim(coalesce(auth.jwt() ->> 'email', ''))), ''),
    CASE WHEN COALESCE(auth.role(), '') = 'service_role' THEN 'service_role' ELSE NULL END,
    'unknown'
  );

  v_mode := lower(btrim(coalesce(p_mode, '')));
  v_reason := NULLIF(btrim(coalesce(p_reason, '')), '');

  IF v_mode NOT IN ('standard', 'custom', 'unlimited') THEN
    RAISE EXCEPTION 'invalid_override_mode' USING ERRCODE = '22023';
  END IF;

  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'audit_reason_required' USING ERRCODE = '22023';
  END IF;

  IF p_expires_at IS NOT NULL AND p_expires_at <= now() THEN
    RAISE EXCEPTION 'override_expires_at_must_be_future' USING ERRCODE = '22023';
  END IF;

  IF v_mode = 'custom' THEN
    IF p_override IS NULL OR p_override < 1 OR p_override > 500 THEN
      RAISE EXCEPTION 'invalid_override_limit' USING ERRCODE = '22023';
    END IF;
    v_override := p_override;
    v_unlimited := false;
  ELSIF v_mode = 'unlimited' THEN
    v_override := NULL;
    v_unlimited := true;
  ELSE
    v_override := NULL;
    v_unlimited := false;
  END IF;

  SELECT to_jsonb(b) INTO v_before
  FROM public.businesses b
  WHERE b.id = p_business_id;

  IF v_before IS NULL THEN
    RAISE EXCEPTION 'business_not_found' USING ERRCODE = 'P0002';
  END IF;

  SELECT public.business_effective_active_venue_limit(b)
    INTO v_before_limit
  FROM public.businesses b
  WHERE b.id = p_business_id;

  PERFORM set_config('gameon.businesses_privileged_write', p_business_id::text, true);

  UPDATE public.businesses
  SET
    admin_active_venue_limit_override = CASE WHEN v_mode = 'standard' THEN NULL ELSE v_override END,
    admin_unlimited_active_venues_override = v_unlimited,
    admin_venue_override_expires_at = CASE WHEN v_mode = 'standard' THEN NULL ELSE p_expires_at END,
    admin_venue_override_reason = CASE WHEN v_mode = 'standard' THEN NULL ELSE v_reason END,
    admin_venue_override_updated_by = v_admin_email,
    admin_venue_override_updated_at = now(),
    entitlement_updated_at = now()
  WHERE id = p_business_id;

  SELECT public.business_effective_active_venue_limit(b)
    INTO v_after_limit
  FROM public.businesses b
  WHERE b.id = p_business_id;

  SELECT count(*)::integer
    INTO v_active_count
  FROM public.venues v
  WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id))
    AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active';

  IF v_after_limit IS NULL OR v_active_count <= COALESCE(v_after_limit, 0) THEN
    PERFORM public.enforce_business_plan_venue_locks(p_business_id);
  END IF;

  SELECT to_jsonb(b) INTO v_after
  FROM public.businesses b
  WHERE b.id = p_business_id;

  INSERT INTO public.admin_audit_logs(admin_email, action, target_type, target_id, before_data, after_data, reason)
  VALUES (
    v_admin_email,
    CASE
      WHEN v_mode = 'standard' THEN 'clear_business_active_venue_limit_override'
      ELSE 'set_business_active_venue_limit_override'
    END,
    'business',
    p_business_id::text,
    v_before || jsonb_build_object('previous_effective_active_venue_limit', v_before_limit),
    v_after || jsonb_build_object(
      'new_effective_active_venue_limit', v_after_limit,
      'override_mode', v_mode,
      'override_expires_at', p_expires_at
    ),
    v_reason
  );

  RETURN jsonb_build_object(
    'ok', true,
    'mode', v_mode,
    'override', v_override,
    'unlimited', v_unlimited,
    'expires_at', p_expires_at,
    'previous_effective_limit', v_before_limit,
    'new_effective_limit', v_after_limit
  );
END;
$$;

COMMENT ON FUNCTION public.admin_set_business_active_venue_limit_override(uuid, text, text, integer, timestamptz, text) IS
  'Admin active venue limit override. Auth via is_support_inbox_admin() (JWT @fangeosports.com or service_role). '
  'Audit actor from JWT via support_inbox_admin_actor_email(); p_admin_email deprecated/ignored. '
  'Sets gameon.businesses_privileged_write for the target business.';

-- 3c) Admin venue activation (writes entitlement_updated_at)
--     p_admin_email: DEPRECATED — retained for iOS signature only; ignored for auth + audit.
CREATE OR REPLACE FUNCTION public.admin_set_business_venue_activation(
  p_business_id uuid,
  p_venue_id uuid,
  p_admin_email text,
  p_active boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
DECLARE
  v_business public.businesses%ROWTYPE;
  v_before jsonb;
  v_after jsonb;
  v_effective_limit integer;
  v_active_count integer;
  v_new_status text;
  v_admin_email text;
BEGIN
  -- Trusted server-side admin gate. Never authorize from p_admin_email.
  IF NOT public.is_support_inbox_admin() THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  v_admin_email := COALESCE(
    NULLIF(public.support_inbox_admin_actor_email(), ''),
    NULLIF(lower(btrim(coalesce(auth.jwt() ->> 'email', ''))), ''),
    CASE WHEN COALESCE(auth.role(), '') = 'service_role' THEN 'service_role' ELSE NULL END,
    'unknown'
  );

  SELECT * INTO v_business
  FROM public.businesses
  WHERE id = p_business_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'business_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.admin_business_managed_venue_ids(p_business_id) mv
    WHERE mv.venue_id = p_venue_id
  ) THEN
    RAISE EXCEPTION 'venue_not_owned_by_business' USING ERRCODE = '42501';
  END IF;

  SELECT to_jsonb(v) INTO v_before
  FROM public.venues v
  WHERE v.id = p_venue_id;

  v_effective_limit := public.business_effective_active_venue_limit(v_business);
  v_new_status := CASE WHEN p_active THEN 'active' ELSE 'plan_locked' END;

  IF p_active AND v_effective_limit IS NOT NULL THEN
    SELECT count(*)::integer INTO v_active_count
    FROM public.venues v
    WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id))
      AND v.id <> p_venue_id
      AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active';

    IF v_active_count >= COALESCE(v_effective_limit, 0) THEN
      RAISE EXCEPTION 'effective_venue_limit_reached' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  PERFORM set_config('app.business_plan_lock_enforcement', 'on', true);
  PERFORM set_config('gameon.businesses_privileged_write', p_business_id::text, true);

  UPDATE public.venues
  SET admin_status = v_new_status
  WHERE id = p_venue_id;

  UPDATE public.businesses
  SET entitlement_updated_at = now()
  WHERE id = p_business_id;

  SELECT to_jsonb(v) INTO v_after
  FROM public.venues v
  WHERE v.id = p_venue_id;

  INSERT INTO public.admin_audit_logs(admin_email, action, target_type, target_id, before_data, after_data, reason)
  VALUES (
    v_admin_email,
    CASE WHEN p_active THEN 'activate_business_venue' ELSE 'deactivate_business_venue' END,
    'venue',
    p_venue_id::text,
    v_before,
    jsonb_build_object('venue', v_after, 'business_id', p_business_id),
    CASE WHEN p_active THEN 'Admin activated venue' ELSE 'Admin deactivated venue' END
  );

  RETURN jsonb_build_object('ok', true, 'newStatus', v_new_status);
END;
$$;

COMMENT ON FUNCTION public.admin_set_business_venue_activation(uuid, uuid, text, boolean) IS
  'Admin venue activate/deactivate. Auth via is_support_inbox_admin() (JWT @fangeosports.com or service_role). '
  'Audit actor from JWT via support_inbox_admin_actor_email(); p_admin_email deprecated/ignored. '
  'Sets gameon.businesses_privileged_write when touching businesses.entitlement_updated_at.';

-- 3d) Legacy wrappers — must not bypass the secured 6-arg implementation.
--     Auth + GUC + audit live only in the 6-arg body above.

CREATE OR REPLACE FUNCTION public.admin_set_business_active_venue_limit_override(
  p_business_id uuid,
  p_admin_email text,
  p_override integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
BEGIN
  -- Delegates to secured 6-arg overload (is_support_inbox_admin + JWT audit).
  -- p_admin_email forwarded for signature compatibility only; ignored by callee.
  RETURN public.admin_set_business_active_venue_limit_override(
    p_business_id,
    p_admin_email,
    'custom',
    p_override,
    NULL,
    'Admin active venue limit override set'
  );
END;
$$;

COMMENT ON FUNCTION public.admin_set_business_active_venue_limit_override(uuid, text, integer) IS
  'Legacy 3-arg iOS wrapper. Delegates to secured 6-arg overload; cannot bypass JWT admin gate.';

CREATE OR REPLACE FUNCTION public.admin_clear_business_active_venue_limit_override(
  p_business_id uuid,
  p_admin_email text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
BEGIN
  RETURN public.admin_set_business_active_venue_limit_override(
    p_business_id,
    p_admin_email,
    'standard',
    NULL,
    NULL,
    'Admin active venue limit override cleared'
  );
END;
$$;

COMMENT ON FUNCTION public.admin_clear_business_active_venue_limit_override(uuid, text) IS
  'Clear override wrapper. Delegates to secured 6-arg overload; cannot bypass JWT admin gate.';

-- ---------------------------------------------------------------------------
-- 4) Table grants — remove anon writes; keep authenticated owner CRUD surface
-- ---------------------------------------------------------------------------

REVOKE ALL ON TABLE public.businesses FROM anon;
GRANT SELECT ON TABLE public.businesses TO anon;

REVOKE ALL ON TABLE public.businesses FROM authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.businesses TO authenticated;

-- service_role retains full access (Supabase default); reaffirm explicitly.
GRANT ALL ON TABLE public.businesses TO service_role;

-- ---------------------------------------------------------------------------
-- 5) EXECUTE grants — authenticated OK only because every overload gates internally
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.save_free_active_business_venues(uuid, uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.save_free_active_business_venues(uuid, uuid[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.save_free_active_business_venues(uuid, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_free_active_business_venues(uuid, uuid[]) TO service_role;

REVOKE ALL ON FUNCTION public.admin_set_business_active_venue_limit_override(uuid, text, text, integer, timestamptz, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_set_business_active_venue_limit_override(uuid, text, text, integer, timestamptz, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_set_business_active_venue_limit_override(uuid, text, text, integer, timestamptz, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_business_active_venue_limit_override(uuid, text, text, integer, timestamptz, text) TO service_role;

REVOKE ALL ON FUNCTION public.admin_set_business_active_venue_limit_override(uuid, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_set_business_active_venue_limit_override(uuid, text, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_set_business_active_venue_limit_override(uuid, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_business_active_venue_limit_override(uuid, text, integer) TO service_role;

REVOKE ALL ON FUNCTION public.admin_clear_business_active_venue_limit_override(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_clear_business_active_venue_limit_override(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_clear_business_active_venue_limit_override(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_clear_business_active_venue_limit_override(uuid, text) TO service_role;

REVOKE ALL ON FUNCTION public.admin_set_business_venue_activation(uuid, uuid, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_set_business_venue_activation(uuid, uuid, text, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_set_business_venue_activation(uuid, uuid, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_business_venue_activation(uuid, uuid, text, boolean) TO service_role;

COMMIT;

-- =============================================================================
-- Post-apply validation (SELECT-only; run manually after apply)
-- =============================================================================
--
-- -- Triggers present
-- SELECT tgname, pg_get_triggerdef(oid)
-- FROM pg_trigger
-- WHERE tgrelid = 'public.businesses'::regclass
--   AND NOT tgisinternal
--   AND tgname IN ('trg_businesses_privileged_columns', 'trg_businesses_privileged_insert')
-- ORDER BY tgname;
--
-- -- INSERT trigger forces entitlement_updated_at = now() (no coalesce of client value)
-- SELECT pg_get_functiondef('public.enforce_businesses_privileged_insert()'::regprocedure)
--   ILIKE '%entitlement_updated_at := now()%' AS forces_now,
--   pg_get_functiondef('public.enforce_businesses_privileged_insert()'::regprocedure)
--   ILIKE '%coalesce(NEW.entitlement_updated_at%' AS has_bad_coalesce;
-- -- Expect: forces_now=true, has_bad_coalesce=false
--
-- -- Table grants (anon should have SELECT only)
-- SELECT grantee, privilege_type
-- FROM information_schema.role_table_grants
-- WHERE table_schema = 'public' AND table_name = 'businesses'
--   AND grantee IN ('anon', 'authenticated', 'service_role')
-- ORDER BY grantee, privilege_type;
--
-- -- RLS update policies still exist for owners (identity edits)
-- SELECT polname, cmd, roles::text
-- FROM pg_policy
-- WHERE polrelid = 'public.businesses'::regclass
-- ORDER BY polname;
--
-- -- Guard functions not callable by clients
-- SELECT p.proname, r.rolname AS grantee, has_function_privilege(r.oid, p.oid, 'EXECUTE') AS can_execute
-- FROM pg_proc p
-- CROSS JOIN pg_roles r
-- WHERE p.pronamespace = 'public'::regnamespace
--   AND p.proname IN ('enforce_businesses_privileged_columns', 'enforce_businesses_privileged_insert')
--   AND r.rolname IN ('anon', 'authenticated', 'service_role')
-- ORDER BY p.proname, r.rolname;
--
-- -- EXECUTE grants by overload (authenticated retained; each overload must gate internally)
-- SELECT
--   p.proname,
--   pg_get_function_identity_arguments(p.oid) AS args,
--   r.rolname AS grantee,
--   has_function_privilege(r.oid, p.oid, 'EXECUTE') AS can_execute
-- FROM pg_proc p
-- CROSS JOIN pg_roles r
-- WHERE p.pronamespace = 'public'::regnamespace
--   AND p.proname IN (
--     'save_free_active_business_venues',
--     'admin_set_business_active_venue_limit_override',
--     'admin_clear_business_active_venue_limit_override',
--     'admin_set_business_venue_activation',
--     'support_inbox_admin_actor_email',
--     'is_support_inbox_admin'
--   )
--   AND r.rolname IN ('anon', 'authenticated', 'service_role')
-- ORDER BY p.proname, args, r.rolname;
-- -- Expect:
-- --   admin_* overloads          → authenticated=true, service_role=true, anon=false
-- --   support_inbox_admin_actor_email → authenticated=false, anon=false, service_role=true
-- --   is_support_inbox_admin     → authenticated=true, service_role=true, anon=false
--
-- -- Admin bodies contain is_support_inbox_admin() and do NOT use p_admin_email for auth/audit
-- SELECT
--   proname,
--   pg_get_function_identity_arguments(oid) AS args,
--   (pg_get_functiondef(oid) ILIKE '%is_support_inbox_admin()%') AS has_admin_gate,
--   (pg_get_functiondef(oid) ILIKE '%support_inbox_admin_actor_email%') AS uses_jwt_actor,
--   (pg_get_functiondef(oid) ILIKE '%NULLIF(btrim(p_admin_email)%') AS still_trusts_p_admin_email
-- FROM pg_proc
-- WHERE pronamespace = 'public'::regnamespace
--   AND proname IN (
--     'admin_set_business_active_venue_limit_override',
--     'admin_set_business_venue_activation'
--   )
-- ORDER BY proname, args;
-- -- Expect 6-arg override + venue_activation: has_admin_gate=true, uses_jwt_actor=true,
-- --         still_trusts_p_admin_email=false
-- -- Expect 3-arg wrapper: delegates only (no privileged GUC of its own)
--
-- -- Confirm GUC set only after auth in privileged-write RPCs
-- SELECT proname, pg_get_function_identity_arguments(oid) AS args
-- FROM pg_proc
-- WHERE pronamespace = 'public'::regnamespace
--   AND proname IN (
--     'save_free_active_business_venues',
--     'admin_set_business_active_venue_limit_override',
--     'admin_set_business_venue_activation'
--   )
--   AND pg_get_functiondef(oid) ILIKE '%gameon.businesses_privileged_write%'
-- ORDER BY proname, args;
--
-- -- Protected column inventory
-- SELECT column_name
-- FROM information_schema.columns
-- WHERE table_schema = 'public' AND table_name = 'businesses'
--   AND column_name IN (
--     'plan_type','plan_status','pro_expires_at','entitlement_updated_at',
--     'venue_limit','monthly_host_limit','statistics_enabled','sponsored_enabled',
--     'unlimited_venues','unlimited_hosting',
--     'admin_pro_promo_batch_id','admin_pro_promo_starts_at','admin_pro_promo_ends_at',
--     'admin_pro_promo_reason','admin_pro_promo_updated_at','admin_pro_promo_updated_by',
--     'exclude_from_global_business_pro_promo','global_business_pro_promo_excluded_at',
--     'global_business_pro_promo_excluded_by','global_business_pro_promo_exclusion_reason',
--     'admin_active_venue_limit_override','admin_unlimited_active_venues_override',
--     'admin_venue_override_expires_at','admin_venue_override_reason',
--     'admin_venue_override_updated_by','admin_venue_override_updated_at'
--   )
-- ORDER BY column_name;
--
-- =============================================================================
-- Staging test matrix (manual)
-- =============================================================================
-- 1)  Normal business owner edits display_name / business_handle → success
-- 2)  Owner directly UPDATE plan_type (or plan_status / pro_expires_at / promo / override) → 42501
-- 3)  Owner INSERT business with Pro / promo / override values → stored as Free; entitlement_updated_at = server now
-- 4)  Owner calls admin_set_business_active_venue_limit_override (own business) with forged
--     p_admin_email='spoof@fangeosports.com' → 42501 not authorized
-- 5)  Owner calls admin_set_business_venue_activation with forged admin email → 42501
-- 6)  Owner targets another business_id via either admin RPC → 42501 (admin gate fails first)
-- 7)  Real @fangeosports.com JWT admin → both admin RPCs succeed
-- 8)  service_role → both admin RPCs succeed; audit actor = 'service_role' when no JWT email
-- 9)  Audit rows record JWT actor email, NOT client-supplied p_admin_email
-- 10) Existing Admin Dashboard iOS calls (3-arg + 6-arg + clear + venue activation) remain compatible
-- 11) Free active venue selection (save_free_active_business_venues) remains functional for owner
-- 12) Owner cannot alter plan/promo via save_free_active_business_venues (UPDATE only
--     free_active_venues_selected_at + entitlement_updated_at)
-- 13) 3-arg admin_set_business_active_venue_limit_override cannot bypass 6-arg admin gate
-- 14) admin_clear_business_active_venue_limit_override delegates to secured 6-arg
-- 15) service_role admin_apply_* promo grant → success (role bypass; no GUC required)
-- 16) anon INSERT/UPDATE/DELETE businesses → permission denied
-- 17) Debug / Release iOS builds: no signature changes required (p_admin_email retained)
--
-- =============================================================================
-- Privileged-write RPC auth summary
-- =============================================================================
-- | RPC / overload                                              | Auth class                          |
-- |-------------------------------------------------------------|-------------------------------------|
-- | save_free_active_business_venues(uuid, uuid[])              | Owner (business_entitlement_caller_owns_business) |
-- | admin_set_business_active_venue_limit_override(6-arg)       | is_support_inbox_admin() JWT/service_role |
-- | admin_set_business_active_venue_limit_override(3-arg)       | Delegates → 6-arg (same gate)       |
-- | admin_clear_business_active_venue_limit_override(2-arg)     | Delegates → 6-arg (same gate)       |
-- | admin_set_business_venue_activation(4-arg)                  | is_support_inbox_admin() JWT/service_role |
-- | admin_apply_* / admin_reopen_* / global exclusion (optional)| service_role EXECUTE only           |
-- | deletion / reactivation cores                               | existing GUCs (not client-callable) |
--
-- =============================================================================
-- Rollback (manual; do not run unless reverting)
-- =============================================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS trg_businesses_privileged_columns ON public.businesses;
-- DROP TRIGGER IF EXISTS trg_businesses_privileged_insert ON public.businesses;
-- DROP FUNCTION IF EXISTS public.enforce_businesses_privileged_columns();
-- DROP FUNCTION IF EXISTS public.enforce_businesses_privileged_insert();
-- -- Restore prior save_free_active / admin override / activation / clear bodies from
-- -- 20260851 / 20260840 if needed (redeploy those function definitions).
-- GRANT ALL ON TABLE public.businesses TO anon;
-- GRANT ALL ON TABLE public.businesses TO authenticated;
-- COMMIT;
