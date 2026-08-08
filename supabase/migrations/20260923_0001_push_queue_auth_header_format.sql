-- =============================================================================
-- 20260923_0001 — Push queue auth header format (legacy JWT vs sb_secret_*)
-- =============================================================================
-- Auth-only. Does NOT modify message RPCs (send_direct_message /
-- friendship_ensure_pending / send_group_message), RLS, or message tables.
--
-- Supabase guidance:
--   legacy service_role JWT → Authorization: Bearer <jwt>
--   new sb_secret_* key     → apikey: <secret>
--
-- Detects the existing Vault credential prefix and sets the correct header.
-- Does NOT invent a new shared/cron secret.
--
-- Do NOT apply from the agent; review and apply deliberately.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.push_worker_auth_headers(
  p_credential text,
  p_cron_secret text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_cred text := btrim(coalesce(p_credential, ''));
  v_headers jsonb;
BEGIN
  IF v_cred = '' THEN
    RAISE EXCEPTION 'push worker credential required';
  END IF;

  IF v_cred LIKE 'sb_secret_%' THEN
    v_headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', v_cred
    );
  ELSE
    v_headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_cred
    );
  END IF;

  IF NULLIF(btrim(coalesce(p_cron_secret, '')), '') IS NOT NULL THEN
    v_headers := v_headers || jsonb_build_object('x-cron-secret', btrim(p_cron_secret));
  END IF;

  RETURN v_headers;
END;
$$;

