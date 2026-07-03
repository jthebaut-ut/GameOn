-- Admin Support Inbox: RPCs, admin RLS for realtime, support_conversations publication.
-- Does not touch direct_messages, direct_conversations, or friendships.

CREATE OR REPLACE FUNCTION public.is_support_inbox_admin(p_admin_email text DEFAULT NULL)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT NULLIF(
    lower(
      btrim(
        coalesce(
          nullif(btrim(coalesce(p_admin_email, '')), ''),
          coalesce(auth.jwt() ->> 'email', '')
        )
      )
    ),
    ''
  ) LIKE '%@fangeosports.com';
$$;

REVOKE ALL ON FUNCTION public.is_support_inbox_admin(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_support_inbox_admin(text) TO authenticated;

DROP POLICY IF EXISTS support_conversations_support_admin_select ON public.support_conversations;
CREATE POLICY support_conversations_support_admin_select
  ON public.support_conversations
  FOR SELECT
  TO authenticated
  USING (public.is_support_inbox_admin());

DROP POLICY IF EXISTS support_messages_support_admin_select ON public.support_messages;
CREATE POLICY support_messages_support_admin_select
  ON public.support_messages
  FOR SELECT
  TO authenticated
  USING (
    deleted_at IS NULL
    AND public.is_support_inbox_admin()
  );

CREATE OR REPLACE FUNCTION public.admin_list_support_conversations(
  p_admin_email text DEFAULT NULL,
  p_limit integer DEFAULT 50
)
RETURNS TABLE (
  id uuid,
  user_id uuid,
  status text,
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

CREATE OR REPLACE FUNCTION public.admin_fetch_support_messages(
  p_conversation_id uuid,
  p_admin_email text DEFAULT NULL,
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
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 200);
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
  SET status = 'open', updated_at = now()
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

REVOKE ALL ON FUNCTION public.admin_list_support_conversations(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_fetch_support_messages(uuid, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_send_support_message(uuid, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_list_support_conversations(text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_fetch_support_messages(uuid, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_send_support_message(uuid, text, text) TO authenticated;

DO $pub$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables pt
    WHERE pt.pubname = 'supabase_realtime'
      AND pt.schemaname = 'public'
      AND pt.tablename = 'support_conversations'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.support_conversations;
  END IF;
END
$pub$;

ALTER TABLE public.support_conversations REPLICA IDENTITY FULL;
