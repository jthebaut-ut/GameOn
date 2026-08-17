SELECT
  p.proname,
  pg_get_function_identity_arguments(p.oid) AS args,
  md5(p.prosrc) AS src_md5,
  p.prosecdef AS security_definer
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'list_fan_team_games',
    'fanout_fan_notification_inbox_for_pickup_update_event',
    'update_fan_team_event_score',
    'set_fan_team_event_scoring_status',
    'correct_fan_team_event_final_score',
    'get_fan_team_record',
    'list_fan_team_scored_results',
    'fan_team_viewer_can_access_team',
    'fan_team_viewer_has_permission',
    'queue_pickup_game_change_push_notification',
    'pickup_meaningful_change_kinds',
    'list_fan_notification_inbox_recipient_user_ids_for_pickup_game'
  )
ORDER BY 1, 2;
