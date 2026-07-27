-- =============================================================================
-- 20260870 — Secure Fan XP awards (remove client-controlled amounts)
-- =============================================================================
--
-- Confirmed issue:
--   public.award_fan_xp(p_user_id, p_amount, p_source, p_source_id, p_source_key)
--   is EXECUTE-granted to authenticated and trusts client-supplied p_amount /
--   p_source / source keys for self-awards. A malicious client can invent XP.
--
-- Secure design (compatibility bridge + new claim API):
--   1) Server-side source → XP allowlist (clients cannot choose amounts).
--   2) Every award validates an authoritative evidence row.
--   3) Target user(s) are derived/validated server-side.
--   4) Idempotency uses canonical (user_id, source, source_id) only.
--   5) Legacy award_fan_xp signature is retained but hardened so released
--      iOS builds keep working while arbitrary amounts/sources fail.
--   6) New claim_fan_xp(p_source, p_source_id) is the preferred client API
--      (no amount, no target user id).
--
-- Does NOT rewrite existing xp_events / user_xp history.
-- Do NOT apply from the agent; review and apply deliberately on staging first.
--
-- Rollback (forward-fix preferred):
--   -- Re-create prior award_fan_xp body from 20260726_0001_fan_xp_system.sql
--   -- DROP FUNCTION public.claim_fan_xp(text, uuid);
--   -- DROP FUNCTION public.fan_xp_apply_award_internal(uuid, integer, text, uuid);
--   -- DROP FUNCTION public.fan_xp_amount_for_source(text);
--   -- DROP FUNCTION public.fan_xp_validate_and_resolve(text, uuid, uuid);
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Preflight
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.user_xp') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.user_xp'];
  END IF;
  IF to_regclass('public.xp_events') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.xp_events'];
  END IF;
  IF to_regclass('public.favorite_venues') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.favorite_venues'];
  END IF;
  IF to_regclass('public.venue_event_interests') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.venue_event_interests'];
  END IF;
  IF to_regclass('public.pickup_games') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.pickup_games'];
  END IF;
  IF to_regclass('public.pickup_game_requests') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.pickup_game_requests'];
  END IF;
  IF to_regclass('public.pickup_game_creator_ratings') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.pickup_game_creator_ratings'];
  END IF;
  IF to_regclass('public.friendships') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.friendships'];
  END IF;

  IF to_regprocedure('public.award_fan_xp(uuid,integer,text,uuid,text)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.award_fan_xp(uuid,integer,text,uuid,text)'];
  END IF;
  IF to_regprocedure('public.ensure_user_xp_row(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.ensure_user_xp_row(uuid)'];
  END IF;
  IF to_regprocedure('public.fan_xp_level_for_total(integer)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.fan_xp_level_for_total(integer)'];
  END IF;
  IF to_regprocedure('public.fan_xp_title_for_level(integer)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.fan_xp_title_for_level(integer)'];
  END IF;

  -- Required evidence columns
  IF to_regclass('public.favorite_venues') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'favorite_venues' AND column_name = 'user_email'
    ) THEN
      v_missing := v_missing || ARRAY['column public.favorite_venues.user_email'];
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'favorite_venues' AND column_name = 'venue_id'
    ) THEN
      v_missing := v_missing || ARRAY['column public.favorite_venues.venue_id'];
    END IF;
  END IF;

  IF to_regclass('public.venue_event_interests') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'venue_event_interests' AND column_name = 'venue_event_id'
    ) THEN
      v_missing := v_missing || ARRAY['column public.venue_event_interests.venue_event_id'];
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'venue_event_interests' AND column_name = 'user_email'
    ) THEN
      v_missing := v_missing || ARRAY['column public.venue_event_interests.user_email'];
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'venue_event_interests' AND column_name = 'interest_status'
    ) THEN
      v_missing := v_missing || ARRAY['column public.venue_event_interests.interest_status'];
    END IF;
  END IF;

  IF to_regclass('public.pickup_games') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'pickup_games' AND column_name = 'creator_user_id'
    ) THEN
      v_missing := v_missing || ARRAY['column public.pickup_games.creator_user_id'];
    END IF;
  END IF;

  IF to_regclass('public.pickup_game_requests') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'pickup_game_requests' AND column_name = 'requester_user_id'
    ) THEN
      v_missing := v_missing || ARRAY['column public.pickup_game_requests.requester_user_id'];
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'pickup_game_requests' AND column_name = 'status'
    ) THEN
      v_missing := v_missing || ARRAY['column public.pickup_game_requests.status'];
    END IF;
  END IF;

  IF to_regclass('public.pickup_game_creator_ratings') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'pickup_game_creator_ratings' AND column_name = 'rater_user_id'
    ) THEN
      v_missing := v_missing || ARRAY['column public.pickup_game_creator_ratings.rater_user_id'];
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'pickup_game_creator_ratings' AND column_name = 'pickup_game_id'
    ) THEN
      v_missing := v_missing || ARRAY['column public.pickup_game_creator_ratings.pickup_game_id'];
    END IF;
  END IF;

  IF to_regclass('public.friendships') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'friendships' AND column_name = 'status'
    ) THEN
      v_missing := v_missing || ARRAY['column public.friendships.status'];
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'friendships' AND column_name = 'requester_id'
    ) THEN
      v_missing := v_missing || ARRAY['column public.friendships.requester_id'];
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'friendships' AND column_name = 'addressee_id'
    ) THEN
      v_missing := v_missing || ARRAY['column public.friendships.addressee_id'];
    END IF;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public' AND indexname = 'uq_xp_events_user_source_dedup'
  ) THEN
    v_missing := v_missing || ARRAY['index public.uq_xp_events_user_source_dedup'];
  END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION '20260870 preflight failed: missing %', array_to_string(v_missing, ', ');
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Canonical server-side source → XP mapping (not client-writable)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_xp_amount_for_source(p_source text)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(trim(coalesce(p_source, '')))
    WHEN 'favorite_venue' THEN 2
    WHEN 'venue_event_interest' THEN 5
    WHEN 'pickup_create' THEN 20
    WHEN 'pickup_join_approved' THEN 10
    WHEN 'pickup_complete' THEN 15
    WHEN 'friend_connected' THEN 5
    ELSE NULL
  END;
