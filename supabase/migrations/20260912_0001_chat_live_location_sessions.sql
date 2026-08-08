-- =============================================================================
-- 20260912_0001 — Chat live location sessions (review-ready; do not auto-apply)
-- =============================================================================
-- Secure mutable state for FanGeo "Share Live Location" cards.
-- Chat messages hold a stable session_id reference; coordinate updates go here.
--
-- Authorization (reuses existing FanGeo chat helpers — do not invent a parallel model):
--
-- SELECT (read live coords):
--   direct → public.is_direct_conversation_participant(uuid,uuid)
--            + public.direct_dm_auth_user_is_message_eligible(uuid)
--            + public.direct_conversation_peer_auth_user_ids(uuid,uuid)
--            + public.pickup_invite_users_are_unblocked(uuid,uuid)
--            (same block / eligibility gates as DM send; participant includes
--             business-owner ↔ businesses.id rows from 20260808_0040)
--   group  → public.is_active_group_member(uuid,uuid)
--            + when group_conversations.pickup_game_id IS NOT NULL:
--              public.is_pickup_game_chat_authorized(uuid,uuid)
--            (same rules as send_group_message in 20260893)
--
-- INSERT / coordinate UPDATE (start or continue sharing):
--   direct → public.direct_message_send_allowed(uuid,uuid)
--            (authoritative DM send gate from 20260869: participant + eligible
--             accounts + either-direction unblock + accepted friendship /
--             venue rules)
--   group  → same active-member + pickup authorization as send_group_message
--   Preferred client coord path: update_chat_live_location_coords(...)
--   (SECURITY DEFINER; updates only latest_* fields under sender/active/
--    not-expired/can_message checks). Direct UPDATE remains RLS+trigger guarded.
--
-- STOP UPDATE (status → stopped/expired):
--   Preferred client path: stop_chat_live_location_session(session_id)
--   (SECURITY DEFINER; sets status='stopped', stopped_at=now() ONLY).
--   Direct UPDATE fallback: sender-only RLS stop policy so a blocked/removed
--   sender can always end sharing even when can_message becomes false
--   (avoids orphaned active sessions). Mutation guard allows ONLY status +
--   stopped_at on that path (no pin move). Prefer the stop RPC for clients.
--
-- expires_at:
--   NOT NULL. Product max share duration is 60 minutes; CHECK allows up to
--   started_at + 65 minutes (5 minutes clock/skew tolerance).
--
-- UPDATE mutation paths (enforced by trigger chat_live_location_sessions_immutable_guard):
--   A. Active + can_message → may update latest_* location fields (status stays active)
--   B. Active → stopped/expired without message access → status + stopped_at only
--   C. service_role stale expiry → status + stopped_at only
--   Immutable trigger is mandatory; RPCs do not replace it.
--
-- Explicitly NOT gated (matches normal messaging RLS):
--   user_chat_inbox_deletion soft/permanent hide is per-user inbox UI state
--   and does not revoke shared conversation authorization.
--
-- Privacy:
-- - No PUBLIC/anon access; no broad profile joins
-- - Exact coordinates only via this table's participant SELECT policy
-- =============================================================================

