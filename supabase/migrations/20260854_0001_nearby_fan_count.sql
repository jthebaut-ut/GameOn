-- Privacy-safe Fans nearby aggregate for Discover Activity Panel.
-- Stores only coarse grid coordinates (server-snapped); exposes only an integer count via RPC.
-- Never returns coordinates, distances, or candidate identities.

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS nearby_coarse_lat double precision NULL,
  ADD COLUMN IF NOT EXISTS nearby_coarse_lng double precision NULL,
  ADD COLUMN IF NOT EXISTS nearby_location_updated_at timestamptz NULL;

COMMENT ON COLUMN public.user_profiles.nearby_coarse_lat IS
  'Privacy-safe nearby presence latitude snapped to a coarse grid (~0.05 deg). Used only by get_nearby_fan_count.';
COMMENT ON COLUMN public.user_profiles.nearby_coarse_lng IS
  'Privacy-safe nearby presence longitude snapped to a coarse grid (~0.05 deg). Used only by get_nearby_fan_count.';
COMMENT ON COLUMN public.user_profiles.nearby_location_updated_at IS
  'When the authenticated user last uploaded a coarse nearby presence location.';

CREATE INDEX IF NOT EXISTS idx_user_profiles_nearby_presence_eligible
  ON public.user_profiles (nearby_coarse_lat, nearby_coarse_lng, last_seen_at DESC)
  WHERE nearby_coarse_lat IS NOT NULL
    AND nearby_coarse_lng IS NOT NULL
    AND last_seen_at IS NOT NULL
    AND COALESCE(discoverable_by_fans, true) = true
    AND COALESCE(is_business_account, false) = false
    AND COALESCE(is_deleted, false) = false;

-- Upsert caller coarse location + presence heartbeat. Snaps before storing; ignores invalid coords.
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
  'Authenticated heartbeat that updates last_seen_at and privacy-safe coarse nearby location (server-snapped grid).';

REVOKE ALL ON FUNCTION public.touch_user_nearby_location(double precision, double precision) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.touch_user_nearby_location(double precision, double precision) TO authenticated;

-- Integer-only nearby fan aggregate. Uses Suggested Fans product radius (45 miles) by default.
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
  v_presence_interval interval := interval '15 minutes';
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

  -- Viewer must be an eligible fan account (not business).
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
  'Returns a privacy-safe integer count of discoverable, recently active fan accounts within radius of the requester center. No identities or coordinates are returned. Presence window: 15 minutes. Default radius: 45 miles.';

REVOKE ALL ON FUNCTION public.get_nearby_fan_count(double precision, double precision, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_nearby_fan_count(double precision, double precision, numeric) TO authenticated;
