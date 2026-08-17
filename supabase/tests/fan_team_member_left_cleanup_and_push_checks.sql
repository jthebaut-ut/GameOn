-- Staging checks for 20260957 (run after apply; does not mutate production data).
-- Covers self-removal staff-RPC rejection + hardened helper EXECUTE grants.
DO $$
DECLARE
  v_src text;
  v_has_authenticated boolean;
  v_has_anon boolean;
  v_has_public boolean;
BEGIN
  IF to_regclass('public.fan_team_member_left_events') IS NULL THEN
    RAISE EXCEPTION 'FAIL: fan_team_member_left_events missing';
  END IF;
  IF to_regclass('public.fan_team_member_left_push_deliveries') IS NULL THEN
    RAISE EXCEPTION 'FAIL: fan_team_member_left_push_deliveries missing';
  END IF;

  -- 1) leave_fan_team remains the voluntary-leave path (cleanup + leadership queue).
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'leave_fan_team'
  ORDER BY oid DESC
  LIMIT 1;
  IF position('queue_fan_team_member_left_push_notification' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: leave_fan_team missing member_left queue';
  END IF;
  IF position('cleanup_fan_team_member_future_event_participation' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: leave_fan_team missing future cleanup';
  END IF;
  IF position('fan_team_role_is_manager_or_owner' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: leave_fan_team missing Owner/Manager recipient filter';
  END IF;

  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'get_pickup_game_roster'
  ORDER BY oid DESC
  LIMIT 1;
  IF position('is_fan_team_linked_request_actor_eligible' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: get_pickup_game_roster missing former-member filter';
  END IF;
  IF position('m.left_at IS NULL' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: get_pickup_game_roster no_response missing left_at filter';
  END IF;

  -- 2–6) remove_fan_team_member is staff-only (reject self; require manage; protect owner).
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'remove_fan_team_member'
  ORDER BY oid DESC
  LIMIT 1;
  IF position('cleanup_fan_team_member_future_event_participation' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_member missing future cleanup';
  END IF;
  IF position('Use leave_fan_team to leave the Team.' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_member missing self-removal rejection';
  END IF;
  IF position('p_user_id = me' IN v_src) = 0 AND position('p_user_id IS NOT DISTINCT FROM me' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_member missing self identity check';
  END IF;
  -- Must NOT retain the old bypass: manage check only when target <> self.
  IF position('p_user_id <> me AND NOT public.fan_team_viewer_can_manage' IN v_src) > 0
     OR position('p_user_id <> me AND NOT fan_team_viewer_can_manage' IN v_src) > 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_member still bypasses manage auth for self';
  END IF;
  IF position('fan_team_viewer_can_manage' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_member missing manage authorization';
  END IF;
  IF position('The team owner cannot be removed.' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_member missing owner protection';
  END IF;

  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'pickup_game_requests_before_update_status'
  ORDER BY oid DESC
  LIMIT 1;
  IF position('fan_team_member_leave_cleanup' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: status trigger missing leave cleanup GUC';
  END IF;
  IF position('Team-linked SELF RSVP' IN v_src) = 0
     AND position('is_pickup_game_fan_team_participant' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: status trigger lost Team self-RSVP branch';
  END IF;

  -- 7) Internal helper must not be executable by authenticated / anon / PUBLIC.
  SELECT EXISTS (
    SELECT 1
    FROM information_schema.routine_privileges
    WHERE specific_schema = 'public'
      AND routine_name = 'is_fan_team_linked_request_actor_eligible'
      AND grantee = 'authenticated'
      AND privilege_type = 'EXECUTE'
  ) INTO v_has_authenticated;
  SELECT EXISTS (
    SELECT 1
    FROM information_schema.routine_privileges
    WHERE specific_schema = 'public'
      AND routine_name = 'is_fan_team_linked_request_actor_eligible'
      AND grantee = 'anon'
      AND privilege_type = 'EXECUTE'
  ) INTO v_has_anon;
  SELECT EXISTS (
    SELECT 1
    FROM information_schema.routine_privileges
    WHERE specific_schema = 'public'
      AND routine_name = 'is_fan_team_linked_request_actor_eligible'
      AND grantee = 'PUBLIC'
      AND privilege_type = 'EXECUTE'
  ) INTO v_has_public;

  IF v_has_authenticated THEN
    RAISE EXCEPTION 'FAIL: is_fan_team_linked_request_actor_eligible still granted to authenticated';
  END IF;
  IF v_has_anon THEN
    RAISE EXCEPTION 'FAIL: is_fan_team_linked_request_actor_eligible still granted to anon';
  END IF;
  IF v_has_public THEN
    RAISE EXCEPTION 'FAIL: is_fan_team_linked_request_actor_eligible still granted to PUBLIC';
  END IF;

  -- 8) Backend dependents still reference the helper (SECURITY DEFINER callers).
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'list_pickup_game_change_push_tokens'
  ORDER BY oid DESC
  LIMIT 1;
  IF position('is_fan_team_linked_request_actor_eligible' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: list_pickup_game_change_push_tokens missing eligibility helper call';
  END IF;

  RAISE NOTICE '[FanTeamMemberLeaveDebug] sql_checks_ok';
END;
$$;

-- Behavioral matrix (staging only; requires disposable Team fixtures).
-- Uncomment / adapt user + team ids in a non-prod project:
--
-- -- 1) ordinary member leave_fan_team → succeeds + queues leadership notification
-- SET LOCAL ROLE authenticated;
-- SELECT set_config('request.jwt.claim.sub', '<member_uuid>', true);
-- SELECT public.leave_fan_team('<team_uuid>');
-- -- expect: fan_team_member_left_events row reason='left' with Owner/Manager recipients
--
-- -- 2) ordinary member remove_fan_team_member(self) → rejected
-- SELECT public.remove_fan_team_member('<team_uuid>', '<member_uuid>'::uuid);
-- -- expect: exception 'Use leave_fan_team to leave the Team.'
--
-- -- 3) Manager remove_fan_team_member(other) → succeeds
-- -- 4) Owner remove_fan_team_member(other) → succeeds
-- -- 5) Member remove_fan_team_member(other) → 'Only the owner or a manager can remove members.'
-- -- 6) remove_fan_team_member(owner) → 'The team owner cannot be removed.'
-- -- 7) SET ROLE authenticated; SELECT public.is_fan_team_linked_request_actor_eligible(...);
-- --    → permission denied for function
-- -- 8) get_pickup_game_roster / leave cleanup paths still succeed via SECURITY DEFINER
;