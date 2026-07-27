-- =============================================================================
-- 20260869 — Direct messages: require accepted friendship to send (Option B)
-- =============================================================================
--
-- Approved product rule (Option B):
--   1) Existing DM history remains visible after unfriending.
--   2) Without an accepted friendship: no new DM inserts, no push from new rows,
--      realtime cannot bypass the server check.
--   3) Re-friending restores the same conversation (no duplicate); history intact.
--   4) Blocking remains stronger than unfriending; do not reveal blocks.
--   5) History retained for participants (subject to block/privacy), moderation,
--      reports, and service_role.
--   6) Do not delete message history on unfriend.
--
-- Venue-scoped business threads (venue_id IS NOT NULL) keep existing venue rules
-- and do NOT require friendship (start_business_venue_conversation path).
--
-- Released iOS inserts via PostgREST into direct_messages; this migration hardens
-- direct_message_send_allowed so the existing INSERT RLS policy enforces Option B
-- without requiring a new send RPC. Safe to deploy before the companion iOS build.
--
-- Do NOT apply from the agent; review and apply deliberately.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Preflight
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.direct_messages') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.direct_messages'];
  END IF;
  IF to_regclass('public.direct_conversations') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.direct_conversations'];
  END IF;
  IF to_regclass('public.friendships') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.friendships'];
  END IF;
  IF to_regclass('public.blocked_users') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.blocked_users'];
  END IF;
  IF to_regclass('public.user_profiles') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.user_profiles'];
  END IF;
  IF to_regclass('public.user_bans') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.user_bans'];
  END IF;
  IF to_regclass('public.businesses') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.businesses'];
  END IF;

  IF to_regprocedure('public.direct_message_send_allowed(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.direct_message_send_allowed(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.is_direct_conversation_participant(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.is_direct_conversation_participant(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.direct_conversation_peer_auth_user_ids(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.direct_conversation_peer_auth_user_ids(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.pickup_invite_users_are_unblocked(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.pickup_invite_users_are_unblocked(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.remove_friend(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.remove_friend(uuid)'];
  END IF;

  IF to_regclass('public.direct_conversations') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'direct_conversations' AND column_name = 'venue_id'
    ) THEN
      v_missing := v_missing || ARRAY['column public.direct_conversations.venue_id'];
    END IF;
  END IF;

  IF to_regclass('public.friendships') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'friendships' AND column_name = 'status'
    ) THEN
      v_missing := v_missing || ARRAY['column public.friendships.status'];
    END IF;
  END IF;

  IF to_regclass('public.user_profiles') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'is_deleted'
    ) THEN
      v_missing := v_missing || ARRAY['column public.user_profiles.is_deleted'];
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'admin_status'
    ) THEN
      v_missing := v_missing || ARRAY['column public.user_profiles.admin_status'];
    END IF;
  END IF;

  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION
      '20260869 preflight failed; missing: %',
      array_to_string(v_missing, ', ');
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 1) Account eligibility for DM send (auth user profiles; business accounts OK)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.direct_dm_auth_user_is_message_eligible(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    p_user_id IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM public.user_profiles up
      WHERE up.id = p_user_id
        AND COALESCE(up.is_deleted, false) = false
        AND COALESCE(lower(trim(up.admin_status)), 'active') = 'active'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.user_bans ub
      WHERE ub.user_id = p_user_id
        AND public.is_user_ban_active(ub.expires_at, ub.lifted_at)
    );
$$;

COMMENT ON FUNCTION public.direct_dm_auth_user_is_message_eligible(uuid) IS
  'True when the auth user profile exists, is not deleted, is active, and is not under an active ban.';

