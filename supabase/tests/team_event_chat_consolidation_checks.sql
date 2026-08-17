-- Team event chat consolidation checks (apply after 20260964).
-- Expected:
--   - link RPC does not create pickup chat; posts Team Chat notice
--   - sync refuses to create Team-linked pickup chats
--   - inbox hides Team-linked pickup rows
--   - publish preserves managed_player_id
--   - Team Chat resolver + system-message helpers are backend-only

DO $$
DECLARE
  v_link_def text;
  v_sync_def text;
  v_ensure_def text;
  v_inbox_def text;
  v_publish_def text;
  v_acl text;
BEGIN
  IF to_regprocedure('public.link_pickup_game_to_fan_team(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: link_pickup_game_to_fan_team missing';
  END IF;
  IF to_regprocedure('public.fan_team_chat_conversation_id_for_pickup_game(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: fan_team_chat_conversation_id_for_pickup_game missing';
  END IF;
  IF to_regprocedure('public.post_fan_team_chat_system_message(uuid,uuid,text,text,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: post_fan_team_chat_system_message missing';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.link_pickup_game_to_fan_team(uuid,uuid)'))
  INTO v_link_def;
  IF v_link_def ILIKE '%ensure_pickup_game_group_conversation%' THEN
    RAISE EXCEPTION 'FAIL: link_pickup_game_to_fan_team still creates pickup chat';
  END IF;
  IF v_link_def NOT ILIKE '%post_fan_team_chat_system_message%' THEN
    RAISE EXCEPTION 'FAIL: link_pickup_game_to_fan_team does not post to Team Chat';
  END IF;
  IF v_link_def NOT ILIKE '%team_meeting%' OR v_link_def NOT ILIKE '%tournament_game%' THEN
    RAISE EXCEPTION 'FAIL: link_pickup_game_to_fan_team missing full event taxonomy';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.sync_pickup_game_group_membership(uuid)'))
  INTO v_sync_def;
  IF v_sync_def NOT ILIKE '%fan_team_game_links%' THEN
    RAISE EXCEPTION 'FAIL: sync_pickup_game_group_membership missing Team-link guard';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.ensure_pickup_game_group_conversation(uuid)'))
  INTO v_ensure_def;
  IF v_ensure_def NOT ILIKE '%Team events use Team Chat%' THEN
    RAISE EXCEPTION 'FAIL: ensure_pickup_game_group_conversation missing Team Chat error';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.get_group_inbox_summaries()'))
  INTO v_inbox_def;
  IF v_inbox_def NOT ILIKE '%fan_team_game_links%' THEN
    RAISE EXCEPTION 'FAIL: get_group_inbox_summaries does not hide Team-linked pickup chats';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.publish_fan_team_event_lineup(uuid,uuid)'))
  INTO v_publish_def;
  IF v_publish_def IS NULL THEN
    RAISE EXCEPTION 'FAIL: publish_fan_team_event_lineup missing';
  END IF;
  IF v_publish_def NOT ILIKE '%managed_player_id%' THEN
    RAISE EXCEPTION 'FAIL: publish_fan_team_event_lineup does not preserve managed_player_id';
  END IF;
  IF v_publish_def NOT ILIKE '%lineup_fingerprint%' THEN
    RAISE EXCEPTION 'FAIL: publish_fan_team_event_lineup missing notice idempotency fingerprint';
  END IF;
  IF v_publish_def NOT ILIKE '%post_fan_team_chat_system_message%' THEN
    RAISE EXCEPTION 'FAIL: publish_fan_team_event_lineup does not post Team Chat notice';
  END IF;

  -- Privilege matrix: resolver + system-message helper must NOT be client-callable.
  SELECT string_agg(privilege_type, ',' ORDER BY privilege_type)
  INTO v_acl
  FROM information_schema.routine_privileges
  WHERE specific_schema = 'public'
    AND routine_name = 'fan_team_chat_conversation_id_for_pickup_game'
    AND grantee = 'authenticated';
  IF v_acl IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: fan_team_chat_conversation_id_for_pickup_game still granted to authenticated (%)', v_acl;
  END IF;

  SELECT string_agg(privilege_type, ',' ORDER BY privilege_type)
  INTO v_acl
  FROM information_schema.routine_privileges
  WHERE specific_schema = 'public'
    AND routine_name = 'post_fan_team_chat_system_message'
    AND grantee = 'authenticated';
  IF v_acl IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: post_fan_team_chat_system_message still granted to authenticated (%)', v_acl;
  END IF;

  RAISE NOTICE 'PASS: team event chat consolidation checks';
END $$;
