-- =============================================================================
-- 20260868 — Group chat invitations, friendship gate, blocked-message visibility
-- =============================================================================
--
-- Product rules (approved):
--   1) Invite only accepted friends who are unblocked both ways.
--   2) Do not silently insert invitees as active members.
--   3) Acceptance required before active membership.
--   4) Accept / Decline.
--   5) Pending invites grant no message/membership/notification access.
--   6) Block before accept cancels invitation and blocks acceptance.
--   7) Post-join blocks: keep memberships; hide blocked sender messages from
--      the blocker; do not disable the whole group.
--   8) Historical messages retained for moderation / non-blocked viewers.
--   9) Do not reveal that a user was blocked.
--
-- Final pre-deploy decisions (this file):
--   - Invitation expiry: 30 days from creation (expires_at set on insert).
--   - Duplicate pending invites: idempotent return of existing id (no raw unique error).
--   - Block cancel: AFTER INSERT + AFTER UPDATE OF blocker/blocked pair columns
--     (INSERT is the live path today; UPDATE is defensive; no-op metadata skips).
--   - add_group_members RETURNS integer = newly created invite count (iOS signature).
--   - Deploy order: apply / re-apply this migration before shipping invite-aware iOS.
--   - Idempotent: safe to re-run (CREATE OR REPLACE / IF NOT EXISTS); does not
--     rewrite existing memberships or message history.
--
-- Do NOT apply from the agent; review and apply deliberately.
-- Existing active memberships remain active (no retroactive pending conversion).
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Preflight
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.group_conversations') IS NULL THEN
    v_missing := v_missing || ARRAY['table group_conversations'];
  END IF;
  IF to_regclass('public.group_conversation_members') IS NULL THEN
    v_missing := v_missing || ARRAY['table group_conversation_members'];
  END IF;
  IF to_regclass('public.group_messages') IS NULL THEN
    v_missing := v_missing || ARRAY['table group_messages'];
  END IF;
  IF to_regclass('public.blocked_users') IS NULL THEN
    v_missing := v_missing || ARRAY['table blocked_users'];
  END IF;
  IF to_regclass('public.friendships') IS NULL THEN
    v_missing := v_missing || ARRAY['table friendships'];
  END IF;
  IF to_regclass('public.user_profiles') IS NULL THEN
    v_missing := v_missing || ARRAY['table user_profiles'];
  END IF;
  IF to_regprocedure('public.pickup_invite_users_are_friends(uuid, uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function pickup_invite_users_are_friends(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.pickup_invite_users_are_unblocked(uuid, uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function pickup_invite_users_are_unblocked(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.is_active_group_member(uuid, uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function is_active_group_member(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.group_active_member_count(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function group_active_member_count(uuid)'];
  END IF;
  IF to_regprocedure('public.group_member_can_read_message(uuid, uuid, timestamptz)') IS NULL THEN
    v_missing := v_missing || ARRAY['function group_member_can_read_message(uuid,uuid,timestamptz)'];
  END IF;
  IF to_regprocedure('public.create_group_conversation(text, uuid[])') IS NULL THEN
    v_missing := v_missing || ARRAY['function create_group_conversation(text,uuid[])'];
  END IF;
  IF to_regprocedure('public.add_group_members(uuid, uuid[])') IS NULL THEN
    v_missing := v_missing || ARRAY['function add_group_members(uuid,uuid[])'];
  END IF;
  IF to_regprocedure('public.get_group_inbox_summaries()') IS NULL THEN
    v_missing := v_missing || ARRAY['function get_group_inbox_summaries()'];
  END IF;
  IF to_regprocedure('public.send_group_message(uuid, text)') IS NULL THEN
    v_missing := v_missing || ARRAY['function send_group_message(uuid,text)'];
  END IF;
  IF to_regprocedure('public.remove_group_member(uuid, uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function remove_group_member(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.leave_group_conversation(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function leave_group_conversation(uuid)'];
  END IF;

  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION 'preflight failed: %', array_to_string(v_missing, ', ');
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 1) Invitation table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.group_conversation_invitations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES public.group_conversations(id) ON DELETE CASCADE,
  inviter_user_id uuid NOT NULL REFERENCES auth.users(id),
  invitee_user_id uuid NOT NULL REFERENCES auth.users(id),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'accepted', 'declined', 'cancelled', 'expired')),
  created_at timestamptz NOT NULL DEFAULT now(),
  responded_at timestamptz,
  cancelled_at timestamptz,
  expires_at timestamptz,
  CONSTRAINT group_conversation_invitations_no_self CHECK (inviter_user_id <> invitee_user_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_group_invitations_pending_pair
  ON public.group_conversation_invitations (conversation_id, invitee_user_id)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_group_invitations_invitee_pending
  ON public.group_conversation_invitations (invitee_user_id, created_at DESC)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_group_invitations_conversation_pending
  ON public.group_conversation_invitations (conversation_id, created_at DESC)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_group_invitations_inviter
  ON public.group_conversation_invitations (inviter_user_id, created_at DESC);

COMMENT ON TABLE public.group_conversation_invitations IS
  'Pending group membership consent. Invitees are NOT in group_conversation_members until accepted.';

ALTER TABLE public.group_conversation_invitations ENABLE ROW LEVEL SECURITY;

-- No direct client writes; SELECT only for invitee / inviter / active admin.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'group_conversation_invitations'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.group_conversation_invitations', r.policyname);
  END LOOP;
END $$;

CREATE POLICY "group_invitations_select_own_or_admin"
ON public.group_conversation_invitations
FOR SELECT
TO authenticated
USING (
  invitee_user_id = auth.uid()
  OR inviter_user_id = auth.uid()
  OR EXISTS (
    SELECT 1
    FROM public.group_conversation_members m
    WHERE m.conversation_id = group_conversation_invitations.conversation_id
      AND m.user_id = auth.uid()
      AND m.left_at IS NULL
      AND m.role = 'admin'
  )
);

REVOKE ALL ON TABLE public.group_conversation_invitations FROM PUBLIC;
REVOKE ALL ON TABLE public.group_conversation_invitations FROM anon;
REVOKE ALL ON TABLE public.group_conversation_invitations FROM authenticated;
GRANT SELECT ON TABLE public.group_conversation_invitations TO authenticated;
GRANT ALL ON TABLE public.group_conversation_invitations TO service_role;

-- ---------------------------------------------------------------------------
-- 2) Helpers — invite eligibility + blocked sender visibility
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.group_users_have_accepted_friendship(
  p_user_a uuid,
  p_user_b uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.pickup_invite_users_are_friends(p_user_a, p_user_b);
$$;

COMMENT ON FUNCTION public.group_users_have_accepted_friendship(uuid, uuid) IS
  'Accepted user↔user friendship. Never trusts client email/handle/role.';

REVOKE ALL ON FUNCTION public.group_users_have_accepted_friendship(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.group_users_have_accepted_friendship(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.group_users_have_accepted_friendship(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.group_users_have_accepted_friendship(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.group_users_are_either_direction_blocked(
  p_user_a uuid,
  p_user_b uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT NOT public.pickup_invite_users_are_unblocked(p_user_a, p_user_b);
$$;

REVOKE ALL ON FUNCTION public.group_users_are_either_direction_blocked(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.group_users_are_either_direction_blocked(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.group_users_are_either_direction_blocked(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.group_users_are_either_direction_blocked(uuid, uuid) TO service_role;

-- Invite eligibility: friendship + unblocked + active fan profile (not business/deleted).
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
    AND public.group_users_have_accepted_friendship(p_actor_user_id, p_candidate_user_id)
    AND public.pickup_invite_users_are_unblocked(p_actor_user_id, p_candidate_user_id);
$$;

COMMENT ON FUNCTION public.group_add_member_eligible(uuid, uuid) IS
  'Group invite eligibility: accepted friendship, unblocked both ways, active non-business profile. Admins cannot bypass.';

REVOKE ALL ON FUNCTION public.group_add_member_eligible(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.group_add_member_eligible(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.group_add_member_eligible(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.group_add_member_eligible(uuid, uuid) TO service_role;

-- Viewer may see a message from sender (system always visible; own messages always visible).
CREATE OR REPLACE FUNCTION public.group_viewer_can_see_sender_message(
  p_viewer_user_id uuid,
  p_sender_user_id uuid,
  p_message_type text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    p_viewer_user_id IS NOT NULL
    AND (
      lower(coalesce(p_message_type, 'text')) = 'system'
      OR p_sender_user_id IS NULL
      OR p_sender_user_id = p_viewer_user_id
      OR public.pickup_invite_users_are_unblocked(p_viewer_user_id, p_sender_user_id)
    );
$$;

COMMENT ON FUNCTION public.group_viewer_can_see_sender_message(uuid, uuid, text) IS
  'Per-viewer hide of blocked-peer text messages. System messages preserved. Does not delete rows.';

REVOKE ALL ON FUNCTION public.group_viewer_can_see_sender_message(uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.group_viewer_can_see_sender_message(uuid, uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.group_viewer_can_see_sender_message(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.group_viewer_can_see_sender_message(uuid, uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION public.is_active_group_admin(
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
    WHERE m.conversation_id = p_conversation_id
      AND m.user_id = p_user_id
      AND m.left_at IS NULL
      AND m.role = 'admin'
  );
$$;

REVOKE ALL ON FUNCTION public.is_active_group_admin(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_active_group_admin(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.is_active_group_admin(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_active_group_admin(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Message SELECT — membership window AND blocked-sender filter
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS "group_messages_select_membership_window" ON public.group_messages;

CREATE POLICY "group_messages_select_membership_window"
ON public.group_messages
FOR SELECT
TO authenticated
USING (
  public.group_member_can_read_message(conversation_id, auth.uid(), created_at)
  AND deleted_at IS NULL
  AND COALESCE(is_deleted, false) = false
  AND public.group_viewer_can_see_sender_message(auth.uid(), sender_id, message_type)
);

-- ---------------------------------------------------------------------------
-- 4) Cancel pending invitations when either party blocks the other
-- ---------------------------------------------------------------------------
-- blocked_users lifecycle (20260809 + ModerationService):
--   block   = INSERT row
--   unblock = DELETE row
--   re-block after unblock = INSERT again
-- There is no soft-delete / active flag and no authenticated UPDATE policy today.
-- Trigger covers INSERT and UPDATE so any future reactivation path that mutates
-- an existing row still cancels pending invitations (idempotent).

CREATE OR REPLACE FUNCTION public.cancel_group_invitations_for_block_pair()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.blocker_user_id IS NULL OR NEW.blocked_user_id IS NULL THEN
    RETURN NEW;
  END IF;

  UPDATE public.group_conversation_invitations
  SET
    status = 'cancelled',
    cancelled_at = now(),
    responded_at = coalesce(responded_at, now())
  WHERE status = 'pending'
    AND (
      (inviter_user_id = NEW.blocker_user_id AND invitee_user_id = NEW.blocked_user_id)
      OR (inviter_user_id = NEW.blocked_user_id AND invitee_user_id = NEW.blocker_user_id)
    );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cancel_group_invitations_on_block ON public.blocked_users;
DROP TRIGGER IF EXISTS trg_cancel_group_invitations_on_block_upd ON public.blocked_users;

CREATE TRIGGER trg_cancel_group_invitations_on_block
  AFTER INSERT ON public.blocked_users
  FOR EACH ROW
  EXECUTE FUNCTION public.cancel_group_invitations_for_block_pair();

-- Defensive UPDATE coverage for pair-identity changes (or future soft reactivation
-- that mutates blocker/blocked columns). Skips no-op / unrelated metadata updates
-- when the pair columns are unchanged. Idempotent; no client-visible block disclosure.
CREATE TRIGGER trg_cancel_group_invitations_on_block_upd
  AFTER UPDATE OF blocker_user_id, blocked_user_id ON public.blocked_users
  FOR EACH ROW
  WHEN (
    OLD.blocker_user_id IS DISTINCT FROM NEW.blocker_user_id
    OR OLD.blocked_user_id IS DISTINCT FROM NEW.blocked_user_id
  )
  EXECUTE FUNCTION public.cancel_group_invitations_for_block_pair();

REVOKE ALL ON FUNCTION public.cancel_group_invitations_for_block_pair() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancel_group_invitations_for_block_pair() FROM anon;
REVOKE ALL ON FUNCTION public.cancel_group_invitations_for_block_pair() FROM authenticated;

-- ---------------------------------------------------------------------------
-- 5) Internal: insert pending invitation (SECURITY DEFINER caller)
-- ---------------------------------------------------------------------------
-- Expiry policy: pending invitations expire 30 days after creation.
-- Idempotent: existing non-expired pending → return that id (no error, no dup event).
-- Active member → return NULL (caller treats as no-op).
-- Declined/cancelled/expired prior rows do not block a new pending invitation.

CREATE OR REPLACE FUNCTION public.group_insert_pending_invitation(
  p_conversation_id uuid,
  p_inviter_user_id uuid,
  p_invitee_user_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_existing uuid;
BEGIN
  IF NOT public.group_add_member_eligible(p_inviter_user_id, p_invitee_user_id) THEN
    RAISE EXCEPTION 'One or more invitees are not eligible.' USING ERRCODE = '42501';
  END IF;

  -- Already active: no invitation, no error (batch-friendly no-op).
  IF public.is_active_group_member(p_conversation_id, p_invitee_user_id) THEN
    RETURN NULL;
  END IF;

  -- Opportunistically expire any stale pending row for this pair before insert/lookup.
  UPDATE public.group_conversation_invitations
  SET status = 'expired', responded_at = coalesce(responded_at, now())
  WHERE conversation_id = p_conversation_id
    AND invitee_user_id = p_invitee_user_id
    AND status = 'pending'
    AND expires_at IS NOT NULL
    AND expires_at <= now();

  SELECT i.id
    INTO v_existing
  FROM public.group_conversation_invitations i
  WHERE i.conversation_id = p_conversation_id
    AND i.invitee_user_id = p_invitee_user_id
    AND i.status = 'pending'
    AND (i.expires_at IS NULL OR i.expires_at > now())
  LIMIT 1;

  IF v_existing IS NOT NULL THEN
    -- Idempotent: already invited.
    RETURN v_existing;
  END IF;

  INSERT INTO public.group_conversation_invitations (
    conversation_id, inviter_user_id, invitee_user_id, status, expires_at
  ) VALUES (
    p_conversation_id,
    p_inviter_user_id,
    p_invitee_user_id,
    'pending',
    now() + interval '30 days'
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.group_insert_pending_invitation(uuid, uuid, uuid) IS
  'Internal invite insert. Sets expires_at = now()+30d. Idempotent for existing pending; NULL if already an active member.';

REVOKE ALL ON FUNCTION public.group_insert_pending_invitation(uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.group_insert_pending_invitation(uuid, uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.group_insert_pending_invitation(uuid, uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.group_insert_pending_invitation(uuid, uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 6) create_group_conversation — creator admin; others get pending invitations
-- ---------------------------------------------------------------------------

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
    RAISE EXCEPTION 'A group requires invitations to at least two friends.';
  END IF;

  IF 1 + coalesce(array_length(v_unique, 1), 0) > 25 THEN
    RAISE EXCEPTION 'A group may have at most 25 active members.';
  END IF;

  FOREACH v_uid IN ARRAY v_unique LOOP
    IF NOT public.group_add_member_eligible(me, v_uid) THEN
      RAISE EXCEPTION 'One or more invitees are not eligible.';
    END IF;
  END LOOP;

  INSERT INTO public.group_conversations (title, created_by)
  VALUES (v_title, me)
  RETURNING id INTO v_id;

  -- Creator is the only immediate active member (admin).
  INSERT INTO public.group_conversation_members (conversation_id, user_id, role, joined_at, last_read_at)
  VALUES (v_id, me, 'admin', now(), now());

  FOREACH v_uid IN ARRAY v_unique LOOP
    PERFORM public.group_insert_pending_invitation(v_id, me, v_uid);
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
REVOKE ALL ON FUNCTION public.create_group_conversation(text, uuid[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.create_group_conversation(text, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_group_conversation(text, uuid[]) TO service_role;

COMMENT ON FUNCTION public.create_group_conversation(text, uuid[]) IS
  'Creates group with creator as sole active admin; selected friends receive pending invitations (30-day expiry; not membership).';

-- ---------------------------------------------------------------------------
-- 7) add_group_members — now creates invitations (iOS signature preserved)
-- ---------------------------------------------------------------------------

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
  v_new uuid[] := ARRAY[]::uuid[];
  v_invited int := 0;
  v_active int;
  v_pending int;
  v_id uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF NOT public.is_active_group_admin(p_conversation_id, me) THEN
    RAISE EXCEPTION 'Only active admins can invite members.';
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

  -- Expire stale pendings for capacity accuracy.
  UPDATE public.group_conversation_invitations
  SET status = 'expired', responded_at = coalesce(responded_at, now())
  WHERE conversation_id = p_conversation_id
    AND status = 'pending'
    AND expires_at IS NOT NULL
    AND expires_at <= now();

  v_active := public.group_active_member_count(p_conversation_id);

  SELECT count(*)::integer INTO v_pending
  FROM public.group_conversation_invitations i
  WHERE i.conversation_id = p_conversation_id
    AND i.status = 'pending'
    AND (i.expires_at IS NULL OR i.expires_at > now());

  FOREACH v_uid IN ARRAY v_unique LOOP
    IF public.is_active_group_member(p_conversation_id, v_uid) THEN
      CONTINUE; -- already_members (idempotent)
    END IF;
    IF EXISTS (
      SELECT 1
      FROM public.group_conversation_invitations i
      WHERE i.conversation_id = p_conversation_id
        AND i.invitee_user_id = v_uid
        AND i.status = 'pending'
        AND (i.expires_at IS NULL OR i.expires_at > now())
    ) THEN
      CONTINUE; -- already_pending (idempotent)
    END IF;
    -- Fail closed: do not partially invite when any remaining candidate is ineligible.
    IF NOT public.group_add_member_eligible(me, v_uid) THEN
      RAISE EXCEPTION 'One or more invitees are not eligible.' USING ERRCODE = '42501';
    END IF;
    v_new := array_append(v_new, v_uid);
  END LOOP;

  IF coalesce(array_length(v_new, 1), 0) = 0 THEN
    RETURN 0;
  END IF;

  IF v_active + v_pending + coalesce(array_length(v_new, 1), 0) > 25 THEN
    RAISE EXCEPTION 'A group may have at most 25 active members (including pending invitations).';
  END IF;

  FOREACH v_uid IN ARRAY v_new LOOP
    v_id := public.group_insert_pending_invitation(p_conversation_id, me, v_uid);
    IF v_id IS NOT NULL THEN
      v_invited := v_invited + 1;
    END IF;
  END LOOP;

  UPDATE public.group_conversations
  SET updated_at = now()
  WHERE id = p_conversation_id;

  RETURN v_invited;
END;
$$;

REVOKE ALL ON FUNCTION public.add_group_members(uuid, uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.add_group_members(uuid, uuid[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.add_group_members(uuid, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.add_group_members(uuid, uuid[]) TO service_role;

COMMENT ON FUNCTION public.add_group_members(uuid, uuid[]) IS
  'Admin invites accepted friends (pending invitations, 30-day expiry). '
  'Returns newly created invite count only. Already-active and already-pending are '
  'idempotent no-ops (return may be 0). Ineligible candidates raise a neutral error. '
  'Signature retained for iOS.';

-- ---------------------------------------------------------------------------
-- 8) Accept / decline / cancel invitation RPCs
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.accept_group_invitation(p_invitation_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_inv public.group_conversation_invitations%ROWTYPE;
  v_payload jsonb;
  v_display text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  SELECT * INTO v_inv
  FROM public.group_conversation_invitations
  WHERE id = p_invitation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invitation not found.' USING ERRCODE = 'P0002';
  END IF;

  IF v_inv.invitee_user_id <> me THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  IF v_inv.status = 'accepted' THEN
    -- Idempotent: already accepted.
    RETURN v_inv.conversation_id;
  END IF;

  IF v_inv.status <> 'pending' THEN
    RAISE EXCEPTION 'Invitation is no longer pending.';
  END IF;

  IF v_inv.expires_at IS NOT NULL AND v_inv.expires_at <= now() THEN
    UPDATE public.group_conversation_invitations
    SET status = 'expired', responded_at = now()
    WHERE id = v_inv.id;
    RAISE EXCEPTION 'Invitation has expired.';
  END IF;

  -- Re-check full eligibility at accept time (friendship, either-direction block,
  -- invitee profile active/non-business). Neutral error — do not disclose block.
  IF NOT public.group_add_member_eligible(v_inv.inviter_user_id, me) THEN
    UPDATE public.group_conversation_invitations
    SET status = 'cancelled', cancelled_at = now(), responded_at = now()
    WHERE id = v_inv.id AND status = 'pending';
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_conversations c
    WHERE c.id = v_inv.conversation_id AND c.is_active = true
  ) THEN
    UPDATE public.group_conversation_invitations
    SET status = 'cancelled', cancelled_at = now(), responded_at = now()
    WHERE id = v_inv.id AND status = 'pending';
    RAISE EXCEPTION 'Group is no longer available.';
  END IF;

  -- Inviter should still be an active member (admin or member) to keep invite valid.
  IF NOT public.is_active_group_member(v_inv.conversation_id, v_inv.inviter_user_id) THEN
    UPDATE public.group_conversation_invitations
    SET status = 'cancelled', cancelled_at = now(), responded_at = now()
    WHERE id = v_inv.id AND status = 'pending';
    RAISE EXCEPTION 'Invitation is no longer valid.';
  END IF;

  IF public.group_active_member_count(v_inv.conversation_id) >= 25 THEN
    RAISE EXCEPTION 'A group may have at most 25 active members.';
  END IF;

  -- Idempotent: already an active member (legacy direct-add or race).
  IF public.is_active_group_member(v_inv.conversation_id, me) THEN
    UPDATE public.group_conversation_invitations
    SET status = 'accepted', responded_at = now()
    WHERE id = v_inv.id AND status = 'pending';
    RETURN v_inv.conversation_id;
  END IF;

  INSERT INTO public.group_conversation_members (conversation_id, user_id, role, joined_at, last_read_at)
  VALUES (v_inv.conversation_id, me, 'member', now(), now())
  ON CONFLICT (conversation_id, user_id) DO UPDATE
    SET
      left_at = NULL,
      role = 'member',
      joined_at = now(),
      muted_until = NULL,
      last_read_at = now()
  WHERE public.group_conversation_members.left_at IS NOT NULL;

  UPDATE public.group_conversation_invitations
  SET status = 'accepted', responded_at = now()
  WHERE id = v_inv.id
    AND status = 'pending';

  SELECT COALESCE(NULLIF(btrim(up.display_name), ''), 'Fan')
    INTO v_display
  FROM public.user_profiles up
  WHERE up.id = me;

  v_payload := jsonb_build_object(
    'event', 'member_joined',
    'affected_user_id', me,
    'affected_display_name', v_display,
    'actor_user_id', v_inv.inviter_user_id
  );

  -- Idempotent-ish system message: one join event per acceptance transaction.
  INSERT INTO public.group_messages (
    conversation_id, sender_id, body, message_type, system_event, system_payload
  ) VALUES (
    v_inv.conversation_id,
    me,
    coalesce(v_display, 'Fan') || ' joined',
    'system',
    'member_joined',
    v_payload
  );

  UPDATE public.group_conversations
  SET
    last_message_at = now(),
    last_message_preview = coalesce(v_display, 'Fan') || ' joined',
    last_message_sender_id = me,
    last_message_type = 'system',
    last_system_event = 'member_joined',
    last_system_payload = v_payload,
    updated_at = now()
  WHERE id = v_inv.conversation_id;

  RETURN v_inv.conversation_id;
END;
$$;

REVOKE ALL ON FUNCTION public.accept_group_invitation(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.accept_group_invitation(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.accept_group_invitation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_group_invitation(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.decline_group_invitation(p_invitation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_inv public.group_conversation_invitations%ROWTYPE;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  SELECT * INTO v_inv
  FROM public.group_conversation_invitations
  WHERE id = p_invitation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invitation not found.' USING ERRCODE = 'P0002';
  END IF;

  IF v_inv.invitee_user_id <> me THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  IF v_inv.status IN ('declined', 'cancelled', 'expired') THEN
    RETURN; -- idempotent
  END IF;

  IF v_inv.status <> 'pending' THEN
    RAISE EXCEPTION 'Invitation is no longer pending.';
  END IF;

  UPDATE public.group_conversation_invitations
  SET status = 'declined', responded_at = now()
  WHERE id = v_inv.id AND status = 'pending';
END;
$$;

REVOKE ALL ON FUNCTION public.decline_group_invitation(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.decline_group_invitation(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.decline_group_invitation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.decline_group_invitation(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.cancel_group_invitation(p_invitation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_inv public.group_conversation_invitations%ROWTYPE;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  SELECT * INTO v_inv
  FROM public.group_conversation_invitations
  WHERE id = p_invitation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invitation not found.' USING ERRCODE = 'P0002';
  END IF;

  IF v_inv.status <> 'pending' THEN
    RETURN; -- idempotent
  END IF;

  IF v_inv.inviter_user_id <> me
     AND NOT public.is_active_group_admin(v_inv.conversation_id, me) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  UPDATE public.group_conversation_invitations
  SET status = 'cancelled', cancelled_at = now(), responded_at = now()
  WHERE id = v_inv.id AND status = 'pending';
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_group_invitation(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancel_group_invitation(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.cancel_group_invitation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_group_invitation(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 9) List invitations (invitee inbox + admin Group Info)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.list_pending_group_invitations_for_me()
RETURNS TABLE (
  invitation_id uuid,
  conversation_id uuid,
  group_title text,
  inviter_user_id uuid,
  created_at timestamptz,
  member_count integer
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Opportunistically mark expired rows so they drop out of badges/UI.
  UPDATE public.group_conversation_invitations
  SET status = 'expired', responded_at = coalesce(responded_at, now())
  WHERE invitee_user_id = auth.uid()
    AND status = 'pending'
    AND expires_at IS NOT NULL
    AND expires_at <= now();

  RETURN QUERY
  SELECT
    i.id AS invitation_id,
    i.conversation_id,
    c.title AS group_title,
    i.inviter_user_id,
    i.created_at,
    public.group_active_member_count(c.id) AS member_count
  FROM public.group_conversation_invitations i
  INNER JOIN public.group_conversations c ON c.id = i.conversation_id AND c.is_active = true
  WHERE i.invitee_user_id = auth.uid()
    AND i.status = 'pending'
    AND (i.expires_at IS NULL OR i.expires_at > now())
    AND public.pickup_invite_users_are_unblocked(i.inviter_user_id, auth.uid())
    AND public.group_users_have_accepted_friendship(i.inviter_user_id, auth.uid())
  ORDER BY i.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.list_pending_group_invitations_for_me() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_pending_group_invitations_for_me() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_pending_group_invitations_for_me() TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_pending_group_invitations_for_me() TO service_role;

CREATE OR REPLACE FUNCTION public.list_pending_group_invitations_for_conversation(
  p_conversation_id uuid
)
RETURNS TABLE (
  invitation_id uuid,
  invitee_user_id uuid,
  inviter_user_id uuid,
  created_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF NOT public.is_active_group_admin(p_conversation_id, auth.uid()) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  UPDATE public.group_conversation_invitations
  SET status = 'expired', responded_at = coalesce(responded_at, now())
  WHERE conversation_id = p_conversation_id
    AND status = 'pending'
    AND expires_at IS NOT NULL
    AND expires_at <= now();

  RETURN QUERY
  SELECT i.id, i.invitee_user_id, i.inviter_user_id, i.created_at
  FROM public.group_conversation_invitations i
  WHERE i.conversation_id = p_conversation_id
    AND i.status = 'pending'
    AND (i.expires_at IS NULL OR i.expires_at > now())
  ORDER BY i.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.list_pending_group_invitations_for_conversation(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_pending_group_invitations_for_conversation(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.list_pending_group_invitations_for_conversation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_pending_group_invitations_for_conversation(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 10) Inbox summaries — last message + unread respect blocked senders
-- ---------------------------------------------------------------------------

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
  ),
  visible_last AS (
    SELECT DISTINCT ON (gm.conversation_id)
      gm.conversation_id,
      gm.body,
      gm.sender_id,
      gm.created_at,
      gm.message_type,
      gm.system_event,
      gm.system_payload
    FROM public.group_messages gm
    INNER JOIN me ON true
    INNER JOIN public.group_conversation_members m
      ON m.conversation_id = gm.conversation_id
     AND m.user_id = me.uid
     AND m.left_at IS NULL
    WHERE gm.deleted_at IS NULL
      AND COALESCE(gm.is_deleted, false) = false
      AND gm.created_at >= m.joined_at
      AND (m.left_at IS NULL OR gm.created_at <= m.left_at)
      AND public.group_viewer_can_see_sender_message(me.uid, gm.sender_id, gm.message_type)
    ORDER BY gm.conversation_id, gm.created_at DESC, gm.id DESC
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
    CASE
      WHEN vl.conversation_id IS NOT NULL THEN vl.body
      WHEN public.group_viewer_can_see_sender_message(me.uid, c.last_message_sender_id, c.last_message_type)
        THEN c.last_message_preview
      ELSE NULL
    END AS last_message_body,
    CASE
      WHEN vl.conversation_id IS NOT NULL THEN vl.sender_id
      WHEN public.group_viewer_can_see_sender_message(me.uid, c.last_message_sender_id, c.last_message_type)
        THEN c.last_message_sender_id
      ELSE NULL
    END AS last_message_sender_id,
    CASE
      WHEN vl.conversation_id IS NOT NULL THEN vl.created_at
      WHEN public.group_viewer_can_see_sender_message(me.uid, c.last_message_sender_id, c.last_message_type)
        THEN c.last_message_at
      ELSE NULL
    END AS last_message_created_at,
    CASE
      WHEN vl.conversation_id IS NOT NULL THEN vl.message_type
      WHEN public.group_viewer_can_see_sender_message(me.uid, c.last_message_sender_id, c.last_message_type)
        THEN coalesce(c.last_message_type, 'text')
      ELSE NULL
    END AS last_message_type,
    CASE
      WHEN vl.conversation_id IS NOT NULL THEN vl.system_event
      WHEN public.group_viewer_can_see_sender_message(me.uid, c.last_message_sender_id, c.last_message_type)
        THEN c.last_system_event
      ELSE NULL
    END AS last_system_event,
    CASE
      WHEN vl.conversation_id IS NOT NULL THEN vl.system_payload
      WHEN public.group_viewer_can_see_sender_message(me.uid, c.last_message_sender_id, c.last_message_type)
        THEN c.last_system_payload
      ELSE NULL
    END AS last_system_payload,
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
        AND public.group_viewer_can_see_sender_message(me.uid, gm.sender_id, gm.message_type)
    ) AS unread_count,
    (m.muted_until IS NOT NULL AND m.muted_until > now()) AS is_muted
  FROM me
  INNER JOIN public.group_conversation_members m
    ON m.user_id = me.uid
   AND m.left_at IS NULL
  INNER JOIN public.group_conversations c
    ON c.id = m.conversation_id
   AND c.is_active = true
  LEFT JOIN visible_last vl ON vl.conversation_id = c.id
  ORDER BY coalesce(vl.created_at, c.last_message_at) DESC NULLS LAST, c.created_at DESC;
$$;

REVOKE ALL ON FUNCTION public.get_group_inbox_summaries() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_group_inbox_summaries() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_group_inbox_summaries() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_group_inbox_summaries() TO service_role;

-- ---------------------------------------------------------------------------
-- 11) send_group_message — still does NOT reject for peer blocks (group-wide)
--     Visibility is enforced on read / inbox / (future) push paths.
-- ---------------------------------------------------------------------------
-- (No body change required beyond documenting intent; existing membership gate remains.)

COMMENT ON FUNCTION public.send_group_message(uuid, text) IS
  'Active members may send. Peer blocks do not reject send (would disable the group). '
  'Blocked viewers hide the message via SELECT policy and inbox unread/preview filters.';

COMMIT;

-- =============================================================================
-- Pre-apply SELECT-only validation (manual — run against target DB first)
-- =============================================================================
-- SELECT to_regclass('public.group_conversations');
-- SELECT to_regclass('public.group_conversation_members');
-- SELECT to_regclass('public.group_messages');
-- SELECT to_regclass('public.blocked_users');
-- SELECT to_regclass('public.friendships');
-- SELECT to_regclass('public.user_profiles');
-- SELECT to_regprocedure('public.create_group_conversation(text,uuid[])');
-- SELECT to_regprocedure('public.add_group_members(uuid,uuid[])');
-- SELECT to_regprocedure('public.send_group_message(uuid,text)');
-- SELECT to_regprocedure('public.get_group_inbox_summaries()');
-- SELECT to_regprocedure('public.remove_group_member(uuid,uuid)');
-- SELECT to_regprocedure('public.leave_group_conversation(uuid)');
-- SELECT to_regprocedure('public.pickup_invite_users_are_friends(uuid,uuid)');
-- SELECT to_regprocedure('public.pickup_invite_users_are_unblocked(uuid,uuid)');
-- SELECT tgname FROM pg_trigger t
--   JOIN pg_class c ON c.oid = t.tgrelid
--   JOIN pg_namespace n ON n.oid = c.relnamespace
--  WHERE n.nspname = 'public' AND c.relname = 'group_conversation_members'
--    AND NOT tgisinternal;
-- -- Expect trg_group_membership_privileged_columns (20260866) present.
-- SELECT column_name FROM information_schema.columns
--  WHERE table_schema='public' AND table_name='blocked_users' ORDER BY 1;
-- -- Expect only blocker_user_id, blocked_user_id, created_at (no soft-delete).
--
-- =============================================================================
-- Post-apply SELECT-only validation (manual)
-- =============================================================================
-- SELECT to_regclass('public.group_conversation_invitations');
-- SELECT tgname FROM pg_trigger
--   WHERE tgname IN (
--     'trg_cancel_group_invitations_on_block',
--     'trg_cancel_group_invitations_on_block_upd'
--   );
-- SELECT polname FROM pg_policies WHERE tablename = 'group_messages';
-- SELECT proname FROM pg_proc WHERE proname IN (
--   'accept_group_invitation','decline_group_invitation','cancel_group_invitation',
--   'list_pending_group_invitations_for_me','group_viewer_can_see_sender_message',
--   'group_add_member_eligible','create_group_conversation','add_group_members',
--   'group_insert_pending_invitation'
-- );
-- SELECT grantee, privilege_type FROM information_schema.role_table_grants
--   WHERE table_name = 'group_conversation_invitations';
-- -- Expect authenticated SELECT only; no INSERT/UPDATE/DELETE for authenticated.
-- SELECT p.proname,
--   has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_exec
-- FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
-- WHERE n.nspname='public' AND p.proname IN (
--   'accept_group_invitation','decline_group_invitation','cancel_group_invitation',
--   'get_group_inbox_summaries','group_add_member_eligible',
--   'group_viewer_can_see_sender_message','group_insert_pending_invitation'
-- );
-- -- Expect anon_exec = false for all of the above.
-- SELECT pg_get_functiondef('public.group_add_member_eligible(uuid,uuid)'::regprocedure)
--   ILIKE '%group_users_have_accepted_friendship%' AS requires_friendship;
-- SELECT pg_get_functiondef('public.create_group_conversation(text,uuid[])'::regprocedure)
--   ILIKE '%group_insert_pending_invitation%' AS creates_invites_not_members;
-- SELECT pg_get_functiondef('public.group_insert_pending_invitation(uuid,uuid,uuid)'::regprocedure)
--   ILIKE '%30 days%' AS sets_30d_expiry;
-- SELECT pg_get_functiondef('public.accept_group_invitation(uuid)'::regprocedure)
--   ILIKE '%group_add_member_eligible%' AS accept_rechecks_eligibility;
-- SELECT pg_get_functiondef('public.get_group_inbox_summaries()'::regprocedure)
--   ILIKE '%group_viewer_can_see_sender_message%' AS inbox_filters_blocks;
-- SELECT qual FROM pg_policies
--  WHERE tablename='group_messages'
--    AND policyname='group_messages_select_membership_window';
-- -- Expect group_viewer_can_see_sender_message in qual.
-- SELECT COUNT(*) FROM public.group_conversation_members WHERE left_at IS NULL;
-- -- Active membership count should be unchanged by re-apply.
--
-- =============================================================================
-- Staging test matrix — see agent final report (32-item checklist)
-- =============================================================================
-- Rollback (manual — destructive; prefer forward-fix):
--   DROP TRIGGER IF EXISTS trg_cancel_group_invitations_on_block ON blocked_users;
--   DROP TRIGGER IF EXISTS trg_cancel_group_invitations_on_block_upd ON blocked_users;
--   DROP FUNCTION IF EXISTS public.cancel_group_invitations_for_block_pair();
--   DROP FUNCTION IF EXISTS public.accept_group_invitation(uuid);
--   DROP FUNCTION IF EXISTS public.decline_group_invitation(uuid);
--   DROP FUNCTION IF EXISTS public.cancel_group_invitation(uuid);
--   DROP FUNCTION IF EXISTS public.list_pending_group_invitations_for_me();
--   DROP FUNCTION IF EXISTS public.list_pending_group_invitations_for_conversation(uuid);
--   DROP FUNCTION IF EXISTS public.group_insert_pending_invitation(uuid,uuid,uuid);
--   DROP TABLE IF EXISTS public.group_conversation_invitations;
--   Restore prior create/add/inbox/message policy bodies from 20260863/20260856.
--   Do NOT drop memberships or messages.
