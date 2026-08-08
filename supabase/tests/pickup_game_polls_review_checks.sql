-- =============================================================================
-- pickup_game_polls_review_checks.sql
-- Manual / staging verification for 20260913_0001 (read-mostly privilege probes).
-- Do NOT run automatically against production as part of apply.
-- =============================================================================

-- A. Snapshot is STABLE (provolatile = 's')
DO $$
DECLARE
  v char;
BEGIN
  SELECT p.provolatile INTO v
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'get_pickup_game_poll_snapshot'
    AND pg_get_function_identity_arguments(p.oid) = 'uuid';
  IF v IS DISTINCT FROM 's' THEN
    RAISE EXCEPTION 'FAIL A: get_pickup_game_poll_snapshot expected STABLE (s), got %', v;
  END IF;
  RAISE NOTICE 'PASS A: snapshot STABLE';
END $$;

-- D. Arbitrary-user helpers not executable by authenticated
DO $$
BEGIN
  IF has_function_privilege(
    'authenticated',
    'public._pickup_poll_user_can_access(uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL D: authenticated can execute _pickup_poll_user_can_access';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public._pickup_poll_user_is_organizer(uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL D: authenticated can execute _pickup_poll_user_is_organizer';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public._close_pickup_game_poll_if_due(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL D: authenticated can execute _close_pickup_game_poll_if_due';
  END IF;
  RAISE NOTICE 'PASS D: internal auth helpers not granted to authenticated';
END $$;

-- E/F. Global close-all privilege model
DO $$
BEGIN
  IF has_function_privilege(
    'authenticated',
    'public.close_due_pickup_game_polls(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL E: authenticated can execute close_due_pickup_game_polls';
  END IF;
  IF NOT has_function_privilege(
    'service_role',
    'public.close_due_pickup_game_polls(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL F: service_role missing close_due_pickup_game_polls';
  END IF;
  RAISE NOTICE 'PASS E/F: global close is service_role only';
END $$;

-- G/H. History-safe FKs on pickup_game_polls
DO $$
DECLARE
  v_pickup_fk integer;
  v_created_del char;
  v_conv_del char;
  v_msg_del char;
BEGIN
  SELECT count(*) INTO v_pickup_fk
  FROM pg_constraint c
  JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
  WHERE c.conrelid = 'public.pickup_game_polls'::regclass
    AND c.contype = 'f'
    AND a.attname = 'pickup_game_id';
  IF v_pickup_fk <> 0 THEN
    RAISE EXCEPTION 'FAIL G: pickup_game_id must not have an FK (got %)', v_pickup_fk;
  END IF;

  SELECT c.confdeltype INTO v_created_del
  FROM pg_constraint c
  WHERE c.conname = 'pickup_game_polls_created_by_fkey';
  IF v_created_del IS DISTINCT FROM 'n' THEN -- n = SET NULL
    RAISE EXCEPTION 'FAIL H: created_by expected ON DELETE SET NULL, got %', v_created_del;
  END IF;

  SELECT c.confdeltype INTO v_conv_del
  FROM pg_constraint c
  WHERE c.conname = 'pickup_game_polls_conversation_id_fkey';
  IF v_conv_del IS DISTINCT FROM 'r' THEN -- r = RESTRICT
    RAISE EXCEPTION 'FAIL G: conversation_id expected ON DELETE RESTRICT, got %', v_conv_del;
  END IF;

  SELECT c.confdeltype INTO v_msg_del
  FROM pg_constraint c
  WHERE c.conname = 'pickup_game_polls_message_id_fkey';
  IF v_msg_del IS DISTINCT FROM 'n' THEN
    RAISE EXCEPTION 'FAIL G: message_id expected ON DELETE SET NULL, got %', v_msg_del;
  END IF;

  RAISE NOTICE 'PASS G/H: history-preserving FK strategy';
END $$;

-- Client RPC signatures present (Swift-compatible)
DO $$
BEGIN
  IF to_regprocedure('public.create_pickup_game_poll(uuid,text,text[],boolean,boolean,boolean)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: missing create_pickup_game_poll signature';
  END IF;
  IF to_regprocedure('public.attach_pickup_game_poll_message(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: missing attach_pickup_game_poll_message';
  END IF;
  IF to_regprocedure('public.set_pickup_game_poll_vote(uuid,uuid[])') IS NULL THEN
    RAISE EXCEPTION 'FAIL: missing set_pickup_game_poll_vote';
  END IF;
  IF to_regprocedure('public.get_pickup_game_poll_snapshot(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: missing get_pickup_game_poll_snapshot';
  END IF;
  IF to_regprocedure('public.close_pickup_game_poll(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: missing close_pickup_game_poll';
  END IF;
  IF to_regprocedure('public.delete_pickup_game_poll(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: missing delete_pickup_game_poll';
  END IF;
  IF to_regprocedure('public.pin_pickup_game_poll(uuid,boolean)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: missing pin_pickup_game_poll';
  END IF;
  -- Old arbitrary-user overloads must be gone
  IF to_regprocedure('public.can_access_pickup_game_poll_conversation(uuid,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL D: legacy can_access(...uuid,uuid) still present';
  END IF;
  IF to_regprocedure('public.is_pickup_game_poll_organizer(uuid,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL D: legacy is_pickup_game_poll_organizer(...uuid,uuid) still present';
  END IF;
  RAISE NOTICE 'PASS: Swift RPC signatures present; legacy user-id oracles removed';
END $$;

-- Manual interactive cases (B/C/I/J/K/L) require seeded fixtures:
-- B. attach wrong-conversation message → exception
-- C. attach wrong-sender / missing __FG_POLL_V1__ / wrong poll_id → exception
-- I. create with prohibited question/option → "isn't allowed"
-- J. nonmember snapshot/vote → Not authorized
-- K. anonymous snapshot voters = []
-- L. closed/archived/due poll vote → This poll is closed.
