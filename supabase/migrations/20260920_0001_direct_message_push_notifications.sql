-- =============================================================================
-- 20260920_0001 — Direct message APNs push (trusted server path)
-- =============================================================================
-- After public.send_direct_message inserts a row, queue notify-direct-message via
-- pg_net + Vault (same pattern as support-reply / pickup-change).
--
-- Does NOT restore authenticated INSERT on public.direct_messages.
-- Does NOT modify 20260915_0005b_direct_messages_rpc_only_enforcement.sql.
--
-- Do NOT apply from the agent; review and apply deliberately in Supabase.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Preference columns (future preview modes; default = show previews)
-- ---------------------------------------------------------------------------
ALTER TABLE public.user_notification_preferences
  ADD COLUMN IF NOT EXISTS direct_message_notifications_enabled boolean NOT NULL DEFAULT true;

ALTER TABLE public.user_notification_preferences
  ADD COLUMN IF NOT EXISTS direct_message_preview_mode text NOT NULL DEFAULT 'always';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'user_notification_preferences_dm_preview_mode_ck'
  ) THEN
    ALTER TABLE public.user_notification_preferences
      ADD CONSTRAINT user_notification_preferences_dm_preview_mode_ck
      CHECK (direct_message_preview_mode IN ('always', 'when_unlocked', 'never'));
  END IF;
END $$;

COMMENT ON COLUMN public.user_notification_preferences.direct_message_notifications_enabled IS
  'When false, user must not receive direct-message APNs. Defaults to true.';

COMMENT ON COLUMN public.user_notification_preferences.direct_message_preview_mode IS
  'DM push body preview: always | when_unlocked | never. UI not required for always default.';

-- ---------------------------------------------------------------------------
-- 2) Dedupe ledger — one logical delivery attempt per message + recipient
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.direct_message_push_deliveries (
  message_id uuid NOT NULL REFERENCES public.direct_messages (id) ON DELETE CASCADE,
  recipient_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL,
  sender_user_id uuid NOT NULL,
  delivery_status text NOT NULL DEFAULT 'queued'
    CHECK (delivery_status IN ('queued', 'sent', 'skipped', 'failed')),
  skip_reason text,
  sent_token_count integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, recipient_user_id)
);

CREATE INDEX IF NOT EXISTS direct_message_push_deliveries_conversation_created_idx
  ON public.direct_message_push_deliveries (conversation_id, created_at DESC);

COMMENT ON TABLE public.direct_message_push_deliveries IS
  'Dedupe ledger for DM APNs: at most one logical notification event per message/recipient.';

ALTER TABLE public.direct_message_push_deliveries ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS direct_message_push_deliveries_service_all
  ON public.direct_message_push_deliveries;
-- No authenticated policies — service_role bypasses RLS.

GRANT ALL ON public.direct_message_push_deliveries TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Queue Edge Function (best-effort; never fails the DM send)
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
  WHERE name = 'DIRECT_MESSAGE_PUSH_CRON_SECRET'
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY updated_at DESC NULLS LAST, created_at DESC
  LIMIT 1;

  v_headers := jsonb_build_object(
    'Content-Type', 'application/json',
    'Authorization', 'Bearer ' || v_service_role_key
  );

  IF v_cron_secret IS NOT NULL THEN
    v_headers := v_headers || jsonb_build_object('x-cron-secret', v_cron_secret);
  END IF;

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
  'Best-effort async invoke of notify-direct-message after a DM row is created. Never raises to callers.';

