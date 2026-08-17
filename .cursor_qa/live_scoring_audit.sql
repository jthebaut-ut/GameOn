-- READ ONLY production audit. Do not mutate.

SELECT version() AS pg_version;

SELECT version AS applied_migration
FROM supabase_migrations.schema_migrations
WHERE version LIKE '202609%' OR version LIKE '202610%'
ORDER BY version;

SELECT
  p.proname,
  pg_get_function_identity_arguments(p.oid) AS args,
  pg_get_function_result(p.oid) AS result
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'list_fan_team_games',
    'fanout_fan_notification_inbox_for_pickup_update_event',
    'list_fan_notification_inbox_recipient_user_ids_for_pickup_game',
    'fan_team_viewer_has_permission',
    'fan_team_viewer_can_access_team',
    'fan_team_viewer_can_score',
    'pickup_meaningful_change_kinds',
    'queue_pickup_game_change_push_notification',
    'update_fan_team_event_score',
    'set_fan_team_event_scoring_status',
    'get_fan_team_record'
  )
ORDER BY 1, 2;

SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'pickup_games'
  AND column_name IN (
    'team_score','opponent_score','home_score','away_score',
    'scoring_status','scoring_finalized_at','opponent_name','game_format',
    'status','archived_at','sport','description','competition_level'
  )
ORDER BY column_name;

SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'fan_team_game_links'
ORDER BY ordinal_position;

SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'pickup_game_update_events'
ORDER BY ordinal_position;

SELECT
  c.relname AS table_name,
  pol.polname AS policy_name,
  pol.polcmd AS cmd,
  pg_get_expr(pol.polqual, pol.polrelid) AS using_expr,
  pg_get_expr(pol.polwithcheck, pol.polrelid) AS check_expr,
  pol.polroles::regrole[] AS roles
FROM pg_policy pol
JOIN pg_class c ON c.oid = pol.polrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN (
    'pickup_games','fan_team_game_links','pickup_game_update_events',
    'fan_team_event_score_events','fan_team_members'
  )
ORDER BY 1, 2;

SELECT tgname, pg_get_triggerdef(t.oid) AS def
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname = 'pickup_games'
  AND NOT t.tgisinternal
ORDER BY tgname;

SELECT conname, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid = 'public.pickup_game_update_events'::regclass
ORDER BY conname;
