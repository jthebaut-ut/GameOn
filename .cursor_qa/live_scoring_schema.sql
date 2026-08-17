SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'pickup_games'
  AND column_name IN (
    'team_score','opponent_score','home_score','away_score',
    'scoring_status','scoring_finalized_at','status','archived_at',
    'opponent_name','game_format','sport'
  )
ORDER BY 1;

SELECT to_regclass('public.fan_team_event_score_events') AS score_events;

SELECT indexname
FROM pg_indexes
WHERE tablename = 'pickup_games' AND indexdef ILIKE '%scor%';

SELECT tgname
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relname = 'pickup_games' AND NOT t.tgisinternal
ORDER BY 1;

SELECT policyname, tablename, cmd
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('pickup_games', 'fan_team_game_links', 'pickup_game_update_events')
ORDER BY tablename, policyname;

SELECT grantee, privilege_type
FROM information_schema.role_table_grants
WHERE table_schema = 'public' AND table_name = 'pickup_games'
  AND grantee IN ('anon','authenticated','PUBLIC','service_role')
ORDER BY 1, 2;

SELECT pg_get_function_result(p.oid) AS result
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'list_fan_team_games';

SELECT reltuples::bigint AS est_rows
FROM pg_class
WHERE oid = 'public.pickup_games'::regclass;
