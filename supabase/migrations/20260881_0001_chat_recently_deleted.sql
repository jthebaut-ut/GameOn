-- =============================================================================
-- 20260881 — Per-user Chat "Recently Deleted" (soft-delete / restore / permanent)
-- =============================================================================
--
-- Product:
--   • Delete from Chats = hide for auth.uid() only (keep membership / shared history)
--   • Recently Deleted = soft-deleted rows within 30 days
--   • Restore = clear soft-delete for auth.uid()
--   • Delete Permanently = mark permanent for auth.uid() only (no group/DM wipe)
--   • New inbound message auto-restores active soft-delete (not permanent / not expired)
--
-- Does NOT:
--   • leave the group (left_at unchanged)
--   • delete messages for other participants
--   • rewrite get_dm_inbox_summaries / get_group_inbox_summaries bodies
--     (client filters via get_my_chat_inbox_exclusions; follow-up may inline filters)
--
-- DO NOT apply from the agent — review and apply deliberately.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Preflight
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.direct_conversations') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.direct_conversations'];
  END IF;
  IF to_regclass('public.direct_messages') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.direct_messages'];
  END IF;
  IF to_regclass('public.group_conversations') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.group_conversations'];
  END IF;
  IF to_regclass('public.group_conversation_members') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.group_conversation_members'];
  END IF;
  IF to_regclass('public.group_messages') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.group_messages'];
  END IF;

  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION
      '20260881 preflight failed (no schema changes applied): %',
      array_to_string(v_missing, ', ')
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 1) Per-user deletion state (one row per user + conversation)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_chat_inbox_deletion (
  user_id uuid NOT NULL,
  conversation_kind text NOT NULL,
  conversation_id uuid NOT NULL,
  deleted_at timestamptz NOT NULL DEFAULT now(),
  permanently_deleted_at timestamptz NULL,
  CONSTRAINT user_chat_inbox_deletion_pkey
    PRIMARY KEY (user_id, conversation_kind, conversation_id),
  CONSTRAINT user_chat_inbox_deletion_kind_check
    CHECK (conversation_kind IN ('direct', 'group')),
  CONSTRAINT user_chat_inbox_deletion_user_fk
    FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE
);

COMMENT ON TABLE public.user_chat_inbox_deletion IS
  'Per-user Chat inbox soft-delete / permanent-delete. Never deletes shared conversation rows.';

CREATE INDEX IF NOT EXISTS user_chat_inbox_deletion_user_active_idx
  ON public.user_chat_inbox_deletion (user_id, permanently_deleted_at, deleted_at DESC);

CREATE INDEX IF NOT EXISTS user_chat_inbox_deletion_conversation_idx
  ON public.user_chat_inbox_deletion (conversation_kind, conversation_id);

ALTER TABLE public.user_chat_inbox_deletion ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_chat_inbox_deletion_select_own ON public.user_chat_inbox_deletion;
CREATE POLICY user_chat_inbox_deletion_select_own
  ON public.user_chat_inbox_deletion
  FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

-- Mutations go through SECURITY DEFINER RPCs only (no direct client INSERT/UPDATE/DELETE).
REVOKE ALL ON TABLE public.user_chat_inbox_deletion FROM PUBLIC;
REVOKE ALL ON TABLE public.user_chat_inbox_deletion FROM anon;
GRANT SELECT ON TABLE public.user_chat_inbox_deletion TO authenticated;
GRANT ALL ON TABLE public.user_chat_inbox_deletion TO service_role;

-- ---------------------------------------------------------------------------
-- 2) Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.chat_inbox_retention_interval()
RETURNS interval
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT interval '30 days';
$$;

