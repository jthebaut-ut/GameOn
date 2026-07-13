-- Fan-initiated business venue DMs: venue-scoped direct_conversations without friendships.
-- Preserves existing fan↔fan and friendship-gated business DM behavior.

-- ---------------------------------------------------------------------------
-- 1) direct_conversations: venue scope columns
-- ---------------------------------------------------------------------------
ALTER TABLE public.direct_conversations
  ADD COLUMN IF NOT EXISTS business_id uuid REFERENCES public.businesses(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS venue_id uuid REFERENCES public.venues(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS fan_initiated boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.direct_conversations.business_id IS
  'Set for fan-initiated venue-scoped business DMs.';
COMMENT ON COLUMN public.direct_conversations.venue_id IS
  'Specific venue the fan chose to contact; multiple rows may share user_a_id/user_b_id per venue.';
COMMENT ON COLUMN public.direct_conversations.fan_initiated IS
  'True when a fan opened a business venue thread; business owners may reply but cannot cold-start these threads.';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'direct_conversations_venue_scope_ck'
  ) THEN
    ALTER TABLE public.direct_conversations
      ADD CONSTRAINT direct_conversations_venue_scope_ck CHECK (
        (venue_id IS NULL AND business_id IS NULL)
        OR (venue_id IS NOT NULL AND business_id IS NOT NULL)
      );
  END IF;
END $$;

-- Allow multiple fan↔owner threads when venue_id differs; keep one friend DM per auth pair.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT c.conname
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'public'
      AND t.relname = 'direct_conversations'
      AND c.contype = 'u'
      AND pg_get_constraintdef(c.oid) ILIKE '%user_a_id%'
      AND pg_get_constraintdef(c.oid) ILIKE '%user_b_id%'
      AND pg_get_constraintdef(c.oid) NOT ILIKE '%venue_id%'
  LOOP
    EXECUTE format('ALTER TABLE public.direct_conversations DROP CONSTRAINT IF EXISTS %I', r.conname);
  END LOOP;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS direct_conversations_friend_pair_uniq
  ON public.direct_conversations (user_a_id, user_b_id)
  WHERE venue_id IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS direct_conversations_business_venue_pair_uniq
  ON public.direct_conversations (user_a_id, user_b_id, business_id, venue_id)
  WHERE venue_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS direct_conversations_venue_inbox_idx
  ON public.direct_conversations (venue_id)
  WHERE venue_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2) Business owner cold-DM guard on venue-scoped threads
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.direct_message_send_allowed(
  p_conversation_id uuid,
  p_sender_auth_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    p_conversation_id IS NOT NULL
    AND p_sender_auth_user_id IS NOT NULL
    AND public.is_direct_conversation_participant(p_conversation_id, p_sender_auth_user_id)
    AND NOT EXISTS (
      SELECT 1
      FROM public.direct_conversation_peer_auth_user_ids(
        p_conversation_id,
        p_sender_auth_user_id
      ) AS peer(peer_auth_user_id)
      WHERE NOT public.pickup_invite_users_are_unblocked(
        p_sender_auth_user_id,
        peer.peer_auth_user_id
      )
    )
    AND (
      SELECT
        CASE
          WHEN dc.venue_id IS NULL THEN true
          WHEN b.owner_user_id IS DISTINCT FROM p_sender_auth_user_id THEN true
          WHEN dc.fan_initiated THEN true
          ELSE EXISTS (
            SELECT 1
            FROM public.direct_messages dm
            WHERE dm.conversation_id = dc.id
              AND dm.sender_id IN (dc.user_a_id, dc.user_b_id)
              AND dm.sender_id <> p_sender_auth_user_id
              AND dm.deleted_at IS NULL
              AND COALESCE(dm.is_deleted, false) = false
            LIMIT 1
          )
        END
      FROM public.direct_conversations dc
      LEFT JOIN public.businesses b ON b.id = dc.business_id
      WHERE dc.id = p_conversation_id
    );
$$;

COMMENT ON FUNCTION public.direct_message_send_allowed(uuid, uuid) IS
  'Participant + block check. Venue-scoped business threads require fan_initiated or an existing peer message before the business owner may send.';

-- ---------------------------------------------------------------------------
-- 3) Fan-initiated venue conversation RPC (no friendships)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.start_business_venue_conversation(
  p_business_id uuid,
  p_venue_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  owner_user_id uuid;
  cid uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF p_business_id IS NULL OR p_venue_id IS NULL THEN
    RAISE EXCEPTION 'Business and venue are required.';
  END IF;

  SELECT b.owner_user_id
    INTO owner_user_id
  FROM public.businesses b
  WHERE b.id = p_business_id
    AND COALESCE(lower(trim(b.admin_status)), '') = 'active'
    AND b.owner_user_id IS NOT NULL
  LIMIT 1;

  IF owner_user_id IS NULL THEN
    RAISE EXCEPTION 'Business not found.';
  END IF;

  IF owner_user_id = me THEN
    RAISE EXCEPTION 'Business owners cannot start fan venue conversations.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.venues v
    WHERE v.id = p_venue_id
      AND v.business_id = p_business_id
      AND COALESCE(lower(trim(v.admin_status)), '') = 'active'
  ) THEN
    RAISE EXCEPTION 'Venue not available for this business.';
  END IF;

  IF NOT public.pickup_invite_users_are_unblocked(me, owner_user_id) THEN
    RAISE EXCEPTION 'You cannot message this business.';
  END IF;

  SELECT dc.id INTO cid
  FROM public.direct_conversations dc
  WHERE dc.business_id = p_business_id
    AND dc.venue_id = p_venue_id
    AND (
      (dc.user_a_id = me AND dc.user_b_id = owner_user_id)
      OR (dc.user_b_id = me AND dc.user_a_id = owner_user_id)
    )
  LIMIT 1;

  IF cid IS NOT NULL THEN
    RETURN cid;
  END IF;

  INSERT INTO public.direct_conversations (
    user_a_id,
    user_b_id,
    business_id,
    venue_id,
    fan_initiated
  )
  VALUES (
    LEAST(me, owner_user_id),
    GREATEST(me, owner_user_id),
    p_business_id,
    p_venue_id,
    true
  )
  RETURNING id INTO cid;

  RETURN cid;
