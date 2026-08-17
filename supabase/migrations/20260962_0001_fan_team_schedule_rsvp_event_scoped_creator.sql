-- =============================================================================
-- 20260962_0001 — Team Schedule RSVP: event-scoped creator (minimal)
-- =============================================================================
-- ROOT CAUSE:
--   get_pickup_game_roster always emitted creator as `organizer` and EXCLUDED them
--   from Team playing/declined/no_response. Clients treated organizer ∪ playing as
--   Going, so every Team event the creator scheduled looked Going regardless of
--   that event's pickup_game_requests row.
--
-- THIS MIGRATION (MINIMAL):
--   Starts from the authoritative 20260961 get_pickup_game_roster body and applies
--   ONLY creator-RSVP presentation fixes for Team-linked events:
--     • Team: creator approved  → playing (Going)
--     • Team: creator pending   → already in pending (Maybe)
--     • Team: creator withdrawn → declined (Can't Go)
--     • Team: creator no row    → no_response
--     • Standalone Pickup: creator still excluded from playing; playing_total
--       remains 1 + joiners (host semantics unchanged)
--     • Team playing_total_count = jsonb_array_length(playing) AFTER managed merge
--       (accounts + managed Going + creator only if approved)
--     • approved_join_count remains joiner-only (excludes creator) for capacity
--
-- EXPLICITLY NOT REDEFINED (would regress 20260960/61 / taxonomy):
--   • schedule_fan_team_game — current iOS Team create is insertPickupGame +
--     link_pickup_game_to_fan_team, which already does NOT auto-insert creator Going.
--     Recreating schedule_fan_team_game from 20260926 would collapse event taxonomy
--     back to match/scrimmage/practice and overwrite newer scheduling behavior.
--   • save_fan_team_event_lineup, set_fan_team_game_rsvp*, managed-player helpers,
--     exclusions, push recipients — untouched.
--
-- NOT APPLIED automatically. Forward-only CREATE OR REPLACE of ONE function.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_pickup_game_roster(p_pickup_game_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_creator uuid;
  v_can_read boolean := false;
  v_is_organizer boolean := false;
  v_is_team_participant boolean := false;
  v_team_id uuid;
  v_game_start_at timestamptz;
  v_game_is_future boolean := false;
  v_organizer jsonb;
  v_playing jsonb := '[]'::jsonb;
  v_pending jsonb := '[]'::jsonb;
  v_declined jsonb := '[]'::jsonb;
  v_no_response jsonb := '[]'::jsonb;
  v_excluded jsonb := '[]'::jsonb;
  v_managed_playing jsonb := '[]'::jsonb;
  v_managed_pending jsonb := '[]'::jsonb;
  v_managed_declined jsonb := '[]'::jsonb;
  v_managed_no_response jsonb := '[]'::jsonb;
  v_managed_excluded jsonb := '[]'::jsonb;
  v_account_playing_count integer := 0;
  v_include_team_responses boolean := false;
  v_can_manage_event_roster boolean := false;
  v_can_view_excluded boolean := false;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '42501';
  END IF;

  IF p_pickup_game_id IS NULL THEN
    RAISE EXCEPTION 'Pickup game id required.';
  END IF;

  SELECT g.creator_user_id, g.game_start_at INTO v_creator, v_game_start_at
  FROM public.pickup_games g
  WHERE g.id = p_pickup_game_id;

  IF v_creator IS NULL THEN
    RAISE EXCEPTION 'Pickup game not found.';
  END IF;

  v_game_is_future := (v_game_start_at IS NOT NULL AND v_game_start_at >= now());

  SELECT EXISTS (
    SELECT 1
    FROM public.pickup_games g
    WHERE g.id = p_pickup_game_id
      AND (
        g.creator_user_id = me
        OR (
          lower(btrim(g.status)) = 'active'
          AND g.is_visible IS TRUE
          AND (g.remove_after_at IS NULL OR g.remove_after_at > now())
        )
        OR public.can_read_pickup_game_for_requester(g.id)
        OR public.is_pickup_game_fan_team_participant(g.id, me)
      )
  ) INTO v_can_read;

  IF NOT v_can_read THEN
    RAISE EXCEPTION 'Not authorized to view this pickup game roster.'
      USING ERRCODE = '42501';
  END IF;

  v_is_organizer := (v_creator = me);
  v_is_team_participant := public.is_pickup_game_fan_team_participant(p_pickup_game_id, me);

  SELECT l.team_id INTO v_team_id
  FROM public.fan_team_game_links l
  WHERE l.pickup_game_id = p_pickup_game_id
  LIMIT 1;

  v_include_team_responses := (v_team_id IS NOT NULL)
    AND (v_is_organizer OR v_is_team_participant);

  v_can_manage_event_roster := (v_team_id IS NOT NULL)
    AND public.fan_team_viewer_can_manage_lineup(v_team_id);

  v_can_view_excluded := v_include_team_responses OR v_can_manage_event_roster;

  SELECT jsonb_build_object(
    'user_id', up.id,
    'display_name', nullif(btrim(coalesce(up.display_name, '')), ''),
    'username', nullif(btrim(coalesce(up.username, '')), ''),
    'avatar_url', nullif(btrim(coalesce(up.avatar_url, '')), ''),
    'avatar_thumbnail_url', nullif(btrim(coalesce(up.avatar_thumbnail_url, up.avatar_url, '')), ''),
    'role', 'organizer'
  )
  INTO v_organizer
  FROM public.user_profiles up
  WHERE up.id = v_creator
    AND coalesce(up.is_deleted, false) = false;

  IF v_organizer IS NULL THEN
    v_organizer := jsonb_build_object(
      'user_id', v_creator,
      'display_name', NULL,
      'username', NULL,
      'avatar_url', NULL,
      'avatar_thumbnail_url', NULL,
      'role', 'organizer'
    );
  END IF;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'user_id', r.requester_user_id,
        'request_id', r.id,
        'display_name', coalesce(
          nullif(btrim(coalesce(up.display_name, '')), ''),
          nullif(btrim(coalesce(r.requester_display_name, '')), '')
        ),
        'username', nullif(btrim(coalesce(up.username, '')), ''),
        'avatar_url', nullif(btrim(coalesce(up.avatar_url, '')), ''),
        'avatar_thumbnail_url', nullif(btrim(coalesce(up.avatar_thumbnail_url, up.avatar_url, '')), ''),
        'role', 'playing',
        'status', 'approved',
        'membership_id', fm.membership_id,
        'is_managed_player', false,
        'managed_player_id', NULL
      )
      ORDER BY r.responded_at NULLS LAST, r.created_at ASC, r.id ASC
    ),
    '[]'::jsonb
  )
  INTO v_playing
  FROM public.pickup_game_requests r
  LEFT JOIN public.user_profiles up
    ON up.id = r.requester_user_id
   AND coalesce(up.is_deleted, false) = false
  LEFT JOIN public.fan_team_members fm
    ON fm.team_id = v_team_id
   AND fm.user_id = r.requester_user_id
   AND fm.left_at IS NULL
  WHERE r.pickup_game_id = p_pickup_game_id
    AND lower(btrim(r.status)) = 'approved'
    AND (
      -- Standalone Pickup: creator stays out of playing (host via organizer object).
      -- Team-linked: creator appears in playing only when they RSVP'd Going for THIS event.
      (v_team_id IS NULL AND r.requester_user_id IS DISTINCT FROM v_creator)
      OR (v_team_id IS NOT NULL)
    )
    AND (
      v_team_id IS NULL
      OR public.is_fan_team_linked_request_actor_eligible(
        v_team_id, r.requester_user_id, r.created_at, v_game_is_future
      )
    )
    AND (
      v_team_id IS NULL
      OR NOT public.is_fan_team_event_member_excluded(v_team_id, p_pickup_game_id, r.requester_user_id)
    );

  -- approved_join_count stays joiner-only (excludes creator) for capacity math.
  SELECT count(*)::integer INTO v_account_playing_count
  FROM jsonb_array_elements(v_playing) elem
  WHERE (elem->>'user_id')::uuid IS DISTINCT FROM v_creator;
  IF v_account_playing_count IS NULL THEN
    v_account_playing_count := 0;
  END IF;

  IF v_is_organizer OR v_include_team_responses THEN
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'user_id', r.requester_user_id,
          'request_id', r.id,
          'display_name', coalesce(
            nullif(btrim(coalesce(up.display_name, '')), ''),
            nullif(btrim(coalesce(r.requester_display_name, '')), '')
          ),
          'username', nullif(btrim(coalesce(up.username, '')), ''),
          'avatar_url', nullif(btrim(coalesce(up.avatar_url, '')), ''),
          'avatar_thumbnail_url', nullif(btrim(coalesce(up.avatar_thumbnail_url, up.avatar_url, '')), ''),
          'role', 'pending',
          'status', 'pending',
          'membership_id', fm.membership_id,
          'is_managed_player', false,
          'managed_player_id', NULL
        )
        ORDER BY r.created_at ASC, r.id ASC
      ),
      '[]'::jsonb
    )
    INTO v_pending
    FROM public.pickup_game_requests r
    LEFT JOIN public.user_profiles up
      ON up.id = r.requester_user_id
     AND coalesce(up.is_deleted, false) = false
    LEFT JOIN public.fan_team_members fm
      ON fm.team_id = v_team_id
     AND fm.user_id = r.requester_user_id
     AND fm.left_at IS NULL
    WHERE r.pickup_game_id = p_pickup_game_id
      AND lower(btrim(r.status)) = 'pending'
      AND (
        v_team_id IS NULL
        OR public.is_fan_team_linked_request_actor_eligible(
          v_team_id, r.requester_user_id, r.created_at, v_game_is_future
        )
      )
      AND (
        v_team_id IS NULL
        OR NOT public.is_fan_team_event_member_excluded(v_team_id, p_pickup_game_id, r.requester_user_id)
      );
  END IF;

  IF v_include_team_responses THEN
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'user_id', r.requester_user_id,
          'request_id', r.id,
          'display_name', coalesce(
            nullif(btrim(coalesce(up.display_name, '')), ''),
            nullif(btrim(coalesce(r.requester_display_name, '')), '')
          ),
          'username', nullif(btrim(coalesce(up.username, '')), ''),
          'avatar_url', nullif(btrim(coalesce(up.avatar_url, '')), ''),
          'avatar_thumbnail_url', nullif(btrim(coalesce(up.avatar_thumbnail_url, up.avatar_url, '')), ''),
          'role', 'declined',
          'status', lower(btrim(r.status)),
          'membership_id', fm.membership_id,
          'is_managed_player', false,
          'managed_player_id', NULL
        )
        ORDER BY r.updated_at DESC NULLS LAST, r.created_at ASC, r.id ASC
      ),
      '[]'::jsonb
    )
    INTO v_declined
    FROM public.pickup_game_requests r
    LEFT JOIN public.user_profiles up
      ON up.id = r.requester_user_id
     AND coalesce(up.is_deleted, false) = false
    LEFT JOIN public.fan_team_members fm
      ON fm.team_id = v_team_id
     AND fm.user_id = r.requester_user_id
     AND fm.left_at IS NULL
    WHERE r.pickup_game_id = p_pickup_game_id
      AND lower(btrim(r.status)) IN ('withdrawn', 'rejected', 'cancelled')
      -- Team Schedule: include creator Can't Go for THIS event (not organizer-as-Going).
      AND public.is_fan_team_linked_request_actor_eligible(
        v_team_id, r.requester_user_id, r.created_at, v_game_is_future
      )
      AND NOT public.is_fan_team_event_member_excluded(v_team_id, p_pickup_game_id, r.requester_user_id);

    -- No Response = ACTIVE ACCOUNT members with no request row (never former
    -- members, never event-excluded members — they live in 'excluded' instead).
    -- Managed seats are handled by their own query below because they have no
    -- pickup_game_requests row and no user_profiles row.
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'user_id', m.user_id,
          'request_id', NULL,
          'display_name', nullif(btrim(coalesce(up.display_name, '')), ''),
          'username', nullif(btrim(coalesce(up.username, '')), ''),
          'avatar_url', nullif(btrim(coalesce(up.avatar_url, '')), ''),
          'avatar_thumbnail_url', nullif(btrim(coalesce(up.avatar_thumbnail_url, up.avatar_url, '')), ''),
          'role', 'no_response',
          'status', 'no_response',
          'membership_id', m.membership_id,
          'is_managed_player', false,
          'managed_player_id', NULL
        )
        ORDER BY lower(coalesce(up.display_name, up.username, '')), m.user_id
      ),
      '[]'::jsonb
    )
    INTO v_no_response
    FROM public.fan_team_members m
    LEFT JOIN public.user_profiles up
      ON up.id = m.user_id
     AND coalesce(up.is_deleted, false) = false
    WHERE m.team_id = v_team_id
      AND m.left_at IS NULL
      AND m.user_id IS NOT NULL
      -- Include creator when they have no pickup_game_requests row for THIS event.
      AND NOT public.is_fan_team_event_member_excluded(v_team_id, p_pickup_game_id, m.user_id)
      AND NOT EXISTS (
        SELECT 1
        FROM public.pickup_game_requests r
        WHERE r.pickup_game_id = p_pickup_game_id
          AND r.requester_user_id = m.user_id
          AND (
            NOT v_game_is_future
            OR public.is_fan_team_linked_request_actor_eligible(
              v_team_id, r.requester_user_id, r.created_at, v_game_is_future
            )
          )
      );
  END IF;

  -- Managed seats: attendance comes from fan_team_event_rsvps.
  IF v_team_id IS NOT NULL AND v_include_team_responses THEN
    SELECT
      coalesce(
        jsonb_agg(seat.seat_row ORDER BY seat.sort_name, seat.membership_id)
          FILTER (WHERE seat.bucket = 'playing'),
        '[]'::jsonb
      ),
      coalesce(
        jsonb_agg(seat.seat_row ORDER BY seat.sort_name, seat.membership_id)
          FILTER (WHERE seat.bucket = 'pending'),
        '[]'::jsonb
      ),
      coalesce(
        jsonb_agg(seat.seat_row ORDER BY seat.sort_name, seat.membership_id)
          FILTER (WHERE seat.bucket = 'declined'),
        '[]'::jsonb
      ),
      coalesce(
        jsonb_agg(seat.seat_row ORDER BY seat.sort_name, seat.membership_id)
          FILTER (WHERE seat.bucket = 'no_response'),
        '[]'::jsonb
      )
    INTO v_managed_playing, v_managed_pending, v_managed_declined, v_managed_no_response
    FROM (
      SELECT
        m.membership_id,
        lower(coalesce(btrim(mp.display_name), '')) AS sort_name,
        CASE lower(btrim(coalesce(r.status, '')))
          WHEN 'going' THEN 'playing'
          WHEN 'maybe' THEN 'pending'
          WHEN 'cant_go' THEN 'declined'
          ELSE 'no_response'
        END AS bucket,
        jsonb_build_object(
          'user_id', m.managed_player_id,
          'request_id', NULL,
          'display_name', nullif(btrim(coalesce(mp.display_name, '')), ''),
          'username', NULL,
          'avatar_url', nullif(btrim(coalesce(mp.avatar_url, '')), ''),
          'avatar_thumbnail_url',
            nullif(btrim(coalesce(mp.avatar_thumbnail_url, mp.avatar_url, '')), ''),
          'role', CASE lower(btrim(coalesce(r.status, '')))
            WHEN 'going' THEN 'playing'
            WHEN 'maybe' THEN 'pending'
            WHEN 'cant_go' THEN 'declined'
            ELSE 'no_response'
          END,
          'status', CASE lower(btrim(coalesce(r.status, '')))
            WHEN 'going' THEN 'approved'
            WHEN 'maybe' THEN 'pending'
            WHEN 'cant_go' THEN 'cant_go'
            ELSE 'no_response'
          END,
          'membership_id', m.membership_id,
          'is_managed_player', true,
          'managed_player_id', m.managed_player_id
        ) AS seat_row
      FROM public.fan_team_members m
      JOIN public.fan_managed_players mp ON mp.id = m.managed_player_id
      LEFT JOIN public.fan_team_event_rsvps r
        ON r.membership_id = m.membership_id
       AND r.pickup_game_id = p_pickup_game_id
       AND r.team_id = m.team_id
      WHERE m.team_id = v_team_id
        AND m.left_at IS NULL
        AND m.managed_player_id IS NOT NULL
        AND NOT public.is_fan_team_event_managed_player_excluded(
          v_team_id, p_pickup_game_id, m.managed_player_id
        )
    ) seat;

    v_playing := v_playing || v_managed_playing;
    v_pending := v_pending || v_managed_pending;
    v_declined := v_declined || v_managed_declined;
    v_no_response := v_no_response || v_managed_no_response;
  END IF;

  IF v_team_id IS NOT NULL AND v_can_view_excluded THEN
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'user_id', m.user_id,
          'request_id', NULL,
          'display_name', nullif(btrim(coalesce(up.display_name, '')), ''),
          'username', nullif(btrim(coalesce(up.username, '')), ''),
          'avatar_url', nullif(btrim(coalesce(up.avatar_url, '')), ''),
          'avatar_thumbnail_url', nullif(btrim(coalesce(up.avatar_thumbnail_url, up.avatar_url, '')), ''),
          'role', 'excluded',
          'status', 'excluded',
          'membership_id', m.membership_id,
          'is_managed_player', false,
          'managed_player_id', NULL
        )
        ORDER BY lower(coalesce(up.display_name, up.username, '')), m.user_id
      ),
      '[]'::jsonb
    )
    INTO v_excluded
    FROM public.fan_team_members m
    INNER JOIN public.fan_team_event_exclusions e
      ON e.team_id = m.team_id
     AND e.pickup_game_id = p_pickup_game_id
     AND e.user_id = m.user_id
    LEFT JOIN public.user_profiles up
      ON up.id = m.user_id
     AND coalesce(up.is_deleted, false) = false
    WHERE m.team_id = v_team_id
      AND m.left_at IS NULL
      AND m.user_id IS NOT NULL;

    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'user_id', m.managed_player_id,
          'request_id', NULL,
          'display_name', nullif(btrim(coalesce(mp.display_name, '')), ''),
          'username', NULL,
          'avatar_url', nullif(btrim(coalesce(mp.avatar_url, '')), ''),
          'avatar_thumbnail_url',
            nullif(btrim(coalesce(mp.avatar_thumbnail_url, mp.avatar_url, '')), ''),
          'role', 'excluded',
          'status', 'excluded',
          'membership_id', m.membership_id,
          'is_managed_player', true,
          'managed_player_id', m.managed_player_id
        )
        ORDER BY lower(coalesce(btrim(mp.display_name), '')), m.membership_id
      ),
      '[]'::jsonb
    )
    INTO v_managed_excluded
    FROM public.fan_team_members m
    JOIN public.fan_managed_players mp ON mp.id = m.managed_player_id
    INNER JOIN public.fan_team_event_exclusions e
      ON e.team_id = m.team_id
     AND e.pickup_game_id = p_pickup_game_id
     AND e.managed_player_id = m.managed_player_id
    WHERE m.team_id = v_team_id
      AND m.left_at IS NULL;

    v_excluded := v_excluded || v_managed_excluded;
  END IF;

  RETURN jsonb_build_object(
    'pickup_game_id', p_pickup_game_id,
    'viewer_is_organizer', v_is_organizer,
    'organizer', v_organizer,
    'playing', v_playing,
    'pending', v_pending,
    'declined', v_declined,
    'no_response', v_no_response,
    'excluded', v_excluded,
    'viewer_can_manage_event_roster', v_can_manage_event_roster,
    'approved_join_count', v_account_playing_count,
    -- Standalone: host always counts (+ joiners). Team: count every Going seat in
    -- v_playing after managed merge (creator only if approved for THIS event).
    'playing_total_count',
      CASE
        WHEN v_team_id IS NULL THEN 1 + v_account_playing_count
        ELSE jsonb_array_length(v_playing)
      END
  );
