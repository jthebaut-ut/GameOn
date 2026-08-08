-- =============================================================================
-- 20260913_0001 — Pickup Game Polls (review-ready; do NOT auto-apply)
-- =============================================================================
-- Normalized polls for pickup-game group chats only.
-- Chat messages hold a stable poll_id reference (__FG_POLL_V1__); votes/status live here.
--
-- Hardening (audit pass):
--   1) Snapshot reads are STABLE + side-effect free (no auto-close writes).
--   2) Message attachment validates conversation/sender/body/poll-id/uniqueness.
--   3) Arbitrary-user auth helpers are internal-only (no authenticated execute).
--   4) Global close-all due polls is service_role only.
--   5) FKs preserve poll/chat history (no CASCADE erase from game/creator delete).
--   6) Server-side content guard mirrors FanGeo client blocked-term list
--      (no prior authoritative SQL UGC filter existed in-repo; client UX remains).
--
-- Authorization:
--   READ  → active group member + is_pickup_game_chat_authorized
--   CREATE / CLOSE / DELETE / PIN → pickup organizer (pickup_games.creator_user_id)
--   VOTE  → same read gate; open + not deleted/archived; server-enforced
-- =============================================================================

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.pickup_games') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.pickup_games'];
  END IF;
  IF to_regclass('public.group_conversations') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.group_conversations'];
  END IF;
  IF to_regclass('public.group_messages') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.group_messages'];
  END IF;
  IF to_regprocedure('public.is_active_group_member(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.is_active_group_member(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.is_pickup_game_chat_authorized(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.is_pickup_game_chat_authorized(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.pickup_game_is_chat_live(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.pickup_game_is_chat_live(uuid)'];
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'pickup_games' AND column_name = 'game_start_at'
  ) THEN
    v_missing := v_missing || ARRAY['column pickup_games.game_start_at'];
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'group_conversations' AND column_name = 'pickup_game_id'
  ) THEN
    v_missing := v_missing || ARRAY['column group_conversations.pickup_game_id'];
  END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION
      '20260913_0001 prerequisites missing: %',
      array_to_string(v_missing, ', ');
  END IF;
END $$;

-- =============================================================================
-- Prior-draft cleanup (no CASCADE)
-- =============================================================================
-- Production failure (2BP01): DROP of can_access_pickup_game_poll_conversation(uuid)
-- was blocked by existing SELECT policies from an earlier poll draft. Drop those
-- policies first (table-guarded), then drop helpers. Authoritative policies are
-- recreated later in the RLS section. Never use DROP ... CASCADE.
--
-- Transaction: run this entire file as one transaction (BEGIN … COMMIT below).
-- If your migration runner already wraps files in a transaction, either keep this
-- outer pair (PostgreSQL warns / no-ops nested BEGIN) or strip the outer BEGIN/COMMIT
-- and rely on the runner — but apply the whole file atomically either way.
BEGIN;

-- 1) Drop RLS policies that reference can_access_pickup_game_poll_conversation
--    (and known prior-draft aliases) before dropping the helper.
DO $$
BEGIN
  IF to_regclass('public.pickup_game_polls') IS NOT NULL THEN
    EXECUTE 'DROP POLICY IF EXISTS pickup_game_polls_select ON public.pickup_game_polls';
    EXECUTE 'DROP POLICY IF EXISTS pickup_game_poll_select ON public.pickup_game_polls';
    EXECUTE 'DROP POLICY IF EXISTS pickup_game_polls_no_direct_write ON public.pickup_game_polls';
  END IF;

  IF to_regclass('public.pickup_game_poll_options') IS NOT NULL THEN
    EXECUTE 'DROP POLICY IF EXISTS pickup_game_poll_options_select ON public.pickup_game_poll_options';
    EXECUTE 'DROP POLICY IF EXISTS pickup_game_poll_options_no_direct_write ON public.pickup_game_poll_options';
  END IF;

  IF to_regclass('public.pickup_game_poll_votes') IS NOT NULL THEN
    EXECUTE 'DROP POLICY IF EXISTS pickup_game_poll_votes_select ON public.pickup_game_poll_votes';
    EXECUTE 'DROP POLICY IF EXISTS pickup_game_poll_votes_no_direct_write ON public.pickup_game_poll_votes';
  END IF;
END $$;

-- 2) Drop prior review-draft function signatures (arbitrary-user / broad-grant drafts).
-- NOTE: Do NOT drop pickup_game_poll_effective_status(public.pickup_game_polls) here —
-- on a clean DB the composite type does not exist yet and PostgreSQL fails argument
-- resolution even with IF EXISTS. That typed drop runs after CREATE TABLE below.
-- Order: client-facing wrappers first, then internal helpers they call.
DROP FUNCTION IF EXISTS public.can_access_pickup_game_poll_conversation(uuid, uuid);
DROP FUNCTION IF EXISTS public.can_access_pickup_game_poll_conversation(uuid);
DROP FUNCTION IF EXISTS public.is_pickup_game_poll_organizer(uuid, uuid);
DROP FUNCTION IF EXISTS public.is_pickup_game_poll_organizer(uuid);
DROP FUNCTION IF EXISTS public.close_due_pickup_game_polls(uuid);
DROP FUNCTION IF EXISTS public._pickup_poll_user_can_access(uuid, uuid);
DROP FUNCTION IF EXISTS public._pickup_poll_user_is_organizer(uuid, uuid);
DROP FUNCTION IF EXISTS public._close_pickup_game_poll_if_due(uuid);
DROP FUNCTION IF EXISTS public._pickup_poll_normalize_moderation_text(text);
DROP FUNCTION IF EXISTS public._pickup_poll_text_is_prohibited(text);

