-- =============================================================================
-- 20261004_0001 — FanGeo Team event scorer attribution
-- =============================================================================
-- Additive. Production-safe. Do NOT apply from the agent.
-- Does NOT edit 20261003_0001_fan_team_event_scoring.sql.
--
-- Adds nullable scorer snapshot columns to fan_team_event_score_events,
-- a 6-arg update_fan_team_event_score overload, and keeps the live 5-arg
-- signature as a compatibility wrapper (current iOS still calls 5 args).
-- =============================================================================

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.fan_team_event_score_events') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_team_event_score_events'];
  END IF;
  IF to_regprocedure(
       'public.update_fan_team_event_score(uuid, uuid, integer, integer, text)'
     ) IS NULL THEN
    v_missing := v_missing || ARRAY['update_fan_team_event_score'];
  END IF;
  IF to_regprocedure(
       'public.queue_fan_team_event_score_push_notification(uuid, uuid, uuid, uuid, text, text, text, text, integer, integer, text)'
     ) IS NULL THEN
    v_missing := v_missing || ARRAY['queue_fan_team_event_score_push_notification'];
  END IF;
  IF to_regclass('public.fan_team_members') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_team_members'];
  END IF;
  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION '20261004 prerequisite missing: %', array_to_string(v_missing, ', ');
  END IF;
END $$;

BEGIN;

ALTER TABLE public.fan_team_event_score_events
  ADD COLUMN IF NOT EXISTS scorer_membership_id uuid,
  ADD COLUMN IF NOT EXISTS scorer_user_id uuid,
  ADD COLUMN IF NOT EXISTS scorer_managed_player_id uuid,
  ADD COLUMN IF NOT EXISTS scorer_display_name_snapshot text,
  ADD COLUMN IF NOT EXISTS scorer_avatar_url_snapshot text,
  ADD COLUMN IF NOT EXISTS scorer_team_id uuid,
  ADD COLUMN IF NOT EXISTS scorer_attribution_kind text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'fan_team_event_score_events_scorer_kind_ck'
  ) THEN
    ALTER TABLE public.fan_team_event_score_events
      ADD CONSTRAINT fan_team_event_score_events_scorer_kind_ck
      CHECK (
        scorer_attribution_kind IS NULL
        OR scorer_attribution_kind IN ('goal', 'score', 'run', 'touchdown_or_score')
      );
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'fan_team_event_score_events_scorer_identity_ck'
  ) THEN
    ALTER TABLE public.fan_team_event_score_events
      ADD CONSTRAINT fan_team_event_score_events_scorer_identity_ck
      CHECK (
        scorer_membership_id IS NULL
        OR (
          scorer_display_name_snapshot IS NOT NULL
          AND char_length(btrim(scorer_display_name_snapshot)) > 0
        )
      );
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS fan_team_event_score_events_scorer_membership_idx
  ON public.fan_team_event_score_events (scorer_membership_id)
  WHERE scorer_membership_id IS NOT NULL;

COMMENT ON COLUMN public.fan_team_event_score_events.scorer_membership_id IS
  'Validated fan_team_members.membership_id for a positive increment. Null when Skip/Unknown or decrement.';
COMMENT ON COLUMN public.fan_team_event_score_events.scorer_display_name_snapshot IS
  'Server-derived roster display name at scoring time. Never trusted from the client.';
COMMENT ON COLUMN public.fan_team_event_score_events.scorer_attribution_kind IS
  'Normalized kind: goal | score | run | touchdown_or_score.';

