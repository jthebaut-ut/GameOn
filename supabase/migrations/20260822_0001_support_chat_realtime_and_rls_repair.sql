-- Support chat: realtime publication, RLS column grant repair, stable conversation resolution.
-- Does not touch direct_messages, direct_conversations, or friendships.

-- RLS policy references deleted_at; authenticated needs SELECT on it for policy evaluation.
GRANT SELECT (deleted_at) ON public.support_messages TO authenticated;

DO $pub$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables pt
    WHERE pt.pubname = 'supabase_realtime'
      AND pt.schemaname = 'public'
      AND pt.tablename = 'support_messages'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.support_messages;
  END IF;
END
$pub$;

-- Filtered postgres_changes on conversation_id requires FULL replica identity.
ALTER TABLE public.support_messages REPLICA IDENTITY FULL;

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
    SELECT sc.id
    INTO v_id
    FROM public.support_conversations sc
    WHERE sc.user_id = v_uid
    ORDER BY COALESCE(sc.last_message_at, sc.updated_at, sc.created_at) DESC
    LIMIT 1;

    IF v_id IS NOT NULL THEN
      UPDATE public.support_conversations sc
      SET status = 'open', updated_at = now()
      WHERE sc.id = v_id
        AND sc.status = 'closed';
    END IF;
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO public.support_conversations (user_id, status)
    VALUES (v_uid, 'open')
    ON CONFLICT DO NOTHING
    RETURNING id INTO v_id;
  END IF;

  IF v_id IS NULL THEN
    SELECT sc.id
    INTO v_id
    FROM public.support_conversations sc
    WHERE sc.user_id = v_uid
      AND sc.status = 'open'
    ORDER BY COALESCE(sc.last_message_at, sc.updated_at, sc.created_at) DESC
    LIMIT 1;
  END IF;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'support conversation unavailable';
  END IF;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.fetch_my_support_messages(p_limit integer DEFAULT 100)
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
  v_conversation_id uuid;
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 200);
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  v_conversation_id := public.get_or_create_my_support_conversation();

  RETURN QUERY
  SELECT
    sm.id,
    sm.conversation_id,
    sm.sender_kind,
    sm.sender_auth_user_id,
    sm.body,
    sm.created_at
  FROM public.support_messages sm
  WHERE sm.conversation_id = v_conversation_id
    AND sm.deleted_at IS NULL
  ORDER BY sm.created_at ASC, sm.id ASC
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.fetch_my_support_messages(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fetch_my_support_messages(integer) TO authenticated;

COMMENT ON FUNCTION public.fetch_my_support_messages(integer) IS
  'Returns support_messages for the caller active support thread (no admin_email).';
