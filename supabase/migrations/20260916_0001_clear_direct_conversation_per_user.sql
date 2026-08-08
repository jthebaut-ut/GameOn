-- =============================================================================
-- 20260916_0001 — Per-user direct conversation clear (privacy fix)
-- =============================================================================
-- PROBLEM
--   iOS calls public.clear_direct_conversation(p_conversation_id). That RPC was
--   never defined in-repo. Production (or legacy) implementations that DELETE /
--   soft-delete shared direct_messages rows (or UI copy promising "for both of
--   you") make User B lose history when User A clears.
--
-- FIX
--   • Per-user watermark table: user_direct_conversation_clear
--   • clear_direct_conversation upserts ONLY the caller's row (cleared_at=now())
--   • Soft-hides the conversation in the caller's inbox via existing
--     soft_delete_chat_inbox_conversation (auto-restores on inbound message)
--   • NEVER deletes/updates shared direct_messages / direct_conversations
--   • get_dm_inbox_summaries / get_dm_unread_total ignore messages at/before
--     the viewer's cleared_at
--
-- Do NOT apply from the agent; review and apply deliberately.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Per-user clear watermark (separate from inbox soft-delete)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_direct_conversation_clear (
  user_id uuid NOT NULL,
  conversation_id uuid NOT NULL,
  cleared_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT user_direct_conversation_clear_pkey
    PRIMARY KEY (user_id, conversation_id),
  CONSTRAINT user_direct_conversation_clear_user_fk
    FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE,
  CONSTRAINT user_direct_conversation_clear_conversation_fk
    FOREIGN KEY (conversation_id) REFERENCES public.direct_conversations (id) ON DELETE CASCADE
);

COMMENT ON TABLE public.user_direct_conversation_clear IS
  'Per-user DM history clear watermark. Messages at/before cleared_at are hidden only for that user. Never mutates shared message rows.';

COMMENT ON COLUMN public.user_direct_conversation_clear.cleared_at IS
  'Viewer-local hide-before watermark. Independent of peer clear state and of moderation is_deleted/deleted_at.';

CREATE INDEX IF NOT EXISTS user_direct_conversation_clear_conversation_idx
  ON public.user_direct_conversation_clear (conversation_id);

ALTER TABLE public.user_direct_conversation_clear ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_direct_conversation_clear FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_direct_conversation_clear_select_own
  ON public.user_direct_conversation_clear;
CREATE POLICY user_direct_conversation_clear_select_own
  ON public.user_direct_conversation_clear
  FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

-- No direct client INSERT/UPDATE/DELETE — SECURITY DEFINER RPC only.
REVOKE ALL ON TABLE public.user_direct_conversation_clear FROM PUBLIC;
REVOKE ALL ON TABLE public.user_direct_conversation_clear FROM anon;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.user_direct_conversation_clear FROM authenticated;
GRANT SELECT ON TABLE public.user_direct_conversation_clear TO authenticated;
GRANT ALL ON TABLE public.user_direct_conversation_clear TO service_role;

-- ---------------------------------------------------------------------------
-- 2) Visibility helper (messages strictly after viewer clear watermark)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.direct_message_after_viewer_clear(
  p_conversation_id uuid,
  p_message_created_at timestamptz,
  p_viewer uuid DEFAULT auth.uid()
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p_viewer IS NOT NULL
    AND p_conversation_id IS NOT NULL
    AND p_message_created_at IS NOT NULL
    AND p_message_created_at > COALESCE(
      (
        SELECT c.cleared_at
        FROM public.user_direct_conversation_clear c
        WHERE c.user_id = p_viewer
          AND c.conversation_id = p_conversation_id
      ),
      '-infinity'::timestamptz
    );
$$;

COMMENT ON FUNCTION public.direct_message_after_viewer_clear(uuid, timestamptz, uuid) IS
  'True when message created_at is strictly after the viewer''s per-user clear watermark (or no watermark).';

REVOKE ALL ON FUNCTION public.direct_message_after_viewer_clear(uuid, timestamptz, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.direct_message_after_viewer_clear(uuid, timestamptz, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.direct_message_after_viewer_clear(uuid, timestamptz, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.direct_message_after_viewer_clear(uuid, timestamptz, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) clear_direct_conversation — per-user only (replaces any shared-delete body)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.clear_direct_conversation(p_conversation_id uuid)
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

  IF NOT public.is_direct_conversation_participant(p_conversation_id, v_uid) THEN
    RAISE EXCEPTION 'Not a conversation participant' USING ERRCODE = '42501';
  END IF;

  -- Viewer-local watermark only. Do NOT touch direct_messages / peer rows.
  INSERT INTO public.user_direct_conversation_clear AS c (
    user_id,
    conversation_id,
    cleared_at
  )
  VALUES (v_uid, p_conversation_id, now())
  ON CONFLICT (user_id, conversation_id) DO UPDATE
  SET cleared_at = EXCLUDED.cleared_at;

  -- Hide from this user's inbox until a newer inbound message auto-restores
  -- (existing chat_inbox_auto_restore_on_inbound_message trigger).
  IF to_regprocedure('public.soft_delete_chat_inbox_conversation(text, uuid)') IS NOT NULL THEN
    PERFORM public.soft_delete_chat_inbox_conversation('direct', p_conversation_id);
  END IF;
END;
$$;

COMMENT ON FUNCTION public.clear_direct_conversation(uuid) IS
  'Per-user DM clear: sets cleared_at for auth.uid() and soft-hides inbox for that user only. Never deletes shared message history.';

REVOKE ALL ON FUNCTION public.clear_direct_conversation(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.clear_direct_conversation(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.clear_direct_conversation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.clear_direct_conversation(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 4) Unread total — ignore messages at/before viewer clear
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_dm_unread_total()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COUNT(*)::integer
  FROM public.direct_messages dm
  LEFT JOIN public.conversation_read_state crs
    ON crs.conversation_id = dm.conversation_id
   AND crs.user_id = auth.uid()
  LEFT JOIN public.user_direct_conversation_clear clr
    ON clr.user_id = auth.uid()
   AND clr.conversation_id = dm.conversation_id
  WHERE auth.uid() IS NOT NULL
    AND public.is_direct_conversation_participant(dm.conversation_id, auth.uid())
    AND dm.sender_id <> auth.uid()
    AND dm.deleted_at IS NULL
    AND COALESCE(dm.is_deleted, FALSE) = FALSE
    AND dm.created_at > COALESCE(crs.last_read_at, 'epoch'::timestamptz)
    AND dm.created_at > COALESCE(clr.cleared_at, '-infinity'::timestamptz);
$$;

COMMENT ON FUNCTION public.get_dm_unread_total() IS
  'Unread DM total for auth.uid(); excludes moderation-hidden rows and messages at/before the viewer clear watermark.';

REVOKE ALL ON FUNCTION public.get_dm_unread_total() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_dm_unread_total() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_dm_unread_total() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_dm_unread_total() TO service_role;

-- ---------------------------------------------------------------------------
-- 5) Inbox summaries — last message + unread honor viewer clear watermark
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_dm_inbox_summaries();

CREATE OR REPLACE FUNCTION public.get_dm_inbox_summaries()
RETURNS TABLE (
  conversation_id uuid,
  friend_user_id uuid,
  friend_display_name text,
  friend_avatar_url text,
  friend_avatar_thumbnail_url text,
  friend_email text,
  friend_is_business boolean,
  friend_business_display_name text,
  venue_id uuid,
  venue_name text,
  venue_location_line text,
  last_message_body text,
  last_message_sender_id uuid,
  last_message_created_at timestamptz,
  unread_count integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH me AS (
    SELECT auth.uid() AS uid
  ),
  my_businesses AS (
    SELECT b.id
    FROM public.businesses b
    CROSS JOIN me
    WHERE b.owner_user_id = me.uid
      AND COALESCE(lower(trim(b.admin_status)), '') = 'active'
  ),
  accepted_friend_candidates AS (
    SELECT friend_user_id, friend_business_id
    FROM (
      SELECT f.addressee_id AS friend_user_id, NULL::uuid AS friend_business_id
      FROM public.friendships f
      CROSS JOIN me
      WHERE f.status = 'accepted'
        AND f.requester_id = me.uid
        AND COALESCE(f.requester_entity_type, 'user') = 'user'
        AND COALESCE(f.addressee_entity_type, 'user') = 'user'

      UNION ALL

      SELECT f.requester_id AS friend_user_id, NULL::uuid AS friend_business_id
      FROM public.friendships f
      CROSS JOIN me
      WHERE f.status = 'accepted'
        AND f.addressee_id = me.uid
        AND COALESCE(f.requester_entity_type, 'user') = 'user'
        AND COALESCE(f.addressee_entity_type, 'user') = 'user'

      UNION ALL

      SELECT b.owner_user_id AS friend_user_id, b.id AS friend_business_id
      FROM public.friendships f
      CROSS JOIN me
      INNER JOIN public.businesses b
        ON b.id = f.addressee_id
       AND b.owner_user_id IS NOT NULL
       AND COALESCE(lower(trim(b.admin_status)), '') = 'active'
      WHERE f.status = 'accepted'
        AND f.requester_id = me.uid
        AND COALESCE(f.requester_entity_type, 'user') = 'user'
        AND COALESCE(f.addressee_entity_type, 'user') = 'business'

      UNION ALL

      SELECT b.owner_user_id AS friend_user_id, b.id AS friend_business_id
      FROM public.friendships f
      CROSS JOIN me
      INNER JOIN public.businesses b
        ON b.id = f.requester_id
       AND b.owner_user_id IS NOT NULL
       AND COALESCE(lower(trim(b.admin_status)), '') = 'active'
      WHERE f.status = 'accepted'
        AND f.addressee_id = me.uid
        AND COALESCE(f.requester_entity_type, 'user') = 'business'
        AND COALESCE(f.addressee_entity_type, 'user') = 'user'

      UNION ALL

      SELECT
        CASE
          WHEN COALESCE(f.requester_entity_type, 'user') = 'business' THEN f.addressee_id
          ELSE f.requester_id
        END AS friend_user_id,
        NULL::uuid AS friend_business_id
      FROM public.friendships f
      INNER JOIN my_businesses mb
        ON (
          COALESCE(f.requester_entity_type, 'user') = 'business'
          AND f.requester_id = mb.id
        )
        OR (
          COALESCE(f.addressee_entity_type, 'user') = 'business'
          AND f.addressee_id = mb.id
        )
      WHERE f.status = 'accepted'
    ) x
    WHERE friend_user_id IS NOT NULL
  ),
  accepted_friends AS (
    SELECT
      friend_user_id,
      (array_agg(friend_business_id) FILTER (WHERE friend_business_id IS NOT NULL))[1] AS friend_business_id
    FROM accepted_friend_candidates
    GROUP BY friend_user_id
  ),
  friendship_base AS (
    SELECT
      af.friend_user_id,
      af.friend_business_id,
      dc.id AS conversation_id,
      dc.venue_id,
      dc.business_id AS conversation_business_id
    FROM accepted_friends af
    CROSS JOIN me
    LEFT JOIN LATERAL (
      SELECT dc_inner.id, dc_inner.venue_id, dc_inner.business_id
      FROM public.direct_conversations dc_inner
      WHERE dc_inner.venue_id IS NULL
        AND (
          (dc_inner.user_a_id = me.uid AND dc_inner.user_b_id = af.friend_user_id)
          OR (dc_inner.user_b_id = me.uid AND dc_inner.user_a_id = af.friend_user_id)
          OR (
            af.friend_business_id IS NOT NULL
            AND (
              (dc_inner.user_a_id = me.uid AND dc_inner.user_b_id = af.friend_business_id)
              OR (dc_inner.user_b_id = me.uid AND dc_inner.user_a_id = af.friend_business_id)
            )
          )
          OR EXISTS (
            SELECT 1
            FROM my_businesses mb
            WHERE
              (dc_inner.user_a_id = af.friend_user_id AND dc_inner.user_b_id = mb.id)
              OR (dc_inner.user_b_id = af.friend_user_id AND dc_inner.user_a_id = mb.id)
          )
        )
      ORDER BY
        CASE
          WHEN (dc_inner.user_a_id = me.uid AND dc_inner.user_b_id = af.friend_user_id)
            OR (dc_inner.user_b_id = me.uid AND dc_inner.user_a_id = af.friend_user_id)
          THEN 0
          ELSE 1
        END
      LIMIT 1
    ) dc ON TRUE
  ),
  venue_conversation_base AS (
    SELECT
      dc.id AS conversation_id,
      CASE
        WHEN dc.user_a_id = me.uid THEN dc.user_b_id
        ELSE dc.user_a_id
      END AS friend_user_id,
      dc.business_id AS friend_business_id,
      dc.venue_id,
      dc.business_id AS conversation_business_id
    FROM public.direct_conversations dc
    CROSS JOIN me
    WHERE dc.venue_id IS NOT NULL
      AND dc.fan_initiated = true
      AND (dc.user_a_id = me.uid OR dc.user_b_id = me.uid)
  ),
  combined_base AS (
    SELECT conversation_id, friend_user_id, friend_business_id, venue_id, conversation_business_id
    FROM friendship_base

    UNION

    SELECT conversation_id, friend_user_id, friend_business_id, venue_id, conversation_business_id
    FROM venue_conversation_base
  ),
  projected AS (
    SELECT
      base.*,
      (
        base.venue_id IS NOT NULL
        AND base.conversation_business_id IS NOT NULL
        AND EXISTS (
          SELECT 1
          FROM my_businesses mb
          WHERE mb.id = base.conversation_business_id
        )
      ) AS viewer_owns_venue_business
    FROM combined_base base
  )
  SELECT
    base.conversation_id,
    base.friend_user_id,
    CASE
      WHEN base.viewer_owns_venue_business THEN
        COALESCE(
          NULLIF(trim(up.display_name), ''),
          NULLIF(split_part(COALESCE(up.email, ''), '@', 1), ''),
          'FanGeo User'
        )
      WHEN base.venue_id IS NOT NULL THEN
        COALESCE(NULLIF(trim(v.venue_name), ''), 'Venue')
      WHEN COALESCE(target_biz.friend_is_business, biz.friend_is_business, venue_biz.friend_is_business, FALSE) THEN
        COALESCE(
          target_biz.friend_business_display_name,
          biz.friend_business_display_name,
          venue_biz.friend_business_display_name,
          target_biz.friend_email,
          biz.friend_email,
          venue_biz.friend_email,
          'Business'
        )
      ELSE
        COALESCE(
          NULLIF(trim(up.display_name), ''),
          NULLIF(split_part(COALESCE(up.email, biz.friend_email, venue_biz.friend_email, ''), '@', 1), ''),
          'FanGeo User'
        )
    END AS friend_display_name,
    CASE
      WHEN base.viewer_owns_venue_business THEN up.avatar_url
      WHEN base.venue_id IS NOT NULL
        OR COALESCE(target_biz.friend_is_business, biz.friend_is_business, venue_biz.friend_is_business, FALSE)
      THEN NULL
      ELSE up.avatar_url
    END AS friend_avatar_url,
    CASE
      WHEN base.viewer_owns_venue_business THEN up.avatar_thumbnail_url
      WHEN base.venue_id IS NOT NULL
        OR COALESCE(target_biz.friend_is_business, biz.friend_is_business, venue_biz.friend_is_business, FALSE)
      THEN NULL
      ELSE up.avatar_thumbnail_url
    END AS friend_avatar_thumbnail_url,
    CASE
      WHEN base.viewer_owns_venue_business THEN NULLIF(lower(trim(up.email)), '')
      ELSE COALESCE(
        target_biz.friend_email,
        biz.friend_email,
        venue_biz.friend_email,
        NULLIF(lower(trim(up.email)), '')
      )
    END AS friend_email,
    CASE
      WHEN base.viewer_owns_venue_business THEN FALSE
      ELSE (
        base.venue_id IS NOT NULL
        OR COALESCE(target_biz.friend_is_business, biz.friend_is_business, venue_biz.friend_is_business, FALSE)
      )
    END AS friend_is_business,
    CASE
      WHEN base.viewer_owns_venue_business THEN NULL
      ELSE COALESCE(
        target_biz.friend_business_display_name,
        biz.friend_business_display_name,
        venue_biz.friend_business_display_name
      )
    END AS friend_business_display_name,
    -- Keep venue_id for thread semantics (friendship exemption); identity fields above are fan when owner views.
    base.venue_id,
    CASE
      WHEN base.viewer_owns_venue_business THEN NULL
      ELSE NULLIF(trim(v.venue_name), '')
    END AS venue_name,
    CASE
      WHEN base.viewer_owns_venue_business THEN NULL
      ELSE COALESCE(
        NULLIF(trim(v.formatted_address), ''),
        NULLIF(trim(concat_ws(', ', NULLIF(trim(v.city), ''), NULLIF(trim(v.state), ''))), ''),
        NULLIF(trim(v.address), '')
      )
    END AS venue_location_line,
    latest_dm.body AS last_message_body,
    latest_dm.sender_id AS last_message_sender_id,
    latest_dm.created_at AS last_message_created_at,
    COALESCE(unread.unread_count, 0) AS unread_count
  FROM projected base
  LEFT JOIN public.user_profiles up
    ON up.id = base.friend_user_id
   AND COALESCE(lower(trim(up.admin_status)), '') <> 'disabled'
  LEFT JOIN public.venues v
    ON v.id = base.venue_id
  LEFT JOIN LATERAL (
    SELECT
      TRUE AS friend_is_business,
      NULLIF(trim(b.display_name), '') AS friend_business_display_name,
      NULLIF(lower(trim(b.owner_email)), '') AS friend_email
    FROM public.businesses b
    WHERE b.id = base.friend_business_id
      AND COALESCE(lower(trim(b.admin_status)), '') = 'active'
    LIMIT 1
  ) target_biz ON TRUE
  LEFT JOIN LATERAL (
    SELECT
      TRUE AS friend_is_business,
      NULLIF(trim(b.display_name), '') AS friend_business_display_name,
      NULLIF(lower(trim(b.owner_email)), '') AS friend_email
    FROM public.businesses b
    WHERE b.id = base.conversation_business_id
      AND COALESCE(lower(trim(b.admin_status)), '') = 'active'
    LIMIT 1
  ) venue_biz ON base.venue_id IS NOT NULL AND NOT base.viewer_owns_venue_business
  LEFT JOIN LATERAL (
    SELECT
      TRUE AS friend_is_business,
      NULLIF(trim(b.display_name), '') AS friend_business_display_name,
      NULLIF(lower(trim(b.owner_email)), '') AS friend_email
    FROM public.businesses b
    WHERE COALESCE(lower(trim(b.admin_status)), '') = 'active'
      AND base.friend_business_id IS NULL
      AND base.venue_id IS NULL
      AND (
        b.owner_user_id = base.friend_user_id
        OR (
          NULLIF(lower(trim(b.owner_email)), '') IS NOT NULL
          AND NULLIF(lower(trim(b.owner_email)), '') = NULLIF(lower(trim(COALESCE(up.email, ''))), '')
        )
      )
    ORDER BY
      CASE WHEN b.owner_user_id = base.friend_user_id THEN 0 ELSE 1 END,
      CASE WHEN NULLIF(trim(b.display_name), '') IS NOT NULL THEN 0 ELSE 1 END,
      b.created_at DESC NULLS LAST
    LIMIT 1
  ) biz ON TRUE
  LEFT JOIN public.user_direct_conversation_clear viewer_clear
    ON viewer_clear.user_id = (SELECT uid FROM me)
   AND viewer_clear.conversation_id = base.conversation_id
  LEFT JOIN LATERAL (
    SELECT dm.body, dm.sender_id, dm.created_at
    FROM public.direct_messages dm
    WHERE dm.conversation_id = base.conversation_id
      AND dm.deleted_at IS NULL
      AND COALESCE(dm.is_deleted, FALSE) = FALSE
      AND dm.created_at > COALESCE(viewer_clear.cleared_at, '-infinity'::timestamptz)
    ORDER BY dm.created_at DESC, dm.id DESC
    LIMIT 1
  ) latest_dm ON TRUE
  LEFT JOIN public.conversation_read_state crs
    ON crs.conversation_id = base.conversation_id
   AND crs.user_id = (SELECT uid FROM me)
  LEFT JOIN LATERAL (
    SELECT COUNT(*)::integer AS unread_count
    FROM public.direct_messages dm
    WHERE dm.conversation_id = base.conversation_id
      AND dm.sender_id <> (SELECT uid FROM me)
      AND dm.deleted_at IS NULL
      AND COALESCE(dm.is_deleted, FALSE) = FALSE
      AND dm.created_at > COALESCE(crs.last_read_at, 'epoch'::timestamptz)
      AND dm.created_at > COALESCE(viewer_clear.cleared_at, '-infinity'::timestamptz)
  ) unread ON TRUE
  WHERE (SELECT uid FROM me) IS NOT NULL
  ORDER BY latest_dm.created_at DESC NULLS LAST, base.conversation_id;
$$;


COMMENT ON FUNCTION public.get_dm_inbox_summaries() IS
  'DM inbox rows with viewer-relative counterparts; last message and unread ignore messages at/before the viewer clear watermark.';

REVOKE ALL ON FUNCTION public.get_dm_inbox_summaries() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_dm_inbox_summaries() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_dm_inbox_summaries() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_dm_inbox_summaries() TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ---------------------------------------------------------------------------
-- Verification (manual)
-- ---------------------------------------------------------------------------
-- SELECT to_regprocedure('public.clear_direct_conversation(uuid)');
-- SELECT to_regclass('public.user_direct_conversation_clear');
-- As User A: SELECT public.clear_direct_conversation('<cid>');
-- As User B: SELECT count(*) FROM direct_messages WHERE conversation_id = '<cid>';
-- Expect: B still sees all non-moderation-deleted rows; A watermark only in A's clear row.
