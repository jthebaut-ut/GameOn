-- Additive private group chat foundation.
-- Does NOT modify direct_conversations, direct_messages, conversation_read_state,
-- message_reports, or DM security helpers (is_direct_conversation_participant, etc.).

-- =============================================================================
-- 1) Tables
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.group_conversations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  created_by uuid NOT NULL REFERENCES auth.users (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  last_message_at timestamptz,
  last_message_preview text,
  last_message_sender_id uuid,
  is_active boolean NOT NULL DEFAULT true,
  CONSTRAINT group_conversations_title_len_ck
    CHECK (char_length(btrim(title)) BETWEEN 1 AND 60)
);

COMMENT ON TABLE public.group_conversations IS
  'Private fan group conversations. Separate from direct_conversations.';

CREATE TABLE IF NOT EXISTS public.group_conversation_members (
  conversation_id uuid NOT NULL REFERENCES public.group_conversations (id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users (id),
  role text NOT NULL CHECK (role IN ('admin', 'member')),
  joined_at timestamptz NOT NULL DEFAULT now(),
  left_at timestamptz,
  muted_until timestamptz,
  last_read_at timestamptz,
  PRIMARY KEY (conversation_id, user_id),
  CONSTRAINT group_conversation_members_left_after_join_ck
    CHECK (left_at IS NULL OR left_at >= joined_at)
);

COMMENT ON TABLE public.group_conversation_members IS
  'Membership source of truth for group chats. Soft-leave via left_at; do not delete rows for audit.';

CREATE TABLE IF NOT EXISTS public.group_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES public.group_conversations (id) ON DELETE CASCADE,
  sender_id uuid NOT NULL REFERENCES auth.users (id),
  body text NOT NULL,
  message_type text NOT NULL DEFAULT 'text'
    CHECK (message_type IN ('text', 'system')),
  system_event text,
  created_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  is_deleted boolean NOT NULL DEFAULT false,
  report_count integer NOT NULL DEFAULT 0,
  CONSTRAINT group_messages_body_nonempty_ck
    CHECK (char_length(btrim(body)) > 0)
);

COMMENT ON TABLE public.group_messages IS
  'Group message history. Authoritative; do not rely only on last_message_preview.';

CREATE TABLE IF NOT EXISTS public.group_message_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_user_id uuid NOT NULL REFERENCES auth.users (id),
  reported_user_id uuid NOT NULL REFERENCES auth.users (id),
  message_id uuid NOT NULL REFERENCES public.group_messages (id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL REFERENCES public.group_conversations (id) ON DELETE CASCADE,
  message_text_snapshot text,
  category text,
  details text,
  status text NOT NULL DEFAULT 'open'
    CHECK (status IN ('open', 'closed', 'actioned')),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT group_message_reports_no_self_ck
    CHECK (reporter_user_id <> reported_user_id)
);

COMMENT ON TABLE public.group_message_reports IS
  'Additive group-message reports. Independent of pair-based message_reports.';

-- =============================================================================
-- 2) Indexes
-- =============================================================================

CREATE INDEX IF NOT EXISTS group_conversation_members_active_user_idx
  ON public.group_conversation_members (user_id)
  WHERE left_at IS NULL;

CREATE INDEX IF NOT EXISTS group_conversation_members_active_conversation_idx
  ON public.group_conversation_members (conversation_id)
  WHERE left_at IS NULL;

CREATE INDEX IF NOT EXISTS group_conversation_members_active_admins_idx
  ON public.group_conversation_members (conversation_id)
  WHERE left_at IS NULL AND role = 'admin';

CREATE INDEX IF NOT EXISTS group_conversations_inbox_idx
  ON public.group_conversations (last_message_at DESC NULLS LAST)
  WHERE is_active = true;

CREATE INDEX IF NOT EXISTS group_messages_conv_created_id_desc_idx
  ON public.group_messages (conversation_id, created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS group_messages_visible_conv_created_idx
  ON public.group_messages (conversation_id, created_at DESC)
  WHERE deleted_at IS NULL AND COALESCE(is_deleted, false) = false;

CREATE INDEX IF NOT EXISTS group_message_reports_open_idx
  ON public.group_message_reports (status, created_at DESC)
  WHERE status = 'open';

-- =============================================================================
-- 3) Membership / eligibility helpers (group-only; do not alter DM helpers)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.is_active_group_member(
  p_conversation_id uuid,
  p_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.group_conversation_members m
    INNER JOIN public.group_conversations c ON c.id = m.conversation_id
    WHERE m.conversation_id = p_conversation_id
      AND m.user_id = p_user_id
      AND m.left_at IS NULL
      AND c.is_active = true
  );