REVOKE ALL ON FUNCTION public.direct_dm_auth_user_is_message_eligible(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.direct_dm_auth_user_is_message_eligible(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.direct_dm_auth_user_is_message_eligible(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.direct_dm_auth_user_is_message_eligible(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 2) Accepted friendship between conversation participants (friendship DMs only)
-- ---------------------------------------------------------------------------
-- Mirrors start_direct_conversation friendship branches (user↔user and
-- user↔business). Venue-scoped threads skip this check in send_allowed.

CREATE OR REPLACE FUNCTION public.direct_conversation_has_accepted_friendship_for_sender(
  p_conversation_id uuid,
  p_sender_auth_user_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_peer uuid;
  v_peer_business_ids uuid[] := '{}'::uuid[];
  v_owned_business_ids uuid[] := '{}'::uuid[];
BEGIN
  IF p_conversation_id IS NULL OR p_sender_auth_user_id IS NULL THEN
    RETURN false;
  END IF;

  -- Venue-scoped business DMs do not require friendship.
  IF EXISTS (
    SELECT 1
    FROM public.direct_conversations dc
    WHERE dc.id = p_conversation_id
      AND dc.venue_id IS NOT NULL
  ) THEN
    RETURN true;
  END IF;

  SELECT peer.peer_auth_user_id
    INTO v_peer
  FROM public.direct_conversation_peer_auth_user_ids(
    p_conversation_id,
    p_sender_auth_user_id
  ) AS peer(peer_auth_user_id)
  LIMIT 1;

  IF v_peer IS NULL THEN
    RETURN false;
  END IF;

  SELECT COALESCE(array_agg(b.id), '{}'::uuid[])
    INTO v_owned_business_ids
  FROM public.businesses b
  WHERE b.owner_user_id = p_sender_auth_user_id
    AND COALESCE(lower(trim(b.admin_status)), '') = 'active';

  SELECT COALESCE(array_agg(b.id), '{}'::uuid[])
    INTO v_peer_business_ids
  FROM public.businesses b
  WHERE b.owner_user_id = v_peer
    AND COALESCE(lower(trim(b.admin_status)), '') = 'active';

  RETURN EXISTS (
    SELECT 1
    FROM public.friendships f
    WHERE f.status = 'accepted'
      AND (
        (
          COALESCE(f.requester_entity_type, 'user') = 'user'
          AND COALESCE(f.addressee_entity_type, 'user') = 'user'
          AND (
            (f.requester_id = p_sender_auth_user_id AND f.addressee_id = v_peer)
            OR (f.requester_id = v_peer AND f.addressee_id = p_sender_auth_user_id)
          )
        )
        OR
        (
          COALESCE(f.requester_entity_type, 'user') = 'user'
          AND COALESCE(f.addressee_entity_type, 'user') = 'business'
          AND f.requester_id = p_sender_auth_user_id
          AND f.addressee_id = ANY (v_peer_business_ids)
        )
        OR
        (
          COALESCE(f.requester_entity_type, 'user') = 'business'
          AND COALESCE(f.addressee_entity_type, 'user') = 'user'
          AND f.requester_id = ANY (v_peer_business_ids)
          AND f.addressee_id = p_sender_auth_user_id
        )
        OR
        (
          COALESCE(f.requester_entity_type, 'user') = 'business'
          AND COALESCE(f.addressee_entity_type, 'user') = 'user'
          AND f.requester_id = ANY (v_owned_business_ids)
          AND f.addressee_id = v_peer
        )
        OR
        (
          COALESCE(f.requester_entity_type, 'user') = 'user'
          AND COALESCE(f.addressee_entity_type, 'user') = 'business'
          AND f.requester_id = v_peer
          AND f.addressee_id = ANY (v_owned_business_ids)
        )
      )
  );
END;
$$;

COMMENT ON FUNCTION public.direct_conversation_has_accepted_friendship_for_sender(uuid, uuid) IS
  'True for venue-scoped threads always; for friendship DMs, true only when an accepted friendship exists between the sender and peer (user↔user or user↔business).';

REVOKE ALL ON FUNCTION public.direct_conversation_has_accepted_friendship_for_sender(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.direct_conversation_has_accepted_friendship_for_sender(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.direct_conversation_has_accepted_friendship_for_sender(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.direct_conversation_has_accepted_friendship_for_sender(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Authoritative send gate — friendship + block + eligibility + venue rules
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
    AND public.direct_dm_auth_user_is_message_eligible(p_sender_auth_user_id)
    AND NOT EXISTS (
      SELECT 1
      FROM public.direct_conversation_peer_auth_user_ids(
        p_conversation_id,
        p_sender_auth_user_id
      ) AS peer(peer_auth_user_id)
      WHERE NOT public.direct_dm_auth_user_is_message_eligible(peer.peer_auth_user_id)
    )
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
    AND public.direct_conversation_has_accepted_friendship_for_sender(
      p_conversation_id,
      p_sender_auth_user_id
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
  'Option B send gate: participant + eligible accounts + either-direction unblock + accepted friendship (friendship DMs) + venue owner cold-DM rules. History SELECT is unaffected.';

REVOKE ALL ON FUNCTION public.direct_message_send_allowed(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.direct_message_send_allowed(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.direct_message_send_allowed(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.direct_message_send_allowed(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 4) Reaffirm INSERT RLS uses the helper (no policy body change required)
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS "direct_messages_insert_as_participant_sender" ON public.direct_messages;

CREATE POLICY "direct_messages_insert_as_participant_sender"
ON public.direct_messages
FOR INSERT
TO authenticated
WITH CHECK (
  sender_id = auth.uid()
  AND public.is_direct_conversation_participant(conversation_id, sender_id)
  AND public.direct_message_send_allowed(conversation_id, sender_id)
);

-- SELECT remains participant-only so history stays readable after unfriend.
-- (Policy body intentionally unchanged; documented here for Option B.)

-- ---------------------------------------------------------------------------
-- 5) Table grants — authenticated writes only through RLS; no anon access
-- ---------------------------------------------------------------------------

REVOKE ALL ON TABLE public.direct_messages FROM PUBLIC;
REVOKE ALL ON TABLE public.direct_messages FROM anon;
GRANT SELECT, INSERT, UPDATE ON TABLE public.direct_messages TO authenticated;
GRANT ALL ON TABLE public.direct_messages TO service_role;

REVOKE ALL ON TABLE public.direct_conversations FROM PUBLIC;
REVOKE ALL ON TABLE public.direct_conversations FROM anon;
GRANT SELECT, INSERT, UPDATE ON TABLE public.direct_conversations TO authenticated;
GRANT ALL ON TABLE public.direct_conversations TO service_role;

-- ---------------------------------------------------------------------------
-- 6) Compatibility: remove_friend_and_clear_conversation → non-destructive
-- ---------------------------------------------------------------------------
-- Legacy iOS may call this name first. Option B: unfriend only; preserve DM
-- history. Explicit "clear for me" remains a separate product (clear_direct_conversation).

CREATE OR REPLACE FUNCTION public.remove_friend_and_clear_conversation(p_friend_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Intentionally does NOT delete or hide direct_messages / direct_conversations.
  PERFORM public.remove_friend(p_friend_user_id);
END;
$$;

COMMENT ON FUNCTION public.remove_friend_and_clear_conversation(uuid) IS
  'Compatibility wrapper for legacy iOS. Option B: ends accepted friendship only; does not clear DM history. Prefer remove_friend for new clients.';

REVOKE ALL ON FUNCTION public.remove_friend_and_clear_conversation(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.remove_friend_and_clear_conversation(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.remove_friend_and_clear_conversation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_friend_and_clear_conversation(uuid) TO service_role;

COMMIT;

-- =============================================================================
-- SELECT-only validation (production-safe; do not mutate)
-- =============================================================================
-- SELECT pg_get_functiondef('public.direct_message_send_allowed(uuid,uuid)'::regprocedure)
--   ILIKE '%direct_conversation_has_accepted_friendship_for_sender%' AS friendship_gated;
-- SELECT pg_get_functiondef('public.remove_friend_and_clear_conversation(uuid)'::regprocedure)
--   ILIKE '%remove_friend%' AND pg_get_functiondef('public.remove_friend_and_clear_conversation(uuid)'::regprocedure)
--   NOT ILIKE '%DELETE FROM public.direct_messages%' AS non_destructive_unfriend_wrapper;
-- SELECT grantee, privilege_type FROM information_schema.role_table_grants
--   WHERE table_schema = 'public' AND table_name = 'direct_messages'
--     AND grantee IN ('anon', 'authenticated', 'service_role')
--   ORDER BY grantee, privilege_type;
-- =============================================================================
-- Rollback (manual):
--   Restore direct_message_send_allowed body from 20260839.
--   DROP FUNCTION public.direct_conversation_has_accepted_friendship_for_sender(uuid,uuid);
--   DROP FUNCTION public.direct_dm_auth_user_is_message_eligible(uuid);
--   DROP FUNCTION public.remove_friend_and_clear_conversation(uuid); -- if unused
--   Re-create INSERT policy from 20260809 (same WITH CHECK shape).
-- =============================================================================
