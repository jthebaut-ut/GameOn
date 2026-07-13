-- Admin active-venue limit override modes for Business Free:
-- standard (no override) | custom integer | unlimited
-- Optional expiration; expired overrides no longer affect effective limit.
-- Does not change default Free venue_limit (5) or convert Free → Pro.

ALTER TABLE public.businesses
  ADD COLUMN IF NOT EXISTS admin_unlimited_active_venues_override boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS admin_venue_override_expires_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS admin_venue_override_reason text NULL,
  ADD COLUMN IF NOT EXISTS admin_venue_override_updated_by text NULL,
  ADD COLUMN IF NOT EXISTS admin_venue_override_updated_at timestamptz NULL;

COMMENT ON COLUMN public.businesses.admin_active_venue_limit_override IS
  'Admin custom Free active-venue cap. NULL with unlimited flag false = standard plan limit. Ignored when admin_unlimited_active_venues_override is true or override is expired.';

COMMENT ON COLUMN public.businesses.admin_unlimited_active_venues_override IS
  'When true and not expired, Free businesses may activate unlimited approved managed venues without becoming Pro.';

COMMENT ON COLUMN public.businesses.admin_venue_override_expires_at IS
  'Optional expiration for admin venue capacity override. NULL = no expiration. Past timestamps deactivate the override.';

-- Canonical effective active-venue limit for a business row.
-- NULL = unlimited (Pro plan OR active admin unlimited override).
CREATE OR REPLACE FUNCTION public.business_effective_active_venue_limit(b public.businesses)
RETURNS integer
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT CASE
    WHEN public.admin_venue_override_is_pro(b) THEN NULL::integer
    WHEN COALESCE(b.admin_unlimited_active_venues_override, false)
      AND (b.admin_venue_override_expires_at IS NULL OR b.admin_venue_override_expires_at > now())
      THEN NULL::integer
    WHEN b.admin_active_venue_limit_override IS NOT NULL
      AND b.admin_active_venue_limit_override > 0
      AND (b.admin_venue_override_expires_at IS NULL OR b.admin_venue_override_expires_at > now())
      THEN GREATEST(1, b.admin_active_venue_limit_override)
    ELSE GREATEST(0, COALESCE(NULLIF(b.venue_limit, 0), 5))
  END;
$$;

-- Keep legacy 3-arg helper for older call sites; prefer business_effective_active_venue_limit.
CREATE OR REPLACE FUNCTION public.admin_venue_override_effective_limit(
  p_is_pro boolean,
  p_venue_limit integer,
  p_override integer
)
RETURNS integer
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT CASE
    WHEN p_is_pro THEN NULL::integer
    WHEN p_override IS NOT NULL AND p_override > 0 THEN GREATEST(1, p_override)
    ELSE GREATEST(0, COALESCE(NULLIF(p_venue_limit, 0), 5))
  END;
$$;

