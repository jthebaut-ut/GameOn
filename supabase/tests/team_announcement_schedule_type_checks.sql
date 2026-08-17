-- Staging checks for 20260976 Team Announcement schedule type.
DO $$
BEGIN
  IF position('announcement' IN (
    SELECT pg_get_constraintdef(oid)
    FROM pg_constraint
    WHERE conname = 'pickup_games_game_format_check'
  )) = 0 THEN
    RAISE EXCEPTION 'FAIL: announcement missing from game_format check';
  END IF;

  IF to_regprocedure('public.is_fan_team_announcement_create_push_format(text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: is_fan_team_announcement_create_push_format missing';
  END IF;

  IF NOT public.is_fan_team_announcement_create_push_format('announcement') THEN
    RAISE EXCEPTION 'FAIL: announcement should be create-push eligible';
  END IF;

  IF public.is_fan_team_game_create_push_format('announcement') THEN
    RAISE EXCEPTION 'FAIL: announcement must not use team_game_created gate';
  END IF;

  IF position('team_announcement' IN pg_get_functiondef(
       'public.queue_team_event_created_push_notification(uuid, uuid, uuid)'::regprocedure
     )) = 0 THEN
    RAISE EXCEPTION 'FAIL: queue missing team_announcement';
  END IF;

  IF position('fan_team_viewer_can_manage' IN pg_get_functiondef(
       'public.link_pickup_game_to_fan_team(uuid, uuid)'::regprocedure
     )) = 0 THEN
    RAISE EXCEPTION 'FAIL: link missing manage gate for announcements';
  END IF;

  IF position('description' IN pg_get_functiondef(
       'public.list_fan_team_games(uuid)'::regprocedure
     )) = 0 THEN
    RAISE EXCEPTION 'FAIL: list_fan_team_games missing description';
  END IF;

  IF to_regprocedure('public.enforce_fan_team_announcement_manage_on_pickup_update()') IS NULL THEN
    RAISE EXCEPTION 'FAIL: announcement update manage gate missing';
  END IF;

  RAISE NOTICE 'PASS: 20260976 Team Announcement symbols present';
END $$;
