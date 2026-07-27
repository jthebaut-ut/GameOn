-- =============================================================================
-- 20260895 — Suggested Fans ranking rebalance
-- =============================================================================
--
-- STATUS: PREPARED ONLY — DO NOT APPLY from the agent. Manual review / staging
-- apply only. Do not run supabase db push --linked from automation.
--
-- Depends on: 20260836 (RPC shape), 20260854 (nearby_coarse_*), 20260886/87
-- (age_access_allows_social), user_favorite_teams.is_primary.
--
-- Changes:
--   * Rebalanced additive component scores (mutual / pickup / proximity / MY TEAM / …)
--   * Real candidate↔ viewer proximity via privacy-safe nearby_coarse_* (never returned)
--   * SQL default radius aligned to product 45 miles
--   * Age-access fail-closed for the viewer via age_access_allows_social(auth.uid())
--   * Fallback reason_type = 'fallback' (not misleading "Active fan")
--   * Recent Activity uses user_profiles.last_seen_at (authoritative heartbeat;
--     user_profiles.updated_at does NOT exist — do not use created_at for activity)
--   * Fallback (+25) ONLY when the candidate has no meaningful ranking signal
--     (mutual / pickup / proximity / MY TEAM / affinity / teams / watch party /
--     venue / recent activity / XP). Never stacks with other reason rows.
--   * Controlled diversity: top ~80% by score, then ~20% stable next-tier picks
--   * Why-suggested reason_type/label = strongest component (deterministic tie-break)
--
-- Does NOT return: coordinates, exact distance, last_seen_at, or private activity.

