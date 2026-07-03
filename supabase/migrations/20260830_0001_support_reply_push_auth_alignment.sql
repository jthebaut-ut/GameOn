-- Align support-reply pg_net auth with pro-game worker patterns:
-- prefer SUPABASE_SERVICE_ROLE_KEY from Vault for bearer, optional x-cron-secret when stored in Vault.

CREATE OR REPLACE FUNCTION public.queue_support_reply_push_notification(
  p_conversation_id uuid,
  p_message_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_url text;
  v_service_role_key text;
  v_cron_secret text;
  v_headers jsonb;
BEGIN
  IF to_regnamespace('net') IS NULL OR to_regclass('vault.decrypted_secrets') IS NULL THEN
    RAISE NOTICE 'support reply push skipped: pg_net or vault unavailable';
    RETURN;
  END IF;

  SELECT rtrim(decrypted_secret, '/')
  INTO v_url
  FROM vault.decrypted_secrets
  WHERE name IN ('fangeo_supabase_url', 'SUPABASE_URL')
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY CASE name WHEN 'fangeo_supabase_url' THEN 0 ELSE 1 END
  LIMIT 1;

  SELECT decrypted_secret
  INTO v_service_role_key
  FROM vault.decrypted_secrets
  WHERE name IN ('SUPABASE_SERVICE_ROLE_KEY', 'fangeo_service_role_key')
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY CASE name WHEN 'SUPABASE_SERVICE_ROLE_KEY' THEN 0 ELSE 1 END
  LIMIT 1;

  SELECT decrypted_secret
  INTO v_cron_secret
  FROM vault.decrypted_secrets
  WHERE name IN (
    'PRO_SCORE_PUSH_WORKER_CRON_SECRET',
    'fangeo_cron_secret',
    'pro_score_push_worker_cron_secret'
  )
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY CASE name
    WHEN 'PRO_SCORE_PUSH_WORKER_CRON_SECRET' THEN 0
    WHEN 'fangeo_cron_secret' THEN 1
    ELSE 2
  END
  LIMIT 1;

  IF v_url IS NULL OR v_service_role_key IS NULL THEN
    RAISE NOTICE 'support reply push skipped: vault secrets missing';
    RETURN;
  END IF;

  v_headers := jsonb_build_object(
    'Content-Type', 'application/json',
    'Authorization', 'Bearer ' || v_service_role_key
  );

  IF v_cron_secret IS NOT NULL THEN
    v_headers := v_headers || jsonb_build_object('x-cron-secret', v_cron_secret);
  END IF;

  PERFORM net.http_post(
    url := v_url || '/functions/v1/notify-support-reply',
    headers := v_headers,
    body := jsonb_build_object(
      'conversation_id', p_conversation_id,
      'message_id', p_message_id
    ),
    timeout_milliseconds := 15000
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'support reply push queue failed: %', SQLERRM;
END;
$$;

COMMENT ON FUNCTION public.queue_support_reply_push_notification(uuid, uuid) IS
  'Best-effort async invoke of notify-support-reply. Bearer prefers Vault SUPABASE_SERVICE_ROLE_KEY; optional x-cron-secret when present in Vault.';