-- ---------------------------------------------------------------------------
-- Sport policy (mirrors iOS FanTeamScoreAttribution.mode)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_team_scorer_attribution_kind(p_sport text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  SELECT CASE
    WHEN lower(btrim(coalesce(p_sport, ''))) ~ '(volleyball|badminton|tennis|padel|pickleball|ping.?pong|running|track|climbing|paragliding|hang.?glid|paramotor|cycling|swim|ski|golf|esport|bowling|dance|ballet|boxing|mma|ufc|wrestl)'
      THEN NULL
    WHEN lower(btrim(coalesce(p_sport, ''))) ~ '(soccer|futsal|futbol)' THEN 'goal'
    WHEN lower(btrim(coalesce(p_sport, ''))) ~ '(nhl|\bhockey\b)' THEN 'goal'
    WHEN lower(btrim(coalesce(p_sport, ''))) ~ 'lacrosse' THEN 'goal'
    WHEN lower(btrim(coalesce(p_sport, ''))) ~ '(nba|wnba|basketball)' THEN 'score'
    WHEN lower(btrim(coalesce(p_sport, ''))) ~ '(baseball|mlb|softball)' THEN 'run'
    WHEN lower(btrim(coalesce(p_sport, ''))) ~ '(nfl|american.?football)' THEN 'touchdown_or_score'
    WHEN lower(btrim(coalesce(p_sport, ''))) IN ('football', 'nfl') THEN 'touchdown_or_score'
    ELSE NULL
  END;
$$;

REVOKE ALL ON FUNCTION public.fan_team_scorer_attribution_kind(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fan_team_scorer_attribution_kind(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.fan_team_scorer_attribution_kind(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_scorer_attribution_kind(text) TO service_role;

-- Server-derived roster snapshot. Never uses client-supplied names.
CREATE OR REPLACE FUNCTION public.fan_team_resolve_eligible_scorer(
  p_team_id uuid,
  p_membership_id uuid
)
RETURNS TABLE (
  membership_id uuid,
  user_id uuid,
  managed_player_id uuid,
  display_name text,
  avatar_url text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT
    m.membership_id,
    m.user_id,
    m.managed_player_id,
    CASE
      WHEN m.managed_player_id IS NOT NULL
        THEN coalesce(nullif(btrim(mp.display_name), ''), 'Player')
      ELSE coalesce(nullif(btrim(p.display_name), ''), 'Fan')
    END::text,
    CASE
      WHEN m.managed_player_id IS NOT NULL
        THEN coalesce(nullif(btrim(mp.avatar_thumbnail_url), ''), nullif(btrim(mp.avatar_url), ''))
      ELSE coalesce(nullif(btrim(p.avatar_thumbnail_url), ''), nullif(btrim(p.avatar_url), ''))
    END
  FROM public.fan_team_members m
  LEFT JOIN public.user_profiles p ON p.id = m.user_id
  LEFT JOIN public.fan_managed_players mp ON mp.id = m.managed_player_id
  WHERE m.membership_id = p_membership_id
    AND m.team_id = p_team_id
    AND m.left_at IS NULL
    AND m.is_player IS TRUE;
$$;

REVOKE ALL ON FUNCTION public.fan_team_resolve_eligible_scorer(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fan_team_resolve_eligible_scorer(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.fan_team_resolve_eligible_scorer(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_resolve_eligible_scorer(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- Queue copy: include scorer snapshot from the audit row (same signature)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.queue_fan_team_event_score_push_notification(
  p_pickup_game_id uuid,
  p_team_id uuid,
  p_editor_user_id uuid,
  p_audit_id uuid,
  p_idempotency_key text,
  p_notification_type text,
  p_team_name text,
  p_opponent_name text,
  p_team_score integer,
  p_opponent_score integer,
  p_game_format text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_event_id uuid;
  v_existing public.pickup_game_update_events%ROWTYPE;
  v_fingerprint text;
  v_payload jsonb;
  v_score_line text;
  v_title text;
  v_kind text;
  v_audit public.fan_team_event_score_events%ROWTYPE;
  v_scorer_name text;
  v_attr text;
  v_sport text;
BEGIN
  IF p_pickup_game_id IS NULL OR p_team_id IS NULL OR p_audit_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_kind := lower(btrim(coalesce(p_notification_type, '')));
  IF v_kind NOT IN ('team_event_scored', 'team_event_final') THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_audit
  FROM public.fan_team_event_score_events e
  WHERE e.id = p_audit_id;

  SELECT nullif(btrim(pg.sport), '') INTO v_sport
  FROM public.pickup_games pg
  WHERE pg.id = p_pickup_game_id;

  v_score_line :=
    coalesce(nullif(btrim(p_team_name), ''), 'Team')
    || ' '
    || p_team_score::text
    || ' – '
    || p_opponent_score::text
    || ' '
    || coalesce(nullif(btrim(p_opponent_name), ''), 'Opponent');

  v_scorer_name := nullif(btrim(coalesce(v_audit.scorer_display_name_snapshot, '')), '');
  v_attr := nullif(btrim(coalesce(v_audit.scorer_attribution_kind, '')), '');

  IF v_kind = 'team_event_final' THEN
    v_title := 'Final';
  ELSIF v_scorer_name IS NOT NULL AND v_kind = 'team_event_scored' THEN
    v_title := CASE v_attr
      WHEN 'goal' THEN 'Goal — ' || v_scorer_name
      WHEN 'run' THEN 'Run scored — ' || v_scorer_name
      WHEN 'score' THEN v_scorer_name || ' scored'
      WHEN 'touchdown_or_score' THEN 'Score — ' || v_scorer_name
      ELSE coalesce(nullif(btrim(p_team_name), ''), 'Team') || ' scored'
    END;
  ELSE
    v_title := coalesce(nullif(btrim(p_team_name), ''), 'Team') || ' scored';
  END IF;

  v_fingerprint := v_kind || ':' || lower(p_pickup_game_id::text) || ':' || lower(btrim(p_idempotency_key));

  v_payload := jsonb_build_object(
    'notification_type', v_kind,
    'team_id', p_team_id,
    'team_name', coalesce(nullif(btrim(p_team_name), ''), ''),
    'title', v_title,
    'score_title', v_title,
    'score_line', v_score_line,
    'team_score', p_team_score,
    'opponent_score', p_opponent_score,
    'after_opponent', coalesce(nullif(btrim(p_opponent_name), ''), ''),
    'game_format', coalesce(p_game_format, ''),
    'sport', coalesce(v_sport, ''),
    'audit_id', p_audit_id,
    'idempotency_key', p_idempotency_key,
    'safe_destination', 'scheduleActivity',
    'scorer_membership_id', v_audit.scorer_membership_id,
    'scorer_user_id', v_audit.scorer_user_id,
    'scorer_managed_player_id', v_audit.scorer_managed_player_id,
    'scorer_display_name', v_scorer_name,
    'scorer_display_name_snapshot', v_scorer_name,
    'scorer_avatar_url', v_audit.scorer_avatar_url_snapshot,
    'scorer_avatar_url_snapshot', v_audit.scorer_avatar_url_snapshot,
    'scorer_team_id', v_audit.scorer_team_id,
    'scorer_attribution_kind', v_attr,
    'player_display_name', v_scorer_name,
    'player_avatar_url', v_audit.scorer_avatar_url_snapshot,
    'is_managed_player', (v_audit.scorer_managed_player_id IS NOT NULL)
  );

  INSERT INTO public.pickup_game_update_events AS e (
    pickup_game_id, editor_user_id, fingerprint, change_kinds, payload, push_delivery_status
  )
  VALUES (
    p_pickup_game_id,
    p_editor_user_id,
    v_fingerprint,
    ARRAY[v_kind]::text[],
    v_payload,
    'pending'
  )
  ON CONFLICT (pickup_game_id, fingerprint) DO NOTHING
  RETURNING id INTO v_event_id;

  IF v_event_id IS NULL THEN
    SELECT * INTO v_existing
    FROM public.pickup_game_update_events
    WHERE pickup_game_id = p_pickup_game_id
      AND fingerprint = v_fingerprint;
    IF v_existing.id IS NULL THEN
      RETURN NULL;
    END IF;
    IF v_existing.push_sent_at IS NULL
       AND v_existing.push_delivery_status IN ('pending', 'queued', 'retryable', 'failed') THEN
      PERFORM public.queue_pickup_game_change_push_notification(v_existing.id);
    END IF;
    RETURN v_existing.id;
  END IF;

  PERFORM public.queue_pickup_game_change_push_notification(v_event_id);
  RETURN v_event_id;
END;
$$;

REVOKE ALL ON FUNCTION public.queue_fan_team_event_score_push_notification(
  uuid, uuid, uuid, uuid, text, text, text, text, integer, integer, text
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.queue_fan_team_event_score_push_notification(
  uuid, uuid, uuid, uuid, text, text, text, text, integer, integer, text
) FROM anon;
REVOKE ALL ON FUNCTION public.queue_fan_team_event_score_push_notification(
  uuid, uuid, uuid, uuid, text, text, text, text, integer, integer, text
) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.queue_fan_team_event_score_push_notification(
  uuid, uuid, uuid, uuid, text, text, text, text, integer, integer, text
) TO service_role;

-- ---------------------------------------------------------------------------
-- 6-arg authoritative score RPC (scorer optional)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_fan_team_event_score(
  p_event_id uuid,
  p_team_id uuid,
  p_team_delta integer,
  p_opponent_delta integer,
  p_idempotency_key text,
  p_scorer_membership_id uuid
)
RETURNS TABLE (
  event_id uuid,
  team_id uuid,
  team_score integer,
  opponent_score integer,
  scoring_status text,
  scoring_finalized_at timestamptz,
  opponent_name text,
  replayed boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := (SELECT auth.uid());
  v_key text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
  v_team_delta integer := coalesce(p_team_delta, 0);
  v_opp_delta integer := coalesce(p_opponent_delta, 0);
  v_link_side text;
  v_pg public.pickup_games%ROWTYPE;
  v_stored_team integer;
  v_stored_opp integer;
  v_new_stored_team integer;
  v_new_stored_opp integer;
  v_view_team integer;
  v_view_opp integer;
  v_prev_view_team integer;
  v_prev_view_opp integer;
  v_kind text;
  v_audit_id uuid;
  v_team_name text;
  v_opponent text;
  v_existing public.fan_team_event_score_events%ROWTYPE;
  v_scorer_team uuid;
  v_scorer_user uuid;
  v_scorer_managed uuid;
  v_scorer_name text;
  v_scorer_avatar text;
  v_attr text;
  v_membership uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '42501';
  END IF;
  IF p_event_id IS NULL OR p_team_id IS NULL THEN
    RAISE EXCEPTION 'Event and Team are required.';
  END IF;
  IF v_key IS NULL OR char_length(v_key) < 8 OR char_length(v_key) > 180 THEN
    RAISE EXCEPTION 'Idempotency key is required.';
  END IF;
  IF v_team_delta = 0 AND v_opp_delta = 0 THEN
    RAISE EXCEPTION 'Score delta is required.';
  END IF;
  IF abs(v_team_delta) + abs(v_opp_delta) > 2
     OR abs(v_team_delta) > 1
     OR abs(v_opp_delta) > 1 THEN
    RAISE EXCEPTION 'Score delta must be +1 or -1 per side.';
  END IF;

  IF NOT public.fan_team_viewer_can_score(p_team_id) THEN
    RAISE EXCEPTION 'Only an Owner or Manager can change the score.'
      USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_key, 880031));
  PERFORM set_config('gameon.fan_team_scoring_rpc', '1', true);

  SELECT l.side INTO v_link_side
  FROM public.fan_team_game_links l
  WHERE l.pickup_game_id = p_event_id
    AND l.team_id = p_team_id
  FOR UPDATE;

  IF v_link_side IS NULL THEN
    RAISE EXCEPTION 'Event is not on this Team.';
  END IF;

  SELECT * INTO v_pg
  FROM public.pickup_games pg
  WHERE pg.id = p_event_id
  FOR UPDATE;

  IF v_pg.id IS NULL THEN
    RAISE EXCEPTION 'Event not found.';
  END IF;

  v_existing := public.fan_team_score_require_matching_audit(v_key, p_event_id, p_team_id);
  IF v_existing.id IS NOT NULL THEN
    event_id := p_event_id;
    team_id := p_team_id;
    team_score := v_existing.new_team_score;
    opponent_score := v_existing.new_opponent_score;
    scoring_status := v_pg.scoring_status;
    scoring_finalized_at := v_pg.scoring_finalized_at;
    opponent_name := coalesce(
      (
        SELECT nullif(btrim(ot.name), '')
        FROM public.fan_team_game_links l2
        JOIN public.fan_teams ot ON ot.id = l2.team_id
        WHERE l2.pickup_game_id = p_event_id
          AND l2.team_id <> p_team_id
        LIMIT 1
      ),
      nullif(btrim(v_pg.opponent_name), '')
    );
    replayed := true;
    RETURN NEXT;
    RETURN;
  END IF;

  IF NOT public.fan_team_event_is_score_capable(v_pg.game_format, v_pg.sport) THEN
    RAISE EXCEPTION 'This event type does not support scoring.';
  END IF;
  IF NOT public.fan_team_event_has_opponent(p_event_id) THEN
    RAISE EXCEPTION 'Add an opponent before scoring.';
  END IF;
  IF v_pg.scoring_status IS DISTINCT FROM 'live' THEN
    RAISE EXCEPTION 'Score can only be changed while the game is Live.';
  END IF;
  IF v_pg.status = 'removed' THEN
    RAISE EXCEPTION 'Cancelled events cannot be scored.';
  END IF;

  v_stored_team := v_pg.team_score;
  v_stored_opp := v_pg.opponent_score;

  IF v_link_side = 'away' THEN
    v_prev_view_team := v_stored_opp;
    v_prev_view_opp := v_stored_team;
    v_view_team := v_stored_opp + v_team_delta;
    v_view_opp := v_stored_team + v_opp_delta;
    v_new_stored_team := v_view_opp;
    v_new_stored_opp := v_view_team;
  ELSE
    v_prev_view_team := v_stored_team;
    v_prev_view_opp := v_stored_opp;
    v_view_team := v_stored_team + v_team_delta;
    v_view_opp := v_stored_opp + v_opp_delta;
    v_new_stored_team := v_view_team;
    v_new_stored_opp := v_view_opp;
  END IF;

  IF v_view_team < 0 OR v_view_opp < 0 THEN
    RAISE EXCEPTION 'Score cannot go below 0.';
  END IF;

  IF v_team_delta + v_opp_delta > 0 THEN
    v_kind := 'increment';
  ELSE
    v_kind := 'decrement';
  END IF;

  -- Scorer only on a positive increment. Decrement/skip ignore the id.
  v_membership := NULL;
  v_scorer_team := NULL;
  v_attr := NULL;
  IF v_kind = 'increment' AND p_scorer_membership_id IS NOT NULL THEN
    v_attr := public.fan_team_scorer_attribution_kind(v_pg.sport);
    IF v_attr IS NOT NULL THEN
      IF v_team_delta > 0 THEN
        v_scorer_team := p_team_id;
      ELSIF v_opp_delta > 0 THEN
        SELECT l2.team_id INTO v_scorer_team
        FROM public.fan_team_game_links l2
        WHERE l2.pickup_game_id = p_event_id
          AND l2.team_id <> p_team_id
        LIMIT 1;
      END IF;
      IF v_scorer_team IS NULL THEN
        RAISE EXCEPTION 'Scorer is not on this Team roster.'
          USING ERRCODE = '23514';
      END IF;
      SELECT
        r.membership_id, r.user_id, r.managed_player_id, r.display_name, r.avatar_url
      INTO
        v_membership, v_scorer_user, v_scorer_managed, v_scorer_name, v_scorer_avatar
      FROM public.fan_team_resolve_eligible_scorer(v_scorer_team, p_scorer_membership_id) r;
      IF v_membership IS NULL THEN
        RAISE EXCEPTION 'Scorer is not on this Team roster.'
          USING ERRCODE = '23514';
      END IF;
    END IF;
  END IF;

  BEGIN
    INSERT INTO public.fan_team_event_score_events (
      team_id, event_id,
      previous_team_score, previous_opponent_score,
      new_team_score, new_opponent_score,
      previous_scoring_status, new_scoring_status,
      kind, changed_by, idempotency_key,
      scorer_membership_id, scorer_user_id, scorer_managed_player_id,
      scorer_display_name_snapshot, scorer_avatar_url_snapshot,
      scorer_team_id, scorer_attribution_kind
    )
    VALUES (
      p_team_id, p_event_id,
      v_prev_view_team, v_prev_view_opp,
      v_view_team, v_view_opp,
      v_pg.scoring_status, v_pg.scoring_status,
      v_kind, me, v_key,
      v_membership, v_scorer_user, v_scorer_managed,
      v_scorer_name, v_scorer_avatar,
      v_scorer_team, v_attr
    )
    RETURNING id INTO v_audit_id;
  EXCEPTION WHEN unique_violation THEN
    v_existing := public.fan_team_score_require_matching_audit(v_key, p_event_id, p_team_id);
    event_id := p_event_id;
    team_id := p_team_id;
    team_score := v_existing.new_team_score;
    opponent_score := v_existing.new_opponent_score;
    scoring_status := v_pg.scoring_status;
    scoring_finalized_at := v_pg.scoring_finalized_at;
    opponent_name := nullif(btrim(coalesce(v_pg.opponent_name, '')), '');
    replayed := true;
    RETURN NEXT;
    RETURN;
  END;

  UPDATE public.pickup_games
  SET team_score = v_new_stored_team,
      opponent_score = v_new_stored_opp
  WHERE id = p_event_id;

  SELECT nullif(btrim(t.name), '') INTO v_team_name
  FROM public.fan_teams t
  WHERE t.id = p_team_id;

  v_opponent := coalesce(
    (
      SELECT nullif(btrim(ot.name), '')
      FROM public.fan_team_game_links l2
      JOIN public.fan_teams ot ON ot.id = l2.team_id
      WHERE l2.pickup_game_id = p_event_id
        AND l2.team_id <> p_team_id
      LIMIT 1
    ),
    nullif(btrim(v_pg.opponent_name), '')
  );

  -- Visible "scored" push only when the FanGeo Team's score increases.
  IF v_team_delta > 0 THEN
    PERFORM public.queue_fan_team_event_score_push_notification(
      p_event_id,
      p_team_id,
      me,
      v_audit_id,
      v_key,
      'team_event_scored',
      v_team_name,
      v_opponent,
      v_view_team,
      v_view_opp,
      v_pg.game_format
    );
  END IF;

  event_id := p_event_id;
  team_id := p_team_id;
  team_score := v_view_team;
  opponent_score := v_view_opp;
  scoring_status := 'live';
  scoring_finalized_at := v_pg.scoring_finalized_at;
  opponent_name := v_opponent;
  replayed := false;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.update_fan_team_event_score(uuid, uuid, integer, integer, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_fan_team_event_score(uuid, uuid, integer, integer, text, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_fan_team_event_score(uuid, uuid, integer, integer, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_fan_team_event_score(uuid, uuid, integer, integer, text, uuid) TO service_role;

-- 5-arg wrapper: current iOS / live callers stay valid.
CREATE OR REPLACE FUNCTION public.update_fan_team_event_score(
  p_event_id uuid,
  p_team_id uuid,
  p_team_delta integer,
  p_opponent_delta integer,
  p_idempotency_key text
)
RETURNS TABLE (
  event_id uuid,
  team_id uuid,
  team_score integer,
  opponent_score integer,
  scoring_status text,
  scoring_finalized_at timestamptz,
  opponent_name text,
  replayed boolean
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT *
  FROM public.update_fan_team_event_score(
    p_event_id,
    p_team_id,
    p_team_delta,
    p_opponent_delta,
    p_idempotency_key,
    NULL::uuid
  );
$$;

REVOKE ALL ON FUNCTION public.update_fan_team_event_score(uuid, uuid, integer, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_fan_team_event_score(uuid, uuid, integer, integer, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_fan_team_event_score(uuid, uuid, integer, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_fan_team_event_score(uuid, uuid, integer, integer, text) TO service_role;

DO $$
DECLARE
  v_src text;
BEGIN
  IF to_regprocedure(
       'public.update_fan_team_event_score(uuid, uuid, integer, integer, text, uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION '20261004 missing 6-arg update_fan_team_event_score';
  END IF;
  IF to_regprocedure(
       'public.update_fan_team_event_score(uuid, uuid, integer, integer, text)'
     ) IS NULL THEN
    RAISE EXCEPTION '20261004 missing 5-arg compatibility wrapper';
  END IF;
  SELECT p.prosrc INTO v_src
  FROM pg_proc p
  WHERE p.oid = to_regprocedure(
    'public.update_fan_team_event_score(uuid, uuid, integer, integer, text, uuid)'
  );
  IF position('fan_team_viewer_can_score' IN v_src) = 0 THEN
    RAISE EXCEPTION '20261004 6-arg RPC missing score authorization';
  END IF;
  IF position('fan_team_resolve_eligible_scorer' IN v_src) = 0 THEN
    RAISE EXCEPTION '20261004 6-arg RPC missing scorer validation';
  END IF;
  IF position('Scorer is not on this Team roster' IN v_src) = 0 THEN
    RAISE EXCEPTION '20261004 6-arg RPC missing scorer rejection';
  END IF;
END $$;

COMMIT;
