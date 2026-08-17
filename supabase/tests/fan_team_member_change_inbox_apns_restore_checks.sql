-- Staging checks for 20260990 (run after apply; does not mutate production data).
-- Do NOT run against production from the agent.

DO $$
DECLARE
  v_src text;
BEGIN
  IF to_regclass('public.fan_team_member_change_events') IS NULL THEN
    RAISE EXCEPTION 'FAIL: fan_team_member_change_events missing';
  END IF;
  IF to_regclass('public.fan_notification_inbox') IS NULL THEN
    RAISE EXCEPTION 'FAIL: fan_notification_inbox missing';
  END IF;

  -- Kind CHECK includes Administrator transitions.
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.fan_team_member_change_events'::regclass
      AND conname = 'fan_team_member_change_events_kind_check'
      AND pg_get_constraintdef(oid) LIKE '%team_admin_granted%'
      AND pg_get_constraintdef(oid) LIKE '%team_admin_removed%'
      AND pg_get_constraintdef(oid) LIKE '%removed_from_team%'
  ) THEN
    RAISE EXCEPTION 'FAIL: kind CHECK missing team_admin_* / removed_from_team';
  END IF;

  -- 1) remove_fan_team_member: emit using captured p_user_id (not post-delete roster).
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'remove_fan_team_member'
  ORDER BY oid DESC
  LIMIT 1;
  IF v_src IS NULL OR position('emit_fan_team_member_change_notification' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_member missing emit';
  END IF;
  IF position('removed_from_team' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_member missing removed_from_team kind';
  END IF;
  IF position('Use leave_fan_team to leave the Team.' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_member missing self-removal rejection';
  END IF;
  IF position('SELECT m.user_id' IN v_src) > 0 AND position('AND m.left_at IS NOT NULL' IN v_src) > 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_member rediscovers recipient after left_at';
  END IF;

  -- 2) set_fan_team_member_role still emits team_role_changed from OLD vs NEW.
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'set_fan_team_member_role'
  ORDER BY oid DESC
  LIMIT 1;
  IF position('team_role_changed' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: set_fan_team_member_role missing team_role_changed';
  END IF;
  IF position('v_old_role IS DISTINCT FROM v_role' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: set_fan_team_member_role missing OLD vs NEW compare';
  END IF;

  -- 3) Administrator toggle emits only on preset boundary.
  -- Canonical contract is text[] (20260986); jsonb overload must not exist.
  IF to_regprocedure('public.set_fan_team_member_permissions(uuid, uuid, text[])') IS NULL THEN
    RAISE EXCEPTION
      'FAIL: set_fan_team_member_permissions(uuid, uuid, text[]) missing';
  END IF;
  IF to_regprocedure('public.set_fan_team_member_permissions(uuid, uuid, jsonb)') IS NOT NULL THEN
    RAISE EXCEPTION
      'FAIL: obsolete set_fan_team_member_permissions(uuid, uuid, jsonb) still exists';
  END IF;
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE oid = to_regprocedure('public.set_fan_team_member_permissions(uuid, uuid, text[])');
  IF position('team_admin_granted' IN v_src) = 0
     OR position('team_admin_removed' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: set_fan_team_member_permissions missing admin kinds';
  END IF;
  IF position('v_was_admin IS DISTINCT FROM v_now_admin' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: set_fan_team_member_permissions missing admin toggle gate';
  END IF;
  IF pg_get_function_identity_arguments(
       to_regprocedure('public.set_fan_team_member_permissions(uuid, uuid, text[])')
     ) IS DISTINCT FROM 'p_team_id uuid, p_membership_id uuid, p_permissions text[]'
     AND pg_get_function_identity_arguments(
       to_regprocedure('public.set_fan_team_member_permissions(uuid, uuid, text[])')
     ) NOT LIKE '%text[]%' THEN
    RAISE EXCEPTION 'FAIL: set_fan_team_member_permissions identity args are not text[]';
  END IF;

  -- 4) Inbox fan-out copy + safe destination + kind-specific dedupe.
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'fanout_fan_notification_inbox_for_member_change_event'
  ORDER BY oid DESC
  LIMIT 1;
  IF position('Removed from Team' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: inbox fanout missing Removed from Team title';
  END IF;
  IF position('You are no longer a member of' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: inbox fanout missing removal body';
  END IF;
  IF position('teamsHome' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: inbox fanout missing teamsHome destination';
  END IF;
  IF position('scheduleActivity' IN v_src) > 0 THEN
    RAISE EXCEPTION 'FAIL: inbox fanout still destinations scheduleActivity';
  END IF;
  IF position('You''re now a ' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: inbox fanout missing role promotion body';
  END IF;

  -- 5) Dual-key APNs queue.
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'queue_fan_team_member_change_push_notification_apns'
  ORDER BY oid DESC
  LIMIT 1;
  IF v_src IS NULL OR position('''apikey''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: member-change APNs queue missing dual-key apikey header';
  END IF;
  IF position('notify-fan-team-member-change' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: APNs queue missing notify-fan-team-member-change';
  END IF;

  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'queue_fan_team_member_change_push_notification'
    AND pronamespace = 'public'::regnamespace
  ORDER BY oid DESC
  LIMIT 1;
  IF position('fanout_fan_notification_inbox_for_member_change_event' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: wrapper missing inbox fanout before APNs';
  END IF;
  IF position('queue_fan_team_member_change_push_notification_apns' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: wrapper missing APNs queue';
  END IF;

  -- 6) upsert destination whitelist accepts teamsHome.
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'upsert_fan_notification_inbox'
  ORDER BY oid DESC
  LIMIT 1;
  IF position('teamshome' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: upsert_fan_notification_inbox does not accept teamsHome';
  END IF;

  -- 7) Helpers exist.
  IF to_regprocedure('public.fan_team_role_display_label(text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: fan_team_role_display_label missing';
  END IF;
  IF to_regprocedure('public.fan_team_is_administrator_preset(text[])') IS NULL THEN
    RAISE EXCEPTION 'FAIL: fan_team_is_administrator_preset missing';
  END IF;
  IF public.fan_team_role_display_label('head_coach') IS DISTINCT FROM 'Head Coach' THEN
    RAISE EXCEPTION 'FAIL: head_coach display label';
  END IF;
  IF public.fan_team_role_display_label('assistant_captain') IS DISTINCT FROM 'Assistant Captain' THEN
    RAISE EXCEPTION 'FAIL: assistant_captain display label';
  END IF;

  RAISE NOTICE 'PASS 20260990 member-change inbox/APNs restore checks';
END $$;