-- =============================================================================
-- Tables
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.pickup_game_polls (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Immutable pickup identity for chat history. No FK CASCADE: hard-deleting a
  -- pickup_games row must not erase poll history (soft cancel archives via trigger).
  pickup_game_id uuid NOT NULL,
  -- Conversation must remain for history; RESTRICT prevents silent erase.
  conversation_id uuid NOT NULL,
  message_id uuid NULL,
  -- Creator may be cleared on account deletion; question/options remain.
  created_by uuid NULL,
  question text NOT NULL,
  allow_multiple boolean NOT NULL DEFAULT false,
  is_anonymous boolean NOT NULL DEFAULT false,
  auto_close_at_game_start boolean NOT NULL DEFAULT true,
  closes_at timestamptz NULL,
  status text NOT NULL DEFAULT 'open'
    CHECK (status IN ('open', 'closed', 'archived')),
  closed_at timestamptz NULL,
  closed_by uuid NULL,
  pinned_at timestamptz NULL,
  deleted_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pickup_game_polls_question_len_ck
    CHECK (char_length(btrim(question)) BETWEEN 1 AND 120)
);

CREATE TABLE IF NOT EXISTS public.pickup_game_poll_options (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  poll_id uuid NOT NULL REFERENCES public.pickup_game_polls (id) ON DELETE CASCADE,
  option_text text NOT NULL,
  sort_order integer NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pickup_game_poll_options_text_len_ck
    CHECK (char_length(btrim(option_text)) BETWEEN 1 AND 40),
  CONSTRAINT pickup_game_poll_options_sort_ck
    CHECK (sort_order BETWEEN 0 AND 7),
  CONSTRAINT pickup_game_poll_options_poll_sort_uq UNIQUE (poll_id, sort_order)
);

CREATE TABLE IF NOT EXISTS public.pickup_game_poll_votes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  poll_id uuid NOT NULL REFERENCES public.pickup_game_polls (id) ON DELETE CASCADE,
  option_id uuid NOT NULL REFERENCES public.pickup_game_poll_options (id) ON DELETE CASCADE,
  -- No auth.users FK CASCADE: deleting a voter account must not erase vote history.
  voter_user_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pickup_game_poll_votes_poll_option_voter_uq
    UNIQUE (poll_id, option_id, voter_user_id)
);

-- Prior-draft cleanup that requires the composite type (safe only after CREATE TABLE).
DO $$
BEGIN
  IF to_regclass('public.pickup_game_polls') IS NOT NULL THEN
    EXECUTE 'DROP FUNCTION IF EXISTS public.pickup_game_poll_effective_status(public.pickup_game_polls)';
  END IF;
END $$;

-- Corrective FK / nullability for environments that applied an earlier draft.
DO $$
DECLARE
  r record;
BEGIN
  -- Drop destructive / overly-tight FKs from prior draft, then re-add safe ones.
  FOR r IN
    SELECT c.conname, c.conrelid::regclass AS tbl
    FROM pg_constraint c
    WHERE c.contype = 'f'
      AND c.conrelid IN (
        'public.pickup_game_polls'::regclass,
        'public.pickup_game_poll_votes'::regclass
      )
  LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT IF EXISTS %I', r.tbl, r.conname);
  END LOOP;

  -- created_by: nullable + SET NULL (preserve poll row on account deletion).
  BEGIN
    ALTER TABLE public.pickup_game_polls
      ALTER COLUMN created_by DROP NOT NULL;
  EXCEPTION
    WHEN others THEN NULL;
  END;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'pickup_game_polls_conversation_id_fkey'
  ) THEN
    ALTER TABLE public.pickup_game_polls
      ADD CONSTRAINT pickup_game_polls_conversation_id_fkey
        FOREIGN KEY (conversation_id)
        REFERENCES public.group_conversations (id)
        ON DELETE RESTRICT;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'pickup_game_polls_message_id_fkey'
  ) THEN
    ALTER TABLE public.pickup_game_polls
      ADD CONSTRAINT pickup_game_polls_message_id_fkey
        FOREIGN KEY (message_id)
        REFERENCES public.group_messages (id)
        ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'pickup_game_polls_created_by_fkey'
  ) THEN
    ALTER TABLE public.pickup_game_polls
      ADD CONSTRAINT pickup_game_polls_created_by_fkey
        FOREIGN KEY (created_by)
        REFERENCES auth.users (id)
        ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'pickup_game_polls_closed_by_fkey'
  ) THEN
    ALTER TABLE public.pickup_game_polls
      ADD CONSTRAINT pickup_game_polls_closed_by_fkey
        FOREIGN KEY (closed_by)
        REFERENCES auth.users (id)
        ON DELETE SET NULL;
  END IF;

  -- Intentionally NO FK from pickup_game_id → pickup_games (history retention).
  -- Intentionally NO FK from voter_user_id → auth.users (history retention).
END $$;