$$;

REVOKE ALL ON FUNCTION public.fan_xp_amount_for_source(text) FROM PUBLIC;
-- Readable by authenticated for documentation / debugging; amount still enforced server-side.
GRANT EXECUTE ON FUNCTION public.fan_xp_amount_for_source(text) TO authenticated;

COMMENT ON FUNCTION public.fan_xp_amount_for_source(text) IS
  'Authoritative Fan XP amounts by source. Clients cannot override.';

-- ---------------------------------------------------------------------------
-- Internal ledger write (SECURITY DEFINER). Not granted to authenticated.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_xp_apply_award_internal(
  p_user_id uuid,
  p_amount integer,
  p_source text,
  p_source_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  src text := lower(trim(coalesce(p_source, '')));
  inserted_id uuid;
  row public.user_xp%ROWTYPE;
  new_total integer;
  new_level integer;
  new_title text;
BEGIN
  IF p_user_id IS NULL OR p_amount IS NULL OR p_amount <= 0 OR src = '' OR p_source_id IS NULL THEN
    RETURN jsonb_build_object('awarded', false, 'reason', 'invalid_input');
  END IF;

  -- Ensure summary row directly (do not call ensure_user_xp_row here):
  -- cross-user awards (join approval / friend) must work while the client-facing
  -- ensure_user_xp_row remains restricted to auth.uid().
  INSERT INTO public.user_xp (user_id, total_xp, level, title)
  VALUES (p_user_id, 0, 1, public.fan_xp_title_for_level(1))
  ON CONFLICT (user_id) DO NOTHING;

  INSERT INTO public.xp_events (user_id, xp_amount, source, source_id, source_key)
  VALUES (p_user_id, p_amount, src, p_source_id, '')
  ON CONFLICT DO NOTHING
  RETURNING id INTO inserted_id;

  IF inserted_id IS NULL THEN
    SELECT * INTO row FROM public.user_xp WHERE user_id = p_user_id;
    RETURN jsonb_build_object(
      'awarded', false,
      'duplicate', true,
      'user_id', p_user_id,
      'total_xp', row.total_xp,
      'level', row.level,
      'title', row.title,
      'xp_gained', 0,
      'source', src,
      'source_id', p_source_id
    );
  END IF;

  -- Use the inserted event amount (never a separate client amount).
  SELECT ux.total_xp + xe.xp_amount
  INTO new_total
  FROM public.user_xp ux
  JOIN public.xp_events xe ON xe.id = inserted_id
  WHERE ux.user_id = p_user_id;

  new_level := public.fan_xp_level_for_total(new_total);
  new_title := public.fan_xp_title_for_level(new_level);

  UPDATE public.user_xp
  SET total_xp = new_total,
      level = new_level,
      title = new_title,
      updated_at = now()
  WHERE user_id = p_user_id
  RETURNING * INTO row;

  RETURN jsonb_build_object(
    'awarded', true,
    'duplicate', false,
    'user_id', p_user_id,
    'total_xp', row.total_xp,
    'level', row.level,
    'title', row.title,
    'xp_gained', p_amount,
    'source', src,
    'source_id', p_source_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.fan_xp_apply_award_internal(uuid, integer, text, uuid) FROM PUBLIC;
-- Intentionally no GRANT to authenticated / anon.

COMMENT ON FUNCTION public.fan_xp_apply_award_internal(uuid, integer, text, uuid) IS
  'Internal Fan XP ledger writer. Not client-callable.';

-- ---------------------------------------------------------------------------
-- Validate evidence + resolve award target(s)
-- Returns jsonb:
--   { ok, reason?, amount, source, source_id, targets: uuid[] }
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_xp_validate_and_resolve(
  p_source text,
  p_source_id uuid,
  p_requested_user_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  src text := lower(trim(coalesce(p_source, '')));
  amount integer;
  my_email text := lower(btrim(coalesce(auth.jwt() ->> 'email', '')));
  v_requester uuid;
  v_creator uuid;
  v_other uuid;
  v_targets uuid[] := ARRAY[]::uuid[];
BEGIN
  IF me IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  amount := public.fan_xp_amount_for_source(src);
  IF amount IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'unknown_source');
  END IF;

  IF p_source_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'source_id_required');
  END IF;

  IF src = 'favorite_venue' THEN
    IF my_email = '' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'missing_auth_email');
    END IF;
    IF NOT EXISTS (
      SELECT 1
      FROM public.favorite_venues fv
      WHERE fv.venue_id = p_source_id
        AND lower(btrim(fv.user_email)) = my_email
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'favorite_not_found');
    END IF;
    v_targets := ARRAY[me];

  ELSIF src = 'venue_event_interest' THEN
    IF my_email = '' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'missing_auth_email');
    END IF;
    IF NOT EXISTS (
      SELECT 1
      FROM public.venue_event_interests vei
      WHERE lower(btrim(vei.venue_event_id)) = lower(p_source_id::text)
        AND lower(btrim(vei.user_email)) = my_email
        AND lower(btrim(vei.interest_status)) IN ('going', 'interested')
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'interest_not_found');
    END IF;
    v_targets := ARRAY[me];

  ELSIF src = 'pickup_create' THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.pickup_games pg
      WHERE pg.id = p_source_id
        AND pg.creator_user_id = me
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'pickup_create_not_eligible');
    END IF;
    v_targets := ARRAY[me];

  ELSIF src = 'pickup_join_approved' THEN
    SELECT pgr.requester_user_id, pg.creator_user_id
    INTO v_requester, v_creator
    FROM public.pickup_game_requests pgr
    JOIN public.pickup_games pg ON pg.id = pgr.pickup_game_id
    WHERE pgr.id = p_source_id
      AND lower(btrim(pgr.status)) = 'approved';

    IF v_requester IS NULL OR v_creator IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'join_request_not_approved');
    END IF;
    IF v_creator IS DISTINCT FROM me THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'not_pickup_creator');
    END IF;
    -- Target is always the approved joiner; client cannot redirect.
    IF p_requested_user_id IS NOT NULL AND p_requested_user_id IS DISTINCT FROM v_requester THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'target_mismatch');
    END IF;
    v_targets := ARRAY[v_requester];

  ELSIF src = 'pickup_complete' THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.pickup_game_creator_ratings r
      WHERE r.pickup_game_id = p_source_id
        AND r.rater_user_id = me
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'rating_not_found');
    END IF;
    v_targets := ARRAY[me];

  ELSIF src = 'friend_connected' THEN
    SELECT
      CASE
        WHEN f.requester_id = me THEN f.addressee_id
        WHEN f.addressee_id = me THEN f.requester_id
        ELSE NULL
      END
    INTO v_other
    FROM public.friendships f
    WHERE f.id = p_source_id
      AND lower(btrim(f.status)) = 'accepted'
      AND (f.requester_id = me OR f.addressee_id = me);

    IF v_other IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'friendship_not_accepted');
    END IF;

    -- Preferred claim path awards both participants.
    -- Legacy award_fan_xp may request a single participant (self or peer).
    IF p_requested_user_id IS NULL THEN
      v_targets := ARRAY[me, v_other];
    ELSIF p_requested_user_id = me OR p_requested_user_id = v_other THEN
      v_targets := ARRAY[p_requested_user_id];
    ELSE
      RETURN jsonb_build_object('ok', false, 'reason', 'friend_target_mismatch');
    END IF;

  ELSE
    RETURN jsonb_build_object('ok', false, 'reason', 'unknown_source');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'amount', amount,
    'source', src,
    'source_id', p_source_id,
    'targets', to_jsonb(v_targets)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.fan_xp_validate_and_resolve(text, uuid, uuid) FROM PUBLIC;
