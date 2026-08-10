-- Expand pickup_games.game_format + add nullable competition_level.
--
-- Do NOT apply from the agent. Apply only after older-app compatibility review.
--
-- Architecture: still one system (pickup_games + fan_team_game_links).
-- No League / Tournament management tables.
--
-- Formats:
--   pickup | practice | scrimmage | match (legacy) |
--   league_game | tournament_game | tryout | clinic
--
-- Team Event intentionally OMITTED from v1: pickup_games.players_needed CHECK
-- requires >= 1, which is incompatible with non-playing Team activities without
-- weakening core Pickup constraints.
--
-- competition_level (nullable):
--   youth | high_school | college_university | adult_recreational |
--   adult_competitive | semi_pro | professional
--
-- Privacy / RLS unchanged (is_visible + existing policies).

-- ---------------------------------------------------------------------------
-- 1) Widen game_format CHECK (preserve legacy match)
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
      'clinic'
    )
  );

-- ---------------------------------------------------------------------------
-- 2) competition_level (nullable for backward compatibility)
-- ---------------------------------------------------------------------------
ALTER TABLE public.pickup_games
  ADD COLUMN IF NOT EXISTS competition_level text;

ALTER TABLE public.pickup_games
  DROP CONSTRAINT IF EXISTS pickup_games_competition_level_check;

ALTER TABLE public.pickup_games
  ADD CONSTRAINT pickup_games_competition_level_check
  CHECK (
    competition_level IS NULL
    OR lower(btrim(competition_level)) IN (
      'youth',
      'high_school',
      'college_university',
      'adult_recreational',
      'adult_competitive',
      'semi_pro',
      'professional'
    )
  );

COMMENT ON COLUMN public.pickup_games.competition_level IS
  'Optional sport level axis (youth…professional). Independent of game_format. Null = unspecified.';

-- ---------------------------------------------------------------------------
-- 3) Team link allowlist (legacy match + new Team-compatible formats)
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

  -- Plain `pickup` is not Team-linkable. Team Event deferred (v1).
  IF v_format NOT IN (
    'practice',
    'scrimmage',
    'match',
    'league_game',
    'tournament_game',
    'tryout',
    'clinic'
  ) THEN
    RAISE EXCEPTION 'Team games must use practice, scrimmage, league_game, tournament_game, tryout, clinic, or legacy match.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.fan_teams t
    WHERE t.id = p_team_id AND t.is_active = true
  ) THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.fan_team_game_links l
    WHERE l.pickup_game_id = p_pickup_game_id
      AND l.team_id = p_team_id
  ) THEN
    RETURN p_pickup_game_id;
  END IF;

  v_side := CASE WHEN v_format = 'practice' THEN 'solo' ELSE 'home' END;

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

COMMENT ON FUNCTION public.link_pickup_game_to_fan_team(uuid, uuid) IS
  'Links creator-owned active pickup_games to a Fan Team. Allowed formats: '
  'practice|scrimmage|match|league_game|tournament_game|tryout|clinic. '
  'Preserves is_visible. practice→solo; others→home.';

-- ---------------------------------------------------------------------------
-- 4) list_fan_team_games — include competition_level (optional for older clients)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.list_fan_team_games(uuid);

CREATE FUNCTION public.list_fan_team_games(p_team_id uuid)
RETURNS TABLE (
  id uuid,
  team_id uuid,
  created_by uuid,
  game_type text,
  sport text,
  title text,
  starts_at timestamptz,
  ends_at timestamptz,
  venue_name text,
  address text,
  city text,
  state text,
  latitude double precision,
  longitude double precision,
  opponent_team_id uuid,
  opponent_name text,
  status text,
  home_score integer,
  away_score integer,
  pickup_game_id uuid,
  my_side text,
  created_at timestamptz,
  competition_level text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF NOT public.is_active_fan_team_member(p_team_id, me) THEN
    RAISE EXCEPTION 'Not a team member.';
  END IF;

  RETURN QUERY
  SELECT
    pg.id,
    p_team_id AS team_id,
    pg.creator_user_id AS created_by,
    pg.game_format AS game_type,
    pg.sport,
    pg.title,
    pg.game_start_at AS starts_at,
    pg.end_time AS ends_at,
    pg.address AS venue_name,
    pg.address,
    pg.city,
    pg.state,
    pg.latitude,
    pg.longitude,
    (
      SELECT l2.team_id
      FROM public.fan_team_game_links l2
      WHERE l2.pickup_game_id = pg.id
        AND l2.team_id <> p_team_id
      LIMIT 1
    ) AS opponent_team_id,
    coalesce(
      (
        SELECT nullif(btrim(ot.name), '')
        FROM public.fan_team_game_links l2
        JOIN public.fan_teams ot ON ot.id = l2.team_id
        WHERE l2.pickup_game_id = pg.id
          AND l2.team_id <> p_team_id
        LIMIT 1
      ),
      nullif(btrim(pg.opponent_name), '')
    ) AS opponent_name,
    CASE
      WHEN pg.status = 'removed' THEN 'cancelled'
      WHEN pg.status = 'expired' THEN 'completed'
      WHEN pg.archived_at IS NOT NULL THEN 'completed'
      ELSE 'scheduled'
    END AS status,
    NULL::integer AS home_score,
    NULL::integer AS away_score,
    pg.id AS pickup_game_id,
    l.side AS my_side,
    pg.created_at,
    pg.competition_level
  FROM public.fan_team_game_links l
  JOIN public.pickup_games pg ON pg.id = l.pickup_game_id
  WHERE l.team_id = p_team_id
  ORDER BY pg.game_start_at DESC
  LIMIT 100;
END;
$$;

REVOKE ALL ON FUNCTION public.list_fan_team_games(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_fan_team_games(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_fan_team_games(uuid) TO service_role;

COMMENT ON FUNCTION public.list_fan_team_games(uuid) IS
  'Team Games list over pickup_games + fan_team_game_links. Includes sport, created_at, competition_level.';
