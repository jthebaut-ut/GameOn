-- Privacy-safe batched Nearby membership for Fans Live Now.
-- Accepts only capped candidate IDs already shown in Chat; returns only qualifying user_ids.
-- No coordinates, distances, cities, or profile fields are returned.
-- Aligns online-now presence window with Fans Live Now (120 seconds).

CREATE OR REPLACE FUNCTION public.get_nearby_fan_count(
  p_center_lat double precision,
  p_center_lng double precision,
  p_radius_miles numeric DEFAULT 45
)
RETURNS TABLE (
  fan_count integer,
  generated_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_viewer uuid := auth.uid();
  v_radius double precision;
  v_count integer := 0;
  v_lat_delta double precision;
  v_lng_delta double precision;
  -- Matches PresenceOnlineStatus.onlineWindowSeconds / Fans Live Now online-now rule.
  v_presence_interval interval := interval '120 seconds';
BEGIN
  IF v_viewer IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '28000';
  END IF;

  IF p_center_lat IS NULL OR p_center_lng IS NULL
     OR p_center_lat < -90 OR p_center_lat > 90
     OR p_center_lng < -180 OR p_center_lng > 180 THEN
    RETURN QUERY SELECT 0::integer, now();
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.user_profiles up
    WHERE up.id = v_viewer
      AND COALESCE(up.is_business_account, false) = false
      AND COALESCE(up.is_deleted, false) = false
      AND COALESCE(lower(trim(up.admin_status)), 'active') = 'active'
      AND up.admin_disabled_at IS NULL
  ) THEN
    RETURN QUERY SELECT 0::integer, now();
    RETURN;
  END IF;

  v_radius := LEAST(GREATEST(COALESCE(p_radius_miles, 45)::double precision, 1), 100);
  v_lat_delta := v_radius / 69.0;
  v_lng_delta := v_radius / GREATEST(COS(radians(p_center_lat)) * 69.172, 0.01);

  SELECT count(*)::integer
  INTO v_count
  FROM public.user_profiles up
  WHERE up.id <> v_viewer
    AND COALESCE(up.discoverable_by_fans, true) = true
    AND COALESCE(up.is_business_account, false) = false
    AND COALESCE(up.is_deleted, false) = false
    AND COALESCE(lower(trim(up.admin_status)), 'active') = 'active'
    AND up.admin_disabled_at IS NULL
    AND NOT lower(trim(coalesce(up.email, ''))) LIKE '%@deleted.fangeo.local'
    AND up.last_seen_at IS NOT NULL
    AND up.last_seen_at >= now() - v_presence_interval
    AND up.nearby_coarse_lat IS NOT NULL
    AND up.nearby_coarse_lng IS NOT NULL
    AND up.nearby_location_updated_at IS NOT NULL
    AND up.nearby_location_updated_at >= now() - v_presence_interval
    AND up.nearby_coarse_lat BETWEEN (p_center_lat - v_lat_delta) AND (p_center_lat + v_lat_delta)
    AND up.nearby_coarse_lng BETWEEN (p_center_lng - v_lng_delta) AND (p_center_lng + v_lng_delta)
    AND (
      3958.7613 * 2 * asin(sqrt(LEAST(1,
        power(sin(radians((up.nearby_coarse_lat - p_center_lat) / 2)), 2)
        + cos(radians(p_center_lat))
          * cos(radians(up.nearby_coarse_lat))
          * power(sin(radians((up.nearby_coarse_lng - p_center_lng) / 2)), 2)
      )))
    ) <= v_radius
    AND NOT EXISTS (
      SELECT 1
      FROM public.user_bans ub
      WHERE ub.user_id = up.id
        AND public.is_user_ban_active(ub.expires_at, ub.lifted_at)
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.blocked_users b
      WHERE (
          (b.blocker_user_id = v_viewer AND b.blocked_user_id = up.id)
          OR (b.blocker_user_id = up.id AND b.blocked_user_id = v_viewer)
        )
    );

  RETURN QUERY SELECT COALESCE(v_count, 0), now();
END;
$$;

COMMENT ON FUNCTION public.get_nearby_fan_count(double precision, double precision, numeric) IS
  'Returns a privacy-safe integer count of discoverable, online-now fan accounts within radius. Presence window: 120 seconds (Fans Live Now). Default radius: 45 miles.';

