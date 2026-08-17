-- =============================================================================
-- 20260971_0001 — Fan Team Chat Polls (review-ready; do NOT auto-apply)
-- =============================================================================
-- Extends the pickup poll architecture (__FG_POLL_V1__ messages + snapshot shape)
-- to Team Chat via parallel tables/RPCs. Does not weaken pickup poll RLS.
--
-- Setting on fan_teams.poll_create_permission:
--   management_only (default) | anyone
-- Create/close/delete/pin enforced server-side from fan_team_members roles
-- (Owner/Manager via fan_team_viewer_can_manage). Captain is NOT management.
-- Managed-player seats never grant chat/poll rights; only auth.uid() account seats.
--
-- Volatility: fan_team_poll_effective_status is STABLE (uses now() for closes_at).
-- =============================================================================

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.fan_teams') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_teams'];
  END IF;
  IF to_regclass('public.fan_team_members') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_team_members'];
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
  IF to_regprocedure('public.fan_team_viewer_can_manage(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.fan_team_viewer_can_manage(uuid)'];
  END IF;
  IF to_regprocedure('public.fan_team_role_is_manager_or_owner(text)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.fan_team_role_is_manager_or_owner(text)'];
  END IF;
  IF to_regprocedure('public._pickup_poll_text_is_prohibited(text)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public._pickup_poll_text_is_prohibited(text)'];
  END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION
      '20260971_0001 prerequisites missing: %',
      array_to_string(v_missing, ', ');
  END IF;
END $$;

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Team poll-create permission column
-- -----------------------------------------------------------------------------
ALTER TABLE public.fan_teams
  ADD COLUMN IF NOT EXISTS poll_create_permission text;

ALTER TABLE public.fan_teams
  ALTER COLUMN poll_create_permission SET DEFAULT 'management_only';

ALTER TABLE public.fan_teams
  DROP CONSTRAINT IF EXISTS fan_teams_poll_create_permission_ck;

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT c.conname
    FROM pg_constraint c
    WHERE c.conrelid = 'public.fan_teams'::regclass
      AND c.contype = 'c'
      AND pg_get_constraintdef(c.oid) ILIKE '%poll_create_permission%'
  LOOP
    EXECUTE format(
      'ALTER TABLE public.fan_teams DROP CONSTRAINT IF EXISTS %I',
      r.conname
    );
  END LOOP;
END $$;

UPDATE public.fan_teams
SET poll_create_permission = 'management_only'
WHERE poll_create_permission IS NULL
   OR btrim(poll_create_permission) = ''
   OR lower(btrim(poll_create_permission)) NOT IN ('management_only', 'anyone');

UPDATE public.fan_teams
SET poll_create_permission = lower(btrim(poll_create_permission))
WHERE poll_create_permission IS DISTINCT FROM lower(btrim(poll_create_permission))
  AND lower(btrim(poll_create_permission)) IN ('management_only', 'anyone');

ALTER TABLE public.fan_teams
  ALTER COLUMN poll_create_permission SET NOT NULL;

ALTER TABLE public.fan_teams
  ADD CONSTRAINT fan_teams_poll_create_permission_ck
  CHECK (poll_create_permission IN ('management_only', 'anyone'));

COMMENT ON COLUMN public.fan_teams.poll_create_permission IS
  'Who may create Team Chat polls: management_only (default) | anyone. Enforced by create_fan_team_poll; setting updates via set_fan_team_poll_create_permission (Owner/Manager only).';

-- -----------------------------------------------------------------------------
-- 2) Tables (mirror pickup shape; team_id instead of pickup_game_id)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.fan_team_polls (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id uuid NOT NULL,
  conversation_id uuid NOT NULL,
  message_id uuid NULL,
  created_by uuid NULL,
  question text NOT NULL,
  allow_multiple boolean NOT NULL DEFAULT false,
  is_anonymous boolean NOT NULL DEFAULT false,
  closes_at timestamptz NULL,
  status text NOT NULL DEFAULT 'open'
    CHECK (status IN ('open', 'closed', 'archived')),
  closed_at timestamptz NULL,
  closed_by uuid NULL,
  pinned_at timestamptz NULL,
  deleted_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fan_team_polls_question_len_ck
    CHECK (char_length(btrim(question)) BETWEEN 1 AND 120)
);