END;
$$;

COMMENT ON FUNCTION public.start_business_venue_conversation(uuid, uuid) IS
  'Fan opens or resumes a venue-scoped DM with a business owner. No friendship row required. Business owners cannot call this RPC.';

REVOKE ALL ON FUNCTION public.start_business_venue_conversation(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.start_business_venue_conversation(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.start_business_venue_conversation(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 4) Inbox summaries: include venue-scoped fan-initiated business threads
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
  )
  SELECT
    base.conversation_id,
    base.friend_user_id,
    CASE
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
          'Player'
        )
    END AS friend_display_name,
    CASE
      WHEN base.venue_id IS NOT NULL
        OR COALESCE(target_biz.friend_is_business, biz.friend_is_business, venue_biz.friend_is_business, FALSE)
      THEN NULL
      ELSE up.avatar_url
    END AS friend_avatar_url,
    CASE
      WHEN base.venue_id IS NOT NULL
        OR COALESCE(target_biz.friend_is_business, biz.friend_is_business, venue_biz.friend_is_business, FALSE)
      THEN NULL
      ELSE up.avatar_thumbnail_url
    END AS friend_avatar_thumbnail_url,
    COALESCE(
      target_biz.friend_email,
      biz.friend_email,
      venue_biz.friend_email,
      NULLIF(lower(trim(up.email)), '')
    ) AS friend_email,
    (
      base.venue_id IS NOT NULL
      OR COALESCE(target_biz.friend_is_business, biz.friend_is_business, venue_biz.friend_is_business, FALSE)
    ) AS friend_is_business,
    COALESCE(
      target_biz.friend_business_display_name,
      biz.friend_business_display_name,
      venue_biz.friend_business_display_name
    ) AS friend_business_display_name,
    base.venue_id,
    NULLIF(trim(v.venue_name), '') AS venue_name,
    COALESCE(
      NULLIF(trim(v.formatted_address), ''),
      NULLIF(trim(concat_ws(', ', NULLIF(trim(v.city), ''), NULLIF(trim(v.state), ''))), ''),
      NULLIF(trim(v.address), '')
    ) AS venue_location_line,
    latest_dm.body AS last_message_body,
    latest_dm.sender_id AS last_message_sender_id,
    latest_dm.created_at AS last_message_created_at,
    COALESCE(unread.unread_count, 0) AS unread_count
  FROM combined_base base
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
  ) venue_biz ON base.venue_id IS NOT NULL
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
  LEFT JOIN LATERAL (
    SELECT dm.body, dm.sender_id, dm.created_at
    FROM public.direct_messages dm
    WHERE dm.conversation_id = base.conversation_id
      AND dm.deleted_at IS NULL
      AND COALESCE(dm.is_deleted, FALSE) = FALSE
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
  ) unread ON TRUE
  WHERE (SELECT uid FROM me) IS NOT NULL
  ORDER BY latest_dm.created_at DESC NULLS LAST, base.conversation_id;
$$;

COMMENT ON FUNCTION public.get_dm_inbox_summaries() IS
  'DM inbox rows for friendship-backed threads and fan-initiated business venue threads (venue context fields included).';

REVOKE ALL ON FUNCTION public.get_dm_inbox_summaries() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_dm_inbox_summaries() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_dm_inbox_summaries() TO service_role;