-- Batched membership: which of the provided Live Now candidate IDs are Nearby.
CREATE OR REPLACE FUNCTION public.get_nearby_fan_ids_among(
  p_center_lat double precision,
  p_center_lng double precision,
  p_candidate_user_ids uuid[],
  p_radius_miles numeric DEFAULT 45
)
RETURNS TABLE (
  user_id uuid
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_viewer uuid := auth.uid();
  v_radius double precision;
  v_lat_delta double precision;
  v_lng_delta double precision;
  v_presence_interval interval := interval '120 seconds';
  v_candidates uuid[];
BEGIN
  IF v_viewer IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '28000';
  END IF;

  IF p_candidate_user_ids IS NULL OR cardinality(p_candidate_user_ids) = 0 THEN
    RETURN;
  END IF;

  -- Cap to Fans Live Now display limit (12). Drop self if present.
  SELECT ARRAY(
    SELECT DISTINCT c
    FROM unnest(p_candidate_user_ids[1:12]) AS c
    WHERE c IS NOT NULL AND c <> v_viewer
    LIMIT 12
  )
  INTO v_candidates;

  IF v_candidates IS NULL OR cardinality(v_candidates) = 0 THEN
    RETURN;
  END IF;

  IF p_center_lat IS NULL OR p_center_lng IS NULL
     OR p_center_lat < -90 OR p_center_lat > 90
     OR p_center_lng < -180 OR p_center_lng > 180 THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.user_profiles up
    WHERE up.id = v_viewer
      AND COALESCE(up.is_business_account, false) = false
      AND COALESCE(up.is_deleted, false) = false
      AND COALESCE(lower(trim(up.admin_status)), 'active') = 'active'
      AND up.admin_disabled_at IS NULL
  ) THEN
    RETURN;
  END IF;

  v_radius := LEAST(GREATEST(COALESCE(p_radius_miles, 45)::double precision, 1), 100);
  v_lat_delta := v_radius / 69.0;
  v_lng_delta := v_radius / GREATEST(COS(radians(p_center_lat)) * 69.172, 0.01);

  RETURN QUERY
  SELECT up.id
  FROM public.user_profiles up
  WHERE up.id = ANY (v_candidates)
    AND COALESCE(up.discoverable_by_fans, true) = true
    AND COALESCE(up.is_business_account, false) = false
    AND COALESCE(up.is_deleted, false) = false
    AND COALESCE(lower(trim(up.admin_status)), 'active') = 'active'
    AND up.admin_disabled_at IS NULL
    AND NOT lower(trim(coalesce(up.email, ''))) LIKE '%@deleted.fangeo.local'
    AND up.last_seen_at IS NOT NULL
    AND up.last_seen_at >= now() - v_presence_interval
    AND up.nearby_coarse_lat IS NOT NULL
    AND up.nearby_coarse_lng IS NOT NULL
    AND up.nearby_location_updated_at IS NOT NULL
    AND up.nearby_location_updated_at >= now() - v_presence_interval
    AND up.nearby_coarse_lat BETWEEN (p_center_lat - v_lat_delta) AND (p_center_lat + v_lat_delta)
    AND up.nearby_coarse_lng BETWEEN (p_center_lng - v_lng_delta) AND (p_center_lng + v_lng_delta)
    AND (
      3958.7613 * 2 * asin(sqrt(LEAST(1,
        power(sin(radians((up.nearby_coarse_lat - p_center_lat) / 2)), 2)
        + cos(radians(p_center_lat))
          * cos(radians(up.nearby_coarse_lat))
          * power(sin(radians((up.nearby_coarse_lng - p_center_lng) / 2)), 2)
      )))
    ) <= v_radius
    AND NOT EXISTS (
      SELECT 1
      FROM public.user_bans ub
      WHERE ub.user_id = up.id
        AND public.is_user_ban_active(ub.expires_at, ub.lifted_at)
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.blocked_users b
      WHERE (
          (b.blocker_user_id = v_viewer AND b.blocked_user_id = up.id)
          OR (b.blocker_user_id = up.id AND b.blocked_user_id = v_viewer)
        )
    );
END;
$$;

COMMENT ON FUNCTION public.get_nearby_fan_ids_among(double precision, double precision, uuid[], numeric) IS
  'Returns only user_ids from a capped candidate list that qualify as Nearby (online-now 120s, discoverable, within radius). No coordinates or profile fields.';

REVOKE ALL ON FUNCTION public.get_nearby_fan_ids_among(double precision, double precision, uuid[], numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_nearby_fan_ids_among(double precision, double precision, uuid[], numeric) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_nearby_fan_ids_among(double precision, double precision, uuid[], numeric) TO authenticated;
