SELECT jsonb_build_object(
  'all_migrations_tail', (
    SELECT coalesce(jsonb_agg(version ORDER BY version), '[]'::jsonb)
    FROM (
      SELECT version FROM supabase_migrations.schema_migrations ORDER BY version DESC LIMIT 40
    ) s
  ),
  'list_src', (
    SELECT p.prosrc FROM pg_proc p
    WHERE p.oid = to_regprocedure('public.list_fan_team_games(uuid)')
  ),
  'fanout_src', (
    SELECT p.prosrc FROM pg_proc p
    WHERE p.oid = to_regprocedure(
      'public.fanout_fan_notification_inbox_for_pickup_update_event(uuid)'
    )
  ),
  'list_config', (
    SELECT p.proconfig FROM pg_proc p
    WHERE p.oid = to_regprocedure('public.list_fan_team_games(uuid)')
  ),
  'fanout_config', (
    SELECT p.proconfig FROM pg_proc p
    WHERE p.oid = to_regprocedure(
      'public.fanout_fan_notification_inbox_for_pickup_update_event(uuid)'
    )
  ),
  'list_acl', (
    SELECT pg_get_functiondef(p.oid)
    FROM pg_proc p
    WHERE p.oid = to_regprocedure('public.list_fan_team_games(uuid)')
  )
) AS dump;
