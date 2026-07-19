-- Group chat membership system events: atomic member-left timeline rows.
-- Additive. Does not alter DM tables or ordinary text-message send paths.

-- =============================================================================
-- 1) Structured system payload + denormalized inbox metadata
-- =============================================================================

ALTER TABLE public.group_messages
  ADD COLUMN IF NOT EXISTS system_payload jsonb;

COMMENT ON COLUMN public.group_messages.system_payload IS
  'Structured membership/system metadata (affected_user_id, affected_display_name, actor_user_id, event). Clients localize; body is English fallback.';

ALTER TABLE public.group_conversations
  ADD COLUMN IF NOT EXISTS last_message_type text NOT NULL DEFAULT 'text'
    CHECK (last_message_type IN ('text', 'system'));

ALTER TABLE public.group_conversations
  ADD COLUMN IF NOT EXISTS last_system_event text;

ALTER TABLE public.group_conversations
  ADD COLUMN IF NOT EXISTS last_system_payload jsonb;

COMMENT ON COLUMN public.group_conversations.last_message_type IS
  'Mirrors latest visible timeline item type for inbox preview formatting.';

-- One departure event per (conversation, member). Protects concurrent/retry leave.
CREATE UNIQUE INDEX IF NOT EXISTS group_messages_member_left_once_idx
  ON public.group_messages (
    conversation_id,
    ((system_payload ->> 'affected_user_id'))
  )
  WHERE message_type = 'system'
    AND system_event = 'member_left'
    AND deleted_at IS NULL
    AND COALESCE(is_deleted, false) = false
    AND nullif(btrim(system_payload ->> 'affected_user_id'), '') IS NOT NULL;

-- =============================================================================
-- 2) RLS: clients cannot soft-delete/edit system rows; cannot report them
-- =============================================================================

DROP POLICY IF EXISTS "group_messages_update_own_or_admin_moderation" ON public.group_messages;

CREATE POLICY "group_messages_update_own_or_admin_moderation"
ON public.group_messages
FOR UPDATE
TO authenticated
USING (
  message_type = 'text'
  AND public.is_active_group_member(conversation_id, auth.uid())
  AND (
    sender_id = auth.uid()
    OR EXISTS (
      SELECT 1
      FROM public.group_conversation_members m
      WHERE m.conversation_id = group_messages.conversation_id
        AND m.user_id = auth.uid()
        AND m.left_at IS NULL
        AND m.role = 'admin'
    )
  )
)
WITH CHECK (
  message_type = 'text'
  AND public.is_active_group_member(conversation_id, auth.uid())
);