-- ---------------------------------------------------------------------------
-- 4) Hook send_direct_message — preserve RPC-only security; queue after INSERT
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.send_direct_message(
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
  v_parent public.direct_messages%ROWTYPE;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '42501';
  END IF;

  PERFORM public.assert_rpc_rate_limit('send_direct_message', 60, 60);

  IF p_conversation_id IS NULL THEN
    RAISE EXCEPTION 'conversation required' USING ERRCODE = '22023';
  END IF;

  IF char_length(v_body) < 1 THEN
    RAISE EXCEPTION 'Message body required.' USING ERRCODE = '22023';
  END IF;

  IF NOT public.direct_message_send_allowed(p_conversation_id, me) THEN
    RAISE EXCEPTION 'Not allowed to send in this conversation.'
      USING ERRCODE = '42501';
  END IF;

  IF p_reply_to_message_id IS NOT NULL THEN
    SELECT * INTO v_parent
    FROM public.direct_messages dm
    WHERE dm.id = p_reply_to_message_id;

    IF NOT FOUND
       OR v_parent.conversation_id IS DISTINCT FROM p_conversation_id
       OR v_parent.deleted_at IS NOT NULL
       OR COALESCE(v_parent.is_deleted, FALSE) = TRUE
       OR NOT public.is_direct_conversation_participant(p_conversation_id, me)
       OR NOT public.direct_message_after_viewer_clear(
            p_conversation_id, v_parent.created_at, me
          )
    THEN
      RAISE EXCEPTION 'reply target unavailable'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  INSERT INTO public.direct_messages (
    conversation_id,
    sender_id,
    body,
    reply_to_message_id
  )
  VALUES (
    p_conversation_id,
    me,
    v_body,
    p_reply_to_message_id
  )
  RETURNING id INTO v_id;

  -- Trusted server-side push queue (never blocks / fails the send).
  PERFORM public.queue_direct_message_push_notification(v_id);

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.send_direct_message(uuid, text, uuid) IS
  'DM send with optional reply_to. Auth.uid() sender; rate-limited; queues APNs via notify-direct-message after insert.';

REVOKE ALL ON FUNCTION public.send_direct_message(uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.send_direct_message(uuid, text, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.send_direct_message(uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_direct_message(uuid, text, uuid) TO service_role;

COMMIT;

-- =============================================================================
-- PRE-DEPLOYMENT VERIFICATION (run manually before apply)
-- =============================================================================
-- SELECT to_regprocedure('public.send_direct_message(uuid, text, uuid)') IS NOT NULL AS send_dm_exists;
-- SELECT has_table_privilege('authenticated', 'public.direct_messages', 'INSERT') AS authed_can_insert; -- expect false
-- SELECT to_regnamespace('net') IS NOT NULL AS pg_net_ready;
-- SELECT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name IN ('fangeo_supabase_url','SUPABASE_URL')) AS url_secret;
-- SELECT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name IN ('fangeo_service_role_key','SUPABASE_SERVICE_ROLE_KEY')) AS sr_secret;
--
-- POST-DEPLOYMENT VERIFICATION
-- =============================================================================
-- SELECT to_regprocedure('public.queue_direct_message_push_notification(uuid)') IS NOT NULL;
-- SELECT column_name FROM information_schema.columns
--  WHERE table_schema='public' AND table_name='user_notification_preferences'
--    AND column_name IN ('direct_message_notifications_enabled','direct_message_preview_mode');
-- SELECT to_regclass('public.direct_message_push_deliveries') IS NOT NULL;
-- -- Confirm RPC body still queues (definition contains queue call):
-- SELECT pg_get_functiondef('public.send_direct_message(uuid, text, uuid)'::regprocedure)
--   ILIKE '%queue_direct_message_push_notification%';
-- -- Confirm INSERT still revoked for authenticated:
-- SELECT has_table_privilege('authenticated', 'public.direct_messages', 'INSERT'); -- expect false
--
-- ROLLBACK (reasonable)
-- =============================================================================
-- BEGIN;
-- -- Remove queue call by restoring prior send_direct_message from 20260917_0001
-- -- (re-apply that function body without PERFORM queue...), then:
-- DROP FUNCTION IF EXISTS public.queue_direct_message_push_notification(uuid);
-- DROP TABLE IF EXISTS public.direct_message_push_deliveries;
-- ALTER TABLE public.user_notification_preferences
--   DROP CONSTRAINT IF EXISTS user_notification_preferences_dm_preview_mode_ck;
-- ALTER TABLE public.user_notification_preferences
--   DROP COLUMN IF EXISTS direct_message_notifications_enabled;
-- ALTER TABLE public.user_notification_preferences
--   DROP COLUMN IF EXISTS direct_message_preview_mode;
-- COMMIT;
-- =============================================================================
