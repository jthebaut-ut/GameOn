-- Staging checks for 20260958 (run after apply; does not mutate production data).
-- Do NOT run against production from the agent. Manual / staging only.
-- Covers self-removal reject, past-event exclusion guard, idempotency, role
-- active-membership gate, and internal helper privilege hardening.

DO $$
DECLARE
  v_src text;
BEGIN
  IF to_regclass('public.fan_team_event_exclusions') IS NULL THEN
    RAISE EXCEPTION 'FAIL: fan_team_event_exclusions missing';
  END IF;
  IF to_regclass('public.fan_team_member_change_events') IS NULL THEN
    RAISE EXCEPTION 'FAIL: fan_team_member_change_events missing';
  END IF;
  IF to_regclass('public.fan_team_member_change_push_deliveries') IS NULL THEN
    RAISE EXCEPTION 'FAIL: fan_team_member_change_push_deliveries missing';
  END IF;

  IF to_regprocedure('public.is_fan_team_event_member_excluded(uuid, uuid, uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: is_fan_team_event_member_excluded missing';
  END IF;
  IF to_regprocedure('public.set_fan_team_event_member_excluded(uuid, uuid, uuid, boolean)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: set_fan_team_event_member_excluded missing';
  END IF;
  IF to_regprocedure('public.emit_fan_team_member_change_notification(uuid, text, uuid, uuid, jsonb)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: emit_fan_team_member_change_notification missing';
  END IF;
  IF to_regprocedure('public.queue_fan_team_member_change_push_notification(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: queue_fan_team_member_change_push_notification missing';
  END IF;

  -- leave_fan_team must still be untouched: member_left pipeline stays leadership-notify.
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'leave_fan_team'
  ORDER BY oid DESC
  LIMIT 1;
  IF v_src IS NULL OR position('queue_fan_team_member_left_push_notification' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: leave_fan_team no longer queues member_left push';
  END IF;
  IF position('emit_fan_team_member_change_notification' IN v_src) > 0 THEN
    RAISE EXCEPTION 'FAIL: leave_fan_team should not use the member-change pipeline';
  END IF;

  -- 1) remove_fan_team_member: staff-only; reject self; no manage-auth bypass.
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'remove_fan_team_member'
  ORDER BY oid DESC
  LIMIT 1;
  IF v_src IS NULL OR position('emit_fan_team_member_change_notification' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_member missing emit_fan_team_member_change_notification';
  END IF;
  IF position('removed_from_team' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_member missing removed_from_team kind';
  END IF;
  IF position('cleanup_fan_team_member_future_event_participation' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_member missing future cleanup (regressed from 20260957)';
  END IF;
  IF position('Use leave_fan_team to leave the Team.' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_member missing self-removal rejection';
  END IF;
  IF position('p_user_id <> me AND NOT public.fan_team_viewer_can_manage' IN v_src) > 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_member reintroduced self manage-auth bypass';
  END IF;
  IF position('The team owner cannot be removed.' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_member missing owner protection';
  END IF;

  -- 2–3) set_fan_team_event_member_excluded: past-event reject + idempotent no-ops.
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'set_fan_team_event_member_excluded'
  ORDER BY oid DESC
  LIMIT 1;
  IF position('Cannot change exclusion for a past event.' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: set_fan_team_event_member_excluded missing past-event guard';
  END IF;
  IF position('v_game_start_at < now()' IN v_src) = 0
     AND position('game_start_at < now()' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: set_fan_team_event_member_excluded missing game_start_at past check';
  END IF;
  IF position('event_exclusion_noop_already_excluded' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: set_fan_team_event_member_excluded missing exclude idempotency';
  END IF;
  IF position('event_exclusion_noop_already_included' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: set_fan_team_event_member_excluded missing add-back idempotency';
  END IF;

  -- 4) set_fan_team_member_role: active membership required before updates.
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'set_fan_team_member_role'
  ORDER BY oid DESC
  LIMIT 1;
  IF v_src IS NULL OR position('team_role_changed' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: set_fan_team_member_role missing team_role_changed emit';
  END IF;
  IF position('is_active_fan_team_member' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: set_fan_team_member_role missing active membership validation';
  END IF;
  IF position('User is not an active team member.' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: set_fan_team_member_role missing active-member exception';
  END IF;

  -- set_fan_team_member_player_number / preferred_position still wired.
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'set_fan_team_member_player_number'
  ORDER BY oid DESC
  LIMIT 1;
  IF v_src IS NULL OR position('emit_fan_team_member_change_notification' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: set_fan_team_member_player_number missing emit call';
  END IF;

  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'set_fan_team_member_preferred_position'
  ORDER BY oid DESC
  LIMIT 1;
  IF v_src IS NULL OR position('emit_fan_team_member_change_notification' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: set_fan_team_member_preferred_position missing emit call';
  END IF;

  -- get_pickup_game_roster exclusion + former-member filters preserved.
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'get_pickup_game_roster'
  ORDER BY oid DESC
  LIMIT 1;
  IF v_src IS NULL OR position('excluded' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: get_pickup_game_roster missing excluded key';
  END IF;
  IF position('is_fan_team_event_member_excluded' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: get_pickup_game_roster missing exclusion filter';
  END IF;
  IF position('viewer_can_manage_event_roster' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: get_pickup_game_roster missing viewer_can_manage_event_roster';
  END IF;
  IF position('is_fan_team_linked_request_actor_eligible' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: get_pickup_game_roster lost 20260957 former-member filter';
  END IF;

  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'list_pickup_game_change_push_tokens'
  ORDER BY oid DESC
  LIMIT 1;
  IF v_src IS NULL OR position('fan_team_event_exclusions' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: list_pickup_game_change_push_tokens missing exclusion filter';
  END IF;
  IF position('linked_teams' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: list_pickup_game_change_push_tokens lost 20260954 active-member union';
  END IF;

  -- 5) Internal helper not executable by clients.
  IF EXISTS (
    SELECT 1
    FROM information_schema.routine_privileges
    WHERE specific_schema = 'public'
      AND routine_name = 'is_fan_team_event_member_excluded'
      AND grantee IN ('authenticated', 'anon', 'PUBLIC')
      AND privilege_type = 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: is_fan_team_event_member_excluded still client-executable';
  END IF;

  -- emit / queue remain backend-only.
  IF EXISTS (
    SELECT 1
    FROM information_schema.routine_privileges
    WHERE specific_schema = 'public'
      AND routine_name IN (
        'emit_fan_team_member_change_notification',
        'queue_fan_team_member_change_push_notification'
      )
      AND grantee IN ('authenticated', 'anon', 'PUBLIC')
      AND privilege_type = 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: member-change emit/queue exposed to client roles';
  END IF;

  RAISE NOTICE '[FanTeamMemberChangeDebug] sql_checks_ok';
END;
$$;

-- Behavioral matrix (staging fixtures; replace UUIDs):
-- 1) SET ROLE authenticated as ordinary member:
--    SELECT remove_fan_team_member(team, self); → 'Use leave_fan_team to leave the Team.'
-- 2) SELECT leave_fan_team(team); → succeeds; fan_team_member_left_events queued
-- 3) set_fan_team_event_member_excluded(team, past_game, member, true)
--    → 'Cannot change exclusion for a past event.'
-- 4) set_fan_team_event_member_excluded(team, future_game, member, true) → succeeds once
-- 5) same exclude again → no new fan_team_member_change_events row
-- 6) set_excluded false twice → only first emits added_back_to_event
-- 7) set_fan_team_member_role(team, former_member, 'captain')
--    → 'User is not an active team member.'
-- 8) SELECT is_fan_team_event_member_excluded(...) as authenticated → permission denied
;