CREATE OR REPLACE FUNCTION public.get_profile_friend_suggestions(
  p_limit int DEFAULT 30,
  p_radius_miles numeric DEFAULT 45,
  p_center_lat double precision DEFAULT NULL,
  p_center_lng double precision DEFAULT NULL
)
RETURNS TABLE (
  user_id uuid,
  display_name text,
  username text,
  avatar_url text,
  avatar_thumbnail_url text,
  reason_type text,
  reason_label text,
  shared_favorite_teams_count int,
  shared_event_interest_count int,
  shared_pickup_game_count int,
  mutual_friend_count int,
  mutual_friend_avatars jsonb,
  score int
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH params AS (
    SELECT
      auth.uid()::uuid AS viewer_id,
      LEAST(GREATEST(COALESCE(p_limit, 30), 1), 50)::int AS result_limit,
      GREATEST(COALESCE(p_radius_miles, 45), 0)::double precision AS radius_miles,
      p_center_lat AS center_lat,
      p_center_lng AS center_lng,
      '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'::text AS uuid_pattern,
      date_trunc('day', timezone('utc', now())) AS diversity_day
  ),
  viewer_profile AS (
    SELECT
      up.id::uuid AS id,
      lower(trim(coalesce(up.email, ''))) AS email_norm,
      up.nearby_coarse_lat AS coarse_lat,
      up.nearby_coarse_lng AS coarse_lng
    FROM public.user_profiles up
    JOIN params p ON p.viewer_id::text = up.id::text
    WHERE p.viewer_id IS NOT NULL
      AND public.age_access_allows_social(p.viewer_id)
      AND COALESCE(lower(trim(up.admin_status)), '') = 'active'
      AND up.admin_disabled_at IS NULL
      AND COALESCE(up.is_business_account, false) = false
      AND COALESCE(up.is_deleted, false) = false
      AND NOT lower(trim(coalesce(up.email, ''))) LIKE '%@deleted.fangeo.local'
  ),
  viewer_location AS (
    SELECT
      vp.id AS viewer_id,
      COALESCE(vp.coarse_lat, p.center_lat) AS lat,
      COALESCE(vp.coarse_lng, p.center_lng) AS lng
    FROM viewer_profile vp
    JOIN params p ON true
  ),
  viewer_friends AS (
    SELECT DISTINCT
      CASE
        WHEN (f.requester_id::text)::uuid = vp.id::uuid THEN (f.addressee_id::text)::uuid
        ELSE (f.requester_id::text)::uuid
      END AS friend_user_id
    FROM viewer_profile vp
    JOIN params p ON true
    JOIN public.friendships f
      ON f.status = 'accepted'
     AND COALESCE(f.requester_entity_type, 'user') = 'user'
     AND COALESCE(f.addressee_entity_type, 'user') = 'user'
     AND f.requester_id::text ~* p.uuid_pattern
     AND f.addressee_id::text ~* p.uuid_pattern
     AND (
       (f.requester_id::text)::uuid = vp.id::uuid
       OR (f.addressee_id::text)::uuid = vp.id::uuid
     )
  ),
  pickup_participants AS (
    SELECT
      pg.id AS pickup_game_id,
      pg.creator_user_id AS participant_user_id
    FROM public.pickup_games pg
    WHERE pg.status = 'active'
      AND pg.is_visible

    UNION

    SELECT
      pg.id AS pickup_game_id,
      pgr.requester_user_id AS participant_user_id
    FROM public.pickup_game_requests pgr
    JOIN public.pickup_games pg
      ON pg.id = pgr.pickup_game_id
    WHERE pgr.status = 'approved'
      AND pg.status = 'active'
      AND pg.is_visible
  ),
  shared_pickup_games AS (
    SELECT
      other.participant_user_id AS candidate_user_id,
      mine.pickup_game_id
    FROM viewer_profile vp
    JOIN pickup_participants mine
      ON mine.participant_user_id::text = vp.id::text
    JOIN pickup_participants other
      ON other.pickup_game_id = mine.pickup_game_id
     AND other.participant_user_id::text <> vp.id::text
  ),
  pickup_game_counts AS (
    SELECT
      spg.candidate_user_id,
      count(DISTINCT spg.pickup_game_id)::int AS shared_pickup_game_count
    FROM shared_pickup_games spg
    GROUP BY spg.candidate_user_id
  ),
  pickup_game_matches AS (
    SELECT
      pgc.candidate_user_id,
      'pickup_game'::text AS reason_type,
      'Played in the same pickup game'::text AS reason_label,
      LEAST(
        1050,
        750 + GREATEST(pgc.shared_pickup_game_count - 1, 0) * 75
      )::int AS score
    FROM pickup_game_counts pgc
    WHERE pgc.shared_pickup_game_count > 0
  ),
  shared_venue_events AS (
    SELECT
      other_profile.id AS candidate_user_id,
      mine.venue_event_id
    FROM viewer_profile vp
    JOIN public.venue_event_interests mine
      ON lower(trim(coalesce(mine.user_email, ''))) = vp.email_norm
    JOIN public.venue_event_interests other
      ON other.venue_event_id::text = mine.venue_event_id::text
     AND lower(trim(coalesce(other.user_email, ''))) <> vp.email_norm
    JOIN public.user_profiles other_profile
      ON lower(trim(coalesce(other_profile.email, ''))) = lower(trim(coalesce(other.user_email, '')))
    LEFT JOIN public.venue_events ve
      ON ve.id::text = mine.venue_event_id::text
    WHERE vp.email_norm <> ''
      AND other_profile.id::text <> vp.id::text
      AND (
        ve.id IS NULL
        OR ve.scheduled_start_at IS NULL
        OR ve.scheduled_start_at >= (now() - interval '180 days')
      )
  ),
  venue_event_counts AS (
    SELECT
      sve.candidate_user_id,
      count(DISTINCT sve.venue_event_id)::int AS shared_event_interest_count
    FROM shared_venue_events sve
    GROUP BY sve.candidate_user_id
  ),
  venue_activity_matches AS (
    SELECT
      vec.candidate_user_id,
      'venue_event'::text AS reason_type,
      'Interested in the same watch party'::text AS reason_label,
      LEAST(
        700,
        500 + GREATEST(vec.shared_event_interest_count - 1, 0) * 50
      )::int AS score
    FROM venue_event_counts vec
    WHERE vec.shared_event_interest_count > 0
  ),
  viewer_primary_team AS (
    SELECT mine.team_id
    FROM viewer_profile vp
    JOIN public.user_favorite_teams mine
      ON mine.user_id::text = vp.id::text
     AND COALESCE(mine.is_primary, false) = true
    LIMIT 1
  ),
  candidate_primary_team AS (
    SELECT
      other.user_id AS candidate_user_id,
      other.team_id AS team_id
    FROM public.user_favorite_teams other
    WHERE COALESCE(other.is_primary, false) = true
  ),
  my_team_same_matches AS (
    SELECT
      cpt.candidate_user_id,
      'my_team'::text AS reason_type,
      'Same MY TEAM'::text AS reason_label,
      600 AS score,
      cpt.team_id AS consumed_team_id
    FROM viewer_primary_team vpt
    JOIN candidate_primary_team cpt
      ON cpt.team_id = vpt.team_id
  ),
  my_team_affinity_matches AS (
    SELECT DISTINCT ON (cand.candidate_user_id)
      cand.candidate_user_id,
      'my_team_affinity'::text AS reason_type,
      'Supports your MY TEAM'::text AS reason_label,
      450 AS score,
      cand.consumed_team_id
    FROM (
      SELECT
        other.user_id AS candidate_user_id,
        vpt.team_id AS consumed_team_id
      FROM viewer_primary_team vpt
      JOIN viewer_profile vp ON true
      JOIN public.user_favorite_teams other
        ON other.team_id = vpt.team_id
       AND other.user_id::text <> vp.id::text

      UNION

      SELECT
        cpt.candidate_user_id,
        cpt.team_id AS consumed_team_id
      FROM candidate_primary_team cpt
      JOIN viewer_profile vp ON true
      JOIN public.user_favorite_teams mine
        ON mine.user_id::text = vp.id::text
       AND mine.team_id = cpt.team_id
    ) cand
    WHERE NOT EXISTS (
      SELECT 1
      FROM my_team_same_matches same
      WHERE same.candidate_user_id::text = cand.candidate_user_id::text
    )
    ORDER BY cand.candidate_user_id, cand.consumed_team_id
  ),
  my_team_matches AS (
    SELECT candidate_user_id, reason_type, reason_label, score FROM my_team_same_matches
    UNION ALL
    SELECT candidate_user_id, reason_type, reason_label, score FROM my_team_affinity_matches
  ),
  my_team_consumed AS (
    SELECT candidate_user_id, consumed_team_id FROM my_team_same_matches
    UNION
    SELECT candidate_user_id, consumed_team_id FROM my_team_affinity_matches
  ),
  favorite_team_counts AS (
    SELECT
      other.user_id AS candidate_user_id,
      count(DISTINCT other.team_id)::int AS shared_favorite_teams_count
    FROM viewer_profile vp
    JOIN public.user_favorite_teams mine
      ON mine.user_id::text = vp.id::text
    JOIN public.user_favorite_teams other
      ON other.team_id = mine.team_id
     AND other.user_id::text <> vp.id::text
    GROUP BY other.user_id
  ),
  ordinary_shared_team_counts AS (
    SELECT
      other.user_id AS candidate_user_id,
      count(DISTINCT other.team_id)::int AS ordinary_shared_teams_count
    FROM viewer_profile vp
    JOIN public.user_favorite_teams mine
      ON mine.user_id::text = vp.id::text
    JOIN public.user_favorite_teams other
      ON other.team_id = mine.team_id
     AND other.user_id::text <> vp.id::text
    WHERE NOT EXISTS (
      SELECT 1
      FROM my_team_consumed mtc
      WHERE mtc.candidate_user_id::text = other.user_id::text
        AND mtc.consumed_team_id = other.team_id
    )
    GROUP BY other.user_id
  ),
  favorite_team_matches AS (
    SELECT
      ost.candidate_user_id,
      'favorite_team'::text AS reason_type,
      'Also supports the same team'::text AS reason_label,
      LEAST(
        525,
        300 + GREATEST(ost.ordinary_shared_teams_count - 1, 0) * 75
      )::int AS score
    FROM ordinary_shared_team_counts ost
    WHERE ost.ordinary_shared_teams_count > 0
  ),
  favorite_venue_counts AS (
    SELECT
      other_profile.id AS candidate_user_id,
      count(DISTINCT other_fav.venue_id)::int AS shared_favorite_venues_count
    FROM viewer_profile vp
    JOIN public.favorite_venues mine
      ON lower(trim(coalesce(mine.user_email, ''))) = vp.email_norm
    JOIN public.favorite_venues other_fav
      ON other_fav.venue_id::text = mine.venue_id::text
     AND lower(trim(coalesce(other_fav.user_email, ''))) <> vp.email_norm
    JOIN public.user_profiles other_profile
      ON lower(trim(coalesce(other_profile.email, ''))) = lower(trim(coalesce(other_fav.user_email, '')))
    WHERE vp.email_norm <> ''
      AND other_profile.id::text <> vp.id::text
    GROUP BY other_profile.id
  ),
  favorite_venue_matches AS (
    SELECT
      fvc.candidate_user_id,
      'favorite_venue'::text AS reason_type,
      'Both follow this venue'::text AS reason_label,
      LEAST(
        400,
        250 + GREATEST(fvc.shared_favorite_venues_count - 1, 0) * 50
      )::int AS score
    FROM favorite_venue_counts fvc
    WHERE fvc.shared_favorite_venues_count > 0
  ),
  mutual_friend_edges AS (
    SELECT DISTINCT
      cand.id AS candidate_user_id,
      vf.friend_user_id AS mutual_friend_id
    FROM viewer_profile vp
    JOIN params p ON true
    JOIN viewer_friends vf ON true
    JOIN public.friendships f
      ON f.status = 'accepted'
     AND COALESCE(f.requester_entity_type, 'user') = 'user'
     AND COALESCE(f.addressee_entity_type, 'user') = 'user'
     AND f.requester_id::text ~* p.uuid_pattern
     AND f.addressee_id::text ~* p.uuid_pattern
     AND (
       (f.requester_id::text)::uuid = vf.friend_user_id::uuid
       OR (f.addressee_id::text)::uuid = vf.friend_user_id::uuid
     )
    JOIN public.user_profiles cand
      ON cand.id::text = (
        CASE
          WHEN (f.requester_id::text)::uuid = vf.friend_user_id::uuid THEN (f.addressee_id::text)::uuid
          ELSE (f.requester_id::text)::uuid
        END
      )::text
     AND cand.id::text <> vp.id::text
    WHERE COALESCE(lower(trim(cand.admin_status)), '') = 'active'
      AND cand.admin_disabled_at IS NULL
      AND COALESCE(cand.is_business_account, false) = false
      AND COALESCE(cand.discoverable_by_fans, true) = true
      AND COALESCE(cand.is_deleted, false) = false
      AND NOT lower(trim(coalesce(cand.email, ''))) LIKE '%@deleted.fangeo.local'
      AND COALESCE(cand.age_access_status, 'unknown') <> 'blocked_under_13'
  ),
  mutual_friend_counts AS (
    SELECT
      mfe.candidate_user_id,
      count(DISTINCT mfe.mutual_friend_id)::int AS mutual_friend_count
    FROM mutual_friend_edges mfe
    GROUP BY mfe.candidate_user_id
  ),
  mutual_friend_matches AS (
    SELECT
      mfc.candidate_user_id,
      'mutual_friends'::text AS reason_type,
      (mfc.mutual_friend_count::text || ' mutual ' || CASE WHEN mfc.mutual_friend_count = 1 THEN 'fan' ELSE 'fans' END)::text AS reason_label,
      LEAST(
        1100,
        800 + GREATEST(mfc.mutual_friend_count - 1, 0) * 100
      )::int AS score
    FROM mutual_friend_counts mfc
    WHERE mfc.mutual_friend_count > 0
  ),
  mutual_friend_avatar_rows AS (
    SELECT
      ranked.candidate_user_id,
      ranked.mutual_friend_id,
      ranked.display_name,
      ranked.avatar_url,
      ranked.avatar_thumbnail_url
    FROM (
      SELECT
        mfe.candidate_user_id,
        mf.id AS mutual_friend_id,
        mf.display_name,
        mf.avatar_url,
        mf.avatar_thumbnail_url,
        row_number() OVER (
          PARTITION BY mfe.candidate_user_id
          ORDER BY lower(trim(coalesce(mf.display_name, mf.username, ''))) ASC, mf.id ASC
        ) AS rn
      FROM mutual_friend_edges mfe
      JOIN public.user_profiles mf
        ON mf.id::text = mfe.mutual_friend_id::text
      WHERE COALESCE(lower(trim(mf.admin_status)), '') = 'active'
        AND mf.admin_disabled_at IS NULL
        AND COALESCE(mf.is_business_account, false) = false
        AND COALESCE(mf.discoverable_by_fans, true) = true
    ) ranked
    WHERE ranked.rn <= 3
  ),
  mutual_friend_avatar_agg AS (
    SELECT
      mfar.candidate_user_id,
      jsonb_agg(
        jsonb_build_object(
          'user_id', mfar.mutual_friend_id,
          'display_name', mfar.display_name,
          'avatar_url', mfar.avatar_url,
          'avatar_thumbnail_url', mfar.avatar_thumbnail_url
        )
        ORDER BY lower(trim(coalesce(mfar.display_name, ''))) ASC, mfar.mutual_friend_id ASC
      ) AS mutual_friend_avatars
    FROM mutual_friend_avatar_rows mfar
    GROUP BY mfar.candidate_user_id
  ),
  proximity_matches AS (
    SELECT
      up.id AS candidate_user_id,
      'proximity'::text AS reason_type,
      'Fan nearby'::text AS reason_label,
      CASE
        WHEN dist.miles IS NULL THEN 0
        WHEN dist.miles <= 2 THEN 700
        WHEN dist.miles <= 5 THEN 550
        WHEN dist.miles <= 10 THEN 400
        WHEN dist.miles <= 20 THEN 250
        WHEN dist.miles <= 30 THEN 150
        WHEN dist.miles <= 45 THEN 75
        ELSE 0
      END AS score
    FROM viewer_location vl
    JOIN public.user_profiles up
      ON up.nearby_coarse_lat IS NOT NULL
     AND up.nearby_coarse_lng IS NOT NULL
     AND up.id::text <> vl.viewer_id::text
    CROSS JOIN LATERAL (
      SELECT
        CASE
          WHEN vl.lat IS NULL OR vl.lng IS NULL THEN NULL::double precision
          ELSE
            3958.7613 * 2 * asin(sqrt(LEAST(1,
              power(sin(radians((up.nearby_coarse_lat - vl.lat) / 2)), 2)
              + cos(radians(vl.lat))
              * cos(radians(up.nearby_coarse_lat))
              * power(sin(radians((up.nearby_coarse_lng - vl.lng) / 2)), 2)
            )))
        END AS miles
    ) dist
    WHERE vl.lat IS NOT NULL
      AND vl.lng IS NOT NULL
  ),
  recent_activity_matches AS (
    SELECT
      up.id AS candidate_user_id,
      'recent_activity'::text AS reason_type,
      'Recently active'::text AS reason_label,
      CASE
        WHEN up.last_seen_at >= now() - interval '7 days' THEN 125
        WHEN up.last_seen_at >= now() - interval '30 days' THEN 75
        ELSE 0
      END AS score
    FROM public.user_profiles up
    WHERE up.last_seen_at IS NOT NULL
      AND up.last_seen_at >= now() - interval '30 days'
      AND COALESCE(up.discoverable_by_fans, true) = true
      AND COALESCE(lower(trim(up.admin_status)), '') = 'active'
      AND up.admin_disabled_at IS NULL
      AND COALESCE(up.is_business_account, false) = false
      AND COALESCE(up.is_deleted, false) = false
      AND NOT lower(trim(coalesce(up.email, ''))) LIKE '%@deleted.fangeo.local'
      AND COALESCE(up.age_access_status, 'unknown') <> 'blocked_under_13'
  ),
  reputation_matches AS (
    SELECT
      up.id AS candidate_user_id,
      'reputation'::text AS reason_type,
      'Active FanGeo member'::text AS reason_label,
      LEAST(
        100,
        GREATEST(0, COALESCE(ux.level, 1) * 5 + COALESCE(ux.total_xp, 0) / 500)
      )::int AS score
    FROM public.user_profiles up
    LEFT JOIN public.user_xp ux
      ON ux.user_id::text = up.id::text
    WHERE COALESCE(ux.level, 1) >= 3
       OR COALESCE(ux.total_xp, 0) >= 500
  ),
  -- All ranking signals except fallback. Fallback must NOT stack with these.
  meaningful_reasons AS (
    SELECT * FROM pickup_game_matches
    UNION ALL
    SELECT * FROM venue_activity_matches
    UNION ALL
    SELECT * FROM my_team_matches
    UNION ALL
    SELECT * FROM favorite_team_matches
    UNION ALL
    SELECT * FROM favorite_venue_matches
    UNION ALL
    SELECT * FROM mutual_friend_matches
    UNION ALL
    SELECT candidate_user_id, reason_type, reason_label, score
    FROM proximity_matches
    WHERE score > 0
    UNION ALL
    SELECT * FROM recent_activity_matches WHERE score > 0
    UNION ALL
    SELECT * FROM reputation_matches WHERE score > 0
  ),
  -- Fallback only for eligible fans with zero meaningful ranking signals.
  fallback_fan_matches AS (
    SELECT
      up.id AS candidate_user_id,
      'fallback'::text AS reason_type,
      'Fan on FanGeo'::text AS reason_label,
      25 AS score
    FROM params p
    JOIN viewer_profile vp ON true
    JOIN public.user_profiles up
      ON up.id::text <> p.viewer_id::text
    WHERE p.viewer_id IS NOT NULL
      AND COALESCE(up.discoverable_by_fans, true) = true
      AND COALESCE(lower(trim(up.admin_status)), '') = 'active'
      AND up.admin_disabled_at IS NULL
      AND COALESCE(up.is_business_account, false) = false
      AND COALESCE(up.is_deleted, false) = false
      AND NOT lower(trim(coalesce(up.email, ''))) LIKE '%@deleted.fangeo.local'
      AND COALESCE(up.age_access_status, 'unknown') <> 'blocked_under_13'
      AND up.last_seen_at IS NOT NULL
      AND up.last_seen_at >= now() - interval '90 days'
      AND NOT EXISTS (
        SELECT 1
        FROM meaningful_reasons mr
        WHERE mr.candidate_user_id::text = up.id::text
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.blocked_users b
        WHERE b.blocker_user_id::text ~* p.uuid_pattern
          AND b.blocked_user_id::text ~* p.uuid_pattern
          AND (
            ((b.blocker_user_id::text)::uuid = p.viewer_id::uuid AND (b.blocked_user_id::text)::uuid = up.id::uuid)
            OR ((b.blocker_user_id::text)::uuid = up.id::uuid AND (b.blocked_user_id::text)::uuid = p.viewer_id::uuid)
          )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.friendships f
        WHERE COALESCE(f.requester_entity_type, 'user') = 'user'
          AND COALESCE(f.addressee_entity_type, 'user') = 'user'
          AND f.status IN ('accepted', 'pending', 'declined')
          AND f.requester_id::text ~* p.uuid_pattern
          AND f.addressee_id::text ~* p.uuid_pattern
          AND (
            ((f.requester_id::text)::uuid = p.viewer_id::uuid AND (f.addressee_id::text)::uuid = up.id::uuid)
            OR ((f.requester_id::text)::uuid = up.id::uuid AND (f.addressee_id::text)::uuid = p.viewer_id::uuid)
          )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.suggested_fan_dismissals d
        WHERE d.user_id::text = p.viewer_id::text
          AND d.dismissed_user_id::text = up.id::text
      )
  ),
  candidate_reasons AS (
    SELECT * FROM meaningful_reasons
    UNION ALL
    SELECT * FROM fallback_fan_matches
  ),
  candidate_scores AS (
    SELECT
      cr.candidate_user_id,
      sum(cr.score)::int AS total_score
    FROM candidate_reasons cr
    GROUP BY cr.candidate_user_id
  ),
  reason_priority AS (
    SELECT * FROM (VALUES
      ('mutual_friends', 1),
      ('pickup_game', 2),
      ('my_team', 3),
      ('my_team_affinity', 3),
      ('proximity', 4),
      ('venue_event', 5),
      ('favorite_team', 6),
      ('favorite_venue', 7),
      ('recent_activity', 8),
      ('reputation', 9),
      ('fallback', 10)
    ) AS t(reason_type, priority)
  ),
  best_reasons AS (
    SELECT DISTINCT ON (cr.candidate_user_id)
      cr.candidate_user_id,
      cr.reason_type,
      cr.reason_label
    FROM candidate_reasons cr
    LEFT JOIN reason_priority rp
      ON rp.reason_type = cr.reason_type
    ORDER BY
      cr.candidate_user_id,
      cr.score DESC,
      COALESCE(rp.priority, 99) ASC,
      cr.reason_type ASC
  ),
  eligible_ranked AS (
    SELECT
      up.id AS user_id,
      up.display_name,
      up.username,
      up.avatar_url,
      up.avatar_thumbnail_url,
      br.reason_type,
      br.reason_label,
      COALESCE(ftc.shared_favorite_teams_count, 0) AS shared_favorite_teams_count,
      COALESCE(vec.shared_event_interest_count, 0) AS shared_event_interest_count,
      COALESCE(pgc.shared_pickup_game_count, 0) AS shared_pickup_game_count,
      COALESCE(mfc.mutual_friend_count, 0) AS mutual_friend_count,
      COALESCE(mfaa.mutual_friend_avatars, '[]'::jsonb) AS mutual_friend_avatars,
      cs.total_score AS score,
      COALESCE(ux.level, 1) AS xp_level,
      COALESCE(ux.total_xp, 0) AS total_xp,
      up.created_at,
      up.last_seen_at,
      row_number() OVER (
        ORDER BY
          cs.total_score DESC,
          COALESCE(ux.level, 1) DESC,
          COALESCE(ux.total_xp, 0) DESC,
          up.created_at DESC NULLS LAST,
          up.last_seen_at DESC NULLS LAST,
          lower(trim(coalesce(up.display_name, up.username, ''))) ASC,
          up.id ASC
      ) AS score_rank
    FROM params p
    JOIN candidate_scores cs ON true
    JOIN best_reasons br
      ON br.candidate_user_id::text = cs.candidate_user_id::text
    JOIN public.user_profiles up
      ON up.id::text = cs.candidate_user_id::text
    LEFT JOIN public.user_xp ux
      ON ux.user_id::text = up.id::text
    LEFT JOIN favorite_team_counts ftc
      ON ftc.candidate_user_id::text = up.id::text
    LEFT JOIN venue_event_counts vec
      ON vec.candidate_user_id::text = up.id::text
    LEFT JOIN pickup_game_counts pgc
      ON pgc.candidate_user_id::text = up.id::text
    LEFT JOIN mutual_friend_counts mfc
      ON mfc.candidate_user_id::text = up.id::text
    LEFT JOIN mutual_friend_avatar_agg mfaa
      ON mfaa.candidate_user_id::text = up.id::text
    WHERE p.viewer_id IS NOT NULL
      AND up.id::text <> p.viewer_id::text
      AND COALESCE(up.discoverable_by_fans, true) = true
      AND COALESCE(lower(trim(up.admin_status)), '') = 'active'
      AND up.admin_disabled_at IS NULL
      AND COALESCE(up.is_business_account, false) = false
      AND COALESCE(up.is_deleted, false) = false
      AND NOT lower(trim(coalesce(up.email, ''))) LIKE '%@deleted.fangeo.local'
      AND COALESCE(up.age_access_status, 'unknown') <> 'blocked_under_13'
      AND NOT EXISTS (
        SELECT 1
        FROM public.blocked_users b
        WHERE b.blocker_user_id::text ~* p.uuid_pattern
          AND b.blocked_user_id::text ~* p.uuid_pattern
          AND (
            ((b.blocker_user_id::text)::uuid = p.viewer_id::uuid AND (b.blocked_user_id::text)::uuid = up.id::uuid)
            OR ((b.blocker_user_id::text)::uuid = up.id::uuid AND (b.blocked_user_id::text)::uuid = p.viewer_id::uuid)
          )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.friendships f
        WHERE COALESCE(f.requester_entity_type, 'user') = 'user'
          AND COALESCE(f.addressee_entity_type, 'user') = 'user'
          AND f.status IN ('accepted', 'pending', 'declined')
          AND f.requester_id::text ~* p.uuid_pattern
          AND f.addressee_id::text ~* p.uuid_pattern
          AND (
            ((f.requester_id::text)::uuid = p.viewer_id::uuid AND (f.addressee_id::text)::uuid = up.id::uuid)
            OR ((f.requester_id::text)::uuid = up.id::uuid AND (f.addressee_id::text)::uuid = p.viewer_id::uuid)
          )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.suggested_fan_dismissals d
        WHERE d.user_id::text = p.viewer_id::text
          AND d.dismissed_user_id::text = up.id::text
      )
  ),
  diversity_params AS (
    SELECT
      p.result_limit,
      -- Display-oriented: protect top 8 of any returned prefix of 10.
      LEAST(8, p.result_limit)::int AS primary_n,
      GREATEST(0, LEAST(2, p.result_limit - LEAST(8, p.result_limit)))::int AS diversity_n,
      p.viewer_id,
      p.diversity_day
    FROM params p
  ),
  primary_picks AS (
    SELECT er.*
    FROM eligible_ranked er
    JOIN diversity_params dp ON true
    WHERE er.score_rank <= dp.primary_n
  ),
  next_tier AS (
    SELECT
      er.*,
      abs(
        hashtextextended(
          dp.viewer_id::text
            || '|'
            || to_char(dp.diversity_day, 'YYYY-MM-DD')
            || '|'
            || er.user_id::text,
          0
        )
      ) AS diversity_hash
    FROM eligible_ranked er
    JOIN diversity_params dp ON true
    WHERE er.score_rank > dp.primary_n
      AND er.score_rank <= dp.primary_n + 20
      AND er.score > 25
  ),
  diversity_picks AS (
    SELECT ranked.*
    FROM (
      SELECT
        nt.*,
        row_number() OVER (ORDER BY nt.diversity_hash ASC, nt.user_id ASC) AS diversity_rn
      FROM next_tier nt
    ) ranked
    CROSS JOIN diversity_params dp
    WHERE ranked.diversity_rn <= dp.diversity_n
  ),
  -- Fill remaining slots (after primary + diversity) in score order.
  remainder_picks AS (
    SELECT er.*
    FROM eligible_ranked er
    JOIN diversity_params dp ON true
    WHERE er.score_rank > dp.primary_n
      AND NOT EXISTS (
        SELECT 1 FROM diversity_picks dpick WHERE dpick.user_id = er.user_id
      )
  ),
  ordered_output AS (
    SELECT
      pp.user_id,
      pp.display_name,
      pp.username,
      pp.avatar_url,
      pp.avatar_thumbnail_url,
      pp.reason_type,
      pp.reason_label,
      pp.shared_favorite_teams_count,
      pp.shared_event_interest_count,
      pp.shared_pickup_game_count,
      pp.mutual_friend_count,
      pp.mutual_friend_avatars,
      pp.score,
      pp.score_rank AS sort_key,
      0 AS bucket
    FROM primary_picks pp

    UNION ALL

    SELECT
      dp.user_id,
      dp.display_name,
      dp.username,
      dp.avatar_url,
      dp.avatar_thumbnail_url,
      dp.reason_type,
      dp.reason_label,
      dp.shared_favorite_teams_count,
      dp.shared_event_interest_count,
      dp.shared_pickup_game_count,
      dp.mutual_friend_count,
      dp.mutual_friend_avatars,
      dp.score,
      dp.diversity_rn AS sort_key,
      1 AS bucket
    FROM diversity_picks dp

    UNION ALL

    SELECT
      rp.user_id,
      rp.display_name,
      rp.username,
      rp.avatar_url,
      rp.avatar_thumbnail_url,
      rp.reason_type,
      rp.reason_label,
      rp.shared_favorite_teams_count,
      rp.shared_event_interest_count,
      rp.shared_pickup_game_count,
      rp.mutual_friend_count,
      rp.mutual_friend_avatars,
      rp.score,
      rp.score_rank AS sort_key,
      2 AS bucket
    FROM remainder_picks rp
  )
  SELECT
    oo.user_id,
    oo.display_name,
    oo.username,
    oo.avatar_url,
    oo.avatar_thumbnail_url,
    oo.reason_type,
    oo.reason_label,
    oo.shared_favorite_teams_count,
    oo.shared_event_interest_count,
    oo.shared_pickup_game_count,
    oo.mutual_friend_count,
    oo.mutual_friend_avatars,
    oo.score
  FROM ordered_output oo
  ORDER BY oo.bucket ASC, oo.sort_key ASC, oo.user_id ASC
  LIMIT (SELECT result_limit FROM params);
$$;

REVOKE ALL ON FUNCTION public.get_profile_friend_suggestions(
  int,
  numeric,
  double precision,
  double precision
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_profile_friend_suggestions(
  int,
  numeric,
  double precision,
  double precision
) TO authenticated;

COMMENT ON FUNCTION public.get_profile_friend_suggestions(
  int,
  numeric,
  double precision,
  double precision
) IS
  'Ranked privacy-safe fan suggestions (rebalanced 20260895). Additive scores: mutuals, pickup, coarse proximity, MY TEAM, teams, watch parties, venues, activity, XP; fallback +25 only when no meaningful signal exists. Excludes self/friends/pending/declined/blocks/business/disabled/undiscoverable/deleted/dismissals/under-13. Never returns coordinates or exact distance. Default radius 45 miles. Viewer gated by age_access_allows_social.';
