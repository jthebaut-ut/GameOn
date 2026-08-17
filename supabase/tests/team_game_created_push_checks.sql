-- Staging checks for 20260975 team_game_created push gating.
-- Run after applying 20260975_0001_team_game_created_push.sql

DO $$
BEGIN
  IF to_regprocedure('public.is_fan_team_game_create_push_format(text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: is_fan_team_game_create_push_format missing';
  END IF;

  IF NOT public.is_fan_team_game_create_push_format('league_game') THEN
    RAISE EXCEPTION 'FAIL: league_game should enqueue create push';
  END IF;
  IF NOT public.is_fan_team_game_create_push_format('tournament_game') THEN
    RAISE EXCEPTION 'FAIL: tournament_game should enqueue create push';
  END IF;
  IF NOT public.is_fan_team_game_create_push_format('match') THEN
    RAISE EXCEPTION 'FAIL: match should enqueue create push';
  END IF;
  IF NOT public.is_fan_team_game_create_push_format('scrimmage') THEN
    RAISE EXCEPTION 'FAIL: scrimmage should enqueue create push';
  END IF;
  IF public.is_fan_team_game_create_push_format('practice') THEN
    RAISE EXCEPTION 'FAIL: practice must NOT enqueue game-created push';
  END IF;
  IF public.is_fan_team_game_create_push_format('tryout') THEN
    RAISE EXCEPTION 'FAIL: tryout must NOT enqueue game-created push';
  END IF;
  IF public.is_fan_team_game_create_push_format('clinic') THEN
    RAISE EXCEPTION 'FAIL: clinic must NOT enqueue game-created push';
  END IF;
  IF public.is_fan_team_game_create_push_format('team_meeting') THEN
    RAISE EXCEPTION 'FAIL: team_meeting must NOT enqueue game-created push';
  END IF;

  IF position('team_game_created' IN pg_get_functiondef(
       'public.queue_team_event_created_push_notification(uuid, uuid, uuid)'::regprocedure
     )) = 0 THEN
    RAISE EXCEPTION 'FAIL: queue_team_event_created_push_notification missing team_game_created';
  END IF;

  IF position('is_fan_team_game_create_push_format' IN pg_get_functiondef(
       'public.queue_team_event_created_push_notification(uuid, uuid, uuid)'::regprocedure
     )) = 0 THEN
    RAISE EXCEPTION 'FAIL: queue function missing format gate';
  END IF;

  RAISE NOTICE 'PASS: 20260975 team_game_created gating symbols present';
END $$;