$$;

COMMENT ON FUNCTION public.is_active_group_member(uuid, uuid) IS
  'True when user is an active (non-left) member of an active group conversation.';

REVOKE ALL ON FUNCTION public.is_active_group_member(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_active_group_member(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_active_group_member(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.group_member_can_read_message(
  p_conversation_id uuid,
  p_user_id uuid,
  p_message_created_at timestamptz
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.group_conversation_members m
    WHERE m.conversation_id = p_conversation_id
      AND m.user_id = p_user_id
      AND p_message_created_at >= m.joined_at
      AND (m.left_at IS NULL OR p_message_created_at <= m.left_at)
  );
$$;

COMMENT ON FUNCTION public.group_member_can_read_message(uuid, uuid, timestamptz) IS
  'History boundary: readable only for membership window [joined_at, left_at].';

REVOKE ALL ON FUNCTION public.group_member_can_read_message(uuid, uuid, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.group_member_can_read_message(uuid, uuid, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.group_member_can_read_message(uuid, uuid, timestamptz) TO service_role;

CREATE OR REPLACE FUNCTION public.group_add_member_eligible(
  p_actor_user_id uuid,
  p_candidate_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    p_actor_user_id IS NOT NULL
    AND p_candidate_user_id IS NOT NULL
    AND p_actor_user_id <> p_candidate_user_id
    AND EXISTS (
      SELECT 1
      FROM public.user_profiles up
      WHERE up.id = p_candidate_user_id
        AND COALESCE(up.is_deleted, false) = false
        AND COALESCE(up.is_business_account, false) = false
        AND COALESCE(lower(trim(up.admin_status)), 'active') = 'active'
    )
    AND public.pickup_invite_users_are_unblocked(p_actor_user_id, p_candidate_user_id);
$$;

COMMENT ON FUNCTION public.group_add_member_eligible(uuid, uuid) IS
  'Narrow group-add eligibility: not self, not deleted, not business, active, unblocked both ways.';

REVOKE ALL ON FUNCTION public.group_add_member_eligible(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.group_add_member_eligible(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.group_add_member_eligible(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.group_active_member_count(p_conversation_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::integer
  FROM public.group_conversation_members m
  WHERE m.conversation_id = p_conversation_id
    AND m.left_at IS NULL;
$$;

REVOKE ALL ON FUNCTION public.group_active_member_count(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.group_active_member_count(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.group_active_member_count(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.group_active_admin_count(p_conversation_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::integer
  FROM public.group_conversation_members m
  WHERE m.conversation_id = p_conversation_id
    AND m.left_at IS NULL
    AND m.role = 'admin';
$$;

REVOKE ALL ON FUNCTION public.group_active_admin_count(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.group_active_admin_count(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.group_active_admin_count(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.group_pairs_are_mutually_unblocked(p_user_ids uuid[])
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  i int;
  j int;
  n int := coalesce(array_length(p_user_ids, 1), 0);
BEGIN
  IF n < 2 THEN
    RETURN true;
  END IF;
  FOR i IN 1..n LOOP
    FOR j IN (i + 1)..n LOOP
      IF NOT public.pickup_invite_users_are_unblocked(p_user_ids[i], p_user_ids[j]) THEN
        RETURN false;
      END IF;
    END LOOP;
  END LOOP;
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.group_pairs_are_mutually_unblocked(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.group_pairs_are_mutually_unblocked(uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.group_pairs_are_mutually_unblocked(uuid[]) TO service_role;

-- =============================================================================
-- 4) RLS
-- =============================================================================

ALTER TABLE public.group_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_conversation_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_message_reports ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT policyname, tablename
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN (
        'group_conversations',
        'group_conversation_members',
        'group_messages',
        'group_message_reports'
      )
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', r.policyname, r.tablename);
  END LOOP;
END $$;

-- Conversations: active members only (left members keep metadata visible only via history window elsewhere;
-- after leave they cannot discover/list via SELECT on conversations unless still member row with left_at set —
-- require active membership for conversation metadata discoverability.)
CREATE POLICY "group_conversations_select_active_members"
ON public.group_conversations
FOR SELECT
TO authenticated
USING (public.is_active_group_member(id, auth.uid()));

CREATE POLICY "group_conversations_update_active_admins"
ON public.group_conversations
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.group_conversation_members m
    WHERE m.conversation_id = group_conversations.id
      AND m.user_id = auth.uid()
      AND m.left_at IS NULL
      AND m.role = 'admin'
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.group_conversation_members m
    WHERE m.conversation_id = group_conversations.id
      AND m.user_id = auth.uid()
      AND m.left_at IS NULL
      AND m.role = 'admin'
  )
);

-- No direct INSERT/DELETE on conversations from clients — RPCs only.

CREATE POLICY "group_members_select_active_peers"
ON public.group_conversation_members
FOR SELECT
TO authenticated
USING (public.is_active_group_member(conversation_id, auth.uid()));

-- Members manage own mute/read via UPDATE of own row only.
CREATE POLICY "group_members_update_own_active"
ON public.group_conversation_members
FOR UPDATE
TO authenticated
USING (user_id = auth.uid() AND left_at IS NULL)
WITH CHECK (user_id = auth.uid());

CREATE POLICY "group_messages_select_membership_window"
ON public.group_messages
FOR SELECT
TO authenticated
USING (
  public.group_member_can_read_message(conversation_id, auth.uid(), created_at)
  AND deleted_at IS NULL
  AND COALESCE(is_deleted, false) = false
);

CREATE POLICY "group_messages_insert_active_sender"
ON public.group_messages
FOR INSERT
TO authenticated
WITH CHECK (
  sender_id = auth.uid()
  AND message_type = 'text'
  AND public.is_active_group_member(conversation_id, auth.uid())
);

CREATE POLICY "group_messages_update_own_or_admin_moderation"
ON public.group_messages
FOR UPDATE
TO authenticated
USING (
  public.is_active_group_member(conversation_id, auth.uid())
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
  public.is_active_group_member(conversation_id, auth.uid())
);

CREATE POLICY "group_message_reports_insert_own"
ON public.group_message_reports
FOR INSERT
TO authenticated
WITH CHECK (
  reporter_user_id = auth.uid()
  AND reported_user_id <> auth.uid()
  AND public.is_active_group_member(conversation_id, auth.uid())
  AND EXISTS (
    SELECT 1
    FROM public.group_messages gm
    WHERE gm.id = message_id
      AND gm.conversation_id = conversation_id
      AND gm.sender_id = reported_user_id
      AND public.group_member_can_read_message(gm.conversation_id, auth.uid(), gm.created_at)
  )
);

CREATE POLICY "group_message_reports_select_own"
ON public.group_message_reports
FOR SELECT
TO authenticated
USING (reporter_user_id = auth.uid());

-- =============================================================================
-- 5) RPCs
-- =============================================================================

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
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF char_length(v_title) < 1 OR char_length(v_title) > 60 THEN
    RAISE EXCEPTION 'Group title must be between 1 and 60 characters.';
  END IF;

  -- Deduplicate member IDs and drop creator/nulls.
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

  INSERT INTO public.group_messages (
    conversation_id, sender_id, body, message_type, system_event
  ) VALUES (
    v_id, me, 'Group created', 'system', 'group_created'
  );

  UPDATE public.group_conversations
  SET
    last_message_at = now(),
    last_message_preview = 'Group created',
    last_message_sender_id = me,
    updated_at = now()
  WHERE id = v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_group_conversation(text, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_group_conversation(text, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_group_conversation(text, uuid[]) TO service_role;

CREATE OR REPLACE FUNCTION public.add_group_members(
  p_conversation_id uuid,
  p_member_ids uuid[]
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_uid uuid;
  v_unique uuid[] := ARRAY[]::uuid[];
  v_added int := 0;
  v_active int;
  v_existing uuid[];
  v_check uuid[];
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.group_conversation_members m
    WHERE m.conversation_id = p_conversation_id
      AND m.user_id = me
      AND m.left_at IS NULL
      AND m.role = 'admin'
  ) THEN
    RAISE EXCEPTION 'Only active admins can add members.';
  END IF;

  FOREACH v_uid IN ARRAY coalesce(p_member_ids, ARRAY[]::uuid[]) LOOP
    IF v_uid IS NULL OR v_uid = me THEN
      CONTINUE;
    END IF;
    IF NOT (v_uid = ANY (v_unique)) THEN
      v_unique := array_append(v_unique, v_uid);
    END IF;
  END LOOP;

  IF coalesce(array_length(v_unique, 1), 0) = 0 THEN
    RETURN 0;
  END IF;

  SELECT coalesce(array_agg(m.user_id), ARRAY[]::uuid[])
    INTO v_existing
  FROM public.group_conversation_members m
  WHERE m.conversation_id = p_conversation_id
    AND m.left_at IS NULL;

  v_active := coalesce(array_length(v_existing, 1), 0);
  IF v_active + coalesce(array_length(v_unique, 1), 0) > 25 THEN
    RAISE EXCEPTION 'A group may have at most 25 active members.';
  END IF;

  FOREACH v_uid IN ARRAY v_unique LOOP
    IF v_uid = ANY (v_existing) THEN
      RAISE EXCEPTION 'Duplicate member.';
    END IF;
    IF NOT public.group_add_member_eligible(me, v_uid) THEN
      RAISE EXCEPTION 'One or more members are not eligible to be added.';
    END IF;
  END LOOP;

  v_check := v_existing || v_unique;
  IF NOT public.group_pairs_are_mutually_unblocked(v_check) THEN
    RAISE EXCEPTION 'Blocked users cannot be added to the same group.';
  END IF;

  FOREACH v_uid IN ARRAY v_unique LOOP
    INSERT INTO public.group_conversation_members (conversation_id, user_id, role, joined_at)
    VALUES (p_conversation_id, v_uid, 'member', now())
    ON CONFLICT (conversation_id, user_id) DO UPDATE
      SET
        left_at = NULL,
        role = 'member',
        joined_at = now(),
        muted_until = NULL,
        last_read_at = NULL
    WHERE public.group_conversation_members.left_at IS NOT NULL;

    v_added := v_added + 1;
  END LOOP;

  UPDATE public.group_conversations
  SET updated_at = now()
  WHERE id = p_conversation_id;

  RETURN v_added;
END;
$$;

REVOKE ALL ON FUNCTION public.add_group_members(uuid, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.add_group_members(uuid, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.add_group_members(uuid, uuid[]) TO service_role;

CREATE OR REPLACE FUNCTION public.remove_group_member(
  p_conversation_id uuid,
  p_user_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_target_role text;
  v_admin_count int;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.group_conversation_members m
    WHERE m.conversation_id = p_conversation_id
      AND m.user_id = me
      AND m.left_at IS NULL
      AND m.role = 'admin'
  ) THEN
    RAISE EXCEPTION 'Only active admins can remove members.';
  END IF;

  IF p_user_id = me THEN
    RAISE EXCEPTION 'Use leave_group_conversation to leave the group.';
  END IF;

  SELECT m.role INTO v_target_role
  FROM public.group_conversation_members m
  WHERE m.conversation_id = p_conversation_id
    AND m.user_id = p_user_id
    AND m.left_at IS NULL;

  IF v_target_role IS NULL THEN
    RAISE EXCEPTION 'Member not found.';
  END IF;

  IF v_target_role = 'admin' THEN
    v_admin_count := public.group_active_admin_count(p_conversation_id);
    IF v_admin_count <= 1 THEN
      RAISE EXCEPTION 'Cannot remove the last admin.';
    END IF;
  END IF;

  UPDATE public.group_conversation_members
  SET left_at = now()
  WHERE conversation_id = p_conversation_id
    AND user_id = p_user_id
    AND left_at IS NULL;

  UPDATE public.group_conversations
  SET updated_at = now()
  WHERE id = p_conversation_id;
END;
$$;

REVOKE ALL ON FUNCTION public.remove_group_member(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.remove_group_member(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_group_member(uuid, uuid) TO service_role;

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
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  SELECT m.role INTO v_role
  FROM public.group_conversation_members m
  WHERE m.conversation_id = p_conversation_id
    AND m.user_id = me
    AND m.left_at IS NULL;

  IF v_role IS NULL THEN
    RAISE EXCEPTION 'Not an active member.';
  END IF;

  IF v_role = 'admin' THEN
    v_admin_count := public.group_active_admin_count(p_conversation_id);
    IF v_admin_count <= 1 THEN
      -- Promote oldest remaining non-admin member if any; otherwise deactivate group.
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
        SET is_active = false, updated_at = now()
        WHERE id = p_conversation_id;
      END IF;
    END IF;
  END IF;

  UPDATE public.group_conversation_members
  SET left_at = now()
  WHERE conversation_id = p_conversation_id
    AND user_id = me
    AND left_at IS NULL;

  UPDATE public.group_conversations
  SET updated_at = now()
  WHERE id = p_conversation_id;
END;
$$;

REVOKE ALL ON FUNCTION public.leave_group_conversation(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.leave_group_conversation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.leave_group_conversation(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.mark_group_conversation_read(
  p_conversation_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF NOT public.is_active_group_member(p_conversation_id, me) THEN
    RAISE EXCEPTION 'Not an active member.';
  END IF;

  UPDATE public.group_conversation_members
  SET last_read_at = now()
  WHERE conversation_id = p_conversation_id
    AND user_id = me
    AND left_at IS NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_group_conversation_read(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_group_conversation_read(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_group_conversation_read(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.set_group_conversation_muted(
  p_conversation_id uuid,
  p_muted boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF NOT public.is_active_group_member(p_conversation_id, me) THEN
    RAISE EXCEPTION 'Not an active member.';
  END IF;

  UPDATE public.group_conversation_members
  SET muted_until = CASE WHEN p_muted THEN 'infinity'::timestamptz ELSE NULL END
  WHERE conversation_id = p_conversation_id
    AND user_id = me
    AND left_at IS NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.set_group_conversation_muted(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_group_conversation_muted(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_group_conversation_muted(uuid, boolean) TO service_role;

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

CREATE OR REPLACE FUNCTION public.get_group_inbox_summaries()
RETURNS TABLE (
  conversation_id uuid,
  title text,
  member_count integer,
  last_message_body text,
  last_message_sender_id uuid,
  last_message_created_at timestamptz,
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

CREATE OR REPLACE FUNCTION public.get_group_conversation_details(
  p_conversation_id uuid
)
RETURNS TABLE (
  conversation_id uuid,
  title text,
  created_by uuid,
  created_at timestamptz,
  member_user_id uuid,
  member_role text,
  member_joined_at timestamptz,
  viewer_is_admin boolean,
  viewer_is_muted boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH me AS (SELECT auth.uid() AS uid)
  SELECT
    c.id AS conversation_id,
    c.title,
    c.created_by,
    c.created_at,
    m.user_id AS member_user_id,
    m.role AS member_role,
    m.joined_at AS member_joined_at,
    EXISTS (
      SELECT 1
      FROM public.group_conversation_members vm
      CROSS JOIN me
      WHERE vm.conversation_id = c.id
        AND vm.user_id = me.uid
        AND vm.left_at IS NULL
        AND vm.role = 'admin'
    ) AS viewer_is_admin,
    EXISTS (
      SELECT 1
      FROM public.group_conversation_members vm
      CROSS JOIN me
      WHERE vm.conversation_id = c.id
        AND vm.user_id = me.uid
        AND vm.left_at IS NULL
        AND vm.muted_until IS NOT NULL
        AND vm.muted_until > now()
    ) AS viewer_is_muted
  FROM public.group_conversations c
  INNER JOIN public.group_conversation_members m
    ON m.conversation_id = c.id
   AND m.left_at IS NULL
  CROSS JOIN me
  WHERE c.id = p_conversation_id
    AND c.is_active = true
    AND public.is_active_group_member(c.id, me.uid);
$$;

REVOKE ALL ON FUNCTION public.get_group_conversation_details(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_group_conversation_details(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_group_conversation_details(uuid) TO service_role;

-- =============================================================================
-- 6) Realtime publication (additive)
-- =============================================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'group_messages'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.group_messages;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'group_conversation_members'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.group_conversation_members;
  END IF;
END $$;
