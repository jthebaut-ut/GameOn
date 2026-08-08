-- =============================================================================
-- 20260922_0001 — Unified chat message APNs (DM + group + pickup + venue)
-- =============================================================================
-- Extends the DM push pipeline into one conceptual worker path:
--   successful message RPC → queue → notify-chat-message → APNs fan-out
--
-- Preserves:
--   • RPC-only DMs (does not touch 20260915_0005b)
--   • send_direct_message / send_group_message security + rate limits
--   • Existing DM queue function (retargeted URL + payload)
--
-- Do NOT apply from the agent; review and apply deliberately in Supabase.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Preference columns (defaults ON)
-- ---------------------------------------------------------------------------
ALTER TABLE public.user_notification_preferences
  ADD COLUMN IF NOT EXISTS group_chat_notifications_enabled boolean NOT NULL DEFAULT true;

ALTER TABLE public.user_notification_preferences
  ADD COLUMN IF NOT EXISTS pickup_chat_notifications_enabled boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.user_notification_preferences.group_chat_notifications_enabled IS
  'When false, user must not receive social group-chat APNs. Defaults to true.';

COMMENT ON COLUMN public.user_notification_preferences.pickup_chat_notifications_enabled IS
  'When false, user must not receive pickup-game chat APNs. Defaults to true.';

-- ---------------------------------------------------------------------------
-- 2) Unified delivery ledger — one row per message_source + message + recipient
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.chat_message_push_deliveries (
  message_source text NOT NULL
    CHECK (message_source IN ('direct', 'group')),
  message_id uuid NOT NULL,
  recipient_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL,
  sender_user_id uuid NOT NULL,
  chat_type text NOT NULL
    CHECK (chat_type IN ('direct', 'venue', 'group', 'pickup')),
  delivery_status text NOT NULL DEFAULT 'queued'
    CHECK (delivery_status IN ('queued', 'sent', 'skipped', 'failed')),
  skip_reason text,
  sent_token_count integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (message_source, message_id, recipient_user_id)
);

CREATE INDEX IF NOT EXISTS chat_message_push_deliveries_conversation_created_idx
  ON public.chat_message_push_deliveries (conversation_id, created_at DESC);

CREATE INDEX IF NOT EXISTS chat_message_push_deliveries_recipient_created_idx
  ON public.chat_message_push_deliveries (recipient_user_id, created_at DESC);

COMMENT ON TABLE public.chat_message_push_deliveries IS
  'Unified dedupe ledger for social chat APNs (direct/venue/group/pickup).';

ALTER TABLE public.chat_message_push_deliveries ENABLE ROW LEVEL SECURITY;
GRANT ALL ON public.chat_message_push_deliveries TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Unified queue helper
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

  v_headers := jsonb_build_object(
    'Content-Type', 'application/json',
    'Authorization', 'Bearer ' || v_service_role_key
  );

  IF v_cron_secret IS NOT NULL THEN
    v_headers := v_headers || jsonb_build_object('x-cron-secret', v_cron_secret);
  END IF;

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
  'Best-effort async invoke of notify-chat-message for direct/group/pickup/venue chat.';

