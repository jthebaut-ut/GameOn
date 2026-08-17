-- =============================================================================
-- SQL self-checks for 20260982 Team schedule create-push (run after apply)
-- =============================================================================
-- Expected: all assertions raise NOTICE ... PASS (or RAISE EXCEPTION on fail).
-- =============================================================================

DO $$
BEGIN
  IF NOT public.is_fan_team_schedule_create_push_format('practice') THEN
    RAISE EXCEPTION 'FAIL practice should enqueue create push';
  END IF;
  IF NOT public.is_fan_team_schedule_create_push_format('team_meeting') THEN
    RAISE EXCEPTION 'FAIL team_meeting should enqueue create push';
  END IF;
  IF NOT public.is_fan_team_schedule_create_push_format('league_game') THEN
    RAISE EXCEPTION 'FAIL league_game should enqueue create push';
  END IF;
  IF public.is_fan_team_schedule_create_push_format('announcement') THEN
    RAISE EXCEPTION 'FAIL announcement belongs to announcement helper, not schedule helper';
  END IF;
  IF NOT public.is_fan_team_announcement_create_push_format('announcement') THEN
    RAISE EXCEPTION 'FAIL announcement helper';
  END IF;
  IF NOT public.is_fan_team_game_create_push_format('scrimmage') THEN
    RAISE EXCEPTION 'FAIL competitive helper';
  END IF;
  IF public.is_fan_team_game_create_push_format('practice') THEN
    RAISE EXCEPTION 'FAIL practice is not competitive game-create';
  END IF;

  IF to_regclass('public.fan_team_push_delivery_diagnostics') IS NULL THEN
    RAISE EXCEPTION 'FAIL diagnostics view missing';
  END IF;

  RAISE NOTICE 'PASS 20260982_team_schedule_create_push_all_formats_checks';
END $$;
