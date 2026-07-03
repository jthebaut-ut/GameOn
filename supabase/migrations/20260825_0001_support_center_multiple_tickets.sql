-- Support Center: multiple tickets per user, list RPC, conversation-scoped chat RPCs.
-- Does not touch direct_messages, direct_conversations, or friendships.

DROP INDEX IF EXISTS public.support_conversations_one_open_per_user;

CREATE OR REPLACE FUNCTION public.get_my_support_requests(
  p_limit integer DEFAULT 50
)
RETURNS TABLE (
  conversation_id uuid,
  subject text,
  issue_type text,
  status text,
  chat_opened_at timestamptz,
  last_message_at timestamptz,
  last_support_message_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  RETURN QUERY
  SELECT
    sc.id,
    sc.subject,
    sc.issue_type,
    sc.status,
    sc.chat_opened_at,
    sc.last_message_at,
    sc.last_support_message_at,
    sc.created_at,
    sc.updated_at
  FROM public.support_conversations sc
  WHERE sc.user_id = v_uid
  ORDER BY COALESCE(sc.last_message_at, sc.updated_at, sc.created_at) DESC
  LIMIT v_limit;
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

CREATE OR REPLACE FUNCTION public.send_my_support_message_for_conversation(
  p_conversation_id uuid,
  p_body text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
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

  IF NOT EXISTS (
    SELECT 1
    FROM public.support_conversations sc
    WHERE sc.id = p_conversation_id
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
    p_conversation_id,
    'user',
    v_uid,
    v_body
  )
  RETURNING id INTO v_message_id;

  RETURN v_message_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.fetch_my_support_messages_for_conversation(
  p_conversation_id uuid,
  p_limit integer DEFAULT 100
)
RETURNS TABLE (
  id uuid,
  conversation_id uuid,
  sender_kind text,
  sender_auth_user_id uuid,
  body text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 200);
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.support_conversations sc
    WHERE sc.id = p_conversation_id
      AND sc.user_id = v_uid
  ) THEN
    RAISE EXCEPTION 'conversation not found';
  END IF;

  RETURN QUERY
  SELECT
    sm.id,
    sm.conversation_id,
    sm.sender_kind,
    sm.sender_auth_user_id,
    sm.body,
    sm.created_at
  FROM public.support_messages sm
  WHERE sm.conversation_id = p_conversation_id
    AND sm.deleted_at IS NULL
  ORDER BY sm.created_at ASC, sm.id ASC
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_support_requests(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.send_my_support_message_for_conversation(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fetch_my_support_messages_for_conversation(uuid, integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_my_support_requests(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_my_support_message_for_conversation(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fetch_my_support_messages_for_conversation(uuid, integer) TO authenticated;

COMMENT ON FUNCTION public.get_my_support_requests(integer) IS
  'Lists the authenticated user support tickets for the Support Center.';
COMMENT ON FUNCTION public.submit_my_support_ticket(text, text, text) IS
  'Creates a new support_conversations row and initial ticket message.';
COMMENT ON FUNCTION public.send_my_support_message_for_conversation(uuid, text) IS
  'Inserts a user message in a specific open support conversation when chat is available.';
COMMENT ON FUNCTION public.fetch_my_support_messages_for_conversation(uuid, integer) IS
  'Returns support_messages for a specific owned support conversation.';