CREATE OR REPLACE FUNCTION public.report_group_message(
  p_message_id uuid,
  p_category text DEFAULT NULL,
  p_details text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_msg public.group_messages%ROWTYPE;
  v_id uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  SELECT * INTO v_msg
  FROM public.group_messages
  WHERE id = p_message_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Message not found.';
  END IF;

  IF v_msg.message_type IS DISTINCT FROM 'text' THEN
    RAISE EXCEPTION 'Cannot report system messages.';
  END IF;

  IF v_msg.sender_id = me THEN
    RAISE EXCEPTION 'Cannot report your own message.';
  END IF;

  IF NOT public.group_member_can_read_message(v_msg.conversation_id, me, v_msg.created_at) THEN
    RAISE EXCEPTION 'Not authorized to report this message.';
  END IF;

  IF NOT public.is_active_group_member(v_msg.conversation_id, me) THEN
    RAISE EXCEPTION 'Not an active member.';
  END IF;

  INSERT INTO public.group_message_reports (
    reporter_user_id,
    reported_user_id,
    message_id,
    conversation_id,
    message_text_snapshot,
    category,
    details
  ) VALUES (
    me,
    v_msg.sender_id,
    v_msg.id,
    v_msg.conversation_id,
    left(v_msg.body, 500),
    nullif(btrim(coalesce(p_category, '')), ''),
    nullif(btrim(coalesce(p_details, '')), '')
  )
  RETURNING id INTO v_id;

  UPDATE public.group_messages
  SET report_count = coalesce(report_count, 0) + 1
  WHERE id = v_msg.id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.report_group_message(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.report_group_message(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_group_message(uuid, text, text) TO service_role;

-- =============================================================================
-- 3) Helper: display-name snapshot for membership events
-- =============================================================================

CREATE OR REPLACE FUNCTION public.group_membership_display_name_snapshot(p_user_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    nullif(btrim(up.username), ''),
    nullif(btrim(up.display_name), ''),
    'Member'
  )
  FROM public.user_profiles up
  WHERE up.id = p_user_id;
$$;

COMMENT ON FUNCTION public.group_membership_display_name_snapshot(uuid) IS
  'Stable leave/join display label: username, then display_name, then Member.';

REVOKE ALL ON FUNCTION public.group_membership_display_name_snapshot(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.group_membership_display_name_snapshot(uuid) TO service_role;

-- =============================================================================
-- 4) Atomic, idempotent leave + member_left system event
-- =============================================================================

CREATE OR REPLACE FUNCTION public.leave_group_conversation(
  p_conversation_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_role text;
  v_admin_count int;
  v_other_admin uuid;
  v_now timestamptz := clock_timestamp();
  v_name text;
  v_payload jsonb;
  v_body text;
  v_existing_event uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  SELECT m.role INTO v_role
  FROM public.group_conversation_members m
  WHERE m.conversation_id = p_conversation_id
    AND m.user_id = me
    AND m.left_at IS NULL;

  -- Idempotent: already left → no duplicate event, no error.
  IF v_role IS NULL THEN
    RETURN;
  END IF;

  v_name := coalesce(
    public.group_membership_display_name_snapshot(me),
    'Member'
  );
  v_payload := jsonb_build_object(
    'event', 'member_left',
    'affected_user_id', me,
    'affected_display_name', v_name,
    'actor_user_id', me
  );
  v_body := v_name || ' left the group.';

  IF v_role = 'admin' THEN
    v_admin_count := public.group_active_admin_count(p_conversation_id);
    IF v_admin_count <= 1 THEN
      SELECT m.user_id INTO v_other_admin
      FROM public.group_conversation_members m
      WHERE m.conversation_id = p_conversation_id
        AND m.left_at IS NULL
        AND m.user_id <> me
        AND m.role = 'member'
      ORDER BY m.joined_at ASC
      LIMIT 1;

      IF v_other_admin IS NOT NULL THEN
        UPDATE public.group_conversation_members
        SET role = 'admin'
        WHERE conversation_id = p_conversation_id
          AND user_id = v_other_admin
          AND left_at IS NULL;
      ELSE
        UPDATE public.group_conversations
        SET is_active = false, updated_at = v_now
        WHERE id = p_conversation_id;
      END IF;
    END IF;
  END IF;

  -- Insert system event before soft-leave so membership window includes it.
  SELECT gm.id INTO v_existing_event
  FROM public.group_messages gm
  WHERE gm.conversation_id = p_conversation_id
    AND gm.message_type = 'system'
    AND gm.system_event = 'member_left'
    AND gm.deleted_at IS NULL
    AND COALESCE(gm.is_deleted, false) = false
    AND gm.system_payload ->> 'affected_user_id' = me::text
  LIMIT 1;

  IF v_existing_event IS NULL THEN
    BEGIN
      INSERT INTO public.group_messages (
        conversation_id,
        sender_id,
        body,
        message_type,
        system_event,
        system_payload,
        created_at
      ) VALUES (
        p_conversation_id,
        me,
        v_body,
        'system',
        'member_left',
        v_payload,
        v_now
      );
    EXCEPTION
      WHEN unique_violation THEN
        NULL; -- concurrent leave already inserted the event
    END;
  END IF;

  UPDATE public.group_conversation_members
  SET left_at = v_now
  WHERE conversation_id = p_conversation_id
    AND user_id = me
    AND left_at IS NULL;

  UPDATE public.group_conversations
  SET
    last_message_at = v_now,
    last_message_preview = v_body,
    last_message_sender_id = me,
    last_message_type = 'system',
    last_system_event = 'member_left',
    last_system_payload = v_payload,
    updated_at = v_now
  WHERE id = p_conversation_id;
END;
$$;

COMMENT ON FUNCTION public.leave_group_conversation(uuid) IS
  'Soft-leave + one idempotent member_left system timeline event in a single transaction.';

REVOKE ALL ON FUNCTION public.leave_group_conversation(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.leave_group_conversation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.leave_group_conversation(uuid) TO service_role;

-- =============================================================================
-- 5) Keep inbox denormalized fields in sync for text send + group create
-- =============================================================================

CREATE OR REPLACE FUNCTION public.send_group_message(
  p_conversation_id uuid,
  p_body text
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
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF char_length(v_body) < 1 THEN
    RAISE EXCEPTION 'Message body required.';
  END IF;

  IF NOT public.is_active_group_member(p_conversation_id, me) THEN
    RAISE EXCEPTION 'Not an active member.';
  END IF;

  INSERT INTO public.group_messages (conversation_id, sender_id, body, message_type)
  VALUES (p_conversation_id, me, v_body, 'text')
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

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.send_group_message(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_group_message(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_group_message(uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION public.create_group_conversation(
  p_title text,
  p_member_ids uuid[]
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_title text := btrim(coalesce(p_title, ''));
  v_ids uuid[];
  v_unique uuid[] := ARRAY[]::uuid[];
  v_id uuid;
  v_uid uuid;
  v_all uuid[];
  v_payload jsonb;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF char_length(v_title) < 1 OR char_length(v_title) > 60 THEN
    RAISE EXCEPTION 'Group title must be between 1 and 60 characters.';
  END IF;

  v_ids := coalesce(p_member_ids, ARRAY[]::uuid[]);
  FOREACH v_uid IN ARRAY v_ids LOOP
    IF v_uid IS NULL OR v_uid = me THEN
      CONTINUE;
    END IF;
    IF NOT (v_uid = ANY (v_unique)) THEN
      v_unique := array_append(v_unique, v_uid);
    END IF;
  END LOOP;

  IF coalesce(array_length(v_unique, 1), 0) < 2 THEN
    RAISE EXCEPTION 'A group requires at least two additional members.';
  END IF;

  IF 1 + coalesce(array_length(v_unique, 1), 0) > 25 THEN
    RAISE EXCEPTION 'A group may have at most 25 active members.';
  END IF;

  FOREACH v_uid IN ARRAY v_unique LOOP
    IF NOT public.group_add_member_eligible(me, v_uid) THEN
      RAISE EXCEPTION 'One or more members are not eligible to be added.';
    END IF;
  END LOOP;

  v_all := array_prepend(me, v_unique);
  IF NOT public.group_pairs_are_mutually_unblocked(v_all) THEN
    RAISE EXCEPTION 'Blocked users cannot be added to the same group.';
  END IF;

  INSERT INTO public.group_conversations (title, created_by)
  VALUES (v_title, me)
  RETURNING id INTO v_id;

  INSERT INTO public.group_conversation_members (conversation_id, user_id, role, joined_at, last_read_at)
  VALUES (v_id, me, 'admin', now(), now());

  FOREACH v_uid IN ARRAY v_unique LOOP
    INSERT INTO public.group_conversation_members (conversation_id, user_id, role, joined_at)
    VALUES (v_id, v_uid, 'member', now());
  END LOOP;

  v_payload := jsonb_build_object(
    'event', 'group_created',
    'actor_user_id', me
  );

  INSERT INTO public.group_messages (
    conversation_id, sender_id, body, message_type, system_event, system_payload
  ) VALUES (
    v_id, me, 'Group created', 'system', 'group_created', v_payload
  );

  UPDATE public.group_conversations
  SET
    last_message_at = now(),
    last_message_preview = 'Group created',
    last_message_sender_id = me,
    last_message_type = 'system',
    last_system_event = 'group_created',
    last_system_payload = v_payload,
    updated_at = now()
  WHERE id = v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_group_conversation(text, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_group_conversation(text, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_group_conversation(text, uuid[]) TO service_role;

-- =============================================================================
-- 6) Inbox summaries expose system metadata (no You: prefix on client)
-- =============================================================================

-- Return-type change requires drop (CREATE OR REPLACE cannot alter OUT columns).
DROP FUNCTION IF EXISTS public.get_group_inbox_summaries();

CREATE OR REPLACE FUNCTION public.get_group_inbox_summaries()
RETURNS TABLE (
  conversation_id uuid,
  title text,
  member_count integer,
  last_message_body text,
  last_message_sender_id uuid,
  last_message_created_at timestamptz,
  last_message_type text,
  last_system_event text,
  last_system_payload jsonb,
  unread_count integer,
  is_muted boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH me AS (
    SELECT auth.uid() AS uid
  )
  SELECT
    c.id AS conversation_id,
    c.title,
    (
      SELECT count(*)::integer
      FROM public.group_conversation_members am
      WHERE am.conversation_id = c.id
        AND am.left_at IS NULL
    ) AS member_count,
    c.last_message_preview AS last_message_body,
    c.last_message_sender_id,
    c.last_message_at AS last_message_created_at,
    coalesce(c.last_message_type, 'text') AS last_message_type,
    c.last_system_event,
    c.last_system_payload,
    (
      SELECT count(*)::integer
      FROM public.group_messages gm
      WHERE gm.conversation_id = c.id
        AND gm.deleted_at IS NULL
        AND COALESCE(gm.is_deleted, false) = false
        AND gm.message_type = 'text'
        AND gm.sender_id IS DISTINCT FROM me.uid
        AND gm.created_at > COALESCE(m.last_read_at, 'epoch'::timestamptz)
        AND gm.created_at >= m.joined_at
        AND (m.left_at IS NULL OR gm.created_at <= m.left_at)
    ) AS unread_count,
    (m.muted_until IS NOT NULL AND m.muted_until > now()) AS is_muted
  FROM me
  INNER JOIN public.group_conversation_members m
    ON m.user_id = me.uid
   AND m.left_at IS NULL
  INNER JOIN public.group_conversations c
    ON c.id = m.conversation_id
   AND c.is_active = true
  ORDER BY c.last_message_at DESC NULLS LAST, c.created_at DESC;
$$;

REVOKE ALL ON FUNCTION public.get_group_inbox_summaries() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_group_inbox_summaries() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_group_inbox_summaries() TO service_role;