-- Preconditions (authoritative helpers from prior migrations).
DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regprocedure('public.is_direct_conversation_participant(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.is_direct_conversation_participant(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.direct_message_send_allowed(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.direct_message_send_allowed(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.direct_dm_auth_user_is_message_eligible(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.direct_dm_auth_user_is_message_eligible(uuid)'];
  END IF;
  IF to_regprocedure('public.direct_conversation_peer_auth_user_ids(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.direct_conversation_peer_auth_user_ids(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.pickup_invite_users_are_unblocked(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.pickup_invite_users_are_unblocked(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.is_active_group_member(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.is_active_group_member(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.is_pickup_game_chat_authorized(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.is_pickup_game_chat_authorized(uuid,uuid)'];
  END IF;
  IF to_regclass('public.group_conversations') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.group_conversations'];
  END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION
      '20260912_0001 prerequisites missing: %',
      array_to_string(v_missing, ', ');
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.chat_live_location_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  conversation_kind text NOT NULL CHECK (conversation_kind IN ('direct', 'group')),
  conversation_id uuid NOT NULL,
  message_id uuid NULL,
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'stopped', 'expired')),
  started_at timestamptz NOT NULL DEFAULT now(),
  -- Product max 60m; CHECK allows +5m clock tolerance (65m). Always required.
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '15 minutes'),
  stopped_at timestamptz NULL,
  latest_lat double precision NOT NULL,
  latest_lng double precision NOT NULL,
  latest_accuracy_m double precision NULL,
  latest_place_label text NULL,
  latest_updated_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chat_live_location_sessions_lat_check
    CHECK (latest_lat >= -90 AND latest_lat <= 90),
  CONSTRAINT chat_live_location_sessions_lng_check
    CHECK (latest_lng >= -180 AND latest_lng <= 180),
  -- expires_at > started_at AND <= started_at + 65m (60m product max + 5m skew).
  CONSTRAINT chat_live_location_sessions_expires_after_start_ck
    CHECK (
      expires_at > started_at
      AND expires_at <= started_at + interval '65 minutes'
    )
);

-- Draft repair: converge earlier nullable / loose-expires drafts to NOT NULL + window.
-- SET DEFAULT → backfill null/out-of-window → SET NOT NULL → drop/recreate named CHECK.
ALTER TABLE public.chat_live_location_sessions
  ALTER COLUMN expires_at SET DEFAULT (now() + interval '15 minutes');

UPDATE public.chat_live_location_sessions
SET expires_at = started_at + interval '15 minutes'
WHERE expires_at IS NULL
   OR expires_at <= started_at
   OR expires_at > started_at + interval '65 minutes';

ALTER TABLE public.chat_live_location_sessions
  ALTER COLUMN expires_at SET NOT NULL;

ALTER TABLE public.chat_live_location_sessions
  DROP CONSTRAINT IF EXISTS chat_live_location_sessions_expires_after_start_ck;

DO $$
DECLARE
  r record;
BEGIN
  -- Drop any alternate draft CHECKs on expires_at so the canonical name wins.
  FOR r IN
    SELECT c.conname
    FROM pg_constraint c
    WHERE c.conrelid = 'public.chat_live_location_sessions'::regclass
      AND c.contype = 'c'
      AND c.conname IS DISTINCT FROM 'chat_live_location_sessions_expires_after_start_ck'
      AND pg_get_constraintdef(c.oid) ILIKE '%expires_at%'
  LOOP
    EXECUTE format(
      'ALTER TABLE public.chat_live_location_sessions DROP CONSTRAINT IF EXISTS %I',
      r.conname
    );
  END LOOP;
END $$;

ALTER TABLE public.chat_live_location_sessions
  ADD CONSTRAINT chat_live_location_sessions_expires_after_start_ck
  CHECK (
    expires_at > started_at
    AND expires_at <= started_at + interval '65 minutes'
  );

COMMENT ON COLUMN public.chat_live_location_sessions.expires_at IS
  'Required end time. Product max share is 60 minutes; CHECK allows started_at + 65 minutes (5m clock tolerance). Immutable after insert.';

CREATE INDEX IF NOT EXISTS chat_live_location_sessions_conversation_idx
  ON public.chat_live_location_sessions (conversation_kind, conversation_id, status);

CREATE INDEX IF NOT EXISTS chat_live_location_sessions_sender_active_idx
  ON public.chat_live_location_sessions (sender_user_id, status)
  WHERE status = 'active';

-- expires_at is always non-null; cron/index scan active sessions by expiry.
-- Drop/recreate so earlier drafts with `expires_at IS NOT NULL` predicate converge.
DROP INDEX IF EXISTS public.chat_live_location_sessions_expires_idx;
CREATE INDEX chat_live_location_sessions_expires_idx
  ON public.chat_live_location_sessions (expires_at)
  WHERE status = 'active';

COMMENT ON TABLE public.chat_live_location_sessions IS
  'Private live-location sessions for FanGeo chat. Exact coordinates are only readable by currently authorized conversation participants (block-aware for DMs; active membership + pickup auth for groups).';

