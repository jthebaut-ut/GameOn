-- =============================================================================
-- 20260914_0001 — Pickup poll create permission (review-ready; do NOT auto-apply)
-- =============================================================================
-- Adds organizer-controlled "Who can create polls?" on pickup_games.
-- Default for all existing + new rows: organizer_only (no unexpected expansion).
--
-- Idempotent / draft-safe:
--   • Clean first-time production apply
--   • Dev DBs that may already have a partial poll_create_permission column
--
-- Server create auth lives in create_pickup_game_poll (not client).
-- Column updates use existing RLS pickup_games_update_creator_only
--   (creator_user_id = auth.uid()) — no new update RPC.
-- Close / delete / pin / vote / moderation / lifecycle unchanged.
-- =============================================================================

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.pickup_games') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.pickup_games'];
  END IF;
  IF to_regclass('public.pickup_game_requests') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.pickup_game_requests'];
  END IF;
  IF to_regprocedure('public.create_pickup_game_poll(uuid,text,text[],boolean,boolean,boolean)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.create_pickup_game_poll(...)'];
  END IF;
  IF to_regprocedure('public._pickup_poll_user_can_access(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public._pickup_poll_user_can_access(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.is_pickup_game_chat_authorized(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.is_pickup_game_chat_authorized(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.pickup_game_is_chat_live(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.pickup_game_is_chat_live(uuid)'];
  END IF;
  IF to_regprocedure('public._pickup_poll_text_is_prohibited(text)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public._pickup_poll_text_is_prohibited(text)'];
  END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION
      '20260914_0001 prerequisites missing: %',
      array_to_string(v_missing, ', ');
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 1) Column repair (converges partial drafts + clean installs)
-- -----------------------------------------------------------------------------
-- Add as nullable text first so IF NOT EXISTS never fights an earlier draft
-- that already has the column under a different nullability/default.
ALTER TABLE public.pickup_games
  ADD COLUMN IF NOT EXISTS poll_create_permission text;

ALTER TABLE public.pickup_games
  ALTER COLUMN poll_create_permission SET DEFAULT 'organizer_only';

-- Drop any prior check on this column (canonical name + alternate draft names)
-- before normalizing so invalid legacy values cannot block the UPDATE.
ALTER TABLE public.pickup_games
  DROP CONSTRAINT IF EXISTS pickup_games_poll_create_permission_ck;

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT c.conname
    FROM pg_constraint c
    WHERE c.conrelid = 'public.pickup_games'::regclass
      AND c.contype = 'c'
      AND pg_get_constraintdef(c.oid) ILIKE '%poll_create_permission%'
  LOOP
    EXECUTE format(
      'ALTER TABLE public.pickup_games DROP CONSTRAINT IF EXISTS %I',
      r.conname
    );
  END LOOP;
END $$;

-- Normalize every invalid value → organizer_only (restrictive default).
UPDATE public.pickup_games
SET poll_create_permission = 'organizer_only'
WHERE poll_create_permission IS NULL
   OR btrim(poll_create_permission) = ''
   OR lower(btrim(poll_create_permission)) NOT IN ('organizer_only', 'approved_players');

-- Canonical lowercase tokens for any previously mixed-case valid values.
UPDATE public.pickup_games
SET poll_create_permission = lower(btrim(poll_create_permission))
WHERE poll_create_permission IS DISTINCT FROM lower(btrim(poll_create_permission))
  AND lower(btrim(poll_create_permission)) IN ('organizer_only', 'approved_players');

ALTER TABLE public.pickup_games
  ALTER COLUMN poll_create_permission SET NOT NULL;

-- Always recreate so final schema converges regardless of prior drafts.
ALTER TABLE public.pickup_games
  ADD CONSTRAINT pickup_games_poll_create_permission_ck
  CHECK (
    poll_create_permission IN (
      'organizer_only',
      'approved_players'
    )
  );

