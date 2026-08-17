-- Staging / local checks for 20260974 Team Schedule notifications + RSVP reset.
-- Run after applying 20260974_0001_team_schedule_notifications_rsvp_reset.sql
-- Does not mutate production data beyond function existence probes.

DO $$
BEGIN
  IF to_regprocedure(
       'public.invalidate_team_linked_pickup_rsvps_on_schedule_change(uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION 'FAIL: invalidate_team_linked_pickup_rsvps_on_schedule_change missing';
  END IF;

  IF to_regprocedure(
       'public.queue_team_event_created_push_notification(uuid, uuid, uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION 'FAIL: queue_team_event_created_push_notification missing';
  END IF;

  IF position('opponent' IN pg_get_functiondef(
       'public.pickup_meaningful_change_kinds(public.pickup_games, public.pickup_games)'::regprocedure
     )) = 0 THEN
    RAISE EXCEPTION 'FAIL: pickup_meaningful_change_kinds missing opponent detection';
  END IF;

  IF position('invalidate_team_linked_pickup_rsvps_on_schedule_change' IN pg_get_functiondef(
       'public.notify_pickup_game_updated_from_rows(public.pickup_games, public.pickup_games, uuid)'::regprocedure
     )) = 0 THEN
    RAISE EXCEPTION 'FAIL: notify_pickup_game_updated_from_rows missing RSVP invalidation';
  END IF;

  IF position('queue_team_event_created_push_notification' IN pg_get_functiondef(
       'public.link_pickup_game_to_fan_team(uuid, uuid)'::regprocedure
     )) = 0 THEN
    RAISE EXCEPTION 'FAIL: link_pickup_game_to_fan_team missing create push enqueue';
  END IF;

  RAISE NOTICE 'PASS: 20260974 Team Schedule notification / RSVP symbols present';
END $$;
