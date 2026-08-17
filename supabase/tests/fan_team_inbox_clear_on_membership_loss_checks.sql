-- Staging checks for 20260991 (run after apply; does not mutate production data).
-- Do NOT run against production from the agent.
--
-- Covers:
--  1) Removed from Team clears old Team notifications (helper + remove ordering)
--  2) Removal notification remains (helper spares removed_from_team; emit AFTER clear)
--  3) Other Team notifications remain (filter is team_id = p_team_id)
--  4) Pickup notifications remain (team_id IS NULL excluded)
--  5) Action Needed unrelated to Team remains (not inbox rows; helper is inbox-only)
--  6) Role change does not clear history
--  7) Team Administrator change does not clear history
--  8) Myself is_player OFF does not clear history
--  9) Managed-player removal does not clear account Team history
-- 10) Voluntary account leave clears Team history
-- 11) Bell unread count updates (clear also sets read_at)
-- 12) App relaunch does not bring cleared notifications back (list RPC cleared_at IS NULL)
-- 13) No inaccessible old Team notification remains tappable (cleared_at filters list)

DO $$
DECLARE
  v_helper text;
  v_remove text;
  v_leave text;
  v_role text;
  v_perms text;
  v_player text;
  v_managed text;
  v_list text;
  v_clear_pos integer;
  v_emit_pos integer;
  v_left_pos integer;
