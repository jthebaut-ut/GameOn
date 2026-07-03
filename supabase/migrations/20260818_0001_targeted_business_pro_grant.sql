-- Targeted Business Pro grants by managed-venue geography (country / state / city).

ALTER TABLE public.business_promotion_batches
  ADD COLUMN IF NOT EXISTS target_filters jsonb NULL;

COMMENT ON COLUMN public.business_promotion_batches.target_filters IS
  'Optional geographic filters for targeted Business Pro grant batches: { country, state, city }.';

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'business_promotion_batches_action_type_check'
  ) THEN
    ALTER TABLE public.business_promotion_batches
      DROP CONSTRAINT business_promotion_batches_action_type_check;
  END IF;

  ALTER TABLE public.business_promotion_batches
    ADD CONSTRAINT business_promotion_batches_action_type_check
    CHECK (action_type IN (
      'regular_business_promo_grant',
      'targeted_business_pro_promo_grant',
      'existing_pro_business_extension',
      'rollback'
    ));
END $$;

CREATE OR REPLACE FUNCTION public.business_promotion_normalize_country(input text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT CASE
    WHEN lower(btrim(coalesce(input, ''))) IN (
      'us',
      'usa',
      'u.s.',
      'u.s.a.',
      'united states',
      'united states of america'
    ) THEN 'united states'
    ELSE lower(btrim(coalesce(input, '')))
  END;
$$;

CREATE OR REPLACE FUNCTION public.business_promotion_country_matches(
  venue_country text,
  filter_country text
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT
    coalesce(btrim(filter_country), '') = ''
    OR (
      public.business_promotion_normalize_country(venue_country) <> ''
      AND public.business_promotion_normalize_country(venue_country) =
        public.business_promotion_normalize_country(filter_country)
    );
$$;

CREATE OR REPLACE FUNCTION public.business_promotion_state_matches(
  venue_state text,
  venue_region text,
  filter_state text
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT
    coalesce(btrim(filter_state), '') = ''
    OR lower(btrim(coalesce(venue_state, ''))) = lower(btrim(filter_state))
    OR lower(btrim(coalesce(venue_region, ''))) = lower(btrim(filter_state))
    OR coalesce(venue_state, '') ILIKE filter_state
    OR coalesce(venue_region, '') ILIKE filter_state;
$$;

CREATE OR REPLACE FUNCTION public.business_promotion_city_matches(
  venue_city text,
  filter_city text
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT
    coalesce(btrim(filter_city), '') = ''
    OR lower(btrim(coalesce(venue_city, ''))) = lower(btrim(filter_city))
    OR coalesce(venue_city, '') ILIKE filter_city;
$$;

CREATE OR REPLACE FUNCTION public.business_managed_venue_location_matches(
  p_business_id uuid,
  p_country text DEFAULT NULL,
  p_state text DEFAULT NULL,
  p_city text DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.admin_business_managed_venue_ids(p_business_id) mv
    JOIN public.venues v ON v.id = mv.venue_id
    WHERE lower(btrim(coalesce(v.admin_status, 'active'))) IN ('active', 'plan_locked')
      AND public.business_promotion_country_matches(v.country, p_country)
      AND public.business_promotion_state_matches(v.state, v.region, p_state)
      AND public.business_promotion_city_matches(v.city, p_city)
  );
$$;

CREATE OR REPLACE FUNCTION public.admin_business_promotion_targeted_preview(
  p_country text DEFAULT NULL,
  p_state text DEFAULT NULL,
  p_city text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_country text := nullif(btrim(coalesce(p_country, '')), '');
  v_state text := nullif(btrim(coalesce(p_state, '')), '');
  v_city text := nullif(btrim(coalesce(p_city, '')), '');
  v_targeted_count integer := 0;
BEGIN
  IF v_country IS NULL AND v_state IS NULL AND v_city IS NULL THEN
    RAISE EXCEPTION 'missing_target_filters' USING ERRCODE = '22023';
  END IF;

  SELECT count(*)::integer
    INTO v_targeted_count
  FROM public.businesses b
  WHERE public.business_regular_promo_grant_target(b)
    AND public.business_managed_venue_location_matches(b.id, v_country, v_state, v_city);

  RETURN jsonb_build_object(
    'targetedGrantTargetCount', v_targeted_count,
    'filters', jsonb_build_object(
      'country', coalesce(v_country, ''),
      'state', coalesce(v_state, ''),
      'city', coalesce(v_city, '')
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_apply_targeted_business_pro_grant(
  p_admin_email text,
  p_ends_at timestamptz,
  p_reason text,
  p_country text DEFAULT NULL,
  p_state text DEFAULT NULL,
  p_city text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
DECLARE
  v_batch_id uuid;
  v_affected integer := 0;
  v_business_id uuid;
  v_preview jsonb;
  v_country text := nullif(btrim(coalesce(p_country, '')), '');
  v_state text := nullif(btrim(coalesce(p_state, '')), '');
  v_city text := nullif(btrim(coalesce(p_city, '')), '');
  v_target_filters jsonb;
BEGIN
  IF p_ends_at IS NULL OR p_ends_at <= now() THEN
    RAISE EXCEPTION 'invalid_promotion_end_date' USING ERRCODE = '22023';
  END IF;

  IF v_country IS NULL AND v_state IS NULL AND v_city IS NULL THEN
    RAISE EXCEPTION 'missing_target_filters' USING ERRCODE = '22023';
  END IF;

  v_target_filters := jsonb_build_object(
    'country', coalesce(v_country, ''),
    'state', coalesce(v_state, ''),
    'city', coalesce(v_city, '')
  );

  v_preview := public.admin_business_promotion_targeted_preview(v_country, v_state, v_city);

  INSERT INTO public.business_promotion_batches (
    action_type,
    promotion_key,
    admin_email,
    reason,
    requested_ends_at,
    preview_data,
    target_filters
  )
  VALUES (
    'targeted_business_pro_promo_grant',
    'targeted_business_pro_grant',
    COALESCE(NULLIF(btrim(p_admin_email), ''), 'unknown'),
    NULLIF(btrim(COALESCE(p_reason, '')), ''),
    p_ends_at,
    v_preview,
    v_target_filters
  )
  RETURNING id INTO v_batch_id;

  INSERT INTO public.business_promotion_batch_items (batch_id, business_id, before_data)
  SELECT
    v_batch_id,
    b.id,
    jsonb_build_object(
      'admin_pro_promo_starts_at', b.admin_pro_promo_starts_at,
      'admin_pro_promo_ends_at', b.admin_pro_promo_ends_at,
      'admin_pro_promo_reason', b.admin_pro_promo_reason,
      'admin_pro_promo_batch_id', b.admin_pro_promo_batch_id,
      'admin_pro_promo_updated_at', b.admin_pro_promo_updated_at,
      'admin_pro_promo_updated_by', b.admin_pro_promo_updated_by,
      'entitlement_updated_at', b.entitlement_updated_at
    )
  FROM public.businesses b
  WHERE public.business_regular_promo_grant_target(b)
    AND public.business_managed_venue_location_matches(b.id, v_country, v_state, v_city);

  UPDATE public.businesses b
  SET
    admin_pro_promo_starts_at = now(),
    admin_pro_promo_ends_at = p_ends_at,
    admin_pro_promo_reason = NULLIF(btrim(COALESCE(p_reason, '')), ''),
    admin_pro_promo_batch_id = v_batch_id,
    admin_pro_promo_updated_at = now(),
    admin_pro_promo_updated_by = COALESCE(NULLIF(btrim(p_admin_email), ''), 'unknown'),
    entitlement_updated_at = now()
  WHERE EXISTS (
    SELECT 1
    FROM public.business_promotion_batch_items i
    WHERE i.batch_id = v_batch_id
      AND i.business_id = b.id
  );

  UPDATE public.business_promotion_batch_items i
  SET after_data = jsonb_build_object(
    'admin_pro_promo_starts_at', b.admin_pro_promo_starts_at,
    'admin_pro_promo_ends_at', b.admin_pro_promo_ends_at,
    'admin_pro_promo_reason', b.admin_pro_promo_reason,
    'admin_pro_promo_batch_id', b.admin_pro_promo_batch_id,
    'admin_pro_promo_updated_at', b.admin_pro_promo_updated_at,
    'admin_pro_promo_updated_by', b.admin_pro_promo_updated_by,
    'entitlement_updated_at', b.entitlement_updated_at
  )
  FROM public.businesses b
  WHERE i.batch_id = v_batch_id
    AND b.id = i.business_id;

  SELECT count(*)::integer
    INTO v_affected
  FROM public.business_promotion_batch_items
  WHERE batch_id = v_batch_id;

  UPDATE public.business_promotion_batches
  SET affected_count = v_affected,
      skipped_count = GREATEST(
        0,
        COALESCE((v_preview ->> 'targetedGrantTargetCount')::integer, 0) - v_affected
      )
  WHERE id = v_batch_id;

  FOR v_business_id IN
    SELECT business_id
    FROM public.business_promotion_batch_items
    WHERE batch_id = v_batch_id
  LOOP
    PERFORM public.enforce_business_plan_venue_locks(v_business_id);
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'batchId', v_batch_id,
    'affectedCount', v_affected,
    'targetFilters', v_target_filters
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_rollback_business_promotion_batch(
  p_batch_id uuid,
  p_admin_email text,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
DECLARE
  v_batch public.business_promotion_batches%ROWTYPE;
  v_restored integer := 0;
  v_business_id uuid;
BEGIN
  SELECT *
    INTO v_batch
  FROM public.business_promotion_batches
  WHERE id = p_batch_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'promotion_batch_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF v_batch.status = 'rolled_back' THEN
    RAISE EXCEPTION 'promotion_batch_already_rolled_back' USING ERRCODE = 'P0001';
  END IF;

  IF v_batch.action_type IN ('regular_business_promo_grant', 'targeted_business_pro_promo_grant') THEN
    UPDATE public.businesses b
    SET
      admin_pro_promo_starts_at = NULLIF(i.before_data ->> 'admin_pro_promo_starts_at', '')::timestamptz,
      admin_pro_promo_ends_at = NULLIF(i.before_data ->> 'admin_pro_promo_ends_at', '')::timestamptz,
      admin_pro_promo_reason = i.before_data ->> 'admin_pro_promo_reason',
      admin_pro_promo_batch_id = NULLIF(i.before_data ->> 'admin_pro_promo_batch_id', '')::uuid,
      admin_pro_promo_updated_at = NULLIF(i.before_data ->> 'admin_pro_promo_updated_at', '')::timestamptz,
      admin_pro_promo_updated_by = i.before_data ->> 'admin_pro_promo_updated_by',
      entitlement_updated_at = COALESCE(NULLIF(i.before_data ->> 'entitlement_updated_at', '')::timestamptz, now())
    FROM public.business_promotion_batch_items i
    WHERE i.batch_id = p_batch_id
      AND i.business_id = b.id;
  ELSIF v_batch.action_type = 'existing_pro_business_extension' THEN
    UPDATE public.businesses b
    SET
      plan_type = COALESCE(NULLIF(i.before_data ->> 'plan_type', ''), 'free'),
      plan_status = COALESCE(NULLIF(i.before_data ->> 'plan_status', ''), 'active'),
      pro_expires_at = NULLIF(i.before_data ->> 'pro_expires_at', '')::timestamptz,
      statistics_enabled = COALESCE((i.before_data ->> 'statistics_enabled')::boolean, false),
      sponsored_enabled = COALESCE((i.before_data ->> 'sponsored_enabled')::boolean, false),
      unlimited_venues = COALESCE((i.before_data ->> 'unlimited_venues')::boolean, false),
      unlimited_hosting = COALESCE((i.before_data ->> 'unlimited_hosting')::boolean, false),
      venue_limit = COALESCE((i.before_data ->> 'venue_limit')::integer, 5),
      monthly_host_limit = COALESCE((i.before_data ->> 'monthly_host_limit')::integer, 5),
      entitlement_updated_at = COALESCE(NULLIF(i.before_data ->> 'entitlement_updated_at', '')::timestamptz, now())
    FROM public.business_promotion_batch_items i
    WHERE i.batch_id = p_batch_id
      AND i.business_id = b.id;
  ELSE
    RAISE EXCEPTION 'promotion_batch_not_rollbackable' USING ERRCODE = 'P0001';
  END IF;

  GET DIAGNOSTICS v_restored = ROW_COUNT;

  UPDATE public.business_promotion_batches
  SET
    status = 'rolled_back',
    rollback_reason = NULLIF(btrim(COALESCE(p_reason, '')), ''),
    rolled_back_at = now(),
    rolled_back_by = COALESCE(NULLIF(btrim(p_admin_email), ''), 'unknown')
  WHERE id = p_batch_id;

  FOR v_business_id IN
    SELECT business_id
    FROM public.business_promotion_batch_items
    WHERE batch_id = p_batch_id
  LOOP
    PERFORM public.enforce_business_plan_venue_locks(v_business_id);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'batchId', p_batch_id, 'restoredCount', v_restored);
END;
$$;

REVOKE ALL ON FUNCTION public.business_promotion_normalize_country(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.business_promotion_country_matches(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.business_promotion_state_matches(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.business_promotion_city_matches(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.business_managed_venue_location_matches(uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_business_promotion_targeted_preview(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_apply_targeted_business_pro_grant(text, timestamptz, text, text, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_business_promotion_targeted_preview(text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_apply_targeted_business_pro_grant(text, timestamptz, text, text, text, text) TO service_role;

COMMENT ON FUNCTION public.business_managed_venue_location_matches(uuid, text, text, text) IS
  'True when any active managed venue for the business matches the optional country/state/city filters.';
COMMENT ON FUNCTION public.admin_business_promotion_targeted_preview(text, text, text) IS
  'Admin preview count for targeted Business Pro grants. Requires at least one geographic filter.';
COMMENT ON FUNCTION public.admin_apply_targeted_business_pro_grant(text, timestamptz, text, text, text, text) IS
  'Bulk grants admin Pro promo to eligible businesses with at least one managed venue in the target geography.';

NOTIFY pgrst, 'reload schema';