CREATE TABLE IF NOT EXISTS public.fan_team_poll_options (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  poll_id uuid NOT NULL REFERENCES public.fan_team_polls (id) ON DELETE CASCADE,
  option_text text NOT NULL,
  sort_order integer NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fan_team_poll_options_text_len_ck
    CHECK (char_length(btrim(option_text)) BETWEEN 1 AND 40),
  CONSTRAINT fan_team_poll_options_sort_ck
    CHECK (sort_order BETWEEN 0 AND 7),
  CONSTRAINT fan_team_poll_options_poll_sort_uq UNIQUE (poll_id, sort_order)
);

CREATE TABLE IF NOT EXISTS public.fan_team_poll_votes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  poll_id uuid NOT NULL REFERENCES public.fan_team_polls (id) ON DELETE CASCADE,
  option_id uuid NOT NULL REFERENCES public.fan_team_poll_options (id) ON DELETE CASCADE,
  voter_user_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fan_team_poll_votes_poll_option_voter_uq
    UNIQUE (poll_id, option_id, voter_user_id)
);

DO $$
BEGIN
  -- Explicit named FK changes only — do not drop unrelated/future FKs on these tables.
  ALTER TABLE public.fan_team_polls
    DROP CONSTRAINT IF EXISTS fan_team_polls_team_id_fkey;
  ALTER TABLE public.fan_team_polls
    ADD CONSTRAINT fan_team_polls_team_id_fkey
    FOREIGN KEY (team_id) REFERENCES public.fan_teams (id) ON DELETE RESTRICT;

  ALTER TABLE public.fan_team_polls
    DROP CONSTRAINT IF EXISTS fan_team_polls_conversation_id_fkey;
  ALTER TABLE public.fan_team_polls
    ADD CONSTRAINT fan_team_polls_conversation_id_fkey
    FOREIGN KEY (conversation_id) REFERENCES public.group_conversations (id) ON DELETE RESTRICT;

  ALTER TABLE public.fan_team_polls
    DROP CONSTRAINT IF EXISTS fan_team_polls_message_id_fkey;
  ALTER TABLE public.fan_team_polls
    ADD CONSTRAINT fan_team_polls_message_id_fkey
    FOREIGN KEY (message_id) REFERENCES public.group_messages (id) ON DELETE SET NULL;

  ALTER TABLE public.fan_team_polls
    DROP CONSTRAINT IF EXISTS fan_team_polls_created_by_fkey;
  ALTER TABLE public.fan_team_polls
    ADD CONSTRAINT fan_team_polls_created_by_fkey
    FOREIGN KEY (created_by) REFERENCES auth.users (id) ON DELETE SET NULL;

  -- Inline CREATE TABLE REFERENCES may use these names; reassert ON DELETE CASCADE.
  ALTER TABLE public.fan_team_poll_votes
    DROP CONSTRAINT IF EXISTS fan_team_poll_votes_poll_id_fkey;
  ALTER TABLE public.fan_team_poll_votes
    ADD CONSTRAINT fan_team_poll_votes_poll_id_fkey
    FOREIGN KEY (poll_id) REFERENCES public.fan_team_polls (id) ON DELETE CASCADE;

  ALTER TABLE public.fan_team_poll_votes
    DROP CONSTRAINT IF EXISTS fan_team_poll_votes_option_id_fkey;
  ALTER TABLE public.fan_team_poll_votes
    ADD CONSTRAINT fan_team_poll_votes_option_id_fkey
    FOREIGN KEY (option_id) REFERENCES public.fan_team_poll_options (id) ON DELETE CASCADE;
END $$;

CREATE INDEX IF NOT EXISTS fan_team_polls_conversation_updated_idx
  ON public.fan_team_polls (conversation_id, updated_at DESC)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS fan_team_polls_team_idx
  ON public.fan_team_polls (team_id)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS fan_team_poll_votes_poll_voter_idx
  ON public.fan_team_poll_votes (poll_id, voter_user_id);

-- -----------------------------------------------------------------------------
-- 3) Access helpers
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._fan_team_poll_user_can_access(
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
    FROM public.fan_teams t
    WHERE t.group_conversation_id = p_conversation_id
      AND t.is_active = true
      AND public.is_active_group_member(p_conversation_id, p_user_id)
  );
$$;

CREATE OR REPLACE FUNCTION public._fan_team_poll_user_can_manage(
  p_team_id uuid,
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
    FROM public.fan_team_members m
    WHERE m.team_id = p_team_id
      AND m.user_id = p_user_id
      AND m.left_at IS NULL
      AND public.fan_team_role_is_manager_or_owner(m.role)
  );