REVOKE ALL ON FUNCTION public.push_worker_auth_headers(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.push_worker_auth_headers(text, text) FROM anon;
REVOKE ALL ON FUNCTION public.push_worker_auth_headers(text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.push_worker_auth_headers(text, text) TO service_role;

COMMENT ON FUNCTION public.push_worker_auth_headers(text, text) IS
  'Builds pg_net headers for Edge push workers: apikey for sb_secret_*, Bearer for legacy JWT.';

-- ---------------------------------------------------------------------------
-- DM queue → notify-direct-message (preserves production target URL)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.queue_direct_message_push_notification(
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
  IF p_message_id IS NULL THEN
    RETURN;
  END IF;

  IF to_regnamespace('net') IS NULL OR to_regclass('vault.decrypted_secrets') IS NULL THEN
    RAISE NOTICE 'direct message push skipped: pg_net or vault unavailable';
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

  IF v_url IS NULL OR v_service_role_key IS NULL THEN
    RAISE NOTICE 'direct message push skipped: vault secrets missing';
    RETURN;
  END IF;

  SELECT decrypted_secret
  INTO v_cron_secret
  FROM vault.decrypted_secrets
  WHERE name IN ('CHAT_MESSAGE_PUSH_CRON_SECRET', 'DIRECT_MESSAGE_PUSH_CRON_SECRET')
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY CASE name
    WHEN 'CHAT_MESSAGE_PUSH_CRON_SECRET' THEN 0
    ELSE 1
  END,
  updated_at DESC NULLS LAST, created_at DESC
  LIMIT 1;

  v_headers := public.push_worker_auth_headers(v_service_role_key, v_cron_secret);

  PERFORM net.http_post(
    url := v_url || '/functions/v1/notify-direct-message',
    headers := v_headers,
    body := jsonb_build_object('message_id', p_message_id),
    timeout_milliseconds := 15000
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'direct message push queue failed: %', SQLERRM;
END;
$$;

REVOKE ALL ON FUNCTION public.queue_direct_message_push_notification(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.queue_direct_message_push_notification(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.queue_direct_message_push_notification(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.queue_direct_message_push_notification(uuid) TO service_role;

COMMENT ON FUNCTION public.queue_direct_message_push_notification(uuid) IS
  'Best-effort async invoke of notify-direct-message with format-aware auth headers.';

-- ---------------------------------------------------------------------------
-- Unified chat queue → notify-chat-message (header format only)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.queue_chat_message_push_notification(
  p_message_id uuid,
  p_message_source text,
  p_chat_type text DEFAULT NULL
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
  v_source text := lower(btrim(coalesce(p_message_source, '')));
  v_chat_type text := lower(btrim(coalesce(p_chat_type, '')));
BEGIN
  IF p_message_id IS NULL THEN
    RETURN;
  END IF;

  IF v_source NOT IN ('direct', 'group') THEN
    RAISE NOTICE 'chat message push skipped: invalid message_source=%', v_source;
    RETURN;
  END IF;

  IF v_chat_type = '' THEN
    v_chat_type := CASE WHEN v_source = 'group' THEN 'group' ELSE 'direct' END;
  END IF;

  IF to_regnamespace('net') IS NULL OR to_regclass('vault.decrypted_secrets') IS NULL THEN
    RAISE NOTICE 'chat message push skipped: pg_net or vault unavailable';
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

  IF v_url IS NULL OR v_service_role_key IS NULL THEN
    RAISE NOTICE 'chat message push skipped: vault secrets missing';
    RETURN;
  END IF;

  SELECT decrypted_secret
  INTO v_cron_secret
  FROM vault.decrypted_secrets
  WHERE name IN ('CHAT_MESSAGE_PUSH_CRON_SECRET', 'DIRECT_MESSAGE_PUSH_CRON_SECRET')
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY CASE name
    WHEN 'CHAT_MESSAGE_PUSH_CRON_SECRET' THEN 0
    ELSE 1
  END,
  updated_at DESC NULLS LAST, created_at DESC
  LIMIT 1;

  v_headers := public.push_worker_auth_headers(v_service_role_key, v_cron_secret);

  PERFORM net.http_post(
    url := v_url || '/functions/v1/notify-chat-message',
    headers := v_headers,
    body := jsonb_build_object(
      'message_id', p_message_id,
      'message_source', v_source,
      'chat_type', v_chat_type
    ),
    timeout_milliseconds := 15000
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'chat message push queue failed: %', SQLERRM;
END;
$$;

REVOKE ALL ON FUNCTION public.queue_chat_message_push_notification(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.queue_chat_message_push_notification(uuid, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.queue_chat_message_push_notification(uuid, text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.queue_chat_message_push_notification(uuid, text, text) TO service_role;

COMMENT ON FUNCTION public.queue_chat_message_push_notification(uuid, text, text) IS
  'Best-effort async invoke of notify-chat-message with format-aware auth headers.';

-- ---------------------------------------------------------------------------
-- Friend-request queue → notify-friend-request (header format only)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.queue_friend_request_push_notification(
  p_friendship_id uuid,
  p_event_id uuid
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
  IF p_friendship_id IS NULL OR p_event_id IS NULL THEN
    RETURN;
  END IF;

  IF to_regnamespace('net') IS NULL OR to_regclass('vault.decrypted_secrets') IS NULL THEN
    RAISE NOTICE 'friend request push skipped: pg_net or vault unavailable';
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

  IF v_url IS NULL OR v_service_role_key IS NULL THEN
    RAISE NOTICE 'friend request push skipped: vault secrets missing';
    RETURN;
  END IF;

  SELECT decrypted_secret
  INTO v_cron_secret
  FROM vault.decrypted_secrets
  WHERE name = 'FRIEND_REQUEST_PUSH_CRON_SECRET'
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY updated_at DESC NULLS LAST, created_at DESC
  LIMIT 1;

  v_headers := public.push_worker_auth_headers(v_service_role_key, v_cron_secret);

  PERFORM net.http_post(
    url := v_url || '/functions/v1/notify-friend-request',
    headers := v_headers,
    body := jsonb_build_object(
      'friendship_id', p_friendship_id,
      'event_id', p_event_id
    ),
    timeout_milliseconds := 15000
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'friend request push queue failed: %', SQLERRM;
END;
$$;

REVOKE ALL ON FUNCTION public.queue_friend_request_push_notification(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.queue_friend_request_push_notification(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.queue_friend_request_push_notification(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.queue_friend_request_push_notification(uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.queue_friend_request_push_notification(uuid, uuid) IS
  'Best-effort async invoke of notify-friend-request with format-aware auth headers.';

COMMIT;

-- =============================================================================
-- PRE-DEPLOY (class only — never select decrypted_secret itself in logs)
-- =============================================================================
-- SELECT
--   name,
--   CASE
--     WHEN decrypted_secret LIKE 'sb_secret_%' THEN 'secret_key'
--     WHEN decrypted_secret LIKE 'eyJ%' THEN 'legacy_jwt'
--     ELSE 'other'
--   END AS credential_class,
--   length(decrypted_secret) AS credential_length
-- FROM vault.decrypted_secrets
-- WHERE name IN ('SUPABASE_SERVICE_ROLE_KEY', 'fangeo_service_role_key');
--
-- POST-DEPLOY
-- =============================================================================
-- SELECT public.push_worker_auth_headers('sb_secret_test', NULL) ? 'apikey';
-- SELECT public.push_worker_auth_headers('eyJhbGciOi.test', NULL) ? 'Authorization';
-- =============================================================================
