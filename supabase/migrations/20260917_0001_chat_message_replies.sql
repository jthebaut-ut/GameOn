-- =============================================================================
-- 20260917_0001 — Chat message replies (DM + group / pickup)
-- =============================================================================
-- Adds optional reply_to_message_id on direct_messages and group_messages.
-- Extends send_direct_message / send_group_message with p_reply_to_message_id
-- (DEFAULT NULL) so old clients keep working without overloads.
--
-- Server validation:
--   • same conversation only
--   • referenced row exists and is readable by caller
--   • DM: honors per-user clear watermark (direct_message_after_viewer_clear)
--   • group: active member + text (non-system) target
--   • never trusts client-authored quote text
--
-- Immutability:
--   • DM: existing allowlist trigger already freezes any new column after insert
--   • group: new allowlist trigger mirrors DM moderation-only UPDATE policy
--
-- Do NOT apply from the agent; review and apply deliberately.
-- Compatible with applied 0005a / 0006 clear / unapplied 0005b.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Columns
-- ---------------------------------------------------------------------------
ALTER TABLE public.direct_messages
  ADD COLUMN IF NOT EXISTS reply_to_message_id uuid;

ALTER TABLE public.group_messages
  ADD COLUMN IF NOT EXISTS reply_to_message_id uuid;

COMMENT ON COLUMN public.direct_messages.reply_to_message_id IS
  'Optional same-conversation parent message. Set only at INSERT via send_direct_message; immutable thereafter.';

COMMENT ON COLUMN public.group_messages.reply_to_message_id IS
  'Optional same-conversation parent message. Set only at INSERT via send_group_message; immutable thereafter.';

-- Soft-deleted parents remain addressable; hard delete nulls the reference.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'direct_messages_reply_to_message_id_fkey'
  ) THEN
    ALTER TABLE public.direct_messages
      ADD CONSTRAINT direct_messages_reply_to_message_id_fkey
      FOREIGN KEY (reply_to_message_id)
      REFERENCES public.direct_messages (id)
      ON DELETE SET NULL;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'group_messages_reply_to_message_id_fkey'
  ) THEN
    ALTER TABLE public.group_messages
      ADD CONSTRAINT group_messages_reply_to_message_id_fkey
      FOREIGN KEY (reply_to_message_id)
      REFERENCES public.group_messages (id)
      ON DELETE SET NULL;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS direct_messages_reply_to_message_id_idx
  ON public.direct_messages (reply_to_message_id)
  WHERE reply_to_message_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS group_messages_reply_to_message_id_idx
  ON public.group_messages (reply_to_message_id)
  WHERE reply_to_message_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 1b) Defense-in-depth: validate reply_to on any INSERT (Phase A table insert)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_direct_message_reply_target()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_parent public.direct_messages%ROWTYPE;
  me uuid := auth.uid();
BEGIN
  IF NEW.reply_to_message_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- service_role / DEFINER paths without a JWT still must keep same-conversation integrity.
  SELECT * INTO v_parent
  FROM public.direct_messages dm
  WHERE dm.id = NEW.reply_to_message_id;

  IF NOT FOUND
     OR v_parent.conversation_id IS DISTINCT FROM NEW.conversation_id
     OR v_parent.deleted_at IS NOT NULL
     OR COALESCE(v_parent.is_deleted, FALSE) = TRUE
  THEN
    RAISE EXCEPTION 'reply target unavailable' USING ERRCODE = '42501';
  END IF;

  IF me IS NOT NULL THEN
    IF NOT public.is_direct_conversation_participant(NEW.conversation_id, me)
       OR NOT public.direct_message_after_viewer_clear(
            NEW.conversation_id, v_parent.created_at, me
          )
    THEN
      RAISE EXCEPTION 'reply target unavailable' USING ERRCODE = '42501';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_direct_message_reply_target() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.enforce_direct_message_reply_target() FROM anon;
REVOKE ALL ON FUNCTION public.enforce_direct_message_reply_target() FROM authenticated;

DROP TRIGGER IF EXISTS trg_direct_messages_reply_target ON public.direct_messages;
CREATE TRIGGER trg_direct_messages_reply_target
  BEFORE INSERT ON public.direct_messages
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_direct_message_reply_target();

CREATE OR REPLACE FUNCTION public.enforce_group_message_reply_target()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_parent public.group_messages%ROWTYPE;
  me uuid := auth.uid();