$$;

CREATE OR REPLACE FUNCTION public._fan_team_poll_user_can_create(
  p_team_id uuid,
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
  v_perm text;
BEGIN
  IF p_user_id IS NULL OR p_team_id IS NULL OR p_conversation_id IS NULL THEN
    RETURN false;
  END IF;

  IF NOT public._fan_team_poll_user_can_access(p_conversation_id, p_user_id) THEN
    RETURN false;
  END IF;

  IF public._fan_team_poll_user_can_manage(p_team_id, p_user_id) THEN
    RETURN true;
  END IF;

  SELECT lower(btrim(t.poll_create_permission))
  INTO v_perm
  FROM public.fan_teams t
  WHERE t.id = p_team_id
    AND t.is_active = true
    AND t.group_conversation_id = p_conversation_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  RETURN v_perm = 'anyone';
END;
$$;

CREATE OR REPLACE FUNCTION public.can_access_fan_team_poll_conversation(p_conversation_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public._fan_team_poll_user_can_access(p_conversation_id, auth.uid());
$$;

CREATE OR REPLACE FUNCTION public.fan_team_poll_effective_status(p_poll public.fan_team_polls)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
BEGIN
  IF p_poll.deleted_at IS NOT NULL THEN
    RETURN 'archived';
  END IF;
  IF p_poll.status IN ('closed', 'archived') THEN
    RETURN p_poll.status;
  END IF;
  IF p_poll.closes_at IS NOT NULL AND p_poll.closes_at <= now() THEN
    RETURN 'closed';
  END IF;
  RETURN 'open';
END;
$$;

CREATE OR REPLACE FUNCTION public._close_fan_team_poll_if_due(p_poll_id uuid)
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

  UPDATE public.fan_team_polls p
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

REVOKE ALL ON FUNCTION public._fan_team_poll_user_can_access(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._fan_team_poll_user_can_access(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public._fan_team_poll_user_can_access(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public._fan_team_poll_user_can_access(uuid, uuid) TO service_role;

REVOKE ALL ON FUNCTION public._fan_team_poll_user_can_manage(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._fan_team_poll_user_can_manage(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public._fan_team_poll_user_can_manage(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public._fan_team_poll_user_can_manage(uuid, uuid) TO service_role;

REVOKE ALL ON FUNCTION public._fan_team_poll_user_can_create(uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._fan_team_poll_user_can_create(uuid, uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public._fan_team_poll_user_can_create(uuid, uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public._fan_team_poll_user_can_create(uuid, uuid, uuid) TO service_role;

REVOKE ALL ON FUNCTION public.can_access_fan_team_poll_conversation(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_access_fan_team_poll_conversation(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.can_access_fan_team_poll_conversation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_access_fan_team_poll_conversation(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.fan_team_poll_effective_status(public.fan_team_polls) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fan_team_poll_effective_status(public.fan_team_polls) FROM anon;
REVOKE ALL ON FUNCTION public.fan_team_poll_effective_status(public.fan_team_polls) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_poll_effective_status(public.fan_team_polls) TO service_role;

REVOKE ALL ON FUNCTION public._close_fan_team_poll_if_due(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._close_fan_team_poll_if_due(uuid) FROM anon;
REVOKE ALL ON FUNCTION public._close_fan_team_poll_if_due(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public._close_fan_team_poll_if_due(uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 4) Permission get/set RPCs
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_fan_team_poll_access(p_team_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_team public.fan_teams%ROWTYPE;
  v_can_manage boolean;
  v_can_create boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT * INTO v_team
  FROM public.fan_teams t
  WHERE t.id = p_team_id
    AND t.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  IF NOT public._fan_team_poll_user_can_access(v_team.group_conversation_id, v_uid) THEN
    RAISE EXCEPTION 'Not authorized.';
  END IF;

  v_can_manage := public._fan_team_poll_user_can_manage(v_team.id, v_uid);
  v_can_create := public._fan_team_poll_user_can_create(
    v_team.id,
    v_team.group_conversation_id,
    v_uid
  );

  RETURN jsonb_build_object(
    'team_id', v_team.id,
    'conversation_id', v_team.group_conversation_id,
    'poll_create_permission', v_team.poll_create_permission,
    'viewer_can_manage', v_can_manage,
    'viewer_can_create', v_can_create
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.set_fan_team_poll_create_permission(
  p_team_id uuid,
  p_permission text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_perm text := lower(btrim(coalesce(p_permission, '')));
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_perm NOT IN ('management_only', 'anyone') THEN
    RAISE EXCEPTION 'Invalid poll create permission.';
  END IF;

  IF NOT public.fan_team_viewer_can_manage(p_team_id) THEN
    RAISE EXCEPTION 'Only team management can change poll permissions.';
  END IF;

  UPDATE public.fan_teams
  SET
    poll_create_permission = v_perm,
    updated_at = now()
  WHERE id = p_team_id
    AND is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  RETURN v_perm;
END;
$$;

REVOKE ALL ON FUNCTION public.get_fan_team_poll_access(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_fan_team_poll_access(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_fan_team_poll_access(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_fan_team_poll_access(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.set_fan_team_poll_create_permission(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_fan_team_poll_create_permission(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_fan_team_poll_create_permission(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_fan_team_poll_create_permission(uuid, text) TO service_role;

-- -----------------------------------------------------------------------------
-- 5) Create / attach / vote / close / delete / pin / snapshot
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_fan_team_poll(
  p_conversation_id uuid,
  p_question text,
  p_options text[],
  p_allow_multiple boolean DEFAULT false,
  p_is_anonymous boolean DEFAULT false
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_team_id uuid;
  v_question text;
  v_opt text;
  v_norm text;
  v_seen text[] := ARRAY[]::text[];
  v_poll_id uuid;
  i integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT t.id
  INTO v_team_id
  FROM public.fan_teams t
  WHERE t.group_conversation_id = p_conversation_id
    AND t.is_active = true;

  IF v_team_id IS NULL THEN
    RAISE EXCEPTION 'Polls are only available in Team chats.';
  END IF;

  IF NOT public._fan_team_poll_user_can_create(v_team_id, p_conversation_id, v_uid) THEN
    RAISE EXCEPTION 'Not authorized to create polls.';
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

  INSERT INTO public.fan_team_polls (
    team_id,
    conversation_id,
    created_by,
    question,
    allow_multiple,
    is_anonymous,
    status
  ) VALUES (
    v_team_id,
    p_conversation_id,
    v_uid,
    v_question,
    coalesce(p_allow_multiple, false),
    coalesce(p_is_anonymous, false),
    'open'
  )
  RETURNING id INTO v_poll_id;

  FOR i IN 1 .. array_length(p_options, 1) LOOP
    v_opt := left(btrim(coalesce(p_options[i], '')), 40);
    INSERT INTO public.fan_team_poll_options (poll_id, option_text, sort_order)
    VALUES (v_poll_id, v_opt, i - 1);
  END LOOP;

  RETURN v_poll_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.attach_fan_team_poll_message(
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
  v_poll public.fan_team_polls%ROWTYPE;
  v_msg public.group_messages%ROWTYPE;
  v_team_conv uuid;
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
  FROM public.fan_team_polls
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

  IF NOT public._fan_team_poll_user_can_access(v_poll.conversation_id, v_uid) THEN
    RAISE EXCEPTION 'Not authorized.';
  END IF;

  SELECT t.group_conversation_id
  INTO v_team_conv
  FROM public.fan_teams t
  WHERE t.id = v_poll.team_id
    AND t.is_active = true;

  IF v_team_conv IS NULL OR v_team_conv IS DISTINCT FROM v_poll.conversation_id THEN
    RAISE EXCEPTION 'Poll conversation is not the authorized Team chat.';
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
    RAISE EXCEPTION 'Message is not a structured poll message.';
  END IF;

  IF position(lower(p_poll_id::text) IN lower(v_body)) = 0 THEN
    RAISE EXCEPTION 'Message does not reference this poll.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.fan_team_polls p
    WHERE p.message_id = p_message_id
      AND p.id IS DISTINCT FROM p_poll_id
  ) THEN
    RAISE EXCEPTION 'Message is already attached to another poll.';
  END IF;

  IF v_poll.message_id IS NOT NULL AND v_poll.message_id IS DISTINCT FROM p_message_id THEN
    RAISE EXCEPTION 'Poll already has an attached message.';
  END IF;

  UPDATE public.fan_team_polls
  SET message_id = p_message_id,
      updated_at = now()
  WHERE id = p_poll_id
    AND (message_id IS NULL OR message_id = p_message_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.set_fan_team_poll_vote(
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
  v_poll public.fan_team_polls%ROWTYPE;
  v_status text;
  v_ids uuid[];
  v_opt uuid;
  v_valid_count integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  PERFORM public._close_fan_team_poll_if_due(p_poll_id);

  SELECT * INTO v_poll
  FROM public.fan_team_polls
  WHERE id = p_poll_id
  FOR UPDATE;

  IF NOT FOUND OR v_poll.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'Poll not found.';
  END IF;

  IF NOT public._fan_team_poll_user_can_access(v_poll.conversation_id, v_uid) THEN
    RAISE EXCEPTION 'Not authorized.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_poll_id::text || ':' || v_uid::text));

  v_status := public.fan_team_poll_effective_status(v_poll);
  IF v_status <> 'open' THEN
    RAISE EXCEPTION 'This poll is closed.';
  END IF;

  v_ids := ARRAY(
    SELECT DISTINCT x
    FROM unnest(coalesce(p_option_ids, ARRAY[]::uuid[])) AS x
    WHERE x IS NOT NULL
  );

  IF coalesce(array_length(v_ids, 1), 0) = 0 THEN
    DELETE FROM public.fan_team_poll_votes
    WHERE poll_id = p_poll_id
      AND voter_user_id = v_uid;
    UPDATE public.fan_team_polls
    SET updated_at = now()
    WHERE id = p_poll_id;
    RETURN;
  END IF;

  IF NOT v_poll.allow_multiple AND coalesce(array_length(v_ids, 1), 0) > 1 THEN
    RAISE EXCEPTION 'This poll allows only one answer.';
  END IF;

  SELECT count(*)::integer
  INTO v_valid_count
  FROM public.fan_team_poll_options o
  WHERE o.poll_id = p_poll_id
    AND o.id = ANY (v_ids);

  IF v_valid_count IS DISTINCT FROM coalesce(array_length(v_ids, 1), 0) THEN
    RAISE EXCEPTION 'Invalid poll answer.';
  END IF;

  IF NOT v_poll.allow_multiple THEN
    DELETE FROM public.fan_team_poll_votes
    WHERE poll_id = p_poll_id
      AND voter_user_id = v_uid;

    INSERT INTO public.fan_team_poll_votes (poll_id, option_id, voter_user_id)
    VALUES (p_poll_id, v_ids[1], v_uid)
    ON CONFLICT (poll_id, option_id, voter_user_id)
    DO UPDATE SET updated_at = now();
  ELSE
    DELETE FROM public.fan_team_poll_votes
    WHERE poll_id = p_poll_id
      AND voter_user_id = v_uid
      AND NOT (option_id = ANY (v_ids));

    FOREACH v_opt IN ARRAY v_ids LOOP
      INSERT INTO public.fan_team_poll_votes (poll_id, option_id, voter_user_id)
      VALUES (p_poll_id, v_opt, v_uid)
      ON CONFLICT (poll_id, option_id, voter_user_id)
      DO UPDATE SET updated_at = now();
    END LOOP;
  END IF;

  UPDATE public.fan_team_polls
  SET updated_at = now()
  WHERE id = p_poll_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.close_fan_team_poll(p_poll_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_poll public.fan_team_polls%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT * INTO v_poll FROM public.fan_team_polls WHERE id = p_poll_id;
  IF NOT FOUND OR v_poll.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'Poll not found.';
  END IF;

  IF NOT public._fan_team_poll_user_can_manage(v_poll.team_id, v_uid) THEN
    RAISE EXCEPTION 'Only team management can close polls.';
  END IF;

  UPDATE public.fan_team_polls
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

CREATE OR REPLACE FUNCTION public.delete_fan_team_poll(p_poll_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_poll public.fan_team_polls%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT * INTO v_poll FROM public.fan_team_polls WHERE id = p_poll_id;
  IF NOT FOUND OR v_poll.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'Poll not found.';
  END IF;

  IF NOT public._fan_team_poll_user_can_manage(v_poll.team_id, v_uid) THEN
    RAISE EXCEPTION 'Only team management can delete polls.';
  END IF;

  UPDATE public.fan_team_polls
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

CREATE OR REPLACE FUNCTION public.pin_fan_team_poll(
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
  v_poll public.fan_team_polls%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT * INTO v_poll FROM public.fan_team_polls WHERE id = p_poll_id;
  IF NOT FOUND OR v_poll.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'Poll not found.';
  END IF;

  IF NOT public._fan_team_poll_user_can_manage(v_poll.team_id, v_uid) THEN
    RAISE EXCEPTION 'Only team management can pin polls.';
  END IF;

  UPDATE public.fan_team_polls
  SET
    pinned_at = CASE WHEN coalesce(p_pinned, true) THEN coalesce(pinned_at, now()) ELSE NULL END,
    updated_at = now()
  WHERE id = p_poll_id
    AND deleted_at IS NULL;
END;
$$;

-- Same JSON shape as get_pickup_game_poll_snapshot so Swift reuses PickupGamePollSnapshot.
CREATE OR REPLACE FUNCTION public.get_fan_team_poll_snapshot(p_poll_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_poll public.fan_team_polls%ROWTYPE;
  v_status text;
  v_total integer;
  v_options jsonb;
  v_my_votes uuid[];
  v_voters jsonb := '[]'::jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT * INTO v_poll FROM public.fan_team_polls WHERE id = p_poll_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Poll not found.';
  END IF;

  IF NOT public._fan_team_poll_user_can_access(v_poll.conversation_id, v_uid) THEN
    RAISE EXCEPTION 'Not authorized.';
  END IF;

  v_status := public.fan_team_poll_effective_status(v_poll);

  SELECT count(DISTINCT v.voter_user_id)::integer
  INTO v_total
  FROM public.fan_team_poll_votes v
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
  FROM public.fan_team_poll_options o
  LEFT JOIN LATERAL (
    SELECT count(*)::integer AS cnt
    FROM public.fan_team_poll_votes v
    WHERE v.option_id = o.id
  ) vc ON true
  WHERE o.poll_id = p_poll_id;

  SELECT coalesce(array_agg(v.option_id), ARRAY[]::uuid[])
  INTO v_my_votes
  FROM public.fan_team_poll_votes v
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
    FROM public.fan_team_poll_votes v
    WHERE v.poll_id = p_poll_id;
  END IF;

  RETURN jsonb_build_object(
    'id', v_poll.id,
    'pickup_game_id', NULL,
    'team_id', v_poll.team_id,
    'conversation_id', v_poll.conversation_id,
    'message_id', v_poll.message_id,
    'created_by', v_poll.created_by,
    'question', v_poll.question,
    'allow_multiple', v_poll.allow_multiple,
    'is_anonymous', v_poll.is_anonymous,
    'auto_close_at_game_start', false,
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
    'viewer_is_organizer', public._fan_team_poll_user_can_manage(v_poll.team_id, v_uid)
  );
END;
$$;

-- Unified routers so chat cards can vote/close without knowing poll backend.
CREATE OR REPLACE FUNCTION public.get_chat_poll_snapshot(p_poll_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.pickup_game_polls WHERE id = p_poll_id) THEN
    RETURN public.get_pickup_game_poll_snapshot(p_poll_id);
  END IF;
  IF EXISTS (SELECT 1 FROM public.fan_team_polls WHERE id = p_poll_id) THEN
    RETURN public.get_fan_team_poll_snapshot(p_poll_id);
  END IF;
  RAISE EXCEPTION 'Poll not found.';
END;
$$;

CREATE OR REPLACE FUNCTION public.set_chat_poll_vote(
  p_poll_id uuid,
  p_option_ids uuid[]
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.pickup_game_polls WHERE id = p_poll_id) THEN
    PERFORM public.set_pickup_game_poll_vote(p_poll_id, p_option_ids);
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM public.fan_team_polls WHERE id = p_poll_id) THEN
    PERFORM public.set_fan_team_poll_vote(p_poll_id, p_option_ids);
    RETURN;
  END IF;
  RAISE EXCEPTION 'Poll not found.';
END;
$$;

CREATE OR REPLACE FUNCTION public.close_chat_poll(p_poll_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.pickup_game_polls WHERE id = p_poll_id) THEN
    PERFORM public.close_pickup_game_poll(p_poll_id);
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM public.fan_team_polls WHERE id = p_poll_id) THEN
    PERFORM public.close_fan_team_poll(p_poll_id);
    RETURN;
  END IF;
  RAISE EXCEPTION 'Poll not found.';
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_chat_poll(p_poll_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.pickup_game_polls WHERE id = p_poll_id) THEN
    PERFORM public.delete_pickup_game_poll(p_poll_id);
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM public.fan_team_polls WHERE id = p_poll_id) THEN
    PERFORM public.delete_fan_team_poll(p_poll_id);
    RETURN;
  END IF;
  RAISE EXCEPTION 'Poll not found.';
END;
$$;

CREATE OR REPLACE FUNCTION public.pin_chat_poll(
  p_poll_id uuid,
  p_pinned boolean DEFAULT true
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.pickup_game_polls WHERE id = p_poll_id) THEN
    PERFORM public.pin_pickup_game_poll(p_poll_id, p_pinned);
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM public.fan_team_polls WHERE id = p_poll_id) THEN
    PERFORM public.pin_fan_team_poll(p_poll_id, p_pinned);
    RETURN;
  END IF;
  RAISE EXCEPTION 'Poll not found.';
END;
$$;

CREATE OR REPLACE FUNCTION public.attach_chat_poll_message(
  p_poll_id uuid,
  p_message_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.pickup_game_polls WHERE id = p_poll_id) THEN
    PERFORM public.attach_pickup_game_poll_message(p_poll_id, p_message_id);
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM public.fan_team_polls WHERE id = p_poll_id) THEN
    PERFORM public.attach_fan_team_poll_message(p_poll_id, p_message_id);
    RETURN;
  END IF;
  RAISE EXCEPTION 'Poll not found.';
END;
$$;

DO $$
DECLARE
  fn text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'create_fan_team_poll(uuid,text,text[],boolean,boolean)',
    'attach_fan_team_poll_message(uuid,uuid)',
    'set_fan_team_poll_vote(uuid,uuid[])',
    'close_fan_team_poll(uuid)',
    'delete_fan_team_poll(uuid)',
    'pin_fan_team_poll(uuid,boolean)',
    'get_fan_team_poll_snapshot(uuid)',
    'get_chat_poll_snapshot(uuid)',
    'set_chat_poll_vote(uuid,uuid[])',
    'close_chat_poll(uuid)',
    'delete_chat_poll(uuid)',
    'pin_chat_poll(uuid,boolean)',
    'attach_chat_poll_message(uuid,uuid)'
  ]
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC', fn);
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM anon', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO service_role', fn);
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 6) RLS + Realtime
-- -----------------------------------------------------------------------------
ALTER TABLE public.fan_team_polls ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fan_team_poll_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fan_team_poll_votes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS fan_team_polls_select ON public.fan_team_polls;
CREATE POLICY fan_team_polls_select
  ON public.fan_team_polls
  FOR SELECT
  TO authenticated
  USING (public.can_access_fan_team_poll_conversation(conversation_id));

DROP POLICY IF EXISTS fan_team_poll_options_select ON public.fan_team_poll_options;
CREATE POLICY fan_team_poll_options_select
  ON public.fan_team_poll_options
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.fan_team_polls p
      WHERE p.id = poll_id
        AND public.can_access_fan_team_poll_conversation(p.conversation_id)
    )
  );

DROP POLICY IF EXISTS fan_team_poll_votes_select ON public.fan_team_poll_votes;
CREATE POLICY fan_team_poll_votes_select
  ON public.fan_team_poll_votes
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.fan_team_polls p
      WHERE p.id = poll_id
        AND public.can_access_fan_team_poll_conversation(p.conversation_id)
        AND (
          p.is_anonymous = false
          OR voter_user_id = auth.uid()
        )
    )
  );

REVOKE ALL ON TABLE public.fan_team_polls FROM PUBLIC;
REVOKE ALL ON TABLE public.fan_team_polls FROM anon;
GRANT SELECT ON TABLE public.fan_team_polls TO authenticated;
GRANT ALL ON TABLE public.fan_team_polls TO service_role;

REVOKE ALL ON TABLE public.fan_team_poll_options FROM PUBLIC;
REVOKE ALL ON TABLE public.fan_team_poll_options FROM anon;
GRANT SELECT ON TABLE public.fan_team_poll_options TO authenticated;
GRANT ALL ON TABLE public.fan_team_poll_options TO service_role;

REVOKE ALL ON TABLE public.fan_team_poll_votes FROM PUBLIC;
REVOKE ALL ON TABLE public.fan_team_poll_votes FROM anon;
GRANT SELECT ON TABLE public.fan_team_poll_votes TO authenticated;
GRANT ALL ON TABLE public.fan_team_poll_votes TO service_role;

DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.fan_team_polls;
  EXCEPTION
    WHEN duplicate_object THEN NULL;
  END;
END $$;

COMMIT;