CREATE OR REPLACE FUNCTION public.enforce_business_plan_venue_locks(p_business_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
DECLARE
  v_business public.businesses%ROWTYPE;
  v_plan_type text;
  v_plan_status text;
  v_is_pro_active boolean;
  v_effective_limit integer;
  v_active_venue_count integer := 0;
  v_row record;
BEGIN
  SELECT *
    INTO v_business
  FROM public.businesses
  WHERE id = p_business_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_plan_type := COALESCE(NULLIF(btrim(v_business.plan_type), ''), 'free');
  v_plan_status := COALESCE(NULLIF(btrim(v_business.plan_status), ''), 'active');
  v_is_pro_active := public.admin_venue_override_is_pro(v_business);
  v_effective_limit := public.business_effective_active_venue_limit(v_business);

  PERFORM set_config('app.business_plan_lock_enforcement', 'on', true);

  SELECT count(*)::integer
    INTO v_active_venue_count
  FROM public.venues v
  WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id))
    AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active';

  -- Pro OR active unlimited Free override: unlock plan_locked managed venues.
  IF v_effective_limit IS NULL THEN
    FOR v_row IN
      UPDATE public.venues v
      SET admin_status = 'active'
      WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id))
        AND lower(btrim(coalesce(v.admin_status, ''))) = 'plan_locked'
      RETURNING v.id
    LOOP
      RAISE NOTICE '[BusinessPlanLock] businessId=% venueId=% previousStatus=% newStatus=% activeVenueCount=% planType=% planStatus=% downgradeDetected=%',
        p_business_id, v_row.id, 'plan_locked', 'active', v_active_venue_count, v_plan_type, v_plan_status, false;
    END LOOP;
    RETURN;
  END IF;

  FOR v_row IN
    WITH ranked AS (
      SELECT
        v.id,
        coalesce(nullif(btrim(v.admin_status), ''), 'active') AS previous_status,
        row_number() OVER (ORDER BY v.created_at DESC NULLS LAST, v.id DESC) AS active_rank
      FROM public.venues v
      WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id))
        AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active'
    )
    UPDATE public.venues v
    SET admin_status = 'plan_locked'
    FROM ranked r
    WHERE v.id = r.id
      AND r.active_rank > COALESCE(v_effective_limit, 0)
    RETURNING v.id, r.previous_status
  LOOP
    RAISE NOTICE '[BusinessPlanLock] businessId=% venueId=% previousStatus=% newStatus=% activeVenueCount=% planType=% planStatus=% downgradeDetected=%',
      p_business_id, v_row.id, v_row.previous_status, 'plan_locked', v_active_venue_count, v_plan_type, v_plan_status, true;
  END LOOP;
END;
$$;

DROP TRIGGER IF EXISTS trg_businesses_enforce_plan_venue_locks ON public.businesses;
CREATE TRIGGER trg_businesses_enforce_plan_venue_locks
AFTER INSERT OR UPDATE OF
  plan_type,
  plan_status,
  pro_expires_at,
  unlimited_venues,
  unlimited_hosting,
  venue_limit,
  monthly_host_limit,
  admin_active_venue_limit_override,
  admin_unlimited_active_venues_override,
  admin_venue_override_expires_at