BEGIN
  IF NEW.reply_to_message_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_parent
  FROM public.group_messages gm
  WHERE gm.id = NEW.reply_to_message_id;

  IF NOT FOUND
     OR v_parent.conversation_id IS DISTINCT FROM NEW.conversation_id
     OR v_parent.deleted_at IS NOT NULL
     OR COALESCE(v_parent.is_deleted, FALSE) = TRUE
     OR COALESCE(v_parent.message_type, 'text') IS DISTINCT FROM 'text'
  THEN
    RAISE EXCEPTION 'reply target unavailable' USING ERRCODE = '42501';
  END IF;

  IF me IS NOT NULL
     AND NOT public.group_member_can_read_message(
          v_parent.conversation_id, me, v_parent.created_at
        )
  THEN
    RAISE EXCEPTION 'reply target unavailable' USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_group_message_reply_target() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.enforce_group_message_reply_target() FROM anon;
REVOKE ALL ON FUNCTION public.enforce_group_message_reply_target() FROM authenticated;

DROP TRIGGER IF EXISTS trg_group_messages_reply_target ON public.group_messages;
CREATE TRIGGER trg_group_messages_reply_target
  BEFORE INSERT ON public.group_messages
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_group_message_reply_target();

-- ---------------------------------------------------------------------------
-- 2) Group messages immutability (mirror DM allowlist)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_group_messages_immutable_columns()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text := coalesce(auth.role(), '');
BEGIN
  IF v_role NOT IN ('authenticated', 'anon') THEN
    RETURN NEW;
  END IF;

  IF (to_jsonb(NEW) - 'report_count' - 'is_deleted' - 'deleted_at')
       IS NOT DISTINCT FROM
     (to_jsonb(OLD) - 'report_count' - 'is_deleted' - 'deleted_at')
  THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'not allowed to update protected group_messages columns'
    USING ERRCODE = '42501';
END;
$$;

COMMENT ON FUNCTION public.enforce_group_messages_immutable_columns() IS
  'BEFORE UPDATE allowlist for authenticated/anon: only report_count, is_deleted, deleted_at may change (freezes reply_to_message_id and all other columns).';

REVOKE ALL ON FUNCTION public.enforce_group_messages_immutable_columns() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.enforce_group_messages_immutable_columns() FROM anon;
REVOKE ALL ON FUNCTION public.enforce_group_messages_immutable_columns() FROM authenticated;

DROP TRIGGER IF EXISTS trg_group_messages_immutable_columns ON public.group_messages;
CREATE TRIGGER trg_group_messages_immutable_columns
  BEFORE UPDATE ON public.group_messages
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_group_messages_immutable_columns();

-- ---------------------------------------------------------------------------
-- 3) send_direct_message — optional p_reply_to_message_id (single signature)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.send_direct_message(uuid, text);
DROP FUNCTION IF EXISTS public.send_direct_message(uuid, text, uuid);

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
      -- Generic denial: do not disclose whether the UUID exists elsewhere.
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

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.send_direct_message(uuid, text, uuid) IS
  'DM send with optional same-conversation reply_to. Old clients omit p_reply_to_message_id. Auth.uid() sender; rate-limited; clear-watermark gated for replies.';

REVOKE ALL ON FUNCTION public.send_direct_message(uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.send_direct_message(uuid, text, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.send_direct_message(uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_direct_message(uuid, text, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 4) send_group_message — optional p_reply_to_message_id (single signature)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.send_group_message(uuid, text);
DROP FUNCTION IF EXISTS public.send_group_message(uuid, text, uuid);

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

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.send_group_message(uuid, text, uuid) IS
  'Group/pickup send with optional same-conversation reply_to. Old clients omit p_reply_to_message_id. System messages cannot be reply targets.';

REVOKE ALL ON FUNCTION public.send_group_message(uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.send_group_message(uuid, text, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.send_group_message(uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_group_message(uuid, text, uuid) TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ---------------------------------------------------------------------------
-- Manual verification
-- ---------------------------------------------------------------------------
-- SELECT to_regprocedure('public.send_direct_message(uuid, text, uuid)');
-- SELECT to_regprocedure('public.send_group_message(uuid, text, uuid)');
-- \d public.direct_messages
-- \d public.group_messages
