
DECLARE
  me uuid := auth.uid();
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF NOT public.fan_team_viewer_can_access_team(p_team_id) THEN
    RAISE EXCEPTION 'Not authorized to view this Team.';
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
    pg.competition_level,
    nullif(btrim(coalesce(pg.description, '')), '') AS description
  FROM public.fan_team_game_links l
  JOIN public.pickup_games pg ON pg.id = l.pickup_game_id
  WHERE l.team_id = p_team_id
  ORDER BY pg.game_start_at DESC
  LIMIT 100;
END;
