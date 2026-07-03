-- Admin list of businesses matching targeted Business Pro campaign geography.

CREATE OR REPLACE FUNCTION public.admin_business_promotion_targeted_ineligible_reason(p_business public.businesses)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
BEGIN
  IF public.business_regular_promo_grant_target(p_business) THEN
    RETURN NULL;
  END IF;

  IF NOT public.business_promotion_business_is_active(p_business) THEN
    IF p_business.admin_archived_at IS NOT NULL THEN
      RETURN 'Archived';
    END IF;

    RETURN 'Inactive';
  END IF;

  IF COALESCE(NULLIF(btrim(p_business.plan_type), ''), 'free') IN ('manual_pro', 'pro_paid')
    AND public.business_individual_pro_is_active(p_business) THEN
    RETURN 'Subscription Pro';
  END IF;

  IF public.business_individual_pro_is_active(p_business)
    OR public.business_admin_pro_promo_is_active(p_business) THEN
    RETURN 'Already Pro';
  END IF;

  RETURN 'Not eligible';
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_business_promotion_targeted_matching_businesses(
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
  v_businesses jsonb;
BEGIN
  IF v_country IS NULL AND v_state IS NULL AND v_city IS NULL THEN
    RAISE EXCEPTION 'missing_target_filters' USING ERRCODE = '22023';
  END IF;

  SELECT coalesce(jsonb_agg(row_data ORDER BY business_name), '[]'::jsonb)
    INTO v_businesses
  FROM (
    SELECT
      jsonb_build_object(
        'businessId', b.id,
        'businessName', coalesce(nullif(btrim(b.display_name), ''), 'Unnamed business'),
        'ownerEmail', coalesce(b.owner_email, ''),
        'city', coalesce(loc.city, ''),
        'state', coalesce(loc.state, ''),
        'country', coalesce(loc.country, ''),
        'planType', coalesce(nullif(btrim(b.plan_type), ''), 'free'),
        'planStatus', coalesce(nullif(btrim(b.plan_status), ''), 'active'),
        'proExpiresAt', b.pro_expires_at,
        'adminProPromoStartsAt', b.admin_pro_promo_starts_at,
        'adminProPromoEndsAt', b.admin_pro_promo_ends_at,
        'adminArchivedAt', b.admin_archived_at,
        'adminStatus', b.admin_status,
        'excludeFromGlobalBusinessProPromo', coalesce(b.exclude_from_global_business_pro_promo, false),
        'eligibleForGrant', public.business_regular_promo_grant_target(b),
        'ineligibleReason', coalesce(public.admin_business_promotion_targeted_ineligible_reason(b), '')
      ) AS row_data,
      coalesce(nullif(btrim(b.display_name), ''), b.owner_email, b.id::text) AS business_name
    FROM public.businesses b
    LEFT JOIN LATERAL (
      SELECT v.city, v.state, v.country
      FROM public.admin_business_managed_venue_ids(b.id) mv
      JOIN public.venues v ON v.id = mv.venue_id
      WHERE lower(btrim(coalesce(v.admin_status, 'active'))) IN ('active', 'plan_locked')
        AND public.business_promotion_country_matches(v.country, v_country)
        AND public.business_promotion_state_matches(v.state, v.region, v_state)
        AND public.business_promotion_city_matches(v.city, v_city)
      ORDER BY coalesce(nullif(btrim(v.venue_name), ''), v.id::text)
      LIMIT 1
    ) loc ON true
    WHERE public.business_promotion_business_is_active(b)
      AND public.business_managed_venue_location_matches(b.id, v_country, v_state, v_city)
  ) ranked;

  RETURN jsonb_build_object(
    'businesses', coalesce(v_businesses, '[]'::jsonb),
    'filters', jsonb_build_object(
      'country', coalesce(v_country, ''),
      'state', coalesce(v_state, ''),
      'city', coalesce(v_city, '')
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_business_promotion_targeted_ineligible_reason(public.businesses) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_business_promotion_targeted_matching_businesses(text, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_business_promotion_targeted_matching_businesses(text, text, text) TO service_role;

COMMENT ON FUNCTION public.admin_business_promotion_targeted_ineligible_reason(public.businesses) IS
  'Human-readable reason a business is not eligible for a targeted Business Pro grant.';
COMMENT ON FUNCTION public.admin_business_promotion_targeted_matching_businesses(text, text, text) IS
  'Admin list of active businesses with at least one managed venue in the selected geography.';

NOTIFY pgrst, 'reload schema';