-- Re-add option/vote FKs that may have been dropped above with the polls table sweep.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'pickup_game_poll_options_poll_id_fkey'
  ) THEN
    ALTER TABLE public.pickup_game_poll_options
      ADD CONSTRAINT pickup_game_poll_options_poll_id_fkey
      FOREIGN KEY (poll_id) REFERENCES public.pickup_game_polls (id) ON DELETE CASCADE;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'pickup_game_poll_votes_poll_id_fkey'
  ) THEN
    ALTER TABLE public.pickup_game_poll_votes
      ADD CONSTRAINT pickup_game_poll_votes_poll_id_fkey
      FOREIGN KEY (poll_id) REFERENCES public.pickup_game_polls (id) ON DELETE CASCADE;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'pickup_game_poll_votes_option_id_fkey'
  ) THEN
    ALTER TABLE public.pickup_game_poll_votes
      ADD CONSTRAINT pickup_game_poll_votes_option_id_fkey
      FOREIGN KEY (option_id) REFERENCES public.pickup_game_poll_options (id) ON DELETE CASCADE;
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS pickup_game_polls_message_id_uq
  ON public.pickup_game_polls (message_id)
  WHERE message_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS pickup_game_polls_conversation_idx
  ON public.pickup_game_polls (conversation_id)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS pickup_game_polls_pickup_idx
  ON public.pickup_game_polls (pickup_game_id)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS pickup_game_polls_open_closes_at_idx
  ON public.pickup_game_polls (closes_at)
  WHERE status = 'open' AND deleted_at IS NULL AND closes_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS pickup_game_poll_options_poll_idx
  ON public.pickup_game_poll_options (poll_id, sort_order);

CREATE INDEX IF NOT EXISTS pickup_game_poll_votes_poll_idx
  ON public.pickup_game_poll_votes (poll_id);

CREATE INDEX IF NOT EXISTS pickup_game_poll_votes_option_idx
  ON public.pickup_game_poll_votes (option_id);

CREATE INDEX IF NOT EXISTS pickup_game_poll_votes_voter_idx
  ON public.pickup_game_poll_votes (poll_id, voter_user_id);

COMMENT ON TABLE public.pickup_game_polls IS
  'Pickup-game chat polls. Soft-deleted and archived rows remain for chat history. pickup_game_id is retained without CASCADE FK.';
COMMENT ON COLUMN public.pickup_game_polls.pickup_game_id IS
  'Immutable pickup id for history. Not FK-cascaded so hard game deletes cannot erase polls.';
COMMENT ON COLUMN public.pickup_game_polls.pinned_at IS
  'Future-ready pin hook; null means unpinned.';
COMMENT ON TABLE public.pickup_game_poll_votes IS
  'One row per (poll, option, voter). Single-answer polls replace via RPC.';

-- =============================================================================
-- Internal auth + moderation helpers (NO client execute)
-- =============================================================================