BEGIN
  IF to_regclass('public.fan_notification_inbox') IS NULL THEN
    RAISE EXCEPTION 'FAIL: fan_notification_inbox missing';
  END IF;

  IF to_regprocedure(
       'public.clear_fan_notification_inbox_for_team_membership_loss(uuid, uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION 'FAIL: clear helper missing';
  END IF;

  SELECT p.prosrc INTO v_helper
  FROM pg_proc p
  WHERE p.oid = 'public.clear_fan_notification_inbox_for_team_membership_loss(uuid, uuid)'::regprocedure;

  -- 1 / 3 / 4: scoped UPDATE by user_id + team_id; no hard delete.
  IF position('i.user_id = p_user_id' IN v_helper) = 0
     OR position('i.team_id = p_team_id' IN v_helper) = 0 THEN
    RAISE EXCEPTION 'FAIL: helper must filter user_id AND team_id';
  END IF;
  IF position('i.cleared_at IS NULL' IN v_helper) = 0 THEN
    RAISE EXCEPTION 'FAIL: helper must only touch uncleared rows';
  END IF;
  IF position('cleared_at = coalesce' IN v_helper) = 0 THEN
    RAISE EXCEPTION 'FAIL: helper must soft-clear via cleared_at';
  END IF;
  IF position('DELETE FROM' IN upper(v_helper)) > 0 THEN
    RAISE EXCEPTION 'FAIL: helper must not hard-delete';
  END IF;

  -- 2: spare the new removal row.
  IF position('removed_from_team' IN v_helper) = 0 THEN
    RAISE EXCEPTION 'FAIL: helper must spare removed_from_team';
  END IF;

  -- 11: unread/bell — mark read_at when clearing so unread count drops.
  IF position('read_at = coalesce' IN v_helper) = 0 THEN
    RAISE EXCEPTION 'FAIL: helper must set read_at so unread/bell drops';
  END IF;

  -- 5: helper only touches fan_notification_inbox (Action Needed is live).
  IF position('fan_notification_inbox' IN v_helper) = 0 THEN
    RAISE EXCEPTION 'FAIL: helper must target fan_notification_inbox';
  END IF;
  IF position('action_needed' IN lower(v_helper)) > 0 THEN
    RAISE EXCEPTION 'FAIL: helper must not mutate Action Needed state';
  END IF;

  -- remove_fan_team_member: capture → mutate → CLEAR → emit.
  SELECT p.prosrc INTO v_remove
  FROM pg_proc p
  WHERE p.oid = 'public.remove_fan_team_member(uuid, uuid)'::regprocedure;

  v_left_pos := position('SET left_at' IN v_remove);
  v_clear_pos := position('clear_fan_notification_inbox_for_team_membership_loss' IN v_remove);
  v_emit_pos := position('emit_fan_team_member_change_notification' IN v_remove);
  IF v_left_pos = 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_member missing membership mutation';
  END IF;
  IF v_clear_pos = 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_member missing inbox clear';
  END IF;
  IF v_emit_pos = 0 OR position('removed_from_team' IN v_remove) = 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_member missing removed_from_team emit';
  END IF;
  IF NOT (v_left_pos < v_clear_pos AND v_clear_pos < v_emit_pos) THEN
    RAISE EXCEPTION
      'FAIL: remove ordering must be left_at → clear → emit (left@% clear@% emit@%)',
      v_left_pos, v_clear_pos, v_emit_pos;
  END IF;
  IF position('Use leave_fan_team to leave the Team.' IN v_remove) = 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_member missing self-removal rejection';
  END IF;

  -- 10: voluntary leave clears Team inbox and does not notify the leaver.
  SELECT p.prosrc INTO v_leave
  FROM pg_proc p
  WHERE p.oid = 'public.leave_fan_team(uuid)'::regprocedure;
  IF position('clear_fan_notification_inbox_for_team_membership_loss' IN v_leave) = 0 THEN
    RAISE EXCEPTION 'FAIL: leave_fan_team missing inbox clear';
  END IF;
  IF position('removed_from_team' IN v_leave) > 0
     OR position('emit_fan_team_member_change_notification' IN v_leave) > 0 THEN
    RAISE EXCEPTION 'FAIL: leave_fan_team must not emit You-left to the leaver';
  END IF;
  v_left_pos := position('SET left_at' IN v_leave);
  v_clear_pos := position('clear_fan_notification_inbox_for_team_membership_loss' IN v_leave);
  IF v_left_pos = 0 OR v_clear_pos = 0 OR v_left_pos > v_clear_pos THEN
    RAISE EXCEPTION 'FAIL: leave_fan_team must mutate membership BEFORE clear';
  END IF;

  -- 6) Role change does not clear.
  SELECT p.prosrc INTO v_role
  FROM pg_proc p
  WHERE p.proname = 'set_fan_team_member_role'
  ORDER BY oid DESC
  LIMIT 1;
  IF v_role IS NOT NULL
     AND position('clear_fan_notification_inbox_for_team_membership_loss' IN v_role) > 0 THEN
    RAISE EXCEPTION 'FAIL: set_fan_team_member_role must not clear Team inbox';
  END IF;

  -- 7) Team Administrator change does not clear.
  IF to_regprocedure('public.set_fan_team_member_permissions(uuid, uuid, text[])') IS NOT NULL THEN
    SELECT p.prosrc INTO v_perms
    FROM pg_proc p
    WHERE p.oid = 'public.set_fan_team_member_permissions(uuid, uuid, text[])'::regprocedure;
    IF position('clear_fan_notification_inbox_for_team_membership_loss' IN v_perms) > 0 THEN
      RAISE EXCEPTION 'FAIL: set_fan_team_member_permissions must not clear Team inbox';
    END IF;
  END IF;

  -- 8) Myself is_player OFF does not clear.
  IF to_regprocedure('public.set_my_fan_team_is_player(uuid, boolean)') IS NOT NULL THEN
    SELECT p.prosrc INTO v_player
    FROM pg_proc p
    WHERE p.oid = 'public.set_my_fan_team_is_player(uuid, boolean)'::regprocedure;
    IF position('clear_fan_notification_inbox_for_team_membership_loss' IN v_player) > 0 THEN
      RAISE EXCEPTION 'FAIL: set_my_fan_team_is_player must not clear Team inbox';
    END IF;
  END IF;

  -- 9) Managed-player removal does not call the helper (account path delegates).
  IF to_regprocedure('public.remove_fan_team_membership(uuid)') IS NOT NULL THEN
    SELECT p.prosrc INTO v_managed
    FROM pg_proc p
    WHERE p.oid = 'public.remove_fan_team_membership(uuid)'::regprocedure;
    IF position('clear_fan_notification_inbox_for_team_membership_loss' IN v_managed) > 0 THEN
      RAISE EXCEPTION 'FAIL: remove_fan_team_membership must not clear on managed-seat path';
    END IF;
    IF position('remove_fan_team_member' IN v_managed) = 0 THEN
      RAISE EXCEPTION 'FAIL: account seats should still delegate to remove_fan_team_member';
    END IF;
  END IF;

  -- 12 / 13: list RPC still hides cleared_at IS NOT NULL (server authority).
  SELECT p.prosrc INTO v_list
  FROM pg_proc p
  WHERE p.oid = 'public.list_my_fan_notification_inbox(integer, timestamptz, uuid)'::regprocedure;
  IF v_list IS NULL OR position('cleared_at IS NULL' IN v_list) = 0 THEN
    RAISE EXCEPTION 'FAIL: list_my_fan_notification_inbox must hide cleared rows';
  END IF;

  -- Helper is not granted to authenticated (internal / service_role only).
  IF has_function_privilege(
       'authenticated',
       'public.clear_fan_notification_inbox_for_team_membership_loss(uuid, uuid)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'FAIL: helper must not be executable by authenticated';
  END IF;

  RAISE NOTICE 'PASS: fan_team_inbox_clear_on_membership_loss_checks';
END $$;
