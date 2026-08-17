-- READ ONLY. Single result set for CLI.

SELECT jsonb_build_object(
  'pg_version', (SELECT version()),
  'applied_202609_plus', (
    SELECT coalesce(jsonb_agg(version ORDER BY version), '[]'::jsonb)
    FROM supabase_migrations.schema_migrations
    WHERE version LIKE '202609%' OR version LIKE '202610%'
  ),
  'functions', (
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'proname', p.proname,
      'args', pg_get_function_identity_arguments(p.oid),
      'result', pg_get_function_result(p.oid)
    ) ORDER BY p.proname, pg_get_function_identity_arguments(p.oid)), '[]'::jsonb)
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
        'get_fan_team_record',
        'correct_fan_team_event_final_score'
      )
  ),
  'pickup_games_score_cols', (
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'column_name', column_name,
      'data_type', data_type,
      'is_nullable', is_nullable,
      'column_default', column_default
    ) ORDER BY column_name), '[]'::jsonb)
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'pickup_games'
      AND column_name IN (
        'team_score','opponent_score','home_score','away_score',
        'scoring_status','scoring_finalized_at','opponent_name','game_format',
        'status','archived_at','sport','description','competition_level'
      )
  ),
  'fan_team_game_links_cols', (
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'column_name', column_name,
      'data_type', data_type,
      'is_nullable', is_nullable
    ) ORDER BY ordinal_position), '[]'::jsonb)
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'fan_team_game_links'
  ),
  'score_audit_exists', to_regclass('public.fan_team_event_score_events') IS NOT NULL,
  'pickup_games_triggers', (
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'tgname', t.tgname,
      'def', pg_get_triggerdef(t.oid)
    ) ORDER BY t.tgname), '[]'::jsonb)
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'pickup_games'
      AND NOT t.tgisinternal
  ),
  'pickup_games_grants', (
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'grantee', grantee,
      'privilege_type', privilege_type
    ) ORDER BY grantee, privilege_type), '[]'::jsonb)
    FROM information_schema.role_table_grants
    WHERE table_schema = 'public' AND table_name = 'pickup_games'
      AND grantee IN ('anon','authenticated','PUBLIC','service_role')
  ),
  'pickup_games_policies', (
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'policy_name', pol.polname,
      'cmd', pol.polcmd
    ) ORDER BY pol.polname), '[]'::jsonb)
    FROM pg_policy pol
    JOIN pg_class c ON c.oid = pol.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = 'pickup_games'
  ),
  'list_fan_team_games_src_sha', (
    SELECT md5(p.prosrc)
    FROM pg_proc p
    WHERE p.oid = to_regprocedure('public.list_fan_team_games(uuid)')
  ),
  'fanout_src_sha', (
    SELECT md5(p.prosrc)
    FROM pg_proc p
    WHERE p.oid = to_regprocedure(
      'public.fanout_fan_notification_inbox_for_pickup_update_event(uuid)'
    )
  ),
  'list_has_description', (
    SELECT position('description' IN p.prosrc) > 0
    FROM pg_proc p
    WHERE p.oid = to_regprocedure('public.list_fan_team_games(uuid)')
  ),
  'list_has_scoring_status', (
    SELECT position('scoring_status' IN p.prosrc) > 0
    FROM pg_proc p
    WHERE p.oid = to_regprocedure('public.list_fan_team_games(uuid)')
  ),
  'list_returns_null_scores', (
    SELECT position('NULL::integer AS home_score' IN p.prosrc) > 0
    FROM pg_proc p
    WHERE p.oid = to_regprocedure('public.list_fan_team_games(uuid)')
  ),
  'fanout_has_team_name_snapshot', (
    SELECT position('coalesce(v_team_name, v_payload' IN p.prosrc) > 0
    FROM pg_proc p
    WHERE p.oid = to_regprocedure(
      'public.fanout_fan_notification_inbox_for_pickup_update_event(uuid)'
    )
  ),
  'fanout_has_recipient_override', (
    SELECT position('recipient_user_ids' IN p.prosrc) > 0
    FROM pg_proc p
    WHERE p.oid = to_regprocedure(
      'public.fanout_fan_notification_inbox_for_pickup_update_event(uuid)'
    )
  ),
  'fanout_has_score_types', (
    SELECT position('team_event_scored' IN p.prosrc) > 0
    FROM pg_proc p
    WHERE p.oid = to_regprocedure(
      'public.fanout_fan_notification_inbox_for_pickup_update_event(uuid)'
    )
  ),
  'fanout_has_join_request', (
    SELECT position('join_request_approved' IN p.prosrc) > 0
    FROM pg_proc p
    WHERE p.oid = to_regprocedure(
      'public.fanout_fan_notification_inbox_for_pickup_update_event(uuid)'
    )
  ),
  'meaningful_kinds_mentions_score', (
    SELECT position('team_score' IN p.prosrc) > 0 OR position('scoring_status' IN p.prosrc) > 0
    FROM pg_proc p
    WHERE p.oid = to_regprocedure(
      'public.pickup_meaningful_change_kinds(public.pickup_games, public.pickup_games)'
    )
  )
) AS audit;
