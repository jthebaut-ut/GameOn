-- Optional enrichment for Team → Games "Recently created" sort.
-- Do NOT apply from the agent. Apply manually after prior Team/pickup migrations.
--
-- Filtering/sorting remains client-side over list_fan_team_games.
-- Without this column, iOS falls back to starts_at for recently-created sort.

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
  created_at timestamptz
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
    pg.created_at
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
  'Team Games list over pickup_games + fan_team_game_links. Includes sport + created_at for client sort.';
