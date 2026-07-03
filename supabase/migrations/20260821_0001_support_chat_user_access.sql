-- FanGeo Support Chat: authenticated user read/write for own thread only.
-- Does not touch direct_messages, direct_conversations, or friendships.

-- Safe column grants (admin_email / assigned_admin_email never exposed to clients).
GRANT SELECT (
  id,
  user_id,
  status,
  last_message_at,
  last_support_message_at,
  last_user_message_at,
  created_at,
  updated_at
) ON public.support_conversations TO authenticated;

GRANT SELECT (
  id,
  conversation_id,
  sender_kind,
  sender_auth_user_id,
  body,
  created_at
) ON public.support_messages TO authenticated;

DROP POLICY IF EXISTS support_conversations_select_own ON public.support_conversations;
CREATE POLICY support_conversations_select_own
  ON public.support_conversations
  FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS support_messages_select_own ON public.support_messages;
CREATE POLICY support_messages_select_own
  ON public.support_messages
  FOR SELECT
  TO authenticated
  USING (
    deleted_at IS NULL
    AND EXISTS (
      SELECT 1
      FROM public.support_conversations sc
      WHERE sc.id = conversation_id
        AND sc.user_id = auth.uid()
    )
  );

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
  ORDER BY sc.updated_at DESC
  LIMIT 1;

  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  INSERT INTO public.support_conversations (user_id, status)
  VALUES (v_uid, 'open')
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT sc.id
    INTO v_id
    FROM public.support_conversations sc
    WHERE sc.user_id = v_uid
      AND sc.status = 'open'
    ORDER BY sc.updated_at DESC
    LIMIT 1;
  END IF;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'support conversation unavailable';
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
  ) THEN
    RAISE EXCEPTION 'support conversation not available';
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

REVOKE ALL ON FUNCTION public.get_or_create_my_support_conversation() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.send_my_support_message(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_or_create_my_support_conversation() TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_my_support_message(text) TO authenticated;

COMMENT ON FUNCTION public.get_or_create_my_support_conversation() IS
  'Returns the authenticated user open support_conversations row, creating one when needed.';
COMMENT ON FUNCTION public.send_my_support_message(text) IS
  'Inserts a user-authored support_messages row in the caller own open support conversation.';
