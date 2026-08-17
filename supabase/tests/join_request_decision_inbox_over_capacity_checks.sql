-- Staging checks for 20260992 (run after apply; does not mutate production data).

DO $$
DECLARE
  v_before text;
  v_after text;
  v_fanout text;
BEGIN
  SELECT p.prosrc INTO v_before
  FROM pg_proc p
  WHERE p.oid = 'public.pickup_game_requests_before_update_status()'::regprocedure;
  IF v_before IS NULL THEN
    RAISE EXCEPTION 'FAIL: pickup_game_requests_before_update_status missing';
  END IF;
  IF position('pickup_game_full' IN v_before) > 0 THEN
    RAISE EXCEPTION 'FAIL: approve still raises pickup_game_full';
  END IF;
  IF position('pickup_request_decision_forbidden' IN v_before) = 0 THEN
    RAISE EXCEPTION 'FAIL: organizer decision guard missing';
  END IF;

  SELECT p.prosrc INTO v_after
  FROM pg_proc p
  WHERE p.oid = 'public.pickup_game_requests_after_decision_notify()'::regprocedure;
  IF v_after IS NULL THEN
    RAISE EXCEPTION 'FAIL: after-decision notify missing';
  END IF;
  IF position('join_request_approved' IN v_after) = 0
     OR position('join_request_rejected' IN v_after) = 0 THEN
    RAISE EXCEPTION 'FAIL: after-decision missing join kinds';
  END IF;
  IF position('queue_pickup_game_change_push_notification' IN v_after) = 0 THEN
    RAISE EXCEPTION 'FAIL: after-decision does not reuse pickup change queue';
  END IF;
  IF position('recipient_user_ids' IN v_after) = 0 THEN
    RAISE EXCEPTION 'FAIL: after-decision missing requester targeting';
  END IF;

  SELECT p.prosrc INTO v_fanout
  FROM pg_proc p
  WHERE p.oid = 'public.fanout_fan_notification_inbox_for_pickup_update_event(uuid)'::regprocedure;
  IF position('Your request to join' IN v_fanout) = 0 THEN
    RAISE EXCEPTION 'FAIL: fanout missing join-decision title';
  END IF;
  IF position('recipient_user_ids' IN v_fanout) = 0 THEN
    RAISE EXCEPTION 'FAIL: fanout does not honor recipient override';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgrelid = 'public.pickup_game_requests'::regclass
      AND tgname = 'pickup_game_requests_after_decision_notify_au'
  ) THEN
    RAISE EXCEPTION 'FAIL: after-decision trigger missing';
  END IF;

  RAISE NOTICE 'PASS: join_request_decision_inbox_over_capacity_checks';
END $$;