-- ---------------------------------------------------------------------------
-- 4) Retarget DM queue → unified worker (keep function name for compatibility)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.queue_direct_message_push_notification(
  p_message_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.queue_chat_message_push_notification(p_message_id, 'direct', 'direct');
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
  'Compat wrapper: queues unified notify-chat-message for direct/venue DMs.';

-- ---------------------------------------------------------------------------
-- 5) Hook send_group_message — preserve all security/rate-limit/reply logic
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.send_group_message(
  p_conversation_id uuid,
  p_body text,
  p_reply_to_message_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_body text := btrim(coalesce(p_body, ''));
  v_id uuid;
  v_preview text;
  v_pickup_game_id uuid;
  v_parent public.group_messages%ROWTYPE;
  v_chat_type text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  PERFORM public.assert_rpc_rate_limit('send_group_message', 60, 60);

  IF char_length(v_body) < 1 THEN
    RAISE EXCEPTION 'Message body required.';
  END IF;

  IF NOT public.is_active_group_member(p_conversation_id, me) THEN
    RAISE EXCEPTION 'Not an active member.';
  END IF;

  SELECT c.pickup_game_id INTO v_pickup_game_id
  FROM public.group_conversations c
  WHERE c.id = p_conversation_id;

  IF v_pickup_game_id IS NOT NULL
     AND NOT public.is_pickup_game_chat_authorized(v_pickup_game_id, me) THEN
    RAISE EXCEPTION 'Not authorized for this pickup game chat.'
      USING ERRCODE = '42501';
  END IF;

  IF p_reply_to_message_id IS NOT NULL THEN
    SELECT * INTO v_parent
    FROM public.group_messages gm
    WHERE gm.id = p_reply_to_message_id;

    IF NOT FOUND
       OR v_parent.conversation_id IS DISTINCT FROM p_conversation_id
       OR v_parent.deleted_at IS NOT NULL
       OR COALESCE(v_parent.is_deleted, FALSE) = TRUE
       OR COALESCE(v_parent.message_type, 'text') IS DISTINCT FROM 'text'
       OR NOT public.group_member_can_read_message(
            v_parent.conversation_id, me, v_parent.created_at
          )
    THEN
      RAISE EXCEPTION 'reply target unavailable'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  INSERT INTO public.group_messages (
    conversation_id,
    sender_id,
    body,
    message_type,
    reply_to_message_id
  )
  VALUES (
    p_conversation_id,
    me,
    v_body,
    'text',
    p_reply_to_message_id
  )
  RETURNING id INTO v_id;

  v_preview := left(v_body, 180);

  UPDATE public.group_conversations
  SET
    last_message_at = now(),
    last_message_preview = v_preview,
    last_message_sender_id = me,
    last_message_type = 'text',
    last_system_event = NULL,
    last_system_payload = NULL,
    updated_at = now()
  WHERE id = p_conversation_id;

  UPDATE public.group_conversation_members
  SET last_read_at = now()
  WHERE conversation_id = p_conversation_id
    AND user_id = me
    AND left_at IS NULL;

  v_chat_type := CASE WHEN v_pickup_game_id IS NOT NULL THEN 'pickup' ELSE 'group' END;
  PERFORM public.queue_chat_message_push_notification(v_id, 'group', v_chat_type);

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.send_group_message(uuid, text, uuid) IS
  'Group/pickup send with optional reply_to. Rate-limited (60/60s). Queues unified chat APNs after insert.';

REVOKE ALL ON FUNCTION public.send_group_message(uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.send_group_message(uuid, text, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.send_group_message(uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_group_message(uuid, text, uuid) TO service_role;

COMMIT;

-- =============================================================================
-- PRE-DEPLOYMENT
-- =============================================================================
-- SELECT to_regprocedure('public.send_direct_message(uuid, text, uuid)') IS NOT NULL;
-- SELECT to_regprocedure('public.send_group_message(uuid, text, uuid)') IS NOT NULL;
-- SELECT has_table_privilege('authenticated', 'public.direct_messages', 'INSERT'); -- false
-- SELECT to_regnamespace('net') IS NOT NULL;
--
-- POST-DEPLOYMENT
-- =============================================================================
-- SELECT to_regclass('public.chat_message_push_deliveries') IS NOT NULL;
-- SELECT to_regprocedure('public.queue_chat_message_push_notification(uuid, text, text)') IS NOT NULL;
-- SELECT pg_get_functiondef('public.send_group_message(uuid, text, uuid)'::regprocedure)
--   ILIKE '%queue_chat_message_push_notification%';
-- SELECT pg_get_functiondef('public.queue_direct_message_push_notification(uuid)'::regprocedure)
--   ILIKE '%queue_chat_message_push_notification%';
-- SELECT column_name FROM information_schema.columns
--  WHERE table_schema='public' AND table_name='user_notification_preferences'
--    AND column_name IN ('group_chat_notifications_enabled','pickup_chat_notifications_enabled');
--
-- ROLLBACK (reasonable)
-- =============================================================================
-- BEGIN;
-- -- Restore send_group_message from 20260917_0001 (no queue), restore
-- -- queue_direct_message_push_notification from 20260920 to hit notify-direct-message,
-- -- then DROP queue_chat_message_push_notification / chat_message_push_deliveries /
-- -- preference columns.
-- COMMIT;
-- =============================================================================