CREATE OR REPLACE FUNCTION public.chat_inbox_soft_delete_is_recoverable(
  p_deleted_at timestamptz,
  p_permanently_deleted_at timestamptz
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT p_permanently_deleted_at IS NULL
    AND p_deleted_at IS NOT NULL
    AND p_deleted_at > (now() - public.chat_inbox_retention_interval());
$$;

REVOKE ALL ON FUNCTION public.chat_inbox_retention_interval() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.chat_inbox_retention_interval() FROM anon;

REVOKE ALL ON FUNCTION public.chat_inbox_soft_delete_is_recoverable(timestamptz, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.chat_inbox_soft_delete_is_recoverable(timestamptz, timestamptz) FROM anon;

CREATE OR REPLACE FUNCTION public.expire_my_chat_inbox_deletions()
RETURNS integer
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_count integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  UPDATE public.user_chat_inbox_deletion d
  SET permanently_deleted_at = d.deleted_at + public.chat_inbox_retention_interval()
  WHERE d.user_id = v_uid
    AND d.permanently_deleted_at IS NULL
    AND d.deleted_at <= (now() - public.chat_inbox_retention_interval());

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.expire_my_chat_inbox_deletions() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.expire_my_chat_inbox_deletions() FROM anon;
GRANT EXECUTE ON FUNCTION public.expire_my_chat_inbox_deletions() TO authenticated;
GRANT EXECUTE ON FUNCTION public.expire_my_chat_inbox_deletions() TO service_role;

CREATE OR REPLACE FUNCTION public.chat_inbox_assert_participant(
  p_kind text,
  p_conversation_id uuid,
  p_user_id uuid
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_kind = 'direct' THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.direct_conversations c
      WHERE c.id = p_conversation_id
        AND (c.user_a_id = p_user_id OR c.user_b_id = p_user_id)
    ) THEN
      RAISE EXCEPTION 'Not a participant of this conversation' USING ERRCODE = '42501';
    END IF;
  ELSIF p_kind = 'group' THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.group_conversation_members m
      WHERE m.conversation_id = p_conversation_id
        AND m.user_id = p_user_id
        AND m.left_at IS NULL
    ) THEN
      RAISE EXCEPTION 'Not an active member of this group' USING ERRCODE = '42501';
    END IF;
  ELSE
    RAISE EXCEPTION 'Invalid conversation_kind' USING ERRCODE = '22023';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.chat_inbox_assert_participant(text, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.chat_inbox_assert_participant(text, uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.chat_inbox_assert_participant(text, uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Soft-delete / restore / permanent-delete
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.soft_delete_chat_inbox_conversation(
  p_conversation_kind text,
  p_conversation_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_conversation_id IS NULL THEN
    RAISE EXCEPTION 'conversation_id is required' USING ERRCODE = '22023';
  END IF;
  IF p_conversation_kind NOT IN ('direct', 'group') THEN
    RAISE EXCEPTION 'Invalid conversation_kind' USING ERRCODE = '22023';
  END IF;

  PERFORM public.chat_inbox_assert_participant(p_conversation_kind, p_conversation_id, v_uid);

  INSERT INTO public.user_chat_inbox_deletion AS d (
    user_id,
    conversation_kind,
    conversation_id,
    deleted_at,
    permanently_deleted_at
  )
  VALUES (v_uid, p_conversation_kind, p_conversation_id, now(), NULL)
  ON CONFLICT (user_id, conversation_kind, conversation_id) DO UPDATE
  SET
    -- Keep original soft-delete clock when already soft-deleted.
    deleted_at = CASE
      WHEN d.permanently_deleted_at IS NOT NULL THEN d.deleted_at
      WHEN d.deleted_at IS NOT NULL THEN d.deleted_at
      ELSE EXCLUDED.deleted_at
    END,
    permanently_deleted_at = d.permanently_deleted_at
  WHERE d.permanently_deleted_at IS NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.restore_chat_inbox_conversation(
  p_conversation_kind text,
  p_conversation_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_conversation_kind NOT IN ('direct', 'group') THEN
    RAISE EXCEPTION 'Invalid conversation_kind' USING ERRCODE = '22023';
  END IF;

  DELETE FROM public.user_chat_inbox_deletion d
  WHERE d.user_id = v_uid
    AND d.conversation_kind = p_conversation_kind
    AND d.conversation_id = p_conversation_id
    AND d.permanently_deleted_at IS NULL
    AND public.chat_inbox_soft_delete_is_recoverable(d.deleted_at, d.permanently_deleted_at);
END;
$$;

CREATE OR REPLACE FUNCTION public.permanently_delete_chat_inbox_conversation(
  p_conversation_kind text,
  p_conversation_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_conversation_kind NOT IN ('direct', 'group') THEN
    RAISE EXCEPTION 'Invalid conversation_kind' USING ERRCODE = '22023';
  END IF;

  PERFORM public.chat_inbox_assert_participant(p_conversation_kind, p_conversation_id, v_uid);

  INSERT INTO public.user_chat_inbox_deletion AS d (
    user_id,
    conversation_kind,
    conversation_id,
    deleted_at,
    permanently_deleted_at
  )
  VALUES (v_uid, p_conversation_kind, p_conversation_id, now(), now())
  ON CONFLICT (user_id, conversation_kind, conversation_id) DO UPDATE
  SET
    permanently_deleted_at = COALESCE(d.permanently_deleted_at, now()),
    deleted_at = COALESCE(d.deleted_at, EXCLUDED.deleted_at);
END;
$$;

REVOKE ALL ON FUNCTION public.soft_delete_chat_inbox_conversation(text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.soft_delete_chat_inbox_conversation(text, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.soft_delete_chat_inbox_conversation(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.soft_delete_chat_inbox_conversation(text, uuid) TO service_role;

REVOKE ALL ON FUNCTION public.restore_chat_inbox_conversation(text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.restore_chat_inbox_conversation(text, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.restore_chat_inbox_conversation(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.restore_chat_inbox_conversation(text, uuid) TO service_role;

REVOKE ALL ON FUNCTION public.permanently_delete_chat_inbox_conversation(text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.permanently_delete_chat_inbox_conversation(text, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.permanently_delete_chat_inbox_conversation(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.permanently_delete_chat_inbox_conversation(text, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 4) Exclusion keys for active inbox client filtering
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_chat_inbox_exclusions()
RETURNS TABLE (
  conversation_kind text,
  conversation_id uuid
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  PERFORM public.expire_my_chat_inbox_deletions();

  RETURN QUERY
  SELECT d.conversation_kind, d.conversation_id
  FROM public.user_chat_inbox_deletion d
  WHERE d.user_id = v_uid
    AND (
      d.permanently_deleted_at IS NOT NULL
      OR d.deleted_at IS NOT NULL
    );
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_chat_inbox_exclusions() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_chat_inbox_exclusions() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_my_chat_inbox_exclusions() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_chat_inbox_exclusions() TO service_role;

-- ---------------------------------------------------------------------------
-- 5) Recently Deleted list (recoverable soft-deletes only)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_recently_deleted_chat_conversations()
RETURNS TABLE (
  conversation_kind text,
  conversation_id uuid,
  deleted_at timestamptz,
  title text,
  subtitle text,
  peer_user_id uuid,
  peer_avatar_url text,
  peer_avatar_thumbnail_url text,
  is_business boolean,
  business_display_name text,
  venue_id uuid,
  member_count integer,
  last_message_body text,
  last_message_created_at timestamptz,
  days_remaining integer
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  PERFORM public.expire_my_chat_inbox_deletions();

  RETURN QUERY
  WITH soft AS (
    SELECT d.*
    FROM public.user_chat_inbox_deletion d
    WHERE d.user_id = v_uid
      AND public.chat_inbox_soft_delete_is_recoverable(d.deleted_at, d.permanently_deleted_at)
  ),
  direct_rows AS (
    SELECT
      s.conversation_kind,
      s.conversation_id,
      s.deleted_at,
      CASE
        WHEN c.venue_id IS NOT NULL THEN COALESCE(NULLIF(trim(v.venue_name), ''), NULLIF(trim(b.display_name), ''), 'Watch Spot')
        WHEN COALESCE(b.id IS NOT NULL, false) THEN COALESCE(NULLIF(trim(b.display_name), ''), COALESCE(NULLIF(trim(up.display_name), ''), 'Business'))
        ELSE COALESCE(NULLIF(trim(up.display_name), ''), NULLIF(trim(up.username), ''), 'Chat')
      END AS title,
      CASE
        WHEN c.venue_id IS NOT NULL THEN 'Watch Spot'
        WHEN COALESCE(b.id IS NOT NULL, false) THEN 'Business'
        ELSE 'Direct'
      END AS subtitle,
      CASE WHEN c.user_a_id = v_uid THEN c.user_b_id ELSE c.user_a_id END AS peer_user_id,
      up.avatar_url AS peer_avatar_url,
      up.avatar_thumbnail_url AS peer_avatar_thumbnail_url,
      (c.venue_id IS NOT NULL OR b.id IS NOT NULL) AS is_business,
      NULLIF(trim(b.display_name), '') AS business_display_name,
      c.venue_id,
      NULL::integer AS member_count,
      (
        SELECT dm.body
        FROM public.direct_messages dm
        WHERE dm.conversation_id = c.id
          AND dm.deleted_at IS NULL
          AND COALESCE(dm.is_deleted, false) = false
        ORDER BY dm.created_at DESC, dm.id DESC
        LIMIT 1
      ) AS last_message_body,
      (
        SELECT dm.created_at
        FROM public.direct_messages dm
        WHERE dm.conversation_id = c.id
          AND dm.deleted_at IS NULL
          AND COALESCE(dm.is_deleted, false) = false
        ORDER BY dm.created_at DESC, dm.id DESC
        LIMIT 1
      ) AS last_message_created_at,
      GREATEST(
        0,
        CEIL(
          EXTRACT(
            EPOCH FROM ((s.deleted_at + public.chat_inbox_retention_interval()) - now())
          ) / 86400.0
        )::integer
      ) AS days_remaining
    FROM soft s
    INNER JOIN public.direct_conversations c
      ON c.id = s.conversation_id
     AND s.conversation_kind = 'direct'
     AND (c.user_a_id = v_uid OR c.user_b_id = v_uid)
    LEFT JOIN public.user_profiles up
      ON up.id = CASE WHEN c.user_a_id = v_uid THEN c.user_b_id ELSE c.user_a_id END
    LEFT JOIN public.venues v
      ON v.id = c.venue_id
    LEFT JOIN public.businesses b
      ON b.id = COALESCE(c.business_id, v.business_id)
  ),
  group_rows AS (
    SELECT
      s.conversation_kind,
      s.conversation_id,
      s.deleted_at,
      COALESCE(NULLIF(trim(gc.title), ''), 'Group') AS title,
      'Group'::text AS subtitle,
      NULL::uuid AS peer_user_id,
      NULL::text AS peer_avatar_url,
      NULL::text AS peer_avatar_thumbnail_url,
      false AS is_business,
      NULL::text AS business_display_name,
      NULL::uuid AS venue_id,
      (
        SELECT count(*)::integer
        FROM public.group_conversation_members am
        WHERE am.conversation_id = gc.id
          AND am.left_at IS NULL
      ) AS member_count,
      CASE
        WHEN public.group_viewer_can_see_sender_message(v_uid, gc.last_message_sender_id, gc.last_message_type)
          THEN gc.last_message_preview
        ELSE NULL
      END AS last_message_body,
      CASE
        WHEN public.group_viewer_can_see_sender_message(v_uid, gc.last_message_sender_id, gc.last_message_type)
          THEN gc.last_message_at
        ELSE NULL
      END AS last_message_created_at,
      GREATEST(
        0,
        CEIL(
          EXTRACT(
            EPOCH FROM ((s.deleted_at + public.chat_inbox_retention_interval()) - now())
          ) / 86400.0
        )::integer
      ) AS days_remaining
    FROM soft s
    INNER JOIN public.group_conversations gc
      ON gc.id = s.conversation_id
     AND s.conversation_kind = 'group'
    INNER JOIN public.group_conversation_members m
      ON m.conversation_id = gc.id
     AND m.user_id = v_uid
     AND m.left_at IS NULL
  )
  SELECT * FROM (
    SELECT * FROM direct_rows
    UNION ALL
    SELECT * FROM group_rows
  ) combined
  ORDER BY deleted_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.list_recently_deleted_chat_conversations() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_recently_deleted_chat_conversations() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_recently_deleted_chat_conversations() TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_recently_deleted_chat_conversations() TO service_role;

-- ---------------------------------------------------------------------------
-- 6) Auto-restore soft-delete on inbound messages (not permanent / not expired)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.chat_inbox_auto_restore_on_inbound_message()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_kind text;
  v_sender uuid;
BEGIN
  IF TG_TABLE_NAME = 'direct_messages' THEN
    v_kind := 'direct';
    v_sender := NEW.sender_id;
  ELSIF TG_TABLE_NAME = 'group_messages' THEN
    -- Only user text restores (ignore system events).
    IF COALESCE(NEW.message_type, 'text') <> 'text' THEN
      RETURN NEW;
    END IF;
    v_kind := 'group';
    v_sender := NEW.sender_id;
  ELSE
    RETURN NEW;
  END IF;

  IF COALESCE(NEW.is_deleted, false) OR NEW.deleted_at IS NOT NULL THEN
    RETURN NEW;
  END IF;

  DELETE FROM public.user_chat_inbox_deletion d
  WHERE d.conversation_kind = v_kind
    AND d.conversation_id = NEW.conversation_id
    AND d.user_id IS DISTINCT FROM v_sender
    AND d.permanently_deleted_at IS NULL
    AND public.chat_inbox_soft_delete_is_recoverable(d.deleted_at, d.permanently_deleted_at);

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_direct_messages_chat_inbox_auto_restore ON public.direct_messages;
CREATE TRIGGER trg_direct_messages_chat_inbox_auto_restore
  AFTER INSERT ON public.direct_messages
  FOR EACH ROW
  EXECUTE FUNCTION public.chat_inbox_auto_restore_on_inbound_message();

DROP TRIGGER IF EXISTS trg_group_messages_chat_inbox_auto_restore ON public.group_messages;
CREATE TRIGGER trg_group_messages_chat_inbox_auto_restore
  AFTER INSERT ON public.group_messages
  FOR EACH ROW
  EXECUTE FUNCTION public.chat_inbox_auto_restore_on_inbound_message();

COMMIT;

-- =============================================================================
-- Manual post-apply validation (read-only)
-- =============================================================================
-- SELECT to_regclass('public.user_chat_inbox_deletion');
-- SELECT to_regprocedure('public.soft_delete_chat_inbox_conversation(text,uuid)');
-- SELECT to_regprocedure('public.restore_chat_inbox_conversation(text,uuid)');
-- SELECT to_regprocedure('public.permanently_delete_chat_inbox_conversation(text,uuid)');
-- SELECT to_regprocedure('public.list_recently_deleted_chat_conversations()');
-- SELECT to_regprocedure('public.get_my_chat_inbox_exclusions()');
--
-- Rollback sketch:
--   DROP TRIGGER IF EXISTS trg_direct_messages_chat_inbox_auto_restore ON public.direct_messages;
--   DROP TRIGGER IF EXISTS trg_group_messages_chat_inbox_auto_restore ON public.group_messages;
--   DROP FUNCTION IF EXISTS public.chat_inbox_auto_restore_on_inbound_message();
--   DROP FUNCTION IF EXISTS public.list_recently_deleted_chat_conversations();
--   DROP FUNCTION IF EXISTS public.get_my_chat_inbox_exclusions();
--   DROP FUNCTION IF EXISTS public.permanently_delete_chat_inbox_conversation(text, uuid);
--   DROP FUNCTION IF EXISTS public.restore_chat_inbox_conversation(text, uuid);
--   DROP FUNCTION IF EXISTS public.soft_delete_chat_inbox_conversation(text, uuid);
--   DROP FUNCTION IF EXISTS public.chat_inbox_assert_participant(text, uuid, uuid);
--   DROP FUNCTION IF EXISTS public.expire_my_chat_inbox_deletions();
--   DROP FUNCTION IF EXISTS public.chat_inbox_soft_delete_is_recoverable(timestamptz, timestamptz);
--   DROP FUNCTION IF EXISTS public.chat_inbox_retention_interval();
--   DROP TABLE IF EXISTS public.user_chat_inbox_deletion;