END;
$$;


COMMENT ON FUNCTION public.get_pickup_game_roster(uuid) IS
  'Privacy-safe pickup roster with dual participant identity (20260961 + 20260962). '
  'Team-linked creators appear in playing/pending/declined/no_response from their '
  'event-scoped pickup_game_requests row; organizer object remains host identity only. '
  'Standalone keeps creator out of playing and playing_total = 1 + joiners. '
  'Managed seats (fan_team_event_rsvps) unchanged. approved_join_count is joiner-only; '
  'Team playing_total_count counts Going seats after managed merge.';

REVOKE ALL ON FUNCTION public.get_pickup_game_roster(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_pickup_game_roster(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_pickup_game_roster(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_pickup_game_roster(uuid) TO service_role;

-- Structural asserts: prove we did not drop managed-player / dual-identity contracts.
DO $$
DECLARE
  v_src text;
BEGIN
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'get_pickup_game_roster'
  ORDER BY oid DESC
  LIMIT 1;

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'assert_failed: get_pickup_game_roster missing';
  END IF;
  IF position('fan_team_event_rsvps' IN v_src) = 0 THEN
    RAISE EXCEPTION 'assert_failed: managed RSVP source missing from roster';
  END IF;
  IF position('is_managed_player' IN v_src) = 0 THEN
    RAISE EXCEPTION 'assert_failed: managed player flag missing from roster';
  END IF;
  IF position('membership_id' IN v_src) = 0 THEN
    RAISE EXCEPTION 'assert_failed: membership_id missing from roster';
  END IF;
  IF position('is_fan_team_event_managed_player_excluded' IN v_src) = 0 THEN
    RAISE EXCEPTION 'assert_failed: managed exclusion helper missing from roster';
  END IF;
  -- Creator Team inclusion markers
  IF position('v_team_id IS NOT NULL' IN v_src) = 0 THEN
    RAISE EXCEPTION 'assert_failed: Team-linked creator playing branch missing';
  END IF;
END $$;

COMMIT;

-- =============================================================================
-- MANUAL APPLY NOTES
-- =============================================================================
-- 1) Apply AFTER 20260961.
-- 2) Do NOT apply 20260962 variants that redefine schedule_fan_team_game from
--    20260926 (taxonomy regression).
-- 3) Current Team Schedule create path (no auto creator Going):
--      insertPickupGame → link_pickup_game_to_fan_team
-- 4) Verify:
--    -- Team creator unanswered appears in no_response, not implied Going
--    SELECT get_pickup_game_roster('<team_game>');
--    -- Managed Going still present after merge
--    SELECT jsonb_array_length(get_pickup_game_roster('<g>')->'playing');
-- =============================================================================
