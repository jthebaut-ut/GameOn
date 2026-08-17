-- =============================================================================
-- 20260951_0001 — Team Schedule event formats: team_meeting + other
-- =============================================================================
-- Extends pickup_games.game_format for Team-linked non-game activities.
-- Preserves all existing format tokens. Does NOT create a parallel events table.
--
-- Team Meeting / Other reuse pickup_games + fan_team_game_links with:
--   players_needed = 1, max_players = NULL (Team-only RSVP; same as recruiting OFF)
--
-- Do NOT apply from the agent; review and apply deliberately in Supabase.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Widen game_format CHECK
-- ---------------------------------------------------------------------------
ALTER TABLE public.pickup_games
  DROP CONSTRAINT IF EXISTS pickup_games_game_format_check;

ALTER TABLE public.pickup_games
  ADD CONSTRAINT pickup_games_game_format_check
  CHECK (
    lower(btrim(game_format)) IN (
      'pickup',
      'practice',
      'scrimmage',
      'match',
      'league_game',
      'tournament_game',
      'tryout',
      'clinic',
      'team_meeting',
      'other'
    )
  );

COMMENT ON COLUMN public.pickup_games.game_format IS
  'Event format: pickup|practice|scrimmage|match|league_game|tournament_game|tryout|clinic|team_meeting|other.';

-- ---------------------------------------------------------------------------
-- 2) link_pickup_game_to_fan_team — allow new Team formats
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.link_pickup_game_to_fan_team(
  p_team_id uuid,
  p_pickup_game_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_creator uuid;
  v_format text;
  v_status text;
  v_side text;
  v_existing_side text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_team_id IS NULL OR p_pickup_game_id IS NULL THEN
    RAISE EXCEPTION 'Team and pickup game are required.';
  END IF;
  IF NOT public.fan_team_viewer_can_organize(p_team_id) THEN
    RAISE EXCEPTION 'Only the owner, a manager, or head coach can schedule Team events.';
  END IF;

  SELECT g.creator_user_id, lower(btrim(coalesce(g.game_format, ''))), lower(btrim(coalesce(g.status, '')))
  INTO v_creator, v_format, v_status
  FROM public.pickup_games g
  WHERE g.id = p_pickup_game_id;

  IF v_creator IS NULL THEN
    RAISE EXCEPTION 'Pickup game not found.';
  END IF;
  IF v_creator <> me THEN
    RAISE EXCEPTION 'Only the creator can link this pickup game to a Team.';
  END IF;
  IF v_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'Only active pickup games can be linked to a Team.';
  END IF;

  -- Plain `pickup` is not Team-linkable.
  IF v_format NOT IN (
    'practice',
    'scrimmage',
    'match',
    'league_game',
    'tournament_game',
    'tryout',
    'clinic',
    'team_meeting',
    'other'
  ) THEN
    RAISE EXCEPTION 'Team events must use practice, scrimmage, league_game, tournament_game, tryout, clinic, match, team_meeting, or other.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.fan_teams t
    WHERE t.id = p_team_id AND t.is_active = true
  ) THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  -- Idempotent: already linked to this Team. Preserve is_visible.
  IF EXISTS (
    SELECT 1
    FROM public.fan_team_game_links l
    WHERE l.pickup_game_id = p_pickup_game_id
      AND l.team_id = p_team_id
  ) THEN
    RETURN p_pickup_game_id;
  END IF;

  -- Exclusive Team association for practice / meetings / other; home for fixtures.
  v_side := CASE
    WHEN v_format IN ('practice', 'team_meeting', 'other') THEN 'solo'
    ELSE 'home'
  END;

  IF v_side = 'solo' THEN
    IF EXISTS (
      SELECT 1
      FROM public.fan_team_game_links l
      WHERE l.pickup_game_id = p_pickup_game_id
    ) THEN
      RAISE EXCEPTION 'This pickup game is already linked to a Team.';
    END IF;
  ELSE
    SELECT l.side INTO v_existing_side
    FROM public.fan_team_game_links l
    WHERE l.pickup_game_id = p_pickup_game_id
      AND l.side IN ('home', 'solo')
    LIMIT 1;

    IF v_existing_side IS NOT NULL THEN
      RAISE EXCEPTION 'This pickup game already has a % Team link.', v_existing_side;
    END IF;
  END IF;

  -- Do NOT mutate is_visible — organizer choice from insert/update stands.

  INSERT INTO public.fan_team_game_links (pickup_game_id, team_id, side)
  VALUES (p_pickup_game_id, p_team_id, v_side);

  BEGIN
    PERFORM public.ensure_pickup_game_group_conversation(p_pickup_game_id);
  EXCEPTION
    WHEN undefined_function THEN
      NULL;
    WHEN OTHERS THEN
      NULL;
  END;

  RETURN p_pickup_game_id;
END;
$$;

REVOKE ALL ON FUNCTION public.link_pickup_game_to_fan_team(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.link_pickup_game_to_fan_team(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.link_pickup_game_to_fan_team(uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.link_pickup_game_to_fan_team(uuid, uuid) IS
  'Links a creator-owned active pickup_games row to a Fan Team (owner/manager/head coach). '
  'Formats: practice|scrimmage|match|league_game|tournament_game|tryout|clinic|team_meeting|other. '
  'Preserves is_visible. practice/team_meeting/other→solo; fixtures→home.';

COMMIT;
