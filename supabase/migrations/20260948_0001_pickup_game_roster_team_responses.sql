-- =============================================================================
-- 20260948_0001_pickup_game_roster_team_responses.sql
-- Extend get_pickup_game_roster for Team-linked attendance presentation.
--
-- Additive JSON keys (older clients ignore):
--   declined     — withdrawn / rejected / cancelled requests (Team participants + organizer)
--   no_response  — active Team members with no request row (Team participants + organizer)
--
-- For Team participants (not only organizer), also return pending (Maybe) rows so
-- Team attendance is visible to the roster — not organizer-only.
--
-- Standalone Pickup behavior for pending remains organizer-only.
-- DOES NOT delete approved participants or change RSVP write semantics.
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
  v_organizer jsonb;
  v_playing jsonb := '[]'::jsonb;
  v_pending jsonb := '[]'::jsonb;
  v_declined jsonb := '[]'::jsonb;
  v_no_response jsonb := '[]'::jsonb;
  v_include_team_responses boolean := false;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '42501';
  END IF;

  IF p_pickup_game_id IS NULL THEN
    RAISE EXCEPTION 'Pickup game id required.';
  END IF;

  SELECT g.creator_user_id INTO v_creator
  FROM public.pickup_games g
  WHERE g.id = p_pickup_game_id;

  IF v_creator IS NULL THEN
    RAISE EXCEPTION 'Pickup game not found.';
  END IF;

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
        'status', 'approved'
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
  WHERE r.pickup_game_id = p_pickup_game_id
    AND lower(btrim(r.status)) = 'approved'
    AND r.requester_user_id IS DISTINCT FROM v_creator;

  -- Pending (Maybe): organizer always; Team participants for Team-linked games.
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
          'status', 'pending'
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
    WHERE r.pickup_game_id = p_pickup_game_id
      AND lower(btrim(r.status)) = 'pending';
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
          'status', lower(btrim(r.status))
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
    WHERE r.pickup_game_id = p_pickup_game_id
      AND lower(btrim(r.status)) IN ('withdrawn', 'rejected', 'cancelled')
      AND r.requester_user_id IS DISTINCT FROM v_creator;

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
          'status', 'no_response'
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
      AND m.user_id IS DISTINCT FROM v_creator
      AND NOT EXISTS (
        SELECT 1
        FROM public.pickup_game_requests r
        WHERE r.pickup_game_id = p_pickup_game_id
          AND r.requester_user_id = m.user_id
      );
  END IF;

  RETURN jsonb_build_object(
    'pickup_game_id', p_pickup_game_id,
    'viewer_is_organizer', v_is_organizer,
    'organizer', v_organizer,
    'playing', v_playing,
    'pending', v_pending,
    'declined', v_declined,
    'no_response', v_no_response,
    'approved_join_count', jsonb_array_length(v_playing),
    'playing_total_count', 1 + jsonb_array_length(v_playing)
  );
END;
$$;

COMMENT ON FUNCTION public.get_pickup_game_roster(uuid) IS
  'Privacy-safe pickup roster. Team-linked adds declined/no_response for Team participants; pending visible to Team participants.';

COMMIT;

-- MANUAL APPLY NOTES
-- 1) Apply after 20260947 (or current latest) in Supabase SQL editor.
-- 2) No Edge Function deploy.
-- 3) Older iOS clients ignore new JSON keys.
