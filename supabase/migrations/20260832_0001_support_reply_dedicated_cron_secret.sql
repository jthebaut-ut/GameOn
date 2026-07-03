-- Dedicated cron secret for support-reply push (separate from PRO_SCORE_PUSH_WORKER_CRON_SECRET).
-- Manual setup: docs/ops/Support_Reply_Push_Vault_Cron_Secret.md
-- Do not store real secret values in this migration.

CREATE OR REPLACE FUNCTION public.support_reply_push_vault_auth_status()
RETURNS TABLE (
  cron_secret_present boolean,
  cron_secret_length integer,
  service_role_present boolean,
  service_role_length integer,
  project_url_present boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    EXISTS (
      SELECT 1
      FROM vault.decrypted_secrets
      WHERE name = 'SUPPORT_REPLY_PUSH_CRON_SECRET'
        AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
    ) AS cron_secret_present,
    (
      SELECT char_length(btrim(decrypted_secret))
      FROM vault.decrypted_secrets
      WHERE name = 'SUPPORT_REPLY_PUSH_CRON_SECRET'
        AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
      ORDER BY updated_at DESC NULLS LAST, created_at DESC
      LIMIT 1
    ) AS cron_secret_length,
    EXISTS (
      SELECT 1
      FROM vault.decrypted_secrets
      WHERE name IN ('fangeo_service_role_key', 'SUPABASE_SERVICE_ROLE_KEY')
        AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
    ) AS service_role_present,
    (
      SELECT char_length(btrim(decrypted_secret))
      FROM vault.decrypted_secrets
      WHERE name IN ('fangeo_service_role_key', 'SUPABASE_SERVICE_ROLE_KEY')
        AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
      ORDER BY CASE name WHEN 'SUPABASE_SERVICE_ROLE_KEY' THEN 0 ELSE 1 END
      LIMIT 1
    ) AS service_role_length,
    EXISTS (
      SELECT 1
      FROM vault.decrypted_secrets
      WHERE name IN ('fangeo_supabase_url', 'SUPABASE_URL')
        AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
    ) AS project_url_present;
$$;

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
  WHERE name = 'SUPPORT_REPLY_PUSH_CRON_SECRET'
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY updated_at DESC NULLS LAST, created_at DESC
  LIMIT 1;

  IF v_url IS NULL OR v_service_role_key IS NULL THEN
    RAISE NOTICE 'support reply push skipped: vault url or service role secret missing';
    RETURN;
  END IF;

  v_headers := jsonb_build_object(
    'Content-Type', 'application/json',
    'Authorization', 'Bearer ' || v_service_role_key
  );

  IF v_cron_secret IS NOT NULL THEN
    v_headers := v_headers || jsonb_build_object(
      'x-cron-secret', v_cron_secret,
      'x-fangeo-cron-secret', v_cron_secret
    );
  ELSE
    RAISE NOTICE
      'support reply push: Vault SUPPORT_REPLY_PUSH_CRON_SECRET missing; '
      'x-cron-secret not sent. See docs/ops/Support_Reply_Push_Vault_Cron_Secret.md';
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
  'Async notify-support-reply invoke. Bearer unchanged. Auth via x-cron-secret when Vault has SUPPORT_REPLY_PUSH_CRON_SECRET.';

COMMENT ON FUNCTION public.support_reply_push_vault_auth_status() IS
  'Ops check: Vault SUPPORT_REPLY_PUSH_CRON_SECRET readiness (lengths only, no secret values).';
