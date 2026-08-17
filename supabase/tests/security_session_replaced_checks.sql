-- Staging checks for 20261002 (run after apply; does not mutate production data).
-- Do NOT run against production from the agent.

DO $$
DECLARE
  v_claim text;
  v_notify text;
  v_queue text;
  v_upsert text;
BEGIN
  IF to_regclass('public.security_session_replaced_events') IS NULL THEN
    RAISE EXCEPTION 'FAIL: security_session_replaced_events missing';
  END IF;
  IF to_regprocedure(
       'public.claim_active_session(text, uuid, text, text)'
     ) IS NULL THEN
    RAISE EXCEPTION 'FAIL: claim_active_session missing';
  END IF;
  IF to_regprocedure(
       'public.notify_replaced_session_device(uuid, text, text, uuid, uuid, text, text)'
     ) IS NULL THEN
    RAISE EXCEPTION 'FAIL: notify_replaced_session_device missing';
  END IF;

  IF public.security_session_replacement_should_notify(NULL, 'new', NULL, gen_random_uuid())
       IS DISTINCT FROM 'no_previous_session' THEN
    RAISE EXCEPTION 'FAIL: first claim must not notify';
  END IF;

  IF public.security_session_replacement_should_notify(
       'old-session', 'new-session',
       '11111111-1111-1111-1111-111111111111'::uuid,
       '11111111-1111-1111-1111-111111111111'::uuid
     ) IS DISTINCT FROM 'same_device' THEN
    RAISE EXCEPTION 'FAIL: same installation must not notify';
  END IF;

  IF public.security_session_replacement_should_notify(
       'old-session', 'new-session',
       '11111111-1111-1111-1111-111111111111'::uuid,
       '22222222-2222-2222-2222-222222222222'::uuid
     ) IS DISTINCT FROM 'notify' THEN
    RAISE EXCEPTION 'FAIL: iPhone then iPad must notify old device';
  END IF;

  IF public.security_session_replacement_should_notify(
       'old-session', 'new-session',
       '11111111-1111-1111-1111-111111111111'::uuid,
       NULL
     ) IS DISTINCT FROM 'missing_new_installation' THEN
    RAISE EXCEPTION 'FAIL: missing new installation must not guess recipients';
  END IF;

  SELECT p.prosrc INTO v_claim
  FROM pg_proc p
  WHERE p.oid = 'public.claim_active_session(text, uuid, text, text)'::regprocedure;
  SELECT p.prosrc INTO v_notify
  FROM pg_proc p
  WHERE p.oid = 'public.notify_replaced_session_device(uuid, text, text, uuid, uuid, text, text)'::regprocedure;
  SELECT p.prosrc INTO v_queue
  FROM pg_proc p
  WHERE p.oid = 'public.queue_security_session_replaced_notification(uuid)'::regprocedure;
  SELECT p.prosrc INTO v_upsert
  FROM pg_proc p
  WHERE p.oid = 'public.upsert_fan_notification_inbox(uuid, text, text, text, text, text, text, text, text, uuid, uuid, uuid, jsonb)'::regprocedure;

  IF position('notify_replaced_session_device' IN v_claim) = 0 THEN
    RAISE EXCEPTION 'FAIL: claim must call shared notify helper';
  END IF;
  IF position('installation_id IS DISTINCT FROM p_new_installation_id' IN v_notify) = 0 THEN
    RAISE EXCEPTION 'FAIL: old-token capture must exclude the new installation';
  END IF;
  IF position('security_session_replaced' IN v_notify) = 0
     OR position('securitySession' IN v_notify) = 0 THEN
    RAISE EXCEPTION 'FAIL: inbox row must be dedicated security type';
  END IF;
  IF position('access_token' IN lower(v_notify)) > 0
     OR position('refresh_token' IN lower(v_notify)) > 0 THEN
    RAISE EXCEPTION 'FAIL: notify helper must not mention auth tokens';
  END IF;
  IF position('ON CONFLICT (user_id, dedupe_key)' IN v_notify) = 0 THEN
    RAISE EXCEPTION 'FAIL: retry must be idempotent via dedupe_key';
  END IF;
  IF position('notify-session-replaced' IN v_queue) = 0 THEN
    RAISE EXCEPTION 'FAIL: queue must invoke notify-session-replaced';
  END IF;
  IF position('WHEN OTHERS' IN v_queue) = 0 THEN
    RAISE EXCEPTION 'FAIL: APNs queue failure must not raise';
  END IF;
  IF position('accountsecurity' IN lower(v_upsert)) = 0
     OR position('securitysession' IN lower(v_upsert)) = 0 THEN
    RAISE EXCEPTION 'FAIL: inbox upsert must accept security kind/destination';
  END IF;

  RAISE NOTICE 'PASS: security_session_replaced_checks';
END $$;