ON public.businesses
FOR EACH ROW
EXECUTE FUNCTION public.trg_enforce_business_plan_venue_locks();

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
BEGIN
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

  UPDATE public.businesses
  SET
    admin_active_venue_limit_override = CASE WHEN v_mode = 'standard' THEN NULL ELSE v_override END,
    admin_unlimited_active_venues_override = v_unlimited,
    admin_venue_override_expires_at = CASE WHEN v_mode = 'standard' THEN NULL ELSE p_expires_at END,
    admin_venue_override_reason = CASE WHEN v_mode = 'standard' THEN NULL ELSE v_reason END,
    admin_venue_override_updated_by = COALESCE(NULLIF(btrim(p_admin_email), ''), 'unknown'),
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

  -- If reducing below current active count, skip auto-lock so the admin can choose
  -- which venues remain active (dashboard applies selection, then locks).
  IF v_after_limit IS NULL OR v_active_count <= COALESCE(v_after_limit, 0) THEN
    PERFORM public.enforce_business_plan_venue_locks(p_business_id);
  END IF;

  SELECT to_jsonb(b) INTO v_after
  FROM public.businesses b
  WHERE b.id = p_business_id;

  INSERT INTO public.admin_audit_logs(admin_email, action, target_type, target_id, before_data, after_data, reason)
  VALUES (
    COALESCE(NULLIF(btrim(p_admin_email), ''), 'unknown'),
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
BEGIN
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
    COALESCE(NULLIF(btrim(p_admin_email), ''), 'unknown'),
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

  -- NULL effective limit = unlimited Free override.
  IF v_venue_limit IS NOT NULL AND v_selected_count > v_venue_limit THEN
    RAISE EXCEPTION 'active_venue_limit_exceeded' USING ERRCODE = 'P0001';
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
  WHERE id = p_business_id;

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

-- Fold override into venue_limit for Free without flipping is_pro_active / unlimited_venues.
-- Unlimited Free override returns venue_limit = 999999 while unlimited_venues stays false.
CREATE OR REPLACE FUNCTION public.get_business_entitlements_v2(p_business_id uuid)
RETURNS TABLE (
  business_id uuid,
  plan_type text,
  plan_status text,
  pro_expires_at timestamptz,
  is_pro_active boolean,
  days_remaining integer,
  statistics_enabled boolean,
  sponsored_enabled boolean,
  unlimited_venues boolean,
  unlimited_hosting boolean,
  venue_limit integer,
  monthly_host_limit integer,
  hosted_game_cycle_bonus_games integer,
  effective_monthly_host_limit integer,
  venues_used integer,
  hosted_games_this_month integer,
  hosted_games_used_this_cycle integer,
  hosted_game_cycle_start_at timestamptz,
  hosted_game_cycle_end_at timestamptz,
  next_reset_at timestamptz,
  entitlement_source text,
  entitlement_updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
DECLARE
  v_business public.businesses%ROWTYPE;
  v_plan_type text;
  v_plan_status text;
  v_individual_pro_active boolean;
  v_admin_promo_active boolean;
  v_global_promo_applies boolean;
  v_global_promo_ends_at timestamptz;
  v_effective_pro_expires_at timestamptz;
  v_is_pro_active boolean;
  v_unlimited_hosting boolean;
  v_venues_used integer := 0;
  v_hosted_games_used integer := 0;
  v_cycle_start_at timestamptz;
  v_next_reset_at timestamptz;
  v_effective_venue_limit integer;
  v_base_monthly_host_limit integer;
  v_active_cycle_bonus integer := 0;
  v_effective_monthly_host_limit integer;
  v_entitlement_source text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '28000';
  END IF;

  SELECT *
    INTO v_business
  FROM public.businesses
  WHERE id = p_business_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business not found: %', p_business_id USING ERRCODE = 'P0002';
  END IF;

  IF NOT public.business_entitlement_caller_can_read(p_business_id) THEN
    RAISE EXCEPTION 'Not authorized to read business entitlements.' USING ERRCODE = '42501';
  END IF;

  PERFORM public.enforce_business_plan_venue_locks(p_business_id);

  -- Re-read after lock enforcement may have mutated venues only (business row unchanged).
  SELECT *
    INTO v_business
  FROM public.businesses
  WHERE id = p_business_id;

  v_plan_type := COALESCE(NULLIF(btrim(v_business.plan_type), ''), 'free');
  v_plan_status := COALESCE(NULLIF(btrim(v_business.plan_status), ''), 'active');
  v_individual_pro_active := public.business_individual_pro_is_active(v_business);
  v_admin_promo_active := public.business_admin_pro_promo_is_active(v_business);

  SELECT s.ends_at
    INTO v_global_promo_ends_at
  FROM public.business_promotion_settings s
  WHERE s.promotion_key = 'global_business_pro'
    AND s.enabled = true
    AND (s.starts_at IS NULL OR now() >= s.starts_at)
    AND (s.ends_at IS NULL OR now() <= s.ends_at)
  LIMIT 1;

  v_global_promo_applies := public.global_business_pro_promotion_applies_to(v_business);
  v_effective_pro_expires_at := CASE
    WHEN v_individual_pro_active THEN v_business.pro_expires_at
    WHEN v_admin_promo_active THEN v_business.admin_pro_promo_ends_at
    WHEN v_global_promo_applies THEN v_global_promo_ends_at
    ELSE v_business.pro_expires_at
  END;
  v_is_pro_active := v_individual_pro_active OR v_admin_promo_active OR v_global_promo_applies;
  v_entitlement_source := CASE
    WHEN v_individual_pro_active AND v_plan_type IN ('subscription_pro', 'pro_paid') THEN 'subscription_pro'
    WHEN v_individual_pro_active
      AND v_plan_type = 'pro_promo'
      AND COALESCE(v_business.exclude_from_global_business_pro_promo, false) THEN 'subscription_pro'
    WHEN v_individual_pro_active AND v_plan_type = 'pro_promo' THEN 'free_user_promo'
    WHEN v_individual_pro_active AND v_plan_type = 'manual_pro' THEN 'manual_pro'
    WHEN v_individual_pro_active THEN v_plan_type
    WHEN v_admin_promo_active THEN 'admin_pro_promo'
    WHEN v_global_promo_applies THEN 'global_business_pro'
    ELSE 'regular'
  END;
  v_unlimited_hosting := public.business_hosting_is_unlimited(v_business);
  v_effective_venue_limit := public.business_effective_active_venue_limit(v_business);

  SELECT w.cycle_start_at, w.next_reset_at
    INTO v_cycle_start_at, v_next_reset_at
  FROM public.business_hosted_game_cycle_window(
    v_business.hosted_game_cycle_anchor_at,
    v_business.hosted_game_cycle_override_at,
    now()
  ) w;

  v_base_monthly_host_limit := CASE
    WHEN v_unlimited_hosting AND NOT v_individual_pro_active THEN 999999
    WHEN v_unlimited_hosting THEN GREATEST(0, COALESCE(v_business.monthly_host_limit, 999999))
    ELSE GREATEST(0, COALESCE(v_business.monthly_host_limit, 5))
  END;

  IF NOT v_unlimited_hosting
     AND v_business.hosted_game_cycle_bonus_cycle_start_at IS NOT NULL
     AND v_business.hosted_game_cycle_bonus_cycle_start_at = v_cycle_start_at THEN
    v_active_cycle_bonus := GREATEST(0, COALESCE(v_business.hosted_game_cycle_bonus_games, 0));
  END IF;

  v_effective_monthly_host_limit := CASE
    WHEN v_unlimited_hosting THEN v_base_monthly_host_limit
    ELSE v_base_monthly_host_limit + v_active_cycle_bonus
  END;

  SELECT count(*)::integer
    INTO v_venues_used
  FROM public.venues v
  WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id))
    AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active';

  WITH business_venues AS (
    SELECT v.id
    FROM public.venues v
    WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id))
      AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active'
  ),
  event_ids AS (
    SELECT ve.id
    FROM public.venue_events ve
    LEFT JOIN public.venues v ON v.id = ve.venue_id
    WHERE ve.created_at >= v_cycle_start_at
      AND ve.created_at < v_next_reset_at
      AND lower(btrim(coalesce(ve.admin_status, 'active'))) = 'active'
      AND (
        ve.venue_id IN (SELECT id FROM business_venues)
        OR v.business_id = p_business_id
        OR (
          v_business.owner_email IS NOT NULL
          AND lower(btrim(coalesce(ve.owner_email, ''))) = lower(btrim(v_business.owner_email))
        )
      )
    UNION
    SELECT bgh.original_venue_event_id
    FROM public.business_game_history bgh
    WHERE bgh.business_id = p_business_id
      AND bgh.created_at >= v_cycle_start_at
      AND bgh.created_at < v_next_reset_at
      AND bgh.original_venue_event_id IS NOT NULL
  )
  SELECT count(DISTINCT id)::integer
    INTO v_hosted_games_used
  FROM event_ids
  WHERE id IS NOT NULL;

  RETURN QUERY
  SELECT
    v_business.id AS business_id,
    v_plan_type AS plan_type,
    v_plan_status AS plan_status,
    v_effective_pro_expires_at AS pro_expires_at,
    v_is_pro_active AS is_pro_active,
    CASE
      WHEN v_effective_pro_expires_at IS NULL THEN NULL
      WHEN v_is_pro_active THEN GREATEST(0, CEIL(EXTRACT(EPOCH FROM (v_effective_pro_expires_at - now())) / 86400.0)::integer)
      ELSE 0
    END AS days_remaining,
    CASE WHEN v_is_pro_active THEN COALESCE(v_business.statistics_enabled, false) OR v_admin_promo_active OR v_global_promo_applies ELSE false END AS statistics_enabled,
    CASE WHEN v_is_pro_active THEN COALESCE(v_business.sponsored_enabled, false) OR v_admin_promo_active OR v_global_promo_applies ELSE false END AS sponsored_enabled,
    -- Pro only. Free unlimited venue override must not flip this (iOS treats it as Pro).
    v_is_pro_active AS unlimited_venues,
    v_unlimited_hosting AS unlimited_hosting,
    CASE
      WHEN v_is_pro_active AND NOT v_individual_pro_active THEN 999999
      WHEN v_is_pro_active THEN GREATEST(0, COALESCE(v_business.venue_limit, 999999))
      WHEN v_effective_venue_limit IS NULL THEN 999999
      ELSE COALESCE(v_effective_venue_limit, 5)
    END AS venue_limit,
    v_base_monthly_host_limit AS monthly_host_limit,
    v_active_cycle_bonus AS hosted_game_cycle_bonus_games,
    v_effective_monthly_host_limit AS effective_monthly_host_limit,
    COALESCE(v_venues_used, 0) AS venues_used,
    COALESCE(v_hosted_games_used, 0) AS hosted_games_this_month,
    COALESCE(v_hosted_games_used, 0) AS hosted_games_used_this_cycle,
    v_cycle_start_at AS hosted_game_cycle_start_at,
    v_next_reset_at AS hosted_game_cycle_end_at,
    v_next_reset_at AS next_reset_at,
    v_entitlement_source AS entitlement_source,
    v_business.entitlement_updated_at AS entitlement_updated_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_business_venue_override_summaries(p_admin_email text)
