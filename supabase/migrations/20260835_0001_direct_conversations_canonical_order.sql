-- Fix direct_conversations_order_ck on user-user DM creation.
-- Canonical insert order: user_a_id = LEAST(me, peer), user_b_id = GREATEST(me, peer).
-- Symmetric pre-insert lookup and business conversation branches unchanged.

CREATE OR REPLACE FUNCTION public.start_direct_conversation(p_friend_user_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  peer_user_id uuid := p_friend_user_id;
  peer_business_owner_user_id uuid;
  peer_business_id uuid;
  peer_business_ids uuid[] := '{}'::uuid[];
  owned_business_ids uuid[] := '{}'::uuid[];
  cid uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF p_friend_user_id IS NULL THEN
    RAISE EXCEPTION 'Friend user id is required.';
  END IF;

  SELECT b.id, b.owner_user_id
    INTO peer_business_id, peer_business_owner_user_id
  FROM public.businesses b
  WHERE b.id = p_friend_user_id
    AND COALESCE(lower(trim(b.admin_status)), '') = 'active'
    AND b.owner_user_id IS NOT NULL
  LIMIT 1;

  IF peer_business_owner_user_id IS NOT NULL THEN
    peer_user_id := peer_business_owner_user_id;
  END IF;

  SELECT COALESCE(array_agg(b.id), '{}'::uuid[])
    INTO owned_business_ids
  FROM public.businesses b
  WHERE b.owner_user_id = me
    AND COALESCE(lower(trim(b.admin_status)), '') = 'active';

  SELECT COALESCE(array_agg(b.id), '{}'::uuid[])
    INTO peer_business_ids
  FROM public.businesses b
  WHERE b.owner_user_id = peer_user_id
    AND COALESCE(lower(trim(b.admin_status)), '') = 'active';

  IF peer_user_id IS NULL OR peer_user_id = me THEN
    RAISE EXCEPTION 'You cannot message yourself.';
  END IF;

  IF NOT public.pickup_invite_users_are_unblocked(me, peer_user_id) THEN
    RAISE EXCEPTION 'You cannot message this user.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.friendships f
    WHERE f.status = 'accepted'
      AND (
        -- Regular user <-> user friendship.
        (
          COALESCE(f.requester_entity_type, 'user') = 'user'
          AND COALESCE(f.addressee_entity_type, 'user') = 'user'
          AND (
            (f.requester_id = me AND f.addressee_id = peer_user_id)
            OR (f.requester_id = peer_user_id AND f.addressee_id = me)
          )
        )
        OR
        -- Signed-in user messaging a business; p_friend_user_id may be the business id
        -- or the owner's auth id from the repaired inbox RPC.
        (
          COALESCE(f.requester_entity_type, 'user') = 'user'
          AND COALESCE(f.addressee_entity_type, 'user') = 'business'
          AND f.requester_id = me
          AND f.addressee_id = ANY(peer_business_ids)
        )
        OR
        (
          COALESCE(f.requester_entity_type, 'user') = 'business'
          AND COALESCE(f.addressee_entity_type, 'user') = 'user'
          AND f.requester_id = ANY(peer_business_ids)
          AND f.addressee_id = me
        )
        OR
        -- Business owner messaging an accepted fan from a business-owned friendship.
        (
          COALESCE(f.requester_entity_type, 'user') = 'business'
          AND COALESCE(f.addressee_entity_type, 'user') = 'user'
          AND f.requester_id = ANY(owned_business_ids)
          AND f.addressee_id = peer_user_id
        )
        OR
        (
          COALESCE(f.requester_entity_type, 'user') = 'user'
          AND COALESCE(f.addressee_entity_type, 'user') = 'business'
          AND f.requester_id = peer_user_id
          AND f.addressee_id = ANY(owned_business_ids)
        )
      )
  ) THEN
    RAISE EXCEPTION 'You can only message accepted friends.';
  END IF;

  SELECT dc.id INTO cid
  FROM public.direct_conversations dc
  WHERE
    (dc.user_a_id = me AND dc.user_b_id = peer_user_id)
    OR (dc.user_b_id = me AND dc.user_a_id = peer_user_id)
    OR (dc.user_a_id = me AND dc.user_b_id = ANY(peer_business_ids))
    OR (dc.user_b_id = me AND dc.user_a_id = ANY(peer_business_ids))
    OR (dc.user_a_id = peer_user_id AND dc.user_b_id = ANY(owned_business_ids))
    OR (dc.user_b_id = peer_user_id AND dc.user_a_id = ANY(owned_business_ids))
  ORDER BY
    CASE
      WHEN (dc.user_a_id = me AND dc.user_b_id = peer_user_id)
        OR (dc.user_b_id = me AND dc.user_a_id = peer_user_id)
      THEN 0
      ELSE 1
    END
  LIMIT 1;

  IF cid IS NOT NULL THEN
    RETURN cid;
  END IF;

  BEGIN
    INSERT INTO public.direct_conversations (user_a_id, user_b_id)
    VALUES (LEAST(me, peer_user_id), GREATEST(me, peer_user_id))
    RETURNING id INTO cid;
  EXCEPTION
    WHEN unique_violation THEN
      SELECT dc.id INTO cid
      FROM public.direct_conversations dc
      WHERE (dc.user_a_id = me AND dc.user_b_id = peer_user_id)
         OR (dc.user_b_id = me AND dc.user_a_id = peer_user_id)
      LIMIT 1;
    WHEN check_violation THEN
      SELECT dc.id INTO cid
      FROM public.direct_conversations dc
      WHERE (dc.user_a_id = me AND dc.user_b_id = peer_user_id)
         OR (dc.user_b_id = me AND dc.user_a_id = peer_user_id)
      LIMIT 1;
  END;

  RETURN cid;
END;
$$;

COMMENT ON FUNCTION public.start_direct_conversation(uuid) IS
  'Starts or returns a 1:1 DM conversation. Business friendships resolve businesses.id to owner auth ids for RLS/realtime. Blocked users cannot start new conversations. User-user rows use canonical UUID order (LEAST/GREATEST).';

REVOKE ALL ON FUNCTION public.start_direct_conversation(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.start_direct_conversation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.start_direct_conversation(uuid) TO service_role;
