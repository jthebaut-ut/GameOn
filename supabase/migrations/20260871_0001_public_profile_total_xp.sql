-- =============================================================================
-- 20260871 — Include total Fan XP on public fan identity profile RPC
-- =============================================================================
-- Source of truth: public.user_xp (summary). Ledger xp_events stays private.
-- Extends get_public_fan_identity_profile with total_xp / xp_level / xp_title
-- so clients avoid a second per-profile user_xp round-trip.
-- Visibility / privacy gates unchanged from 20260862.
-- Do NOT apply from the agent; review and apply deliberately.
-- =============================================================================

BEGIN;

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.user_xp') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.user_xp'];
  END IF;
  IF to_regprocedure('public.get_public_fan_identity_profile(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.get_public_fan_identity_profile(uuid)'];
  END IF;
  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION '20260871 preflight failed; missing: %', array_to_string(v_missing, ', ');
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.get_public_fan_identity_profile(p_target_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_viewer uuid := auth.uid();
  v_target uuid := p_target_user_id;
  v_profile public.user_profiles%ROWTYPE;
  v_mutual_count int := 0;
  v_shared_teams int := 0;
  v_venue_count int := 0;
  v_pickup_hosted int := 0;
  v_pickup_joined int := 0;
  v_show_home_city boolean := false;
  v_home_city text := NULL;
  v_home_region text := NULL;
  v_home_country text := NULL;
  v_total_xp integer := 0;
  v_xp_level integer := 1;
  v_xp_title text := 'Rookie Fan';
BEGIN
  IF v_viewer IS NULL OR v_target IS NULL OR v_viewer = v_target THEN
    RETURN jsonb_build_object('visible', false);
  END IF;

  SELECT up.*
  INTO v_profile
  FROM public.user_profiles up
  WHERE up.id::text = v_target::text
    AND COALESCE(lower(trim(up.admin_status)), '') = 'active'
    AND up.admin_disabled_at IS NULL
    AND COALESCE(up.is_business_account, false) = false
    AND (
      COALESCE(up.discoverable_by_fans, true) = true
      OR public.pickup_invite_users_are_friends(v_viewer, v_target)
    )
    AND COALESCE(up.is_deleted, false) = false
    AND NOT lower(trim(coalesce(up.email, ''))) LIKE '%@deleted.fangeo.local'
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('visible', false);
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.blocked_users b
    WHERE (b.blocker_user_id::text = v_viewer::text AND b.blocked_user_id::text = v_target::text)
       OR (b.blocker_user_id::text = v_target::text AND b.blocked_user_id::text = v_viewer::text)
  ) THEN
    RETURN jsonb_build_object('visible', false);
  END IF;

  -- Privacy gate: user-selected home city only; never GPS/coordinates.
  IF COALESCE(v_profile.show_home_city, false)
     AND nullif(trim(coalesce(v_profile.home_city, '')), '') IS NOT NULL THEN
    v_show_home_city := true;
    v_home_city := nullif(trim(v_profile.home_city), '');
    v_home_region := nullif(trim(coalesce(v_profile.home_region, '')), '');
    v_home_country := nullif(trim(coalesce(v_profile.home_country, '')), '');
  END IF;

  WITH viewer_friends AS (
    SELECT CASE
      WHEN f.requester_id::text = v_viewer::text THEN f.addressee_id
      ELSE f.requester_id
    END AS friend_id
    FROM public.friendships f
    WHERE f.status = 'accepted'
      AND (f.requester_id::text = v_viewer::text OR f.addressee_id::text = v_viewer::text)
  ),
  target_friends AS (
    SELECT CASE
      WHEN f.requester_id::text = v_target::text THEN f.addressee_id
      ELSE f.requester_id
    END AS friend_id
    FROM public.friendships f
    WHERE f.status = 'accepted'
      AND (f.requester_id::text = v_target::text OR f.addressee_id::text = v_target::text)
  ),
  mutual AS (
    SELECT vf.friend_id
    FROM viewer_friends vf
    INNER JOIN target_friends tf ON tf.friend_id::text = vf.friend_id::text
    WHERE vf.friend_id::text NOT IN (v_viewer::text, v_target::text)
  )
  SELECT count(*)::int INTO v_mutual_count FROM mutual;

  SELECT count(DISTINCT mine.team_id)::int
  INTO v_shared_teams
  FROM public.user_favorite_teams mine
  JOIN public.user_favorite_teams theirs
    ON theirs.team_id = mine.team_id
   AND theirs.user_id::text = v_target::text
  WHERE mine.user_id::text = v_viewer::text;

  SELECT count(*)::int
  INTO v_venue_count
  FROM public.favorite_venues fv
  WHERE lower(trim(coalesce(fv.user_email, ''))) = lower(trim(coalesce(v_profile.email, '')));

  SELECT count(*)::int
  INTO v_pickup_hosted
  FROM public.pickup_games pg
  WHERE pg.creator_user_id::text = v_target::text;

  SELECT count(*)::int
  INTO v_pickup_joined
  FROM public.pickup_game_requests pgr
  WHERE pgr.requester_user_id::text = v_target::text
    AND lower(trim(coalesce(pgr.status, ''))) = 'approved';

  SELECT
    COALESCE(ux.total_xp, 0),
    COALESCE(ux.level, 1),
    COALESCE(NULLIF(btrim(ux.title), ''), 'Rookie Fan')
  INTO v_total_xp, v_xp_level, v_xp_title
  FROM public.user_xp ux
  WHERE ux.user_id = v_target;

  IF NOT FOUND THEN
    v_total_xp := 0;
    v_xp_level := 1;
    v_xp_title := 'Rookie Fan';
  END IF;

  RETURN jsonb_build_object(
    'visible', true,
    'discoverable_by_fans', COALESCE(v_profile.discoverable_by_fans, true),
    'total_xp', v_total_xp,
    'xp_level', v_xp_level,
    'xp_title', v_xp_title,
    'user_id', v_target,
    'display_name', nullif(trim(coalesce(v_profile.display_name, '')), ''),
    'username', nullif(trim(coalesce(v_profile.username, '')), ''),
    'bio', nullif(trim(coalesce(v_profile.bio, '')), ''),
    'avatar_url', nullif(trim(coalesce(v_profile.avatar_url, '')), ''),
    'avatar_thumbnail_url', nullif(trim(coalesce(v_profile.avatar_thumbnail_url, '')), ''),
    'member_since', v_profile.created_at,
    'national_team_country_code', nullif(trim(coalesce(v_profile.national_team_country_code, '')), ''),
    'national_team_country_name', nullif(trim(coalesce(v_profile.national_team_country_name, '')), ''),
    'national_team_flag', nullif(trim(coalesce(v_profile.national_team_flag, '')), ''),
    'national_team_supporter_label', nullif(trim(coalesce(v_profile.national_team_supporter_label, '')), ''),
    'show_home_city', v_show_home_city,
    'home_city', v_home_city,
    'home_region', v_home_region,
    'home_country', v_home_country,
    'fan_identity_preferences', COALESCE(v_profile.fan_identity_preferences, '{}'::jsonb),
    'home_crowd_venue', public.home_crowd_venue_summary(
      v_profile.home_crowd_venue_id,
      v_profile.home_crowd_set_at,
      v_target
    ),
    'favorite_team_ids', COALESCE(
      (
        SELECT jsonb_agg(uft.team_id ORDER BY uft.team_id)
        FROM public.user_favorite_teams uft
        WHERE uft.user_id::text = v_target::text
      ),
      '[]'::jsonb
    ),
    'shared_team_ids', COALESCE(
      (
        SELECT jsonb_agg(DISTINCT mine.team_id ORDER BY mine.team_id)
        FROM public.user_favorite_teams mine
        JOIN public.user_favorite_teams theirs
          ON theirs.team_id = mine.team_id
         AND theirs.user_id::text = v_target::text
        WHERE mine.user_id::text = v_viewer::text
      ),
      '[]'::jsonb
    ),
    'mutual_fans_count', v_mutual_count,
    'shared_teams_count', v_shared_teams,
    'venue_count', v_venue_count,
    'pickup_hosted_count', v_pickup_hosted,
    'pickup_joined_count', v_pickup_joined,
    'mutual_fan_avatars', COALESCE(
      (
        WITH viewer_friends AS (
          SELECT CASE
            WHEN f.requester_id::text = v_viewer::text THEN f.addressee_id
            ELSE f.requester_id
          END AS friend_id
          FROM public.friendships f
          WHERE f.status = 'accepted'
            AND (f.requester_id::text = v_viewer::text OR f.addressee_id::text = v_viewer::text)
        ),
        target_friends AS (
          SELECT CASE
            WHEN f.requester_id::text = v_target::text THEN f.addressee_id
            ELSE f.requester_id
          END AS friend_id
          FROM public.friendships f
          WHERE f.status = 'accepted'
            AND (f.requester_id::text = v_target::text OR f.addressee_id::text = v_target::text)
        )
        SELECT jsonb_agg(
          jsonb_build_object(
            'user_id', up.id,
            'display_name', nullif(trim(coalesce(up.display_name, '')), ''),
            'avatar_url', nullif(trim(coalesce(up.avatar_thumbnail_url, up.avatar_url, '')), '')
          )
          ORDER BY up.display_name NULLS LAST, up.id
        )
        FROM (
          SELECT vf.friend_id
          FROM viewer_friends vf
          INNER JOIN target_friends tf ON tf.friend_id::text = vf.friend_id::text
          WHERE vf.friend_id::text NOT IN (v_viewer::text, v_target::text)
          LIMIT 4
        ) m
        JOIN public.user_profiles up ON up.id::text = m.friend_id::text
        WHERE COALESCE(lower(trim(up.admin_status)), '') = 'active'
          AND up.admin_disabled_at IS NULL
          AND COALESCE(up.is_deleted, false) = false
          AND NOT lower(trim(coalesce(up.email, ''))) LIKE '%@deleted.fangeo.local'
          AND COALESCE(up.is_business_account, false) = false
          -- Mutual friends are already accepted friends of the viewer: include them even when
          -- Discover My Profile is OFF. Do not require discoverable_by_fans here.
          AND NOT EXISTS (
            SELECT 1
            FROM public.blocked_users b
            WHERE (b.blocker_user_id::text = v_viewer::text AND b.blocked_user_id::text = up.id::text)
               OR (b.blocker_user_id::text = up.id::text AND b.blocked_user_id::text = v_viewer::text)
          )
      ),
      '[]'::jsonb
    ),
    'venue_cards', COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'venue_id', v.id,
            'venue_name', nullif(trim(coalesce(v.venue_name, '')), ''),
            'city_label', nullif(trim(coalesce(v.city, '')), ''),
            'thumbnail_url', nullif(trim(coalesce(v.cover_photo_thumbnail_url, v.cover_photo_url, '')), '')
          )
          ORDER BY fv.id DESC
        )
        FROM (
          SELECT fv.venue_id, fv.id
          FROM public.favorite_venues fv
          WHERE lower(trim(coalesce(fv.user_email, ''))) = lower(trim(coalesce(v_profile.email, '')))
          ORDER BY fv.id DESC
          LIMIT 3
        ) fv
        JOIN public.venues v ON v.id::text = fv.venue_id::text
        WHERE COALESCE(lower(trim(v.admin_status)), 'active') = 'active'
      ),
      '[]'::jsonb
    )
  );
END;
$$;

COMMENT ON FUNCTION public.get_public_fan_identity_profile(uuid) IS
  'Public fan identity profile for authenticated viewers. Includes total_xp/xp_level/xp_title from user_xp when visible.';

REVOKE ALL ON FUNCTION public.get_public_fan_identity_profile(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_fan_identity_profile(uuid) TO authenticated;

COMMIT;
