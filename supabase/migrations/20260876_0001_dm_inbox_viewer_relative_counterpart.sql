-- Viewer-relative DM inbox counterparts for venue-scoped business threads.
-- When the authenticated viewer owns the conversation's business, the counterpart
-- is the fan participant (identity fields), not the viewer's own venue/business.
-- Fan viewers of the same thread continue to see venue/business identity.

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
  'DM inbox rows with viewer-relative counterparts: fans see venue/business peers; business owners see fan peers for venue threads.';

REVOKE ALL ON FUNCTION public.get_dm_inbox_summaries() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_dm_inbox_summaries() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_dm_inbox_summaries() TO service_role;