COMMENT ON COLUMN public.pickup_games.poll_create_permission IS
  'Who may create pickup-chat polls: organizer_only (default) | approved_players. Create enforced by create_pickup_game_poll; column updates enforced by RLS pickup_games_update_creator_only (creator_user_id = auth.uid()).';

-- -----------------------------------------------------------------------------
-- Organizer update path (documented; no new RPC)
-- -----------------------------------------------------------------------------
-- Client: MapViewModel.updatePickupGamePollCreatePermission →
--   UPDATE public.pickup_games SET poll_create_permission = ... WHERE id = ...
-- Backend guarantee (existing, unchanged):
--   POLICY pickup_games_update_creator_only
--     FOR UPDATE TO authenticated
--     USING  (creator_user_id = auth.uid())
--     WITH CHECK (creator_user_id = auth.uid())
-- Therefore:
--   ✓ organizer can change it
--   ✓ approved / pending / nonmember / modified client cannot bypass
-- CHECK constraint rejects any value other than the two allowed tokens.
-- No additional update RPC — would duplicate RLS without benefit.

-- Internal helper: approved participant (not pending / rejected / withdrawn).
CREATE OR REPLACE FUNCTION public._pickup_poll_user_is_approved_participant(
  p_pickup_game_id uuid,
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
    FROM public.pickup_game_requests r
    WHERE r.pickup_game_id = p_pickup_game_id
      AND r.requester_user_id = p_user_id
      AND lower(btrim(r.status)) = 'approved'
  );
$$;

