-- Staging checks for 20260954 Team Event change-push active-member recipients.
-- Do NOT run against production from the agent. Manual / staging only.
--
-- Expectation: for a Team-linked pickup, active members are returned even with
-- no pickup_game_requests row (No Response). Editor excluded. Soft-left excluded.

-- Replace placeholders before running.
-- \set pickup_id '00000000-0000-0000-0000-000000000001'
-- \set editor_id '00000000-0000-0000-0000-000000000002'
-- \set member_id '00000000-0000-0000-0000-000000000003'

DO $$
DECLARE
  v_src text;
BEGIN
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'list_pickup_game_change_push_tokens'
  ORDER BY oid DESC
  LIMIT 1;

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'list_pickup_game_change_push_tokens missing';
  END IF;
  IF position('fan_team_members' IN v_src) = 0 THEN
    RAISE EXCEPTION 'list_pickup_game_change_push_tokens missing fan_team_members union (apply 20260954)';
  END IF;
  IF position('linked_teams' IN v_src) = 0 THEN
    RAISE EXCEPTION 'list_pickup_game_change_push_tokens missing linked_teams CTE (apply 20260954)';
  END IF;

  RAISE NOTICE '[TeamEventChangePushDebug] sql_fn_ok fan_team_members_union=true';
END $$;