CREATE OR REPLACE FUNCTION public._pickup_poll_user_can_access(
  p_conversation_id uuid,
  p_user_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pickup_id uuid;
BEGIN
  IF p_conversation_id IS NULL OR p_user_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT c.pickup_game_id
  INTO v_pickup_id
  FROM public.group_conversations c
  WHERE c.id = p_conversation_id;

  IF v_pickup_id IS NULL THEN
    RETURN false;
  END IF;

  IF NOT public.is_active_group_member(p_conversation_id, p_user_id) THEN
    RETURN false;
  END IF;

  RETURN public.is_pickup_game_chat_authorized(v_pickup_id, p_user_id);
END;
$$;

CREATE OR REPLACE FUNCTION public._pickup_poll_user_is_organizer(
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
    FROM public.pickup_games g
    WHERE g.id = p_pickup_game_id
      AND g.creator_user_id = p_user_id
  );
$$;

-- Client-safe wrapper: always auth.uid(), never accepts arbitrary user ids.
CREATE OR REPLACE FUNCTION public.can_access_pickup_game_poll_conversation(
  p_conversation_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public._pickup_poll_user_can_access(p_conversation_id, auth.uid());
$$;

CREATE OR REPLACE FUNCTION public.pickup_game_poll_effective_status(
  p_poll public.pickup_game_polls
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_poll.deleted_at IS NOT NULL THEN
    RETURN 'archived';
  END IF;
  IF p_poll.status = 'archived' THEN
    RETURN 'archived';
  END IF;
  IF p_poll.status = 'closed' THEN
    RETURN 'closed';
  END IF;
  -- Read-time close: does not write. Persist via vote path / service_role cleanup.
  IF p_poll.closes_at IS NOT NULL AND p_poll.closes_at <= now() THEN
    RETURN 'closed';
  END IF;
  RETURN 'open';
END;
$$;

-- Mirrors GameOn/ModerationClientChecks.swift blocked-term scan (authoritative for poll create).
-- No prior reusable SQL UGC moderation function existed in migrations; this is the in-DB guard.
CREATE OR REPLACE FUNCTION public._pickup_poll_normalize_moderation_text(p_text text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
STRICT
SET search_path = public
AS $$
DECLARE
  s text := lower(p_text);
BEGIN
  -- Mirror ModerationClientChecks.swift leet map (same substitution set).
  s := translate(s, '0134578$@!+', 'oieastbsait');
  s := regexp_replace(s, '[^a-z0-9]', '', 'g');
  RETURN s;
END;
$$;

CREATE OR REPLACE FUNCTION public._pickup_poll_text_is_prohibited(p_text text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
DECLARE
  collapsed text;
  tok text;
  long_words text[] := ARRAY[
    'fuck', 'shit', 'bitch', 'bastard', 'asshole', 'motherfucker', 'bullshit',
    'dickhead', 'dickbag', 'cocksuck', 'pisshead', 'douchebag', 'jackass',
    'dumbass', 'hardon', 'jerkoff', 'cumshot', 'blowjob', 'handjob',
    'faggot', 'nigger', 'nigga', 'spic', 'chink', 'kike', 'wetback', 'retard'
  ];
  short_tokens text[] := ARRAY[
    'fuk', 'fck', 'sht', 'cnt', 'dik', 'twat', 'slut', 'whore', 'piss', 'crap'
  ];
  w text;
BEGIN
  IF p_text IS NULL OR btrim(p_text) = '' THEN
    RETURN false;
  END IF;

  collapsed := public._pickup_poll_normalize_moderation_text(p_text);
  IF collapsed = '' THEN
    RETURN false;
  END IF;

  FOREACH w IN ARRAY long_words LOOP
    IF char_length(w) >= 4 AND position(w IN collapsed) > 0 THEN
      RETURN true;
    END IF;
  END LOOP;

  IF collapsed = ANY (short_tokens) THEN
    RETURN true;
  END IF;

  FOREACH tok IN ARRAY regexp_split_to_array(lower(p_text), '[^a-zA-Z0-9]+') LOOP
    IF tok IS NULL OR tok = '' THEN
      CONTINUE;
    END IF;
    tok := public._pickup_poll_normalize_moderation_text(tok);
    IF tok = ANY (short_tokens) THEN
      RETURN true;
    END IF;
  END LOOP;

  RETURN false;
END;
$$;

REVOKE ALL ON FUNCTION public._pickup_poll_user_can_access(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._pickup_poll_user_can_access(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public._pickup_poll_user_can_access(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public._pickup_poll_user_can_access(uuid, uuid) TO service_role;

REVOKE ALL ON FUNCTION public._pickup_poll_user_is_organizer(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._pickup_poll_user_is_organizer(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public._pickup_poll_user_is_organizer(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public._pickup_poll_user_is_organizer(uuid, uuid) TO service_role;

REVOKE ALL ON FUNCTION public.can_access_pickup_game_poll_conversation(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_access_pickup_game_poll_conversation(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.can_access_pickup_game_poll_conversation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_access_pickup_game_poll_conversation(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.pickup_game_poll_effective_status(public.pickup_game_polls) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pickup_game_poll_effective_status(public.pickup_game_polls) FROM anon;
REVOKE ALL ON FUNCTION public.pickup_game_poll_effective_status(public.pickup_game_polls) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.pickup_game_poll_effective_status(public.pickup_game_polls) TO service_role;

REVOKE ALL ON FUNCTION public._pickup_poll_normalize_moderation_text(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._pickup_poll_normalize_moderation_text(text) FROM anon;
REVOKE ALL ON FUNCTION public._pickup_poll_normalize_moderation_text(text) FROM authenticated;

REVOKE ALL ON FUNCTION public._pickup_poll_text_is_prohibited(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._pickup_poll_text_is_prohibited(text) FROM anon;
REVOKE ALL ON FUNCTION public._pickup_poll_text_is_prohibited(text) FROM authenticated;

-- =============================================================================
-- Auto-close / archive maintenance
-- =============================================================================

-- Single-poll persist-if-due. Internal write helper used by vote / attach paths.
CREATE OR REPLACE FUNCTION public._close_pickup_game_poll_if_due(p_poll_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count integer := 0;
BEGIN
  IF p_poll_id IS NULL THEN
    RETURN false;
  END IF;

  UPDATE public.pickup_game_polls p
  SET
    status = 'closed',
    closed_at = coalesce(p.closed_at, now()),
    updated_at = now()
  WHERE p.id = p_poll_id
    AND p.deleted_at IS NULL
    AND p.status = 'open'
    AND p.closes_at IS NOT NULL
    AND p.closes_at <= now();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count > 0;
END;
$$;

-- Global (or optional single-id) maintenance. service_role ONLY.
CREATE OR REPLACE FUNCTION public.close_due_pickup_game_polls(p_poll_id uuid DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count integer := 0;
BEGIN
  UPDATE public.pickup_game_polls p
  SET
    status = 'closed',
    closed_at = coalesce(p.closed_at, now()),
    updated_at = now()
  WHERE p.deleted_at IS NULL
    AND p.status = 'open'
    AND p.closes_at IS NOT NULL
    AND p.closes_at <= now()
    AND (p_poll_id IS NULL OR p.id = p_poll_id);

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.archive_pickup_game_polls_for_game(p_pickup_game_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count integer := 0;
BEGIN
  IF p_pickup_game_id IS NULL THEN
    RETURN 0;
  END IF;

  UPDATE public.pickup_game_polls p
  SET
    status = 'archived',
    closed_at = coalesce(p.closed_at, now()),
    updated_at = now()
  WHERE p.pickup_game_id = p_pickup_game_id
    AND p.deleted_at IS NULL
    AND p.status <> 'archived';

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_pickup_game_archive_polls()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF (
         lower(btrim(coalesce(NEW.status, ''))) IN ('removed', 'cancelled', 'canceled', 'expired')
         OR NEW.archived_at IS NOT NULL
       )
       AND (
         lower(btrim(coalesce(OLD.status, ''))) IS DISTINCT FROM lower(btrim(coalesce(NEW.status, '')))
         OR OLD.archived_at IS DISTINCT FROM NEW.archived_at
       )
    THEN
      PERFORM public.archive_pickup_game_polls_for_game(NEW.id);
    END IF;

    IF NEW.game_start_at IS DISTINCT FROM OLD.game_start_at THEN
      UPDATE public.pickup_game_polls p
      SET
        closes_at = NEW.game_start_at,
        updated_at = now()
      WHERE p.pickup_game_id = NEW.id
        AND p.deleted_at IS NULL
        AND p.status = 'open'
        AND p.auto_close_at_game_start = true;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS pickup_game_archive_polls ON public.pickup_games;
CREATE TRIGGER pickup_game_archive_polls
  AFTER UPDATE OF status, archived_at, game_start_at
  ON public.pickup_games
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_pickup_game_archive_polls();

REVOKE ALL ON FUNCTION public._close_pickup_game_poll_if_due(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._close_pickup_game_poll_if_due(uuid) FROM anon;
REVOKE ALL ON FUNCTION public._close_pickup_game_poll_if_due(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public._close_pickup_game_poll_if_due(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.close_due_pickup_game_polls(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.close_due_pickup_game_polls(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.close_due_pickup_game_polls(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.close_due_pickup_game_polls(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.archive_pickup_game_polls_for_game(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.archive_pickup_game_polls_for_game(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.archive_pickup_game_polls_for_game(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.archive_pickup_game_polls_for_game(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.trg_pickup_game_archive_polls() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.trg_pickup_game_archive_polls() FROM anon;
REVOKE ALL ON FUNCTION public.trg_pickup_game_archive_polls() FROM authenticated;

-- =============================================================================
-- RPCs (client signatures unchanged for Swift PickupGamePollService)
-- =============================================================================

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
  v_question text;
  v_opt text;
  v_norm text;
  v_seen text[] := ARRAY[]::text[];
  v_poll_id uuid;
  v_closes_at timestamptz := NULL;
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

  SELECT g.creator_user_id, g.game_start_at
  INTO v_creator, v_game_start
  FROM public.pickup_games g
  WHERE g.id = v_pickup_id;

  IF v_creator IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'Only the organizer can create polls.';
  END IF;

  v_question := left(btrim(coalesce(p_question, '')), 120);
  IF v_question IS NULL OR char_length(v_question) < 1 THEN
    RAISE EXCEPTION 'Enter a question for this poll.';
  END IF;

  IF public._pickup_poll_text_is_prohibited(v_question) THEN
    RAISE EXCEPTION 'This poll contains content that isn''t allowed.';
  END IF;

  IF p_options IS NULL OR coalesce(array_length(p_options, 1), 0) < 2 THEN
    RAISE EXCEPTION 'Add at least two answers.';
  END IF;
  IF coalesce(array_length(p_options, 1), 0) > 8 THEN
    RAISE EXCEPTION 'Polls support up to 8 answers.';
  END IF;

  FOR i IN 1 .. array_length(p_options, 1) LOOP
    v_opt := left(btrim(coalesce(p_options[i], '')), 40);
    IF v_opt IS NULL OR char_length(v_opt) < 1 THEN
      RAISE EXCEPTION 'Answers cannot be empty.';
    END IF;
    IF public._pickup_poll_text_is_prohibited(v_opt) THEN
      RAISE EXCEPTION 'This poll contains content that isn''t allowed.';
    END IF;
    v_norm := lower(v_opt);
    IF v_norm = ANY (v_seen) THEN
      RAISE EXCEPTION 'Answers must be unique.';
    END IF;
    v_seen := v_seen || ARRAY[v_norm];
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

  FOR i IN 1 .. array_length(p_options, 1) LOOP
    v_opt := left(btrim(coalesce(p_options[i], '')), 40);
    INSERT INTO public.pickup_game_poll_options (poll_id, option_text, sort_order)
    VALUES (v_poll_id, v_opt, i - 1);
  END LOOP;

  RETURN v_poll_id;
END;
$$;

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

  -- Poll creator may attach (organizer or approved player per poll_create_permission).
  -- Close/delete/pin remain organizer-only in their RPCs.

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

CREATE OR REPLACE FUNCTION public.set_pickup_game_poll_vote(
  p_poll_id uuid,
  p_option_ids uuid[]
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_poll public.pickup_game_polls%ROWTYPE;
  v_status text;
  v_ids uuid[];
  v_opt uuid;
  v_valid_count integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- Persist due close for THIS poll only (not global). Idempotent.
  PERFORM public._close_pickup_game_poll_if_due(p_poll_id);

  -- Lock poll row for transaction serialization (prevents concurrent vote races).
  SELECT * INTO v_poll
  FROM public.pickup_game_polls
  WHERE id = p_poll_id
  FOR UPDATE;

  IF NOT FOUND OR v_poll.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'Poll not found.';
  END IF;

  IF NOT public._pickup_poll_user_can_access(v_poll.conversation_id, v_uid) THEN
    RAISE EXCEPTION 'Not authorized.';
  END IF;

  -- Belt-and-suspenders: serialize per (poll, voter) across concurrent RPCs.
  PERFORM pg_advisory_xact_lock(hashtext(p_poll_id::text || ':' || v_uid::text));

  v_status := public.pickup_game_poll_effective_status(v_poll);
  IF v_status <> 'open' THEN
    RAISE EXCEPTION 'This poll is closed.';
  END IF;

  v_ids := ARRAY(
    SELECT DISTINCT x
    FROM unnest(coalesce(p_option_ids, ARRAY[]::uuid[])) AS x
    WHERE x IS NOT NULL
  );

  IF coalesce(array_length(v_ids, 1), 0) = 0 THEN
    DELETE FROM public.pickup_game_poll_votes
    WHERE poll_id = p_poll_id
      AND voter_user_id = v_uid;
    UPDATE public.pickup_game_polls
    SET updated_at = now()
    WHERE id = p_poll_id;
    RETURN;
  END IF;

  IF NOT v_poll.allow_multiple AND coalesce(array_length(v_ids, 1), 0) > 1 THEN
    RAISE EXCEPTION 'This poll allows only one answer.';
  END IF;

  SELECT count(*)::integer
  INTO v_valid_count
  FROM public.pickup_game_poll_options o
  WHERE o.poll_id = p_poll_id
    AND o.id = ANY (v_ids);

  IF v_valid_count IS DISTINCT FROM coalesce(array_length(v_ids, 1), 0) THEN
    RAISE EXCEPTION 'Invalid poll answer.';
  END IF;

  IF NOT v_poll.allow_multiple THEN
    -- Single-choice: delete ALL prior votes for (poll, voter), then insert the
    -- one option. Avoids partial-delete + multi-insert races under concurrency.
    DELETE FROM public.pickup_game_poll_votes
    WHERE poll_id = p_poll_id
      AND voter_user_id = v_uid;

    INSERT INTO public.pickup_game_poll_votes (poll_id, option_id, voter_user_id)
    VALUES (p_poll_id, v_ids[1], v_uid)
    ON CONFLICT (poll_id, option_id, voter_user_id)
    DO UPDATE SET updated_at = now();
  ELSE
    -- Multiple-choice: upsert selected set (delete removed, insert new).
    DELETE FROM public.pickup_game_poll_votes
    WHERE poll_id = p_poll_id
      AND voter_user_id = v_uid
      AND NOT (option_id = ANY (v_ids));

    FOREACH v_opt IN ARRAY v_ids LOOP
      INSERT INTO public.pickup_game_poll_votes (poll_id, option_id, voter_user_id)
      VALUES (p_poll_id, v_opt, v_uid)
      ON CONFLICT (poll_id, option_id, voter_user_id)
      DO UPDATE SET updated_at = now();
    END LOOP;
  END IF;

  -- Bump poll.updated_at for Realtime (no recursive trigger on votes).
  UPDATE public.pickup_game_polls
  SET updated_at = now()
  WHERE id = p_poll_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.close_pickup_game_poll(p_poll_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_poll public.pickup_game_polls%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT * INTO v_poll FROM public.pickup_game_polls WHERE id = p_poll_id;
  IF NOT FOUND OR v_poll.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'Poll not found.';
  END IF;

  IF NOT public._pickup_poll_user_is_organizer(v_poll.pickup_game_id, v_uid) THEN
    RAISE EXCEPTION 'Only the organizer can close polls.';
  END IF;

  -- Terminal states are not reopened.
  UPDATE public.pickup_game_polls
  SET
    status = CASE WHEN status = 'archived' THEN 'archived' ELSE 'closed' END,
    closed_at = coalesce(closed_at, now()),
    closed_by = v_uid,
    updated_at = now()
  WHERE id = p_poll_id
    AND deleted_at IS NULL
    AND status = 'open';
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_pickup_game_poll(p_poll_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_poll public.pickup_game_polls%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT * INTO v_poll FROM public.pickup_game_polls WHERE id = p_poll_id;
  IF NOT FOUND OR v_poll.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'Poll not found.';
  END IF;

  IF NOT public._pickup_poll_user_is_organizer(v_poll.pickup_game_id, v_uid) THEN
    RAISE EXCEPTION 'Only the organizer can delete polls.';
  END IF;

  UPDATE public.pickup_game_polls
  SET
    deleted_at = now(),
    status = 'archived',
    closed_at = coalesce(closed_at, now()),
    closed_by = coalesce(closed_by, v_uid),
    updated_at = now()
  WHERE id = p_poll_id
    AND deleted_at IS NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.pin_pickup_game_poll(
  p_poll_id uuid,
  p_pinned boolean DEFAULT true
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_poll public.pickup_game_polls%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT * INTO v_poll FROM public.pickup_game_polls WHERE id = p_poll_id;
  IF NOT FOUND OR v_poll.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'Poll not found.';
  END IF;

  IF NOT public._pickup_poll_user_is_organizer(v_poll.pickup_game_id, v_uid) THEN
    RAISE EXCEPTION 'Only the organizer can pin polls.';
  END IF;

  UPDATE public.pickup_game_polls
  SET
    pinned_at = CASE WHEN coalesce(p_pinned, true) THEN coalesce(pinned_at, now()) ELSE NULL END,
    updated_at = now()
  WHERE id = p_poll_id
    AND deleted_at IS NULL;
END;
$$;

-- STABLE + side-effect free. Due polls appear closed via effective_status without UPDATE.
CREATE OR REPLACE FUNCTION public.get_pickup_game_poll_snapshot(p_poll_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_poll public.pickup_game_polls%ROWTYPE;
  v_status text;
  v_total integer;
  v_options jsonb;
  v_my_votes uuid[];
  v_voters jsonb := '[]'::jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT * INTO v_poll FROM public.pickup_game_polls WHERE id = p_poll_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Poll not found.';
  END IF;

  IF NOT public._pickup_poll_user_can_access(v_poll.conversation_id, v_uid) THEN
    RAISE EXCEPTION 'Not authorized.';
  END IF;

  v_status := public.pickup_game_poll_effective_status(v_poll);

  SELECT count(DISTINCT v.voter_user_id)::integer
  INTO v_total
  FROM public.pickup_game_poll_votes v
  WHERE v.poll_id = p_poll_id;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', o.id,
        'text', o.option_text,
        'sort_order', o.sort_order,
        'vote_count', coalesce(vc.cnt, 0)
      )
      ORDER BY o.sort_order
    ),
    '[]'::jsonb
  )
  INTO v_options
  FROM public.pickup_game_poll_options o
  LEFT JOIN LATERAL (
    SELECT count(*)::integer AS cnt
    FROM public.pickup_game_poll_votes v
    WHERE v.option_id = o.id
  ) vc ON true
  WHERE o.poll_id = p_poll_id;

  SELECT coalesce(array_agg(v.option_id), ARRAY[]::uuid[])
  INTO v_my_votes
  FROM public.pickup_game_poll_votes v
  WHERE v.poll_id = p_poll_id
    AND v.voter_user_id = v_uid;

  IF NOT v_poll.is_anonymous THEN
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'option_id', v.option_id,
          'voter_user_id', v.voter_user_id
        )
      ),
      '[]'::jsonb
    )
    INTO v_voters
    FROM public.pickup_game_poll_votes v
    WHERE v.poll_id = p_poll_id;
  END IF;

  RETURN jsonb_build_object(
    'id', v_poll.id,
    'pickup_game_id', v_poll.pickup_game_id,
    'conversation_id', v_poll.conversation_id,
    'message_id', v_poll.message_id,
    'created_by', v_poll.created_by,
    'question', v_poll.question,
    'allow_multiple', v_poll.allow_multiple,
    'is_anonymous', v_poll.is_anonymous,
    'auto_close_at_game_start', v_poll.auto_close_at_game_start,
    'closes_at', v_poll.closes_at,
    'status', v_status,
    'closed_at', v_poll.closed_at,
    'pinned_at', v_poll.pinned_at,
    'deleted_at', v_poll.deleted_at,
    'created_at', v_poll.created_at,
    'updated_at', v_poll.updated_at,
    'total_voters', v_total,
    'options', v_options,
    'my_option_ids', to_jsonb(coalesce(v_my_votes, ARRAY[]::uuid[])),
    'voters', v_voters,
    'viewer_is_organizer', public._pickup_poll_user_is_organizer(v_poll.pickup_game_id, v_uid)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_pickup_game_poll(uuid, text, text[], boolean, boolean, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_pickup_game_poll(uuid, text, text[], boolean, boolean, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.create_pickup_game_poll(uuid, text, text[], boolean, boolean, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_pickup_game_poll(uuid, text, text[], boolean, boolean, boolean) TO service_role;

REVOKE ALL ON FUNCTION public.attach_pickup_game_poll_message(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.attach_pickup_game_poll_message(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.attach_pickup_game_poll_message(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.attach_pickup_game_poll_message(uuid, uuid) TO service_role;

REVOKE ALL ON FUNCTION public.set_pickup_game_poll_vote(uuid, uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_pickup_game_poll_vote(uuid, uuid[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_pickup_game_poll_vote(uuid, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_pickup_game_poll_vote(uuid, uuid[]) TO service_role;

REVOKE ALL ON FUNCTION public.close_pickup_game_poll(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.close_pickup_game_poll(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.close_pickup_game_poll(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.close_pickup_game_poll(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.delete_pickup_game_poll(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_pickup_game_poll(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.delete_pickup_game_poll(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_pickup_game_poll(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.pin_pickup_game_poll(uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pin_pickup_game_poll(uuid, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.pin_pickup_game_poll(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pin_pickup_game_poll(uuid, boolean) TO service_role;

REVOKE ALL ON FUNCTION public.get_pickup_game_poll_snapshot(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_pickup_game_poll_snapshot(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_pickup_game_poll_snapshot(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_pickup_game_poll_snapshot(uuid) TO service_role;

-- =============================================================================
-- RLS
-- =============================================================================

ALTER TABLE public.pickup_game_polls ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pickup_game_poll_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pickup_game_poll_votes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pickup_game_polls_select ON public.pickup_game_polls;
DROP POLICY IF EXISTS pickup_game_polls_no_direct_write ON public.pickup_game_polls;
CREATE POLICY pickup_game_polls_select
  ON public.pickup_game_polls
  FOR SELECT
  TO authenticated
  USING (public.can_access_pickup_game_poll_conversation(conversation_id));
-- Writes: SECURITY DEFINER RPCs only.

DROP POLICY IF EXISTS pickup_game_poll_options_select ON public.pickup_game_poll_options;
DROP POLICY IF EXISTS pickup_game_poll_options_no_direct_write ON public.pickup_game_poll_options;
CREATE POLICY pickup_game_poll_options_select
  ON public.pickup_game_poll_options
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.pickup_game_polls p
      WHERE p.id = poll_id
        AND public.can_access_pickup_game_poll_conversation(p.conversation_id)
    )
  );

DROP POLICY IF EXISTS pickup_game_poll_votes_select ON public.pickup_game_poll_votes;
DROP POLICY IF EXISTS pickup_game_poll_votes_no_direct_write ON public.pickup_game_poll_votes;
CREATE POLICY pickup_game_poll_votes_select
  ON public.pickup_game_poll_votes
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.pickup_game_polls p
      WHERE p.id = poll_id
        AND public.can_access_pickup_game_poll_conversation(p.conversation_id)
        AND (
          p.is_anonymous = false
          OR voter_user_id = auth.uid()
        )
    )
  );

REVOKE ALL ON TABLE public.pickup_game_polls FROM PUBLIC;
REVOKE ALL ON TABLE public.pickup_game_polls FROM anon;
GRANT SELECT ON TABLE public.pickup_game_polls TO authenticated;
GRANT ALL ON TABLE public.pickup_game_polls TO service_role;

REVOKE ALL ON TABLE public.pickup_game_poll_options FROM PUBLIC;
REVOKE ALL ON TABLE public.pickup_game_poll_options FROM anon;
GRANT SELECT ON TABLE public.pickup_game_poll_options TO authenticated;
GRANT ALL ON TABLE public.pickup_game_poll_options TO service_role;

REVOKE ALL ON TABLE public.pickup_game_poll_votes FROM PUBLIC;
REVOKE ALL ON TABLE public.pickup_game_poll_votes FROM anon;
GRANT SELECT ON TABLE public.pickup_game_poll_votes TO authenticated;
GRANT ALL ON TABLE public.pickup_game_poll_votes TO service_role;

-- Realtime: poll row updates (including vote-driven updated_at). Idempotent add.
DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.pickup_game_polls;
  EXCEPTION
    WHEN duplicate_object THEN NULL;
  END;
  -- Votes table is NOT required for clients (snapshot refresh on poll.updated_at).
  -- Keep votes out of realtime by default to avoid redundant fan-out; safe no-op drop if added by draft.
  BEGIN
    ALTER PUBLICATION supabase_realtime DROP TABLE public.pickup_game_poll_votes;
  EXCEPTION
    WHEN undefined_object THEN NULL;
    WHEN others THEN NULL;
  END;
END $$;

COMMIT;

-- =============================================================================
-- Verification matrix (read-only / manual review — do not auto-run in prod apply)
-- =============================================================================
-- A. Snapshot volatility:
--    SELECT p.proname, p.provolatile
--    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public' AND p.proname = 'get_pickup_game_poll_snapshot';
--    -- expect 's' (STABLE). Body must not call close_due / _close_* write helpers.
--
-- B/C. Attach denial (wrong conversation / wrong sender / missing sentinel):
--    SELECT public.attach_pickup_game_poll_message('<poll>', '<wrong_message>');
--    -- expect exception.
--
-- D. Internal helpers not executable by authenticated:
--    SELECT has_function_privilege('authenticated',
--      'public._pickup_poll_user_can_access(uuid,uuid)', 'EXECUTE');  -- false
--    SELECT has_function_privilege('authenticated',
--      'public._pickup_poll_user_is_organizer(uuid,uuid)', 'EXECUTE'); -- false
--
-- E/F. Global close grants:
--    SELECT has_function_privilege('authenticated',
--      'public.close_due_pickup_game_polls(uuid)', 'EXECUTE'); -- false
--    SELECT has_function_privilege('service_role',
--      'public.close_due_pickup_game_polls(uuid)', 'EXECUTE'); -- true
--
-- G/H. History FKs:
--    SELECT conname, confdeltype, pg_get_constraintdef(oid)
--    FROM pg_constraint
--    WHERE conrelid = 'public.pickup_game_polls'::regclass AND contype = 'f';
--    -- no pickup_game_id FK; created_by ON DELETE SET NULL; conversation RESTRICT;
--    -- message SET NULL. No CASCADE from pickup_games/auth.users onto polls.
--
-- I. Prohibited content:
--    SELECT public.create_pickup_game_poll(conv, 'what the fuck', ARRAY['a','b'], false, false, true);
--    -- expect "isn't allowed" (as authenticated organizer).
--
-- J. Nonmember:
--    SELECT public.get_pickup_game_poll_snapshot('<poll>'); -- as nonmember → Not authorized
--    SELECT public.set_pickup_game_poll_vote('<poll>', ARRAY['<opt>']); -- Not authorized
--
-- K. Anonymous voters hidden in snapshot JSON: voters = [] when is_anonymous.
--
-- L. Closed/archived:
--    After status closed/archived or closes_at <= now(), set_pickup_game_poll_vote raises
--    'This poll is closed.'
--
-- M. Concurrent single-choice vote serialization (manual / staging):
--    Setup: allow_multiple=false poll with options A and B; voter has vote on A.
--    Two concurrent sessions (same voter) call:
--      set_pickup_game_poll_vote(poll, ARRAY[B])
--      set_pickup_game_poll_vote(poll, ARRAY[A])
--    Expect: both complete without unique-violation / lost-update errors;
--    final vote count for voter = exactly 1 row; option_id is either A or B
--    (last commit wins). FOR UPDATE on poll + pg_advisory_xact_lock(poll:voter)
--    serialize the delete-all-then-insert-one path.
--    Multi-choice (allow_multiple=true) keeps upsert-of-selected-set under the
--    same locks; option-belongs-to-poll + open + access checks unchanged.
-- =============================================================================
