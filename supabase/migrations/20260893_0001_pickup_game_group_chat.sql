-- =============================================================================
-- 20260893_0001_pickup_game_group_chat.sql
-- REVIEW ONLY — do NOT apply to the linked production project from this change set.
--
-- Private pickup-game chat: one group_conversations row per pickup game.
-- Membership is derived from pickup_games.creator_user_id ∪ approved join requests.
-- Reuses group_messages / group realtime / unread / reports. Does NOT modify DM tables.
-- =============================================================================

-- Preflight: required foundation objects.
DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.pickup_games') IS NULL THEN
    v_missing := v_missing || ARRAY['table pickup_games'];
  END IF;
  IF to_regclass('public.pickup_game_requests') IS NULL THEN
    v_missing := v_missing || ARRAY['table pickup_game_requests'];
  END IF;
  IF to_regclass('public.group_conversations') IS NULL THEN
    v_missing := v_missing || ARRAY['table group_conversations'];
  END IF;
  IF to_regclass('public.group_conversation_members') IS NULL THEN
    v_missing := v_missing || ARRAY['table group_conversation_members'];
  END IF;
  IF to_regclass('public.group_messages') IS NULL THEN
    v_missing := v_missing || ARRAY['table group_messages'];
  END IF;
  IF to_regprocedure('public.is_active_group_member(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function is_active_group_member(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.assert_age_access_allows_social(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function assert_age_access_allows_social(uuid)'];
  END IF;
  IF to_regprocedure('public.age_access_enforcement_mode()') IS NULL THEN
    v_missing := v_missing || ARRAY['function age_access_enforcement_mode()'];
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'pickup_games' AND column_name = 'archived_at'
  ) THEN
    v_missing := v_missing || ARRAY['column pickup_games.archived_at'];
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'pickup_games' AND column_name = 'remove_after_at'
  ) THEN
    v_missing := v_missing || ARRAY['column pickup_games.remove_after_at'];
  END IF;
  IF coalesce(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION '20260893 preflight failed: missing %', array_to_string(v_missing, ', ');
  END IF;
END $$;

-- =============================================================================
-- 1) Schema: link group conversations to pickup games (nullable for social groups)
-- =============================================================================

ALTER TABLE public.group_conversations
  ADD COLUMN IF NOT EXISTS pickup_game_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'group_conversations_pickup_game_id_fkey'
  ) THEN
    ALTER TABLE public.group_conversations
      ADD CONSTRAINT group_conversations_pickup_game_id_fkey
      FOREIGN KEY (pickup_game_id)
      REFERENCES public.pickup_games (id)
      ON DELETE SET NULL;
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS group_conversations_pickup_game_id_uidx
  ON public.group_conversations (pickup_game_id)
  WHERE pickup_game_id IS NOT NULL;

COMMENT ON COLUMN public.group_conversations.pickup_game_id IS
  'When set, this conversation is the private chat for that pickup game. '
  'Membership must be synced from organizer + approved joiners only.';

-- =============================================================================
-- 2) Authorization helpers (authoritative; never trust client membership claims)
-- =============================================================================
-- Chat-live game predicate (fail-closed):
--   status must be exactly 'active' (canonical: active|removed|expired; NOT NULL)
--   archived_at must be NULL (20260883 archival; status may still be 'active')
--   remove_after_at must be null or still in the future
-- Do NOT coalesce NULL/empty status to 'active'.

CREATE OR REPLACE FUNCTION public.pickup_game_is_chat_live(p_pickup_game_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.pickup_games g
    WHERE g.id = p_pickup_game_id
      AND lower(btrim(g.status)) = 'active'
      AND g.archived_at IS NULL
      AND (g.remove_after_at IS NULL OR g.remove_after_at > now())
  );
$$;

COMMENT ON FUNCTION public.pickup_game_is_chat_live(uuid) IS
  'True when a pickup game may host chat: status=active, not archived, not past remove_after_at.';

