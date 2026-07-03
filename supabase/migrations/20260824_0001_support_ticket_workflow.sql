-- Ticket-first FanGeo Support workflow.
-- Does not touch direct_messages, direct_conversations, or friendships.

ALTER TABLE public.support_conversations
  ADD COLUMN IF NOT EXISTS subject text,
  ADD COLUMN IF NOT EXISTS issue_type text,
  ADD COLUMN IF NOT EXISTS chat_opened_at timestamptz;

GRANT SELECT (
  subject,
  issue_type,
  chat_opened_at
) ON public.support_conversations TO authenticated;

CREATE OR REPLACE FUNCTION public.get_my_support_ticket_status()
RETURNS TABLE (
  conversation_id uuid,
  status text,
  subject text,
  issue_type text,
  chat_opened_at timestamptz,
  last_support_message_at timestamptz,
  chat_available boolean,
  pending_review boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.support_conversations%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  SELECT sc.*
  INTO v_row
  FROM public.support_conversations sc
  WHERE sc.user_id = v_uid
    AND sc.status = 'open'
  ORDER BY COALESCE(sc.last_message_at, sc.updated_at, sc.created_at) DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN QUERY
    SELECT
      NULL::uuid,
      'none'::text,
      NULL::text,
      NULL::text,
      NULL::timestamptz,
      NULL::timestamptz,
      false,
      false;
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    v_row.id,
    v_row.status,
    v_row.subject,
    v_row.issue_type,
    v_row.chat_opened_at,
    v_row.last_support_message_at,
    (
      v_row.chat_opened_at IS NOT NULL
      OR v_row.last_support_message_at IS NOT NULL
    ),
    (
      v_row.chat_opened_at IS NULL
      AND v_row.last_support_message_at IS NULL
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_my_support_ticket(
  p_subject text,
  p_issue_type text,
  p_body text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_subject text;
  v_issue_type text;
  v_body text;
  v_conversation_id uuid;
  v_message_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  v_subject := btrim(coalesce(p_subject, ''));
  v_issue_type := btrim(coalesce(p_issue_type, ''));
  v_body := btrim(coalesce(p_body, ''));

  IF char_length(v_subject) = 0 OR char_length(v_subject) > 200 THEN
    RAISE EXCEPTION 'invalid subject';
  END IF;
  IF char_length(v_issue_type) = 0 OR char_length(v_issue_type) > 64 THEN
    RAISE EXCEPTION 'invalid issue type';
  END IF;
  IF char_length(v_body) = 0 OR char_length(v_body) > 4000 THEN
    RAISE EXCEPTION 'invalid message body';
  END IF;

  SELECT sc.id
  INTO v_conversation_id
  FROM public.support_conversations sc
  WHERE sc.user_id = v_uid
    AND sc.status = 'open'
  ORDER BY COALESCE(sc.last_message_at, sc.updated_at, sc.created_at) DESC
  LIMIT 1;

  IF v_conversation_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
      FROM public.support_conversations sc
      WHERE sc.id = v_conversation_id
        AND (
          sc.chat_opened_at IS NOT NULL
          OR sc.last_support_message_at IS NOT NULL
        )
    ) THEN
      RAISE EXCEPTION 'support chat already active';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.support_messages sm
      WHERE sm.conversation_id = v_conversation_id
        AND sm.deleted_at IS NULL
    ) THEN
      RETURN v_conversation_id;
    END IF;

    UPDATE public.support_conversations sc
    SET
      subject = v_subject,
      issue_type = v_issue_type,
      updated_at = now()
    WHERE sc.id = v_conversation_id;
  ELSE
    INSERT INTO public.support_conversations (
      user_id,
      status,
      subject,
      issue_type
    )
    VALUES (
      v_uid,
      'open',
      v_subject,
      v_issue_type
    )
    RETURNING id INTO v_conversation_id;
  END IF;

  INSERT INTO public.support_messages (
    conversation_id,
    sender_kind,
    sender_auth_user_id,
    body
  )
  VALUES (
    v_conversation_id,
    'user',
    v_uid,
    v_body
  )
  RETURNING id INTO v_message_id;

  RETURN v_conversation_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_or_create_my_support_conversation()
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  SELECT sc.id
  INTO v_id
  FROM public.support_conversations sc
  WHERE sc.user_id = v_uid
    AND sc.status = 'open'
  ORDER BY COALESCE(sc.last_message_at, sc.updated_at, sc.created_at) DESC
  LIMIT 1;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'no open support conversation';
  END IF;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.send_my_support_message(p_body text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_conversation_id uuid;
  v_body text;
  v_message_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  v_body := btrim(coalesce(p_body, ''));
  IF char_length(v_body) = 0 OR char_length(v_body) > 4000 THEN
    RAISE EXCEPTION 'invalid message body';
  END IF;

  v_conversation_id := public.get_or_create_my_support_conversation();

  IF NOT EXISTS (
    SELECT 1
    FROM public.support_conversations sc
    WHERE sc.id = v_conversation_id
      AND sc.user_id = v_uid
      AND sc.status = 'open'
      AND (
        sc.chat_opened_at IS NOT NULL
        OR sc.last_support_message_at IS NOT NULL
      )
  ) THEN
    RAISE EXCEPTION 'support chat not available';
  END IF;

  INSERT INTO public.support_messages (
    conversation_id,
    sender_kind,
    sender_auth_user_id,
    body
  )
  VALUES (
    v_conversation_id,
    'user',
    v_uid,
    v_body
  )
  RETURNING id INTO v_message_id;

  RETURN v_message_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_open_support_chat(
  p_conversation_id uuid,
  p_admin_email text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_support_inbox_admin(p_admin_email) THEN
    RAISE EXCEPTION 'not authorized';
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
  WHERE sc.id = p_conversation_id;

  RETURN p_conversation_id;
END;
$$;

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

  RETURN v_message_id;
END;
$$;

DROP FUNCTION IF EXISTS public.admin_list_support_conversations(text, integer);

CREATE FUNCTION public.admin_list_support_conversations(
  p_admin_email text DEFAULT NULL,
  p_limit integer DEFAULT 50
)
RETURNS TABLE (
  id uuid,
  user_id uuid,
  status text,
  subject text,
  issue_type text,
  chat_opened_at timestamptz,
  last_message_at timestamptz,
  last_user_message_at timestamptz,
  last_support_message_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz,
  last_message_body text,
  last_message_sender_kind text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
BEGIN
  IF NOT public.is_support_inbox_admin(p_admin_email) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  RETURN QUERY
  SELECT
    sc.id,
    sc.user_id,
    sc.status,
    sc.subject,
    sc.issue_type,
    sc.chat_opened_at,
    sc.last_message_at,
    sc.last_user_message_at,
    sc.last_support_message_at,
    sc.created_at,
    sc.updated_at,
    lm.body AS last_message_body,
    lm.sender_kind AS last_message_sender_kind
  FROM public.support_conversations sc
  LEFT JOIN LATERAL (
    SELECT sm.body, sm.sender_kind
    FROM public.support_messages sm
    WHERE sm.conversation_id = sc.id
      AND sm.deleted_at IS NULL
    ORDER BY sm.created_at DESC, sm.id DESC
    LIMIT 1
  ) lm ON true
  ORDER BY COALESCE(sc.last_message_at, sc.updated_at, sc.created_at) DESC
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_support_ticket_status() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.submit_my_support_ticket(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_open_support_chat(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_list_support_conversations(text, integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_my_support_ticket_status() TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_my_support_ticket(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_open_support_chat(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_support_conversations(text, integer) TO authenticated;

COMMENT ON FUNCTION public.get_my_support_ticket_status() IS
  'Returns the caller open support ticket state for ticket-first FanGeo Support UX.';
COMMENT ON FUNCTION public.submit_my_support_ticket(text, text, text) IS
  'Creates or reuses an open support_conversations row and stores the initial ticket message.';
COMMENT ON FUNCTION public.admin_open_support_chat(uuid, text) IS
  'Marks a support ticket chat as available to the user without sending a message.';
COMMENT ON FUNCTION public.admin_list_support_conversations(text, integer) IS
  'Lists support tickets for the admin inbox, including subject, issue type, and chat-open state.';
