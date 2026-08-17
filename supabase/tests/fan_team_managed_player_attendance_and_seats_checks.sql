-- Staging checks for 20260961 (run after apply; does not mutate production data).
-- Do NOT run against production from the agent. Manual / staging only.
-- Covers the seat-scoped writers, guardian read reach, dual-identity roster
-- buckets, lineup XOR handling, and privilege hardening of the new helpers.

DO $$
DECLARE
  v_src text;
BEGIN
  -- Dependency: 20260960 must already be applied.
  IF to_regclass('public.fan_managed_players') IS NULL
     OR to_regclass('public.fan_team_event_rsvps') IS NULL THEN
    RAISE EXCEPTION 'FAIL: 20260960 not applied';
  END IF;

  -- 1) New RPCs exist with the exact signatures the iOS client calls.
  IF to_regprocedure(
    'public.set_fan_team_member_player_number_for_membership(uuid, uuid, integer)'
  ) IS NULL THEN
    RAISE EXCEPTION 'FAIL: set_fan_team_member_player_number_for_membership missing';
  END IF;
  IF to_regprocedure(
    'public.set_fan_team_member_preferred_position_for_membership(uuid, uuid, text)'
  ) IS NULL THEN
    RAISE EXCEPTION 'FAIL: set_fan_team_member_preferred_position_for_membership missing';
  END IF;
  IF to_regprocedure(
    'public.set_fan_team_event_membership_excluded(uuid, uuid, uuid, boolean)'
  ) IS NULL THEN
    RAISE EXCEPTION 'FAIL: set_fan_team_event_membership_excluded missing';
  END IF;
  IF to_regprocedure(
    'public.emit_fan_team_member_change_notification_for_membership(uuid, text, uuid, uuid, jsonb)'
  ) IS NULL THEN
    RAISE EXCEPTION 'FAIL: emit_fan_team_member_change_notification_for_membership missing';
  END IF;
  IF to_regprocedure(
    'public.is_fan_team_event_managed_player_excluded(uuid, uuid, uuid)'
  ) IS NULL THEN
    RAISE EXCEPTION 'FAIL: is_fan_team_event_managed_player_excluded missing';
  END IF;

  -- 2) Member-change events can record the managed subject; the deployed Edge
  --    still requires a real auth.users target.
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'fan_team_member_change_events'
      AND column_name = 'target_managed_player_id'
  ) THEN
    RAISE EXCEPTION 'FAIL: fan_team_member_change_events.target_managed_player_id missing';
  END IF;
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'fan_team_member_change_events'
      AND column_name = 'target_user_id'
      AND is_nullable = 'YES'
  ) THEN
    RAISE EXCEPTION 'FAIL: target_user_id became nullable (breaks deployed Edge)';
  END IF;

  -- 3) Seat writers: membership-keyed, staff-gated, uniqueness preserved.
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'set_fan_team_member_player_number_for_membership'
  ORDER BY oid DESC
  LIMIT 1;
  IF position('fan_team_viewer_can_manage' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: membership player-number writer missing owner/manager gate';
  END IF;
  IF position('already assigned' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: membership player-number writer missing uniqueness check';
  END IF;
  IF position('emit_fan_team_member_change_notification_for_membership' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: membership player-number writer missing seat-scoped emit';
  END IF;

  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'set_fan_team_member_preferred_position_for_membership'
  ORDER BY oid DESC
  LIMIT 1;
  IF position('fan_team_viewer_can_manage_lineup' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: membership position writer missing lineup-manager gate';
  END IF;

  -- 4) Legacy user-scoped writers must delegate (single implementation).
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'set_fan_team_member_player_number'
  ORDER BY oid DESC
  LIMIT 1;
  IF position('set_fan_team_member_player_number_for_membership' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: set_fan_team_member_player_number no longer delegates';
  END IF;

  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'set_fan_team_member_preferred_position'
  ORDER BY oid DESC
  LIMIT 1;
  IF position('set_fan_team_member_preferred_position_for_membership' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: set_fan_team_member_preferred_position no longer delegates';
  END IF;

  -- 5) Guardians reach the roster even without a seat of their own.
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'is_pickup_game_fan_team_participant'
  ORDER BY oid DESC
  LIMIT 1;
  IF position('fan_managed_player_guardians' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: is_pickup_game_fan_team_participant ignores guardians';
  END IF;

  -- 6) Roster: managed seats in every bucket, account capacity math untouched.
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'get_pickup_game_roster'
  ORDER BY oid DESC
  LIMIT 1;
  IF position('fan_team_event_rsvps' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: get_pickup_game_roster ignores managed RSVPs';
  END IF;
  IF position('is_managed_player' IN v_src) = 0
     OR position('managed_player_id' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: get_pickup_game_roster missing managed identity keys';
  END IF;
  IF position('is_fan_team_event_managed_player_excluded' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: get_pickup_game_roster missing managed exclusion filter';
  END IF;
  IF position('v_account_playing_count' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: get_pickup_game_roster capacity is no longer account-only';
  END IF;
  -- Regressions from earlier migrations must survive the REPLACE.
  IF position('is_fan_team_linked_request_actor_eligible' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: get_pickup_game_roster lost 20260957 former-member filter';
  END IF;
  IF position('viewer_can_manage_event_roster' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: get_pickup_game_roster lost viewer_can_manage_event_roster';
  END IF;

  -- 7) Lineups accept user_id XOR managed_player_id.
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'save_fan_team_event_lineup'
  ORDER BY oid DESC
  LIMIT 1;
  IF position('is_active_fan_team_managed_member' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: save_fan_team_event_lineup does not validate managed seats';
  END IF;
  IF position('either an account or a managed player' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: save_fan_team_event_lineup missing identity XOR guard';
  END IF;
  IF position('Duplicate lineup player.' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: save_fan_team_event_lineup missing per-participant dedupe';
  END IF;

  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'get_fan_team_event_lineup'
  ORDER BY oid DESC
  LIMIT 1;
  IF position('managed_player_id' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: get_fan_team_event_lineup does not return managed identity';
  END IF;
  IF position('fan_team_viewer_can_access_team' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: get_fan_team_event_lineup blocks guardians';
  END IF;

  -- 8) Change push reaches guardians of managed seats.
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'list_pickup_game_change_push_tokens'
  ORDER BY oid DESC
  LIMIT 1;
  IF position('fan_managed_player_guardians' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: list_pickup_game_change_push_tokens skips guardians';
  END IF;
  IF position('linked_teams' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: list_pickup_game_change_push_tokens lost active-member union';
  END IF;

  -- 9) Internal helpers stay backend-only; client RPCs stay client-callable.
  IF EXISTS (
    SELECT 1
    FROM information_schema.routine_privileges
    WHERE specific_schema = 'public'
      AND routine_name IN (
        'emit_fan_team_member_change_notification_for_membership',
        'is_fan_team_event_managed_player_excluded',
        'is_fan_team_event_membership_excluded'
      )
      AND grantee IN ('authenticated', 'anon', 'PUBLIC')
      AND privilege_type = 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: internal managed-seat helpers exposed to client roles';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.routine_privileges
    WHERE specific_schema = 'public'
      AND routine_name = 'set_fan_team_member_player_number_for_membership'
      AND grantee = 'authenticated'
      AND privilege_type = 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: membership player-number RPC not callable by authenticated';
  END IF;

  RAISE NOTICE '[FanTeamManagedPlayerDebug] sql_checks_ok';
END;
$$;

-- Behavioral matrix (staging fixtures; replace UUIDs):
--  1) owner/manager: set_fan_team_member_player_number_for_membership(team, managed_seat, 12)
--     → succeeds; second seat with 12 → 'That player number is already assigned on this Team.'
--  2) ordinary member: same call → 'Only the owner or a manager can set player numbers.'
--  3) coach: set_fan_team_member_preferred_position_for_membership(team, managed_seat, 'GK')
--     → succeeds; member → 'Only coaches and managers can set player positions.'
--  4) guardian with no seat: get_pickup_game_roster(linked_game) → allowed,
--     viewer_can_manage_event_roster = false
--  5) set_fan_team_game_rsvp_for_membership(game, managed_seat, 'going')
--     → child in "playing" with user_id = managed_player_id, is_managed_player = true
--  6) no fan_team_event_rsvps row → child in "no_response"
--  7) set_fan_team_event_membership_excluded(team, future_game, managed_seat, true)
--     → child only in "excluded"; lineup seat and RSVP row deleted; repeat is a no-op
--  8) save_fan_team_event_lineup with both user_id and managed_player_id in one element
--     → 'Lineup player must be either an account or a managed player.'
--  9) non-Team viewer on an outside-recruiting event → no managed rows at all
-- 10) approved_join_count / playing_total_count identical before and after managed RSVPs
;