ALTER TABLE public.chat_live_location_sessions ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.chat_live_location_sessions FROM PUBLIC;
REVOKE ALL ON TABLE public.chat_live_location_sessions FROM anon;
GRANT SELECT, INSERT, UPDATE ON TABLE public.chat_live_location_sessions TO authenticated;
GRANT ALL ON TABLE public.chat_live_location_sessions TO service_role;

-- ---------------------------------------------------------------------------
-- Access helpers
-- ---------------------------------------------------------------------------

-- True when the caller may currently READ live-location session state.
CREATE OR REPLACE FUNCTION public.chat_live_location_can_access_conversation(
  p_kind text,
  p_conversation_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_pickup_game_id uuid;
BEGIN
  IF me IS NULL OR p_conversation_id IS NULL OR p_kind IS NULL THEN
    RETURN false;
  END IF;

  IF p_kind = 'direct' THEN
    -- Reuse DM participant helper (includes business-entity ownership) plus the
    -- same block + account-eligibility gates used by direct_message_send_allowed.
    -- Does NOT gate on user_chat_inbox_deletion (per-user inbox UI only).
    RETURN public.is_direct_conversation_participant(p_conversation_id, me)
      AND public.direct_dm_auth_user_is_message_eligible(me)
      AND NOT EXISTS (
        SELECT 1
        FROM public.direct_conversation_peer_auth_user_ids(p_conversation_id, me)
          AS peer(peer_auth_user_id)
        WHERE NOT public.direct_dm_auth_user_is_message_eligible(peer.peer_auth_user_id)
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.direct_conversation_peer_auth_user_ids(p_conversation_id, me)
          AS peer(peer_auth_user_id)
        WHERE NOT public.pickup_invite_users_are_unblocked(me, peer.peer_auth_user_id)
      );
  ELSIF p_kind = 'group' THEN
    -- Same membership window as normal group messaging.
    IF NOT public.is_active_group_member(p_conversation_id, me) THEN
      RETURN false;
    END IF;

    SELECT c.pickup_game_id
      INTO v_pickup_game_id
    FROM public.group_conversations c
    WHERE c.id = p_conversation_id;

    IF NOT FOUND THEN
      RETURN false;
    END IF;

    -- Pickup private chats: organizer / approved joiner + chat-live only.
    IF v_pickup_game_id IS NOT NULL
       AND NOT public.is_pickup_game_chat_authorized(v_pickup_game_id, me) THEN
      RETURN false;
    END IF;

    RETURN true;
  END IF;

  RETURN false;
END;
$$;

COMMENT ON FUNCTION public.chat_live_location_can_access_conversation(text, uuid) IS
  'Live-location READ authorization. Direct: is_direct_conversation_participant + DM eligibility/block helpers. Group: is_active_group_member (+ is_pickup_game_chat_authorized when pickup-linked). Inbox hide/permanent delete is not consulted.';

REVOKE ALL ON FUNCTION public.chat_live_location_can_access_conversation(text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.chat_live_location_can_access_conversation(text, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.chat_live_location_can_access_conversation(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.chat_live_location_can_access_conversation(text, uuid) TO service_role;

-- True when the caller may currently START or CONTINUE sharing into the conversation.
CREATE OR REPLACE FUNCTION public.chat_live_location_can_message_conversation(
  p_kind text,
  p_conversation_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_pickup_game_id uuid;
BEGIN
  IF me IS NULL OR p_conversation_id IS NULL OR p_kind IS NULL THEN
    RETURN false;
  END IF;

  IF p_kind = 'direct' THEN
    -- Authoritative DM send gate (20260869).
    RETURN public.direct_message_send_allowed(p_conversation_id, me);
  ELSIF p_kind = 'group' THEN
    -- Mirrors send_group_message (20260893).
    IF NOT public.is_active_group_member(p_conversation_id, me) THEN
      RETURN false;
    END IF;

    SELECT c.pickup_game_id
      INTO v_pickup_game_id
    FROM public.group_conversations c
    WHERE c.id = p_conversation_id;

    IF NOT FOUND THEN
      RETURN false;
    END IF;

    IF v_pickup_game_id IS NOT NULL
       AND NOT public.is_pickup_game_chat_authorized(v_pickup_game_id, me) THEN
      RETURN false;
    END IF;

    RETURN true;
  END IF;

  RETURN false;
END;
$$;

COMMENT ON FUNCTION public.chat_live_location_can_message_conversation(text, uuid) IS
  'Live-location START/UPDATE authorization. Direct: direct_message_send_allowed. Group: is_active_group_member (+ is_pickup_game_chat_authorized when pickup-linked), matching send_group_message.';

REVOKE ALL ON FUNCTION public.chat_live_location_can_message_conversation(text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.chat_live_location_can_message_conversation(text, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.chat_live_location_can_message_conversation(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.chat_live_location_can_message_conversation(text, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- RLS policies
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS "chat_live_location_select_participants" ON public.chat_live_location_sessions;
CREATE POLICY "chat_live_location_select_participants"
ON public.chat_live_location_sessions
FOR SELECT
TO authenticated
USING (
  -- Sender may always read their own session (needed for Stop UI after access loss).
  sender_user_id = auth.uid()
  OR public.chat_live_location_can_access_conversation(conversation_kind, conversation_id)
);

DROP POLICY IF EXISTS "chat_live_location_insert_sender" ON public.chat_live_location_sessions;
CREATE POLICY "chat_live_location_insert_sender"
ON public.chat_live_location_sessions
FOR INSERT
TO authenticated
WITH CHECK (
  auth.uid() IS NOT NULL
  AND sender_user_id = auth.uid()
  AND status = 'active'
  AND latest_lat >= -90 AND latest_lat <= 90
  AND latest_lng >= -180 AND latest_lng <= 180
  AND expires_at IS NOT NULL
  AND expires_at > started_at
  AND expires_at <= started_at + interval '65 minutes'
  AND public.chat_live_location_can_message_conversation(conversation_kind, conversation_id)
);

-- Coordinate updates: sender must still be allowed to message the conversation.
-- Preferred client path: update_chat_live_location_coords (RPC); this policy
-- remains for direct UPDATE compatibility under the immutable trigger.
DROP POLICY IF EXISTS "chat_live_location_update_sender_active" ON public.chat_live_location_sessions;
DROP POLICY IF EXISTS "chat_live_location_update_coords_when_messageable" ON public.chat_live_location_sessions;
CREATE POLICY "chat_live_location_update_coords_when_messageable"
ON public.chat_live_location_sessions
FOR UPDATE
TO authenticated
USING (
  sender_user_id = auth.uid()
  AND status = 'active'
  AND expires_at > now()
  AND public.chat_live_location_can_message_conversation(conversation_kind, conversation_id)
)
WITH CHECK (
  sender_user_id = auth.uid()
  AND status = 'active'
  AND expires_at > now()
  AND expires_at > started_at
  AND expires_at <= started_at + interval '65 minutes'
  AND latest_lat >= -90 AND latest_lat <= 90
  AND latest_lng >= -180 AND latest_lng <= 180
  AND public.chat_live_location_can_message_conversation(conversation_kind, conversation_id)
);

-- Safe stop path: sender can always end their own active session, even after
-- leave / removal / block / friendship loss (prevents orphaned active shares).
-- Preferred client path: stop_chat_live_location_session (RPC).
-- RLS only constrains status; the mutation guard freezes location/message fields.
DROP POLICY IF EXISTS "chat_live_location_stop_sender" ON public.chat_live_location_sessions;
CREATE POLICY "chat_live_location_stop_sender"
ON public.chat_live_location_sessions
FOR UPDATE
TO authenticated
USING (
  sender_user_id = auth.uid()
  AND status = 'active'
)
WITH CHECK (
  sender_user_id = auth.uid()
  AND status IN ('stopped', 'expired')
);

-- Mutation guard:
--   A) active + can_message → latest_* (and optional one-time message_id link)
--   B) active → stopped/expired (access-loss stop) → status + stopped_at ONLY
--   C) service_role expiry → status + stopped_at ONLY
CREATE OR REPLACE FUNCTION public.chat_live_location_sessions_immutable_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_service boolean :=
    COALESCE(auth.role(), '') = 'service_role'
    OR session_user IN ('postgres', 'service_role', 'supabase_admin');
  v_can_message boolean := false;
  v_location_changed boolean;
  v_message_id_changed boolean;
  v_is_stop_or_expire boolean;
BEGIN
  -- Always-immutable identity / ownership / schedule fields.
  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.sender_user_id IS DISTINCT FROM OLD.sender_user_id
     OR NEW.conversation_kind IS DISTINCT FROM OLD.conversation_kind
     OR NEW.conversation_id IS DISTINCT FROM OLD.conversation_id
     OR NEW.started_at IS DISTINCT FROM OLD.started_at
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
     OR NEW.expires_at IS DISTINCT FROM OLD.expires_at
  THEN
    RAISE EXCEPTION 'chat_live_location_sessions identity/schedule columns are immutable'
      USING ERRCODE = '42501';
  END IF;

  -- Terminal sessions cannot be resumed or rewritten (coords, message_id, etc.).
  IF OLD.status IN ('stopped', 'expired') THEN
    RAISE EXCEPTION 'chat_live_location_sessions terminal rows are immutable'
      USING ERRCODE = '42501';
  END IF;

  IF OLD.status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'chat_live_location_sessions only active rows may be updated'
      USING ERRCODE = '42501';
  END IF;

  v_is_stop_or_expire := NEW.status IN ('stopped', 'expired');
  v_location_changed :=
    NEW.latest_lat IS DISTINCT FROM OLD.latest_lat
    OR NEW.latest_lng IS DISTINCT FROM OLD.latest_lng
    OR NEW.latest_accuracy_m IS DISTINCT FROM OLD.latest_accuracy_m
    OR NEW.latest_place_label IS DISTINCT FROM OLD.latest_place_label
    OR NEW.latest_updated_at IS DISTINCT FROM OLD.latest_updated_at;
  v_message_id_changed := NEW.message_id IS DISTINCT FROM OLD.message_id;

  -- Paths B / C: end session — only status + stopped_at may change.
  IF v_is_stop_or_expire THEN
    IF v_location_changed OR v_message_id_changed THEN
      RAISE EXCEPTION
        'chat_live_location_sessions stop/expire may only change status and stopped_at'
        USING ERRCODE = '42501';
    END IF;

    IF NEW.stopped_at IS NULL THEN
      RAISE EXCEPTION 'chat_live_location_sessions stop/expire requires stopped_at'
        USING ERRCODE = '23514';
    END IF;

    IF NOT v_is_service THEN
      IF auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM OLD.sender_user_id THEN
        RAISE EXCEPTION 'chat_live_location_sessions stop requires session sender'
          USING ERRCODE = '42501';
      END IF;
    END IF;

    RETURN NEW;
  END IF;

  -- Path A: remain active — authorized coordinate (or one-time message link) update.
  IF NEW.status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'chat_live_location_sessions invalid status transition'
      USING ERRCODE = '42501';
  END IF;

  IF NEW.stopped_at IS DISTINCT FROM OLD.stopped_at THEN
    RAISE EXCEPTION 'chat_live_location_sessions.stopped_at cannot change while active'
      USING ERRCODE = '42501';
  END IF;

  -- expires_at is NOT NULL; reject coordinate updates past expiry.
  IF OLD.expires_at <= now() THEN
    RAISE EXCEPTION 'chat_live_location_sessions expired session cannot receive updates'
      USING ERRCODE = '42501';
  END IF;

  IF auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM OLD.sender_user_id THEN
    RAISE EXCEPTION 'chat_live_location_sessions coordinate update requires session sender'
      USING ERRCODE = '42501';
  END IF;

  v_can_message := public.chat_live_location_can_message_conversation(
    OLD.conversation_kind,
    OLD.conversation_id
  );
  IF NOT v_can_message THEN
    RAISE EXCEPTION
      'chat_live_location_sessions coordinate update requires conversation message access'
      USING ERRCODE = '42501';
  END IF;

  -- message_id: allow NULL → value once while active; never rewrite afterward.
  IF v_message_id_changed
     AND NOT (OLD.message_id IS NULL AND NEW.message_id IS NOT NULL) THEN
    RAISE EXCEPTION 'chat_live_location_sessions.message_id is immutable once set'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.chat_live_location_sessions_immutable_guard() IS
  'BEFORE UPDATE guard (mandatory). Active+can_message may update latest_* (path A). Stop/expire (path B) and service_role expiry (path C) may change only status + stopped_at. Identity/schedule/terminal rows are frozen. Trigger-only; not for client EXECUTE. Preferred client mutations: update_chat_live_location_coords / stop_chat_live_location_session.';

DROP TRIGGER IF EXISTS trg_chat_live_location_sessions_immutable
  ON public.chat_live_location_sessions;
CREATE TRIGGER trg_chat_live_location_sessions_immutable
  BEFORE UPDATE ON public.chat_live_location_sessions
  FOR EACH ROW
  EXECUTE FUNCTION public.chat_live_location_sessions_immutable_guard();

REVOKE ALL ON FUNCTION public.chat_live_location_sessions_immutable_guard() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.chat_live_location_sessions_immutable_guard() FROM anon;
REVOKE ALL ON FUNCTION public.chat_live_location_sessions_immutable_guard() FROM authenticated;
-- Trigger-only: no EXECUTE grants to client roles.

-- ---------------------------------------------------------------------------
-- Preferred client mutation RPCs (SECURITY DEFINER)
-- Direct table UPDATE remains available under RLS + immutable trigger;
-- clients should prefer these RPCs so mutations cannot widen columns.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.update_chat_live_location_coords(
  p_session_id uuid,
  p_lat float8,
  p_lng float8,
  p_accuracy float8,
  p_place_label text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.chat_live_location_sessions%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF p_session_id IS NULL THEN
    RAISE EXCEPTION 'session_id required' USING ERRCODE = '22023';
  END IF;

  IF p_lat IS NULL OR p_lat < -90 OR p_lat > 90
     OR p_lng IS NULL OR p_lng < -180 OR p_lng > 180 THEN
    RAISE EXCEPTION 'Invalid coordinates' USING ERRCODE = '23514';
  END IF;

  SELECT * INTO v_row
  FROM public.chat_live_location_sessions
  WHERE id = p_session_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Live location session not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_row.sender_user_id IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'Only the session sender can update coordinates'
      USING ERRCODE = '42501';
  END IF;

  IF v_row.status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'Live location session is not active'
      USING ERRCODE = '42501';
  END IF;

  IF v_row.expires_at <= now() THEN
    RAISE EXCEPTION 'Live location session has expired'
      USING ERRCODE = '42501';
  END IF;

  IF NOT public.chat_live_location_can_message_conversation(
    v_row.conversation_kind,
    v_row.conversation_id
  ) THEN
    RAISE EXCEPTION
      'Conversation message access required to update live location'
      USING ERRCODE = '42501';
  END IF;

  -- latest_* fields only (immutable trigger still enforces column freezes).
  UPDATE public.chat_live_location_sessions
  SET
    latest_lat = p_lat,
    latest_lng = p_lng,
    latest_accuracy_m = p_accuracy,
    latest_place_label = p_place_label,
    latest_updated_at = now()
  WHERE id = p_session_id
    AND status = 'active';
END;
$$;

COMMENT ON FUNCTION public.update_chat_live_location_coords(uuid, float8, float8, float8, text) IS
  'Preferred client path to refresh live-location coordinates. Requires auth.uid()=sender, status=active, not expired, can_message. Updates only latest_* fields. Immutable trigger remains mandatory.';

REVOKE ALL ON FUNCTION public.update_chat_live_location_coords(uuid, float8, float8, float8, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_chat_live_location_coords(uuid, float8, float8, float8, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_chat_live_location_coords(uuid, float8, float8, float8, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_chat_live_location_coords(uuid, float8, float8, float8, text) TO service_role;

CREATE OR REPLACE FUNCTION public.stop_chat_live_location_session(
  p_session_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.chat_live_location_sessions%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF p_session_id IS NULL THEN
    RAISE EXCEPTION 'session_id required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_row
  FROM public.chat_live_location_sessions
  WHERE id = p_session_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Live location session not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_row.sender_user_id IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'Only the session sender can stop sharing'
      USING ERRCODE = '42501';
  END IF;

  IF v_row.status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'Live location session is not active'
      USING ERRCODE = '42501';
  END IF;

  -- status + stopped_at ONLY (immutable trigger path B still applies).
  UPDATE public.chat_live_location_sessions
  SET
    status = 'stopped',
    stopped_at = now()
  WHERE id = p_session_id
    AND status = 'active';
END;
$$;

COMMENT ON FUNCTION public.stop_chat_live_location_session(uuid) IS
  'Preferred client path to end a live-location share. Requires auth.uid()=sender and status=active. Sets status=stopped and stopped_at=now() only. Immutable trigger remains mandatory.';

REVOKE ALL ON FUNCTION public.stop_chat_live_location_session(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.stop_chat_live_location_session(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.stop_chat_live_location_session(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.stop_chat_live_location_session(uuid) TO service_role;

-- Expire active sessions past expires_at (service / cron friendly).
-- expires_at is always NOT NULL, so every active session is cron-eligible.
-- Smallest mutation set: status + stopped_at (guard path C).
CREATE OR REPLACE FUNCTION public.chat_live_location_expire_stale_sessions()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count integer;
BEGIN
  UPDATE public.chat_live_location_sessions
  SET status = 'expired',
      stopped_at = COALESCE(stopped_at, now())
  WHERE status = 'active'
    AND expires_at <= now();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

COMMENT ON FUNCTION public.chat_live_location_expire_stale_sessions() IS
  'Marks active live-location sessions past expires_at as expired (status + stopped_at only). expires_at is always NOT NULL so cron can expire every active session. Intended for service_role / cron.';

REVOKE ALL ON FUNCTION public.chat_live_location_expire_stale_sessions() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.chat_live_location_expire_stale_sessions() FROM anon;
REVOKE ALL ON FUNCTION public.chat_live_location_expire_stale_sessions() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.chat_live_location_expire_stale_sessions() TO service_role;

-- Optional: publish for Realtime card updates (apply only if publication exists).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    BEGIN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_live_location_sessions;
    EXCEPTION
      WHEN duplicate_object THEN
        NULL;
    END;
  END IF;
END $$;

-- =============================================================================
-- Verification matrix (manual; do not auto-run against production data)
-- =============================================================================
-- A. Active authorized sender updates latest_lat/lng/accuracy/place/updated_at
--    → ALLOWED (RLS coords policy + guard path A)
--    Prefer: SELECT public.update_chat_live_location_coords(id, lat, lng, acc, label);
-- B. Sender loses conversation access; UPDATE status=stopped, stopped_at=now()
--    only → ALLOWED (RLS stop policy + guard path B)
--    Prefer: SELECT public.stop_chat_live_location_session(id);
-- C. Sender loses access; UPDATE status=stopped AND latest_lat/lng change
--    → DENIED (guard: stop/expire may only change status and stopped_at)
-- D. Sender loses access; UPDATE status=stopped AND message_id change
--    → DENIED (guard)
-- E. Sender UPDATE status stopped → active
--    → DENIED (RLS: no policy; guard: terminal rows immutable)
-- F. Sender UPDATE coords after expires_at <= now() while status still active
--    → DENIED (RLS coords USING expires_at > now(); guard expired check)
-- G. service_role chat_live_location_expire_stale_sessions()
--    → ALLOWED (status + stopped_at only; guard path C; expires_at always set)
-- H. Non-sender UPDATE status=stopped / stop RPC
--    → DENIED (RLS stop USING sender_user_id; guard/RPC sender check)
-- I. INSERT with expires_at NULL or expires_at > started_at + 65 minutes
--    → DENIED (NOT NULL + CHECK + INSERT WITH CHECK)
-- J. update_chat_live_location_coords without can_message → DENIED
-- K. stop_chat_live_location_session as non-sender → DENIED
-- =============================================================================
