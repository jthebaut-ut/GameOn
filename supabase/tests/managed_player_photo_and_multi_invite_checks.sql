-- =============================================================================
-- Structural checks for 20260965 (managed player photo clear + multi invite)
-- Do NOT apply as a migration. Run manually after applying 20260965.
-- =============================================================================

DO $$
DECLARE
  v_src text;
BEGIN
  IF to_regprocedure(
    'public.accept_fan_team_invitation_for_participants(uuid,boolean,uuid[])'
  ) IS NULL THEN
    RAISE EXCEPTION 'FAIL: accept_fan_team_invitation_for_participants missing';
  END IF;

  IF to_regprocedure(
    'public.update_managed_player(uuid,text,text,text,int,text,text,boolean,boolean)'
  ) IS NULL THEN
    RAISE EXCEPTION 'FAIL: update_managed_player 9-arg signature missing';
  END IF;

  -- Old 8-arg overload must be gone so PostgREST resolves one function.
  IF to_regprocedure(
    'public.update_managed_player(uuid,text,text,text,int,text,text,boolean)'
  ) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: update_managed_player 8-arg overload still present';
  END IF;

  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE oid = to_regprocedure(
    'public.accept_fan_team_invitation_for_participants(uuid,boolean,uuid[])'
  );
  IF position('group_conversation_members' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: multi-accept missing Team Chat self path';
  END IF;
  IF position('managed_player_seats_disabled' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: multi-accept missing managed flag gate';
  END IF;
  IF position('A team may have at most 50 members.' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: multi-accept missing capacity check';
  END IF;

  -- Managed seats must never insert children into chat in this function.
  -- Heuristic: no INSERT INTO group_conversation_members that uses managed_player.
  IF position('managed_player_id' IN v_src) > 0
     AND v_src ~* 'insert into public\.group_conversation_members[\s\S]{0,200}managed_player' THEN
    RAISE EXCEPTION 'FAIL: multi-accept appears to chat-insert managed seats';
  END IF;

  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE oid = to_regprocedure(
    'public.accept_fan_team_invitation_as_managed_player(uuid,uuid)'
  );
  IF position('accept_fan_team_invitation_for_participants' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: single managed accept does not delegate to multi RPC';
  END IF;

  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE oid = to_regprocedure('public.assert_rpc_rate_limit(text,int,int)');
  IF position('''accept_fan_team_invitation_for_participants''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: rate-limit allowlist missing multi-accept bucket';
  END IF;
  IF position('''create_managed_player''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: rate-limit allowlist lost create_managed_player';
  END IF;

  RAISE NOTICE 'PASS: 20260965 managed player photo + multi invite checks';
END $$;