REVOKE ALL ON FUNCTION public._pickup_poll_user_is_approved_participant(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._pickup_poll_user_is_approved_participant(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public._pickup_poll_user_is_approved_participant(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public._pickup_poll_user_is_approved_participant(uuid, uuid) TO service_role;

-- Replace create RPC with setting-aware authorization (signature unchanged).
-- Validation: REJECT over-length question/options (do not truncate).
CREATE OR REPLACE FUNCTION public.create_pickup_game_poll(
  p_conversation_id uuid,
  p_question text,
  p_options text[],
  p_allow_multiple boolean DEFAULT false,
  p_is_anonymous boolean DEFAULT false,
  p_auto_close_at_game_start boolean DEFAULT true
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_pickup_id uuid;
  v_creator uuid;
  v_game_start timestamptz;
  v_permission text;
  v_question text;
  v_opt text;
  v_norm text;
  v_seen text[] := ARRAY[]::text[];
  v_clean_options text[] := ARRAY[]::text[];
  v_poll_id uuid;
  v_closes_at timestamptz := NULL;
  v_can_create boolean := false;
  v_option_count integer;
  i integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT c.pickup_game_id
  INTO v_pickup_id
  FROM public.group_conversations c
  WHERE c.id = p_conversation_id;

  IF v_pickup_id IS NULL THEN
    RAISE EXCEPTION 'Polls are only available in pickup game chats.';
  END IF;

  IF NOT public._pickup_poll_user_can_access(p_conversation_id, v_uid) THEN
    RAISE EXCEPTION 'Not authorized.';
  END IF;

  IF NOT public.pickup_game_is_chat_live(v_pickup_id) THEN
    RAISE EXCEPTION 'This pickup game is no longer active.';
  END IF;

  SELECT
    g.creator_user_id,
    g.game_start_at,
    lower(btrim(coalesce(g.poll_create_permission, 'organizer_only')))
  INTO v_creator, v_game_start, v_permission
  FROM public.pickup_games g
  WHERE g.id = v_pickup_id;

  IF v_creator IS NULL THEN
    RAISE EXCEPTION 'Pickup game not found.';
  END IF;

  IF v_permission IS DISTINCT FROM 'approved_players' THEN
    v_permission := 'organizer_only';
  END IF;

  IF v_permission = 'organizer_only' THEN
    v_can_create := (v_creator = v_uid);
  ELSE
    -- approved_players: organizer OR approved participant (pending/non-approved denied).
    v_can_create := (
      v_creator = v_uid
      OR public._pickup_poll_user_is_approved_participant(v_pickup_id, v_uid)
    );
  END IF;

  IF NOT v_can_create THEN
    IF v_permission = 'organizer_only' THEN
      RAISE EXCEPTION 'Only the organizer can create polls.';
    ELSE
      RAISE EXCEPTION 'Only the organizer or approved players can create polls.';
    END IF;
  END IF;

  -- Reject (do not truncate) over-length question.
  v_question := btrim(coalesce(p_question, ''));
  IF v_question IS NULL OR char_length(v_question) < 1 THEN
    RAISE EXCEPTION 'Enter a question for this poll.';
  END IF;
  IF char_length(v_question) > 120 THEN
    RAISE EXCEPTION 'Question must be 120 characters or fewer.';
  END IF;

  IF public._pickup_poll_text_is_prohibited(v_question) THEN
    RAISE EXCEPTION 'This poll contains content that isn''t allowed.';
  END IF;

  v_option_count := coalesce(array_length(p_options, 1), 0);
  IF p_options IS NULL OR v_option_count < 2 THEN
    RAISE EXCEPTION 'Add at least two answers.';
  END IF;
  IF v_option_count > 8 THEN
    RAISE EXCEPTION 'Polls support up to 8 answers.';
  END IF;

  FOR i IN 1 .. v_option_count LOOP
    -- Reject (do not truncate) over-length options.
    v_opt := btrim(coalesce(p_options[i], ''));
    IF v_opt IS NULL OR char_length(v_opt) < 1 THEN
      RAISE EXCEPTION 'Answers cannot be empty.';
    END IF;
    IF char_length(v_opt) > 40 THEN
      RAISE EXCEPTION 'Each answer must be 40 characters or fewer.';
    END IF;
    IF public._pickup_poll_text_is_prohibited(v_opt) THEN
      RAISE EXCEPTION 'This poll contains content that isn''t allowed.';
    END IF;
    v_norm := lower(v_opt);
    IF v_norm = ANY (v_seen) THEN
      RAISE EXCEPTION 'Answers must be unique.';
    END IF;
    v_seen := v_seen || ARRAY[v_norm];
    v_clean_options := v_clean_options || ARRAY[v_opt];
  END LOOP;

  IF coalesce(p_auto_close_at_game_start, true) AND v_game_start IS NOT NULL THEN
    v_closes_at := v_game_start;
  END IF;

  INSERT INTO public.pickup_game_polls (
    pickup_game_id,
    conversation_id,
    created_by,
    question,
    allow_multiple,
    is_anonymous,
    auto_close_at_game_start,
    closes_at,
    status
  ) VALUES (
    v_pickup_id,
    p_conversation_id,
    v_uid,
    v_question,
    coalesce(p_allow_multiple, false),
    coalesce(p_is_anonymous, false),
    coalesce(p_auto_close_at_game_start, true),
    v_closes_at,
    'open'
  )
  RETURNING id INTO v_poll_id;

  FOR i IN 1 .. array_length(v_clean_options, 1) LOOP
    INSERT INTO public.pickup_game_poll_options (poll_id, option_text, sort_order)
    VALUES (v_poll_id, v_clean_options[i], i - 1);
  END LOOP;

  RETURN v_poll_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_pickup_game_poll(uuid, text, text[], boolean, boolean, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_pickup_game_poll(uuid, text, text[], boolean, boolean, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.create_pickup_game_poll(uuid, text, text[], boolean, boolean, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_pickup_game_poll(uuid, text, text[], boolean, boolean, boolean) TO service_role;

-- Allow the poll creator (organizer or approved player) to attach the chat message.
-- Close/delete/pin remain organizer-only.
CREATE OR REPLACE FUNCTION public.attach_pickup_game_poll_message(
  p_poll_id uuid,
  p_message_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_poll public.pickup_game_polls%ROWTYPE;
  v_msg public.group_messages%ROWTYPE;
  v_conv_pickup uuid;
  v_body text;
  v_sentinel constant text := '__FG_POLL_V1__';
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF p_poll_id IS NULL OR p_message_id IS NULL THEN
    RAISE EXCEPTION 'Poll message attachment requires poll_id and message_id.';
  END IF;

  SELECT * INTO v_poll
  FROM public.pickup_game_polls
  WHERE id = p_poll_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Poll not found.';
  END IF;

  IF v_poll.deleted_at IS NOT NULL OR v_poll.status = 'archived' THEN
    RAISE EXCEPTION 'Cannot attach a message to an archived poll.';
  END IF;

  IF v_poll.created_by IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'Not authorized.';
  END IF;

  IF NOT public._pickup_poll_user_can_access(v_poll.conversation_id, v_uid) THEN
    RAISE EXCEPTION 'Not authorized.';
  END IF;

  SELECT c.pickup_game_id
  INTO v_conv_pickup
  FROM public.group_conversations c
  WHERE c.id = v_poll.conversation_id;

  IF v_conv_pickup IS NULL OR v_conv_pickup IS DISTINCT FROM v_poll.pickup_game_id THEN
    RAISE EXCEPTION 'Poll conversation is not the authorized pickup game chat.';
  END IF;

  SELECT * INTO v_msg
  FROM public.group_messages
  WHERE id = p_message_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Message not found.';
  END IF;

  IF v_msg.conversation_id IS DISTINCT FROM v_poll.conversation_id THEN
    RAISE EXCEPTION 'Message does not belong to this poll conversation.';
  END IF;

  IF v_msg.sender_id IS DISTINCT FROM v_uid
     OR v_msg.sender_id IS DISTINCT FROM v_poll.created_by THEN
    RAISE EXCEPTION 'Message sender must be the poll creator.';
  END IF;

  IF coalesce(v_msg.is_deleted, false) OR v_msg.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'Cannot attach a deleted message.';
  END IF;

  v_body := coalesce(v_msg.body, '');
  IF position(v_sentinel IN v_body) = 0 THEN
    RAISE EXCEPTION 'Message is not a structured pickup poll message.';
  END IF;

  IF position(lower(p_poll_id::text) IN lower(v_body)) = 0 THEN
    RAISE EXCEPTION 'Message does not reference this poll.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.pickup_game_polls p
    WHERE p.message_id = p_message_id
      AND p.id IS DISTINCT FROM p_poll_id
  ) THEN
    RAISE EXCEPTION 'Message is already attached to another poll.';
  END IF;

  IF v_poll.message_id IS NOT NULL AND v_poll.message_id IS DISTINCT FROM p_message_id THEN
    RAISE EXCEPTION 'Poll already has an attached message.';
  END IF;

  UPDATE public.pickup_game_polls
  SET message_id = p_message_id,
      updated_at = now()
  WHERE id = p_poll_id
    AND (message_id IS NULL OR message_id = p_message_id);
END;
$$;

REVOKE ALL ON FUNCTION public.attach_pickup_game_poll_message(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.attach_pickup_game_poll_message(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.attach_pickup_game_poll_message(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.attach_pickup_game_poll_message(uuid, uuid) TO service_role;

-- =============================================================================
-- Verification (manual)
-- =============================================================================
-- Column: SELECT poll_create_permission, count(*) FROM pickup_games GROUP BY 1;
--   expect only organizer_only / approved_players; default organizer_only
-- Constraint: \d+ pickup_games → pickup_games_poll_create_permission_ck
-- Organizer UPDATE poll_create_permission → ok (RLS creator-only)
-- Approved/pending/nonmember UPDATE → 0 rows / RLS deny
-- Over-length question (>120) / option (>40) → exception (not truncated)
-- <2 or >8 options / duplicate normalized options → exception
-- Organizer-only create by approved non-organizer → exception
-- approved_players + approved joiner create → ok
-- pending requester create → cannot create
-- Close/delete/pin still organizer-only (unchanged RPCs)
-- =============================================================================
