-- Expand targeted Business Pro preview with regional business breakdown counts.

CREATE OR REPLACE FUNCTION public.business_promotion_target_region_matches(
  b public.businesses,
  p_country text DEFAULT NULL,
  p_state text DEFAULT NULL,
  p_city text DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT public.business_promotion_business_is_active(b)
    AND public.business_managed_venue_location_matches(b.id, p_country, p_state, p_city);
$$;

CREATE OR REPLACE FUNCTION public.business_promotion_effective_pro_active(b public.businesses)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT public.business_individual_pro_is_active(b)
    OR public.business_admin_pro_promo_is_active(b)
    OR public.global_business_pro_promotion_applies_to(b);
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
  v_result jsonb;
BEGIN
  IF v_country IS NULL AND v_state IS NULL AND v_city IS NULL THEN
    RAISE EXCEPTION 'missing_target_filters' USING ERRCODE = '22023';
  END IF;

  WITH region_businesses AS (
    SELECT b.*
    FROM public.businesses b
    WHERE public.business_promotion_target_region_matches(b, v_country, v_state, v_city)
  ),
  classified AS (
    SELECT
      b.id,
      public.business_promotion_effective_pro_active(b) AS effective_pro_active,
      public.business_regular_promo_grant_target(b) AS grant_target,
      (
        COALESCE(NULLIF(btrim(b.plan_type), ''), 'free') IN ('manual_pro', 'pro_paid')
        AND public.business_individual_pro_is_active(b)
      ) AS subscription_pro_skipped
    FROM region_businesses b
  )
  SELECT jsonb_build_object(
    'totalBusinessesInRegion', count(*)::integer,
    'currentBusinessProCount', count(*) FILTER (WHERE effective_pro_active)::integer,
    'regularBusinessCount', count(*) FILTER (WHERE NOT effective_pro_active)::integer,
    'targetedGrantTargetCount', count(*) FILTER (WHERE grant_target)::integer,
    'subscriptionProSkippedCount', count(*) FILTER (WHERE subscription_pro_skipped)::integer,
    'filters', jsonb_build_object(
      'country', coalesce(v_country, ''),
      'state', coalesce(v_state, ''),
      'city', coalesce(v_city, '')
    )
  )
    INTO v_result
  FROM classified;

  RETURN coalesce(v_result, jsonb_build_object(
    'totalBusinessesInRegion', 0,
    'currentBusinessProCount', 0,
    'regularBusinessCount', 0,
    'targetedGrantTargetCount', 0,
    'subscriptionProSkippedCount', 0,
    'filters', jsonb_build_object(
      'country', coalesce(v_country, ''),
      'state', coalesce(v_state, ''),
      'city', coalesce(v_city, '')
    )
  ));
END;
$$;

REVOKE ALL ON FUNCTION public.business_promotion_target_region_matches(public.businesses, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.business_promotion_effective_pro_active(public.businesses) FROM PUBLIC;

COMMENT ON FUNCTION public.business_promotion_target_region_matches(public.businesses, text, text, text) IS
  'True when an active business has at least one managed venue matching the optional geographic filters.';
COMMENT ON FUNCTION public.business_promotion_effective_pro_active(public.businesses) IS
  'True when a business currently has Business Pro from individual plan, admin promo grant, or global promotion.';
COMMENT ON FUNCTION public.admin_business_promotion_targeted_preview(text, text, text) IS
  'Admin preview breakdown for targeted Business Pro grants in a selected region.';

NOTIFY pgrst, 'reload schema';
