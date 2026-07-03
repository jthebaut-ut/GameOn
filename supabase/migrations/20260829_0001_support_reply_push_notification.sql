-- Queue APNs when an admin posts a support reply (sender_kind = support).

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
  WHERE name IN ('fangeo_service_role_key', 'SUPABASE_SERVICE_ROLE_KEY')
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY CASE name WHEN 'fangeo_service_role_key' THEN 0 ELSE 1 END
  LIMIT 1;

  IF v_url IS NULL OR v_service_role_key IS NULL THEN
    RAISE NOTICE 'support reply push skipped: vault secrets missing';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url := v_url || '/functions/v1/notify-support-reply',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_service_role_key
    ),
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

REVOKE ALL ON FUNCTION public.queue_support_reply_push_notification(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.queue_support_reply_push_notification(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.admin_send_support_message(
  p_conversation_id uuid,
  p_body text,
  p_admin_email text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_email text;
  v_body text;
  v_message_id uuid;
BEGIN
  IF NOT public.is_support_inbox_admin(p_admin_email) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_admin_email := NULLIF(
    btrim(
      coalesce(
        nullif(btrim(coalesce(p_admin_email, '')), ''),
        coalesce(auth.jwt() ->> 'email', '')
      )
    ),
    ''
  );

  v_body := btrim(coalesce(p_body, ''));
  IF char_length(v_body) = 0 OR char_length(v_body) > 4000 THEN
    RAISE EXCEPTION 'invalid message body';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.support_conversations sc
    WHERE sc.id = p_conversation_id
  ) THEN
    RAISE EXCEPTION 'conversation not found';
  END IF;

  UPDATE public.support_conversations sc
  SET
    chat_opened_at = COALESCE(sc.chat_opened_at, now()),
    status = 'open',
    updated_at = now()
  WHERE sc.id = p_conversation_id
    AND sc.status = 'closed';

  INSERT INTO public.support_messages (
    conversation_id,
    sender_kind,
    admin_email,
    body
  )
  VALUES (
    p_conversation_id,
    'support',
    v_admin_email,
    v_body
  )
  RETURNING id INTO v_message_id;

  PERFORM public.queue_support_reply_push_notification(p_conversation_id, v_message_id);

  RETURN v_message_id;
END;
$$;

COMMENT ON FUNCTION public.queue_support_reply_push_notification(uuid, uuid) IS
  'Best-effort async invoke of notify-support-reply edge function after admin support replies.';