-- Not granted to clients; used only by award/claim SECURITY DEFINER functions.

COMMENT ON FUNCTION public.fan_xp_validate_and_resolve(text, uuid, uuid) IS
  'Validates Fan XP evidence rows and resolves award targets. Internal.';

-- ---------------------------------------------------------------------------
-- Preferred client API: claim_fan_xp(source, source_id) — no amount / no user id
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.claim_fan_xp(
  p_source text,
  p_source_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  resolved jsonb;
  targets uuid[];
  amount integer;
  src text;
  sid uuid;
  t uuid;
  one jsonb;
  results jsonb := '[]'::jsonb;
  any_awarded boolean := false;
  all_duplicate boolean := true;
  self_row public.user_xp%ROWTYPE;
  self_gained integer := 0;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  -- For friend_connected, omit requested user so both participants are awarded.
  resolved := public.fan_xp_validate_and_resolve(p_source, p_source_id, NULL);
  IF coalesce((resolved ->> 'ok')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'awarded', false,
      'duplicate', false,
      'reason', coalesce(resolved ->> 'reason', 'rejected')
    );
  END IF;

  amount := (resolved ->> 'amount')::integer;
  src := resolved ->> 'source';
  sid := (resolved ->> 'source_id')::uuid;
  SELECT ARRAY(SELECT jsonb_array_elements_text(resolved -> 'targets')::uuid)
  INTO targets;

  FOREACH t IN ARRAY targets LOOP
    one := public.fan_xp_apply_award_internal(t, amount, src, sid);
    results := results || jsonb_build_array(one);
    IF coalesce((one ->> 'awarded')::boolean, false) THEN
      any_awarded := true;
      all_duplicate := false;
    ELSIF coalesce((one ->> 'duplicate')::boolean, false) IS NOT TRUE THEN
      all_duplicate := false;
    END IF;
    IF t = me THEN
      self_gained := coalesce((one ->> 'xp_gained')::integer, 0);
    END IF;
  END LOOP;

  SELECT * INTO self_row FROM public.user_xp WHERE user_id = me;

  RETURN jsonb_build_object(
    'awarded', any_awarded,
    'duplicate', (NOT any_awarded) AND all_duplicate,
    'total_xp', self_row.total_xp,
    'level', self_row.level,
    'title', self_row.title,
    'xp_gained', self_gained,
    'source', src,
    'source_id', sid,
    'results', results
  );
END;
$$;

REVOKE ALL ON FUNCTION public.claim_fan_xp(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_fan_xp(text, uuid) TO authenticated;

COMMENT ON FUNCTION public.claim_fan_xp(text, uuid) IS
  'Secure Fan XP claim: validates evidence, uses server amounts, awards resolved targets.';

-- ---------------------------------------------------------------------------
-- Harden legacy award_fan_xp for released iOS builds
-- Ignores client p_amount and p_source_key; validates evidence; fixed amounts.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.award_fan_xp(
  p_user_id uuid,
  p_amount integer,
  p_source text,
  p_source_id uuid DEFAULT NULL,
  p_source_key text DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  resolved jsonb;
  targets uuid[];
  amount integer;
  src text;
  sid uuid;
  t uuid;
  one jsonb;
  matched jsonb;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  -- Reject source_key-only farming. Canonical awards require a real source_id.
  IF p_source_id IS NULL THEN
    RETURN jsonb_build_object(
      'awarded', false,
      'duplicate', false,
      'reason', 'source_id_required',
      'xp_gained', 0
    );
  END IF;

  -- p_amount and p_source_key are intentionally ignored.
  resolved := public.fan_xp_validate_and_resolve(p_source, p_source_id, p_user_id);
  IF coalesce((resolved ->> 'ok')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'awarded', false,
      'duplicate', false,
      'reason', coalesce(resolved ->> 'reason', 'rejected'),
      'xp_gained', 0
    );
  END IF;

  amount := (resolved ->> 'amount')::integer;
  src := resolved ->> 'source';
  sid := (resolved ->> 'source_id')::uuid;
  SELECT ARRAY(SELECT jsonb_array_elements_text(resolved -> 'targets')::uuid)
  INTO targets;

  -- Legacy path awards exactly the validated target set (usually one user;
  -- friend_connected with a requested participant stays single-target).
  matched := NULL;
  FOREACH t IN ARRAY targets LOOP
    one := public.fan_xp_apply_award_internal(t, amount, src, sid);
    IF matched IS NULL AND t = coalesce(p_user_id, me) THEN
      matched := one;
    ELSIF matched IS NULL THEN
      matched := one;
    END IF;
  END LOOP;

  IF matched IS NULL THEN
    RETURN jsonb_build_object(
      'awarded', false,
      'duplicate', false,
      'reason', 'no_target',
      'xp_gained', 0
    );
  END IF;

  RETURN jsonb_build_object(
    'awarded', coalesce((matched ->> 'awarded')::boolean, false),
    'duplicate', coalesce((matched ->> 'duplicate')::boolean, false),
    'total_xp', matched -> 'total_xp',
    'level', matched -> 'level',
    'title', matched -> 'title',
    'xp_gained', coalesce((matched ->> 'xp_gained')::integer, 0)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.award_fan_xp(uuid, integer, text, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.award_fan_xp(uuid, integer, text, uuid, text) TO authenticated;

COMMENT ON FUNCTION public.award_fan_xp(uuid, integer, text, uuid, text) IS
  'Legacy-compatible Fan XP award. Ignores client amount/source_key; validates evidence and uses server amounts.';

-- ---------------------------------------------------------------------------
-- Harden ensure_user_xp_row: authenticated may only ensure their own row
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ensure_user_xp_row(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
BEGIN
  -- Allow internal SECURITY DEFINER callers (no JWT) and self-ensure.
  -- When called by an authenticated client, restrict to auth.uid().
  IF me IS NOT NULL AND p_user_id IS DISTINCT FROM me THEN
    RAISE EXCEPTION 'Not allowed to ensure XP row for another user.';
  END IF;
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'user_id required';
  END IF;

  INSERT INTO public.user_xp (user_id, total_xp, level, title)
  VALUES (p_user_id, 0, 1, public.fan_xp_title_for_level(1))
  ON CONFLICT (user_id) DO NOTHING;
END;
$$;

REVOKE ALL ON FUNCTION public.ensure_user_xp_row(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ensure_user_xp_row(uuid) TO authenticated;

COMMIT;