RETURNS TABLE (
  business_id uuid,
  display_name text,
  owner_email text,
  plan_type text,
  plan_status text,
  computed_is_pro boolean,
  venue_limit integer,
  effective_venue_limit integer,
  admin_active_venue_limit_override integer,
  approved_count integer,
  active_count integer,
  locked_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH b AS (
    SELECT *
    FROM public.businesses
    WHERE lower(btrim(coalesce(admin_status, ''))) = 'active'
  ),
  counts AS (
    SELECT
      b.id AS business_id,
      count(DISTINCT v.id)::integer AS approved_count,
      count(DISTINCT v.id) FILTER (WHERE lower(btrim(coalesce(v.admin_status, 'active'))) = 'active')::integer AS active_count,
      count(DISTINCT v.id) FILTER (WHERE lower(btrim(coalesce(v.admin_status, 'active'))) = 'plan_locked')::integer AS locked_count
    FROM b
    LEFT JOIN public.venues v ON v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(b.id))
    GROUP BY b.id
  )
  SELECT
    b.id,
    b.display_name,
    b.owner_email,
    COALESCE(NULLIF(btrim(b.plan_type), ''), 'free') AS plan_type,
    COALESCE(NULLIF(btrim(b.plan_status), ''), 'active') AS plan_status,
    public.admin_venue_override_is_pro(b) AS computed_is_pro,
    COALESCE(b.venue_limit, 5) AS venue_limit,
    public.business_effective_active_venue_limit(b) AS effective_venue_limit,
    CASE
      WHEN COALESCE(b.admin_unlimited_active_venues_override, false)
        AND (b.admin_venue_override_expires_at IS NULL OR b.admin_venue_override_expires_at > now())
        THEN NULL
      WHEN b.admin_venue_override_expires_at IS NOT NULL AND b.admin_venue_override_expires_at <= now()
        THEN NULL
      ELSE b.admin_active_venue_limit_override
    END AS admin_active_venue_limit_override,
    COALESCE(c.approved_count, 0),
    COALESCE(c.active_count, 0),
    COALESCE(c.locked_count, 0)
  FROM b
  LEFT JOIN counts c ON c.business_id = b.id
  ORDER BY lower(coalesce(b.display_name, '')), b.created_at DESC;
END;
$$;

-- Legacy 3-arg setter (iOS AdminScreen) → custom mode, no expiration.
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

-- Keep 2-arg clear for iOS; optional reason overload for dashboard.
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

REVOKE ALL ON FUNCTION public.business_effective_active_venue_limit(public.businesses) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_set_business_active_venue_limit_override(uuid, text, text, integer, timestamptz, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_set_business_active_venue_limit_override(uuid, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_clear_business_active_venue_limit_override(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.business_effective_active_venue_limit(public.businesses) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_business_active_venue_limit_override(uuid, text, text, integer, timestamptz, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_business_active_venue_limit_override(uuid, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_clear_business_active_venue_limit_override(uuid, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
