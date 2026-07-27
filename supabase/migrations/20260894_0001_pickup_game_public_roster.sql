-- =============================================================================
-- 20260894_0001_pickup_game_public_roster.sql
-- REVIEW ONLY — do NOT apply to the linked production project from this change set.
--
-- Privacy-safe pickup roster for social proof:
--   • Any caller who can see the game receives organizer + approved joiners
--   • Pending applicants are returned ONLY to the game organizer
--   • Rejected / cancelled / withdrawn are never returned
-- Does NOT loosen pickup_game_requests table RLS.
-- =============================================================================

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.pickup_games') IS NULL THEN
    v_missing := v_missing || ARRAY['table pickup_games'];
  END IF;
  IF to_regclass('public.pickup_game_requests') IS NULL THEN
    v_missing := v_missing || ARRAY['table pickup_game_requests'];
  END IF;
  IF to_regclass('public.user_profiles') IS NULL THEN
    v_missing := v_missing || ARRAY['table user_profiles'];
  END IF;
  IF coalesce(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION '20260894 preflight failed: missing %', array_to_string(v_missing, ', ');
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.get_pickup_game_roster(p_pickup_game_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_creator uuid;
  v_can_read boolean := false;
  v_is_organizer boolean := false;
  v_organizer jsonb;
  v_playing jsonb := '[]'::jsonb;
  v_pending jsonb := '[]'::jsonb;
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

  -- Mirror pickup_games SELECT eligibility (authenticated path).
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
      )
  ) INTO v_can_read;

  IF NOT v_can_read THEN
    RAISE EXCEPTION 'Not authorized to view this pickup game roster.'
      USING ERRCODE = '42501';
  END IF;

  v_is_organizer := (v_creator = me);

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

  IF v_is_organizer THEN
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

  RETURN jsonb_build_object(
    'pickup_game_id', p_pickup_game_id,
    'viewer_is_organizer', v_is_organizer,
    'organizer', v_organizer,
    'playing', v_playing,
    'pending', v_pending,
    'approved_join_count', jsonb_array_length(v_playing),
    'playing_total_count', 1 + jsonb_array_length(v_playing)
  );
END;
$$;

COMMENT ON FUNCTION public.get_pickup_game_roster(uuid) IS
  'Privacy-safe pickup roster. Organizer + approved joiners for eligible viewers; '
  'pending applicants only when caller is the organizer. No rejected/cancelled/withdrawn.';

REVOKE ALL ON FUNCTION public.get_pickup_game_roster(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_pickup_game_roster(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_pickup_game_roster(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_pickup_game_roster(uuid) TO service_role;