REVOKE ALL ON FUNCTION public.pickup_game_is_chat_live(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pickup_game_is_chat_live(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.pickup_game_is_chat_live(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.pickup_game_is_chat_live(uuid) TO service_role;

-- Internal age check for roster mirroring. Unlike age_access_allows_social, this may
-- evaluate arbitrary user ids (sync runs under an organizer JWT / DEFINER context).
-- Not granted to authenticated — prevents cross-user age probing.
CREATE OR REPLACE FUNCTION public.pickup_game_chat_member_age_ok(p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status text;
  v_policy text;
  v_checked_at timestamptz;
  v_mode text;
  v_current_policy text;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT
    coalesce(up.age_access_status, 'unknown'),
    nullif(btrim(coalesce(up.age_policy_version, '')), ''),
    up.age_checked_at
  INTO v_status, v_policy, v_checked_at
  FROM public.user_profiles up
  WHERE up.id = p_user_id;

  v_mode := public.age_access_enforcement_mode();

  IF NOT FOUND THEN
    RETURN v_mode <> 'require_eligible';
  END IF;

  IF v_status = 'blocked_under_13' THEN
    RETURN false;
  END IF;

  IF v_mode = 'require_eligible' THEN
    v_current_policy := public.age_access_current_policy_version();
    RETURN v_status = 'eligible'
       AND v_policy IS NOT NULL
       AND v_policy = v_current_policy
       AND v_checked_at IS NOT NULL;
  END IF;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.pickup_game_chat_member_age_ok(uuid) IS
  'Internal roster age gate for pickup chat sync. Mirrors age_access_allows_social without cross-user JWT binding.';

REVOKE ALL ON FUNCTION public.pickup_game_chat_member_age_ok(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pickup_game_chat_member_age_ok(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.pickup_game_chat_member_age_ok(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.pickup_game_chat_member_age_ok(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.is_pickup_game_chat_authorized(
  p_pickup_game_id uuid,
  p_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    p_pickup_game_id IS NOT NULL
    AND p_user_id IS NOT NULL
    AND public.pickup_game_is_chat_live(p_pickup_game_id)
    AND EXISTS (
      SELECT 1
      FROM public.pickup_games g
      WHERE g.id = p_pickup_game_id
        AND (
          g.creator_user_id = p_user_id
          OR EXISTS (
            SELECT 1
            FROM public.pickup_game_requests r
            WHERE r.pickup_game_id = g.id
              AND r.requester_user_id = p_user_id
              AND lower(btrim(r.status)) = 'approved'
          )
        )
    );
$$;

COMMENT ON FUNCTION public.is_pickup_game_chat_authorized(uuid, uuid) IS
  'True when user is the pickup organizer or an approved joiner of a chat-live pickup game.';

REVOKE ALL ON FUNCTION public.is_pickup_game_chat_authorized(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_pickup_game_chat_authorized(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.is_pickup_game_chat_authorized(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_pickup_game_chat_authorized(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.pickup_game_chat_authorized_user_ids(
  p_pickup_game_id uuid
)
RETURNS TABLE (user_id uuid)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT g.creator_user_id AS user_id
  FROM public.pickup_games g
  WHERE g.id = p_pickup_game_id
    AND public.pickup_game_is_chat_live(p_pickup_game_id)
  UNION
  SELECT r.requester_user_id AS user_id
  FROM public.pickup_game_requests r
  WHERE r.pickup_game_id = p_pickup_game_id
    AND lower(btrim(r.status)) = 'approved'
    AND public.pickup_game_is_chat_live(p_pickup_game_id);
$$;

COMMENT ON FUNCTION public.pickup_game_chat_authorized_user_ids(uuid) IS
  'Authoritative chat roster: organizer ∪ approved joiners for a chat-live pickup game.';

REVOKE ALL ON FUNCTION public.pickup_game_chat_authorized_user_ids(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pickup_game_chat_authorized_user_ids(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.pickup_game_chat_authorized_user_ids(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.pickup_game_chat_authorized_user_ids(uuid) TO service_role;

-- =============================================================================
-- 3) Membership sync (soft-leave on revoke; do not delete message history)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.sync_pickup_game_group_membership(
  p_pickup_game_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_conversation_id uuid;
  v_creator uuid;
  v_game_status text;
  v_archived_at timestamptz;
  v_remove_after_at timestamptz;
  v_chat_live boolean;
  v_title text;
  v_uid uuid;
  v_authorized uuid[] := ARRAY[]::uuid[];
BEGIN
  SELECT
    g.creator_user_id,
    lower(btrim(g.status)),
    g.archived_at,
    g.remove_after_at,
    left(
      nullif(
        btrim(
          coalesce(
            nullif(btrim(coalesce(g.title, '')), ''),
            nullif(btrim(coalesce(g.sport, '')), '') || ' pickup',
            'Pickup game'
          )
        ),
        ''
      ),
      60
    )
  INTO v_creator, v_game_status, v_archived_at, v_remove_after_at, v_title
  FROM public.pickup_games g
  WHERE g.id = p_pickup_game_id;

  IF v_creator IS NULL THEN
    RAISE EXCEPTION 'Pickup game not found.';
  END IF;

  v_chat_live := (
    v_game_status = 'active'
    AND v_archived_at IS NULL
    AND (v_remove_after_at IS NULL OR v_remove_after_at > now())
  );

  SELECT c.id INTO v_conversation_id
  FROM public.group_conversations c
  WHERE c.pickup_game_id = p_pickup_game_id
  LIMIT 1;

  -- No chat yet and game is not chat-live → nothing to sync.
  IF v_conversation_id IS NULL AND NOT v_chat_live THEN
    RETURN NULL;
  END IF;

  IF v_conversation_id IS NULL THEN
    BEGIN
      INSERT INTO public.group_conversations (
        title,
        created_by,
        pickup_game_id,
        is_active
      ) VALUES (
        coalesce(v_title, 'Pickup game'),
        v_creator,
        p_pickup_game_id,
        true
      )
      RETURNING id INTO v_conversation_id;

      INSERT INTO public.group_conversation_members (
        conversation_id, user_id, role, joined_at, last_read_at
      ) VALUES (
        v_conversation_id, v_creator, 'admin', now(), now()
      );

      INSERT INTO public.group_messages (
        conversation_id, sender_id, body, message_type, system_event
      ) VALUES (
        v_conversation_id,
        v_creator,
        'Pickup game chat created',
        'system',
        'group_created'
      );

      UPDATE public.group_conversations
      SET
        last_message_at = now(),
        last_message_preview = 'Pickup game chat created',
        last_message_sender_id = v_creator,
        last_message_type = 'system',
        updated_at = now()
      WHERE id = v_conversation_id;
    EXCEPTION
      WHEN unique_violation THEN
        -- Concurrent first-open: another session created the row; reuse it.
        SELECT c.id INTO v_conversation_id
        FROM public.group_conversations c
        WHERE c.pickup_game_id = p_pickup_game_id
        LIMIT 1;

        IF v_conversation_id IS NULL THEN
          RAISE;
        END IF;
    END;
  END IF;

  IF NOT v_chat_live THEN
    -- Soft-leave everyone; keep messages; deactivate conversation.
    UPDATE public.group_conversation_members
    SET left_at = coalesce(left_at, now())
    WHERE conversation_id = v_conversation_id
      AND left_at IS NULL;

    UPDATE public.group_conversations
    SET is_active = false, updated_at = now()
    WHERE id = v_conversation_id;

    RETURN v_conversation_id;
  END IF;

  -- Ensure conversation stays active while the game is chat-live.
  UPDATE public.group_conversations
  SET
    is_active = true,
    title = coalesce(v_title, title),
    updated_at = now()
  WHERE id = v_conversation_id;

  SELECT coalesce(array_agg(DISTINCT a.user_id), ARRAY[]::uuid[])
    INTO v_authorized
  FROM public.pickup_game_chat_authorized_user_ids(p_pickup_game_id) a
  WHERE public.pickup_game_chat_member_age_ok(a.user_id);

  -- Soft-leave anyone who lost approval / is not the organizer / age-ineligible.
  UPDATE public.group_conversation_members m
  SET left_at = now()
  WHERE m.conversation_id = v_conversation_id
    AND m.left_at IS NULL
    AND NOT (m.user_id = ANY (v_authorized));

  -- Grant / re-activate authorized users.
  FOREACH v_uid IN ARRAY v_authorized LOOP
    INSERT INTO public.group_conversation_members (
      conversation_id,
      user_id,
      role,
      joined_at,
      last_read_at
    ) VALUES (
      v_conversation_id,
      v_uid,
      CASE WHEN v_uid = v_creator THEN 'admin' ELSE 'member' END,
      now(),
      CASE WHEN v_uid = v_creator THEN now() ELSE NULL END
    )
    ON CONFLICT (conversation_id, user_id) DO UPDATE
      SET
        left_at = NULL,
        role = CASE
          WHEN public.group_conversation_members.user_id = v_creator THEN 'admin'
          ELSE 'member'
        END,
        -- Re-join after revoke: new membership window (history while out stays hidden).
        -- Note: resetting joined_at also hides messages from a prior approved period
        -- under the single-row membership model (same as intentional rejoin privacy).
        joined_at = CASE
          WHEN public.group_conversation_members.left_at IS NOT NULL THEN now()
          ELSE public.group_conversation_members.joined_at
        END,
        muted_until = CASE
          WHEN public.group_conversation_members.left_at IS NOT NULL THEN NULL
          ELSE public.group_conversation_members.muted_until
        END,
        last_read_at = CASE
          WHEN public.group_conversation_members.left_at IS NOT NULL THEN NULL
          ELSE public.group_conversation_members.last_read_at
        END
    WHERE public.group_conversation_members.left_at IS NOT NULL
       OR public.group_conversation_members.role IS DISTINCT FROM
          (CASE WHEN EXCLUDED.user_id = v_creator THEN 'admin' ELSE 'member' END);
  END LOOP;

  RETURN v_conversation_id;
END;
$$;

COMMENT ON FUNCTION public.sync_pickup_game_group_membership(uuid) IS
  'Mirrors organizer + approved joiners into group_conversation_members. Soft-leaves revoked users. Concurrent-create safe via unique pickup_game_id.';

REVOKE ALL ON FUNCTION public.sync_pickup_game_group_membership(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sync_pickup_game_group_membership(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.sync_pickup_game_group_membership(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.sync_pickup_game_group_membership(uuid) TO service_role;

-- =============================================================================
-- 4) Ensure / open RPC (idempotent; callable by authorized users only)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.ensure_pickup_game_group_conversation(
  p_pickup_game_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_conversation_id uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF p_pickup_game_id IS NULL THEN
    RAISE EXCEPTION 'Pickup game id required.';
  END IF;

  PERFORM public.assert_age_access_allows_social(me);

  IF NOT public.is_pickup_game_chat_authorized(p_pickup_game_id, me) THEN
    RAISE EXCEPTION 'Not authorized for this pickup game chat.'
      USING ERRCODE = '42501';
  END IF;

  v_conversation_id := public.sync_pickup_game_group_membership(p_pickup_game_id);

  IF v_conversation_id IS NULL THEN
    RAISE EXCEPTION 'Pickup game chat is unavailable.';
  END IF;

  -- Defense in depth: caller must be an active member after sync.
  IF NOT public.is_active_group_member(v_conversation_id, me) THEN
    RAISE EXCEPTION 'Not authorized for this pickup game chat.'
      USING ERRCODE = '42501';
  END IF;

  RETURN v_conversation_id;
END;
$$;

COMMENT ON FUNCTION public.ensure_pickup_game_group_conversation(uuid) IS
  'Idempotent open/create of the private chat for a pickup game. '
  'Only the organizer or an approved joiner may call it.';

REVOKE ALL ON FUNCTION public.ensure_pickup_game_group_conversation(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ensure_pickup_game_group_conversation(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.ensure_pickup_game_group_conversation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ensure_pickup_game_group_conversation(uuid) TO service_role;

-- =============================================================================
-- 5) Triggers: keep membership aligned with participation / game lifecycle
-- =============================================================================
-- Request rows: pickup_game_id + requester_user_id are treated as immutable in
-- product workflows, but the trigger still watches them and syncs OLD+NEW games
-- so a rare rewrite cannot leave stale membership.
-- Game rows: status, archived_at, remove_after_at, and creator_user_id (defense;
-- ownership transfer is not a product path — account deletion changes status).

CREATE OR REPLACE FUNCTION public.trg_pickup_game_request_sync_chat_membership()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_old_status text;
  v_new_status text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF lower(btrim(coalesce(NEW.status, ''))) = 'approved' THEN
      PERFORM public.sync_pickup_game_group_membership(NEW.pickup_game_id);
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    v_old_status := lower(btrim(coalesce(OLD.status, '')));
    v_new_status := lower(btrim(coalesce(NEW.status, '')));

    IF OLD.pickup_game_id IS DISTINCT FROM NEW.pickup_game_id THEN
      IF OLD.pickup_game_id IS NOT NULL THEN
        PERFORM public.sync_pickup_game_group_membership(OLD.pickup_game_id);
      END IF;
      IF NEW.pickup_game_id IS NOT NULL THEN
        PERFORM public.sync_pickup_game_group_membership(NEW.pickup_game_id);
      END IF;
      RETURN NEW;
    END IF;

    IF OLD.requester_user_id IS DISTINCT FROM NEW.requester_user_id
       OR (v_old_status IS DISTINCT FROM v_new_status
           AND (v_old_status = 'approved' OR v_new_status = 'approved')) THEN
      PERFORM public.sync_pickup_game_group_membership(NEW.pickup_game_id);
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    IF lower(btrim(coalesce(OLD.status, ''))) = 'approved' THEN
      PERFORM public.sync_pickup_game_group_membership(OLD.pickup_game_id);
    END IF;
    RETURN OLD;
  END IF;

  RETURN coalesce(NEW, OLD);
END;
$$;

REVOKE ALL ON FUNCTION public.trg_pickup_game_request_sync_chat_membership() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.trg_pickup_game_request_sync_chat_membership() FROM anon;
REVOKE ALL ON FUNCTION public.trg_pickup_game_request_sync_chat_membership() FROM authenticated;

DROP TRIGGER IF EXISTS pickup_game_request_sync_chat_membership ON public.pickup_game_requests;
CREATE TRIGGER pickup_game_request_sync_chat_membership
  AFTER INSERT
     OR UPDATE OF status, pickup_game_id, requester_user_id
     OR DELETE
  ON public.pickup_game_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_pickup_game_request_sync_chat_membership();

CREATE OR REPLACE FUNCTION public.trg_pickup_game_status_sync_chat_membership()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'UPDATE'
     AND (
       lower(btrim(coalesce(OLD.status, ''))) IS DISTINCT FROM lower(btrim(coalesce(NEW.status, '')))
       OR OLD.archived_at IS DISTINCT FROM NEW.archived_at
       OR OLD.creator_user_id IS DISTINCT FROM NEW.creator_user_id
       OR OLD.remove_after_at IS DISTINCT FROM NEW.remove_after_at
     ) THEN
    PERFORM public.sync_pickup_game_group_membership(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.trg_pickup_game_status_sync_chat_membership() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.trg_pickup_game_status_sync_chat_membership() FROM anon;
REVOKE ALL ON FUNCTION public.trg_pickup_game_status_sync_chat_membership() FROM authenticated;

DROP TRIGGER IF EXISTS pickup_game_status_sync_chat_membership ON public.pickup_games;
CREATE TRIGGER pickup_game_status_sync_chat_membership
  AFTER UPDATE OF status, archived_at, creator_user_id, remove_after_at
  ON public.pickup_games
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_pickup_game_status_sync_chat_membership();

-- =============================================================================
-- 6) Harden social group RPCs against free-form membership on pickup chats
-- =============================================================================

CREATE OR REPLACE FUNCTION public.group_conversation_is_pickup_linked(p_conversation_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.group_conversations c
    WHERE c.id = p_conversation_id
      AND c.pickup_game_id IS NOT NULL
  );
$$;

REVOKE ALL ON FUNCTION public.group_conversation_is_pickup_linked(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.group_conversation_is_pickup_linked(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.group_conversation_is_pickup_linked(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.group_conversation_is_pickup_linked(uuid) TO service_role;

-- Patch add_group_members: refuse pickup-linked conversations.
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

  IF public.group_conversation_is_pickup_linked(p_conversation_id) THEN
    RAISE EXCEPTION 'Pickup game chat membership is managed by game participation.'
      USING ERRCODE = '42501';
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
      CONTINUE;
    END IF;
    IF EXISTS (
      SELECT 1
      FROM public.group_conversation_invitations i
      WHERE i.conversation_id = p_conversation_id
        AND i.invitee_user_id = v_uid
        AND i.status = 'pending'
        AND (i.expires_at IS NULL OR i.expires_at > now())
    ) THEN
      CONTINUE;
    END IF;
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

-- Patch leave: pickup chat access is revoked via game participation only.
-- Body matches 20260863 leave semantics + pickup guard.
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

  IF public.group_conversation_is_pickup_linked(p_conversation_id) THEN
    RAISE EXCEPTION 'Leave this pickup game to exit its chat.'
      USING ERRCODE = '42501';
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
        NULL;
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
  'Soft-leave + one idempotent member_left system timeline event. '
  'Pickup-game chats cannot be left here — withdraw from the game instead.';

REVOKE ALL ON FUNCTION public.leave_group_conversation(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.leave_group_conversation(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.leave_group_conversation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.leave_group_conversation(uuid) TO service_role;

-- Patch remove_group_member: body from 20260856 + pickup guard + anon revoke (20260866).
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

  IF public.group_conversation_is_pickup_linked(p_conversation_id) THEN
    RAISE EXCEPTION 'Pickup game chat membership is managed by game participation.'
      USING ERRCODE = '42501';
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
REVOKE ALL ON FUNCTION public.remove_group_member(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.remove_group_member(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_group_member(uuid, uuid) TO service_role;

-- =============================================================================
-- 7) Inbox / details: expose pickup_game_id for client labeling
-- =============================================================================

DROP FUNCTION IF EXISTS public.get_group_inbox_summaries();

-- Body from 20260868 + additive pickup_game_id column only.
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
  is_muted boolean,
  pickup_game_id uuid
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
    (m.muted_until IS NOT NULL AND m.muted_until > now()) AS is_muted,
    c.pickup_game_id
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

DROP FUNCTION IF EXISTS public.get_group_conversation_details(uuid);

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
  viewer_is_muted boolean,
  pickup_game_id uuid
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
    ) AS viewer_is_muted,
    c.pickup_game_id
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
REVOKE ALL ON FUNCTION public.get_group_conversation_details(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_group_conversation_details(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_group_conversation_details(uuid) TO service_role;

-- =============================================================================
-- 8) Defense: pickup chats re-check participation on send (stale membership)
-- =============================================================================
-- Predecessor: 20260863 send_group_message (+ anon revoke from 20260866).
-- Intentional pickup delta only: when group_conversations.pickup_game_id IS NOT NULL,
-- require is_pickup_game_chat_authorized before insert.

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
  v_pickup_game_id uuid;
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

  SELECT c.pickup_game_id INTO v_pickup_game_id
  FROM public.group_conversations c
  WHERE c.id = p_conversation_id;

  IF v_pickup_game_id IS NOT NULL
     AND NOT public.is_pickup_game_chat_authorized(v_pickup_game_id, me) THEN
    RAISE EXCEPTION 'Not authorized for this pickup game chat.'
      USING ERRCODE = '42501';
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

COMMENT ON FUNCTION public.send_group_message(uuid, text) IS
  'Send a text group message. Active membership required. Pickup-linked chats also require live organizer/approved authorization.';

REVOKE ALL ON FUNCTION public.send_group_message(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.send_group_message(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.send_group_message(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_group_message(uuid, text) TO service_role;

COMMENT ON FUNCTION public.ensure_pickup_game_group_conversation(uuid) IS
  'Idempotent open/create of the private chat for a pickup game. '
  'Only the organizer or an approved joiner may call it. '
  'Unauthorized callers (pending/rejected/nonparticipant/former) receive 42501.';
