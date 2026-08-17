-- Staging / structural checks for 20260970 Fan Teams audit hardening.
-- Run AFTER applying 20260970. Manual only — does not mutate production data.

DO $$
DECLARE
  v_src text;
BEGIN
  -- Helper EXECUTE denied for authenticated (oracle hardening).
  IF has_function_privilege(
    'authenticated',
    'public.is_active_fan_team_member(uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: is_active_fan_team_member still executable by authenticated';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public.is_pickup_game_fan_team_participant(uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: is_pickup_game_fan_team_participant still executable by authenticated';
  END IF;

  -- Viewer wrappers remain available for RLS.
  IF NOT has_function_privilege(
    'authenticated',
    'public.is_active_fan_team_member_for_viewer(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: is_active_fan_team_member_for_viewer missing authenticated EXECUTE';
  END IF;
  IF NOT has_function_privilege(
    'authenticated',
    'public.is_pickup_game_fan_team_participant_for_viewer(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: is_pickup_game_fan_team_participant_for_viewer missing authenticated EXECUTE';
  END IF;

  -- Client RPCs preserved.
  IF NOT has_function_privilege(
    'authenticated',
    'public.accept_fan_team_invitation(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: accept_fan_team_invitation EXECUTE missing';
  END IF;
  IF NOT has_function_privilege(
    'authenticated',
    'public.accept_fan_team_invitation_for_participants(uuid,boolean,uuid[])',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: accept_fan_team_invitation_for_participants EXECUTE missing';
  END IF;
  IF NOT has_function_privilege(
    'authenticated',
    'public.remove_fan_team_member(uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_member EXECUTE missing';
  END IF;
  IF NOT has_function_privilege(
    'authenticated',
    'public.remove_fan_team_membership(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_membership EXECUTE missing';
  END IF;
  IF NOT has_function_privilege(
    'authenticated',
    'public.list_fan_team_schedule_attendance(uuid,uuid[])',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: list_fan_team_schedule_attendance EXECUTE missing';
  END IF;
  IF NOT has_function_privilege(
    'authenticated',
    'public.get_fan_team_game_rsvp(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: get_fan_team_game_rsvp EXECUTE missing';
  END IF;

  -- Stale chat admin removed on soft-rejoin (no preserve-admin CASE).
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE oid = 'public.accept_fan_team_invitation(uuid)'::regprocedure;
  IF position('WHEN public.group_conversation_members.role = ''admin'' THEN ''admin''' IN v_src) > 0 THEN
    RAISE EXCEPTION 'FAIL: accept_fan_team_invitation still preserves stale chat admin';
  END IF;
  IF position('fan_team_chat_role_for_team_role' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: accept_fan_team_invitation missing chat role mapping helper';
  END IF;

  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE oid = 'public.accept_fan_team_invitation_for_participants(uuid,boolean,uuid[])'::regprocedure;
  IF position('WHEN public.group_conversation_members.role = ''admin'' THEN ''admin''' IN v_src) > 0 THEN
    RAISE EXCEPTION 'FAIL: accept_for_participants still preserves stale chat admin';
  END IF;

  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE oid = 'public.leave_fan_team(uuid)'::regprocedure;
  IF position('role = ''member''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: leave_fan_team does not demote chat admin on soft-leave';
  END IF;

  -- Avatar validation present on update writes.
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE oid = 'public.update_managed_player(uuid,text,text,text,int,text,text,boolean,boolean)'::regprocedure;
  IF position('is_valid_managed_player_avatar_url' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: update_managed_player missing avatar URL validation';
  END IF;
  IF position('p_clear_avatar' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: update_managed_player lost clear-avatar support';
  END IF;

  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE oid = 'public.create_managed_player(text,text,text,int,text,text)'::regprocedure;
  IF position('managed_player_avatar_url_invalid' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: create_managed_player missing avatar-on-create rejection';
  END IF;

  -- Preview payload includes managed_player_id.
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE oid = 'public.list_my_fan_teams()'::regprocedure;
  IF position('''managed_player_id''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: list_my_fan_teams preview missing managed_player_id';
  END IF;

  RAISE NOTICE 'PASS: fan_teams_audit_hardening_checks';
END $$;
