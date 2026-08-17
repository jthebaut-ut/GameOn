-- Staging checks for 20260956 Team self-RSVP guard.
-- Do NOT run against production from the agent.

DO $$
DECLARE
  v_src text;
BEGIN
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'pickup_game_requests_before_update_status'
  ORDER BY oid DESC
  LIMIT 1;

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'pickup_game_requests_before_update_status missing';
  END IF;
  IF position('fan_team_game_links' IN v_src) = 0 THEN
    RAISE EXCEPTION 'Team self-RSVP branch missing — apply 20260956';
  END IF;
  IF position('is_pickup_game_fan_team_participant' IN v_src) = 0 THEN
    RAISE EXCEPTION 'Team participant check missing in status trigger — apply 20260956';
  END IF;
  IF position('pickup_request_decision_forbidden' IN v_src) = 0 THEN
    RAISE EXCEPTION 'standalone organizer decision guard missing';
  END IF;

  RAISE NOTICE '[TeamRSVPDebug] sql_trigger_ok team_self_rsvp_branch=true';
END $$;
