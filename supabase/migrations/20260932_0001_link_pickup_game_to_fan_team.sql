-- Fan Team Schedule Game → reuse classic Pickup create, then link.
--
-- Do NOT apply until ready. Architecture (approved):
--   Team → SettingsPickupGameFormView → insertPickupGame → pickup_games
--        → link_pickup_game_to_fan_team → fan_team_game_links
--
-- Organizer participation: normal insertPickupGame already establishes the
-- organizer via pickup_games.creator_user_id. Chat/roster helpers treat the
-- creator as organizer without a pickup_game_requests row. This RPC therefore
-- does NOT insert/mutate organizer attendance (no hardcoded skill_level, no
-- status overwrite of pending/withdrawn/rejected history).
--
-- Multi-Team links: schema allows one pickup + home + away (Team A vs Team B).
-- This entry point only creates the initiating Team's first link
-- (practice→solo, scrimmage/match→home). It rejects unsafe/conflicting sides
-- for THIS call, but does NOT reject merely because another side-link exists.
--
-- Visibility: iOS Team create passes is_visible=false on insert BEFORE this
-- RPC; this function also forces is_visible=false as defense in depth.

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
  IF NOT public.fan_team_viewer_can_manage(p_team_id) THEN
    RAISE EXCEPTION 'Only the owner or a manager can schedule games.';
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
  IF v_format NOT IN ('practice', 'scrimmage', 'match') THEN
    RAISE EXCEPTION 'Team games must use practice, scrimmage, or match.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.fan_teams t
    WHERE t.id = p_team_id AND t.is_active = true
  ) THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  -- Idempotent: already linked to this Team.
  IF EXISTS (
    SELECT 1
    FROM public.fan_team_game_links l
    WHERE l.pickup_game_id = p_pickup_game_id
      AND l.team_id = p_team_id
  ) THEN
    UPDATE public.pickup_games
    SET is_visible = false
    WHERE id = p_pickup_game_id
      AND is_visible IS DISTINCT FROM false;
    RETURN p_pickup_game_id;
  END IF;

  v_side := CASE WHEN v_format = 'practice' THEN 'solo' ELSE 'home' END;

  -- Side-conflict checks only (preserve future home+away on one pickup).
  -- practice/solo: exclusive single-Team association.
  IF v_side = 'solo' THEN
    IF EXISTS (
      SELECT 1
      FROM public.fan_team_game_links l
      WHERE l.pickup_game_id = p_pickup_game_id
    ) THEN
      RAISE EXCEPTION 'This pickup game is already linked to a Team.';
    END IF;
  ELSE
    -- home (scrimmage/match initiate): allow existing away (future Team-vs-Team);
    -- reject if home or solo already taken.
    SELECT l.side INTO v_existing_side
    FROM public.fan_team_game_links l
    WHERE l.pickup_game_id = p_pickup_game_id
      AND l.side IN ('home', 'solo')
    LIMIT 1;

    IF v_existing_side IS NOT NULL THEN
      RAISE EXCEPTION 'This pickup game already has a % Team link.', v_existing_side;
    END IF;
  END IF;

  UPDATE public.pickup_games
  SET is_visible = false
  WHERE id = p_pickup_game_id;

  INSERT INTO public.fan_team_game_links (pickup_game_id, team_id, side)
  VALUES (p_pickup_game_id, p_team_id, v_side);

  -- Best-effort game chat (same helper as normal Pickup). Organizer authorization
  -- is creator_user_id — no organizer pickup_game_requests row required.
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
  'Links a creator-owned active pickup_games row to a Fan Team (manager/owner only). '
  'Forces is_visible=false; writes fan_team_game_links (practice=solo, else home). '
  'Does not mutate pickup_game_requests — organizer is pickup_games.creator_user_id. '
  'Rejects conflicting sides only; allows future home+away multi-Team links.';
