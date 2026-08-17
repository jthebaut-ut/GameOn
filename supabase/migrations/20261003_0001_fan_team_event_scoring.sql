-- =============================================================================
-- 20261003_0001 — FanGeo Team event scoring (Live / Final / W-L-T)
-- =============================================================================
-- Additive. Production-safe. Do NOT apply from the agent.
--
-- Team events remain pickup_games + fan_team_game_links. This adds:
--   * team_score / opponent_score / scoring_status / scoring_finalized_at
--   * append-only fan_team_event_score_events (UNIQUE idempotency_key)
--   * Owner/Manager (or edit_events) RPCs: mark live, delta score, mark final,
--     correct final
--   * Derived get_fan_team_record + paginated list_fan_team_scored_results
--   * Score/final APNs via existing pickup_game_update_events →
--     notify-pickup-game-change (no new Edge Function)
--
-- Score columns are RPC-only (GUC-gated trigger). Direct client UPDATEs cannot
-- mutate them. Score-only writes are excluded from pickup_meaningful_change_kinds
-- so they do not fire team_event_updated.
-- =============================================================================

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.pickup_games') IS NULL THEN
    v_missing := v_missing || ARRAY['pickup_games'];
  END IF;
  IF to_regclass('public.fan_team_game_links') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_team_game_links'];
  END IF;
  IF to_regclass('public.fan_teams') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_teams'];
  END IF;
  IF to_regclass('public.pickup_game_update_events') IS NULL THEN
    v_missing := v_missing || ARRAY['pickup_game_update_events'];
  END IF;
  IF to_regprocedure('public.fan_team_viewer_has_permission(uuid, text)') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_team_viewer_has_permission'];
  END IF;
  IF to_regprocedure('public.list_fan_team_games(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['list_fan_team_games'];
  END IF;
  IF to_regprocedure('public.queue_pickup_game_change_push_notification(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['queue_pickup_game_change_push_notification'];
  END IF;
  IF to_regprocedure(
       'public.fanout_fan_notification_inbox_for_pickup_update_event(uuid)'
     ) IS NULL THEN
    v_missing := v_missing || ARRAY['fanout_fan_notification_inbox_for_pickup_update_event'];
  END IF;
  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION '20261003 prerequisite missing: %', array_to_string(v_missing, ', ');
  END IF;
END $$;

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Score columns on pickup_games
-- ---------------------------------------------------------------------------
ALTER TABLE public.pickup_games
  ADD COLUMN IF NOT EXISTS team_score integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS opponent_score integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS scoring_status text NOT NULL DEFAULT 'scheduled',
  ADD COLUMN IF NOT EXISTS scoring_finalized_at timestamptz;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'pickup_games_team_score_nonneg_ck'
  ) THEN
    ALTER TABLE public.pickup_games
      ADD CONSTRAINT pickup_games_team_score_nonneg_ck
      CHECK (team_score >= 0) NOT VALID;
    ALTER TABLE public.pickup_games VALIDATE CONSTRAINT pickup_games_team_score_nonneg_ck;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'pickup_games_opponent_score_nonneg_ck'
  ) THEN
    ALTER TABLE public.pickup_games
      ADD CONSTRAINT pickup_games_opponent_score_nonneg_ck
      CHECK (opponent_score >= 0) NOT VALID;
    ALTER TABLE public.pickup_games VALIDATE CONSTRAINT pickup_games_opponent_score_nonneg_ck;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'pickup_games_scoring_status_ck'
  ) THEN
    ALTER TABLE public.pickup_games
      ADD CONSTRAINT pickup_games_scoring_status_ck
      CHECK (scoring_status IN ('scheduled', 'live', 'final')) NOT VALID;
    ALTER TABLE public.pickup_games VALIDATE CONSTRAINT pickup_games_scoring_status_ck;
  END IF;
END $$;

COMMENT ON COLUMN public.pickup_games.team_score IS
  'FanGeo Team (home/solo link) score. Opponent is opponent_score. RPC-only.';
COMMENT ON COLUMN public.pickup_games.opponent_score IS
  'Opponent score for Team head-to-head events. RPC-only.';
COMMENT ON COLUMN public.pickup_games.scoring_status IS
  'scheduled | live | final. Independent of pickup_games.status archive lifecycle.';
COMMENT ON COLUMN public.pickup_games.scoring_finalized_at IS
  'Set when scoring_status becomes final. Used for Results ordering + record.';

DO $$
DECLARE
  v_type text;
BEGIN
  SELECT data_type INTO v_type
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'pickup_games' AND column_name = 'team_score';
  IF v_type IS DISTINCT FROM 'integer' THEN
    RAISE EXCEPTION 'pickup_games.team_score exists with incompatible type %', v_type;
  END IF;
  SELECT data_type INTO v_type
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'pickup_games' AND column_name = 'opponent_score';
  IF v_type IS DISTINCT FROM 'integer' THEN
    RAISE EXCEPTION 'pickup_games.opponent_score exists with incompatible type %', v_type;
  END IF;
  SELECT data_type INTO v_type
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'pickup_games' AND column_name = 'scoring_status';
  IF v_type IS DISTINCT FROM 'text' THEN
    RAISE EXCEPTION 'pickup_games.scoring_status exists with incompatible type %', v_type;
  END IF;
  SELECT data_type INTO v_type
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'pickup_games' AND column_name = 'scoring_finalized_at';
  IF v_type IS NOT NULL AND v_type IS DISTINCT FROM 'timestamp with time zone' THEN
    RAISE EXCEPTION 'pickup_games.scoring_finalized_at exists with incompatible type %', v_type;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS pickup_games_scoring_final_idx
  ON public.pickup_games (scoring_finalized_at DESC)
  WHERE scoring_status = 'final';

-- ---------------------------------------------------------------------------
-- 2) Append-only score audit
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.fan_team_event_score_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id uuid NOT NULL REFERENCES public.fan_teams (id) ON DELETE CASCADE,
  event_id uuid NOT NULL REFERENCES public.pickup_games (id) ON DELETE CASCADE,
  previous_team_score integer NOT NULL,
  previous_opponent_score integer NOT NULL,
  new_team_score integer NOT NULL,
  new_opponent_score integer NOT NULL,
  previous_scoring_status text NOT NULL,
  new_scoring_status text NOT NULL,
  kind text NOT NULL,
  changed_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  idempotency_key text NOT NULL,
  CONSTRAINT fan_team_event_score_events_idempotency_uidx UNIQUE (idempotency_key),
  CONSTRAINT fan_team_event_score_events_kind_ck
    CHECK (kind IN (
      'increment', 'decrement', 'mark_live', 'mark_final', 'correct_final'
    )),
  CONSTRAINT fan_team_event_score_events_scores_nonneg_ck
    CHECK (
      previous_team_score >= 0
      AND previous_opponent_score >= 0
      AND new_team_score >= 0
      AND new_opponent_score >= 0
    ),
  CONSTRAINT fan_team_event_score_events_idempotency_len_ck
    CHECK (char_length(idempotency_key) BETWEEN 8 AND 180)
);

CREATE INDEX IF NOT EXISTS fan_team_event_score_events_event_created_idx
  ON public.fan_team_event_score_events (event_id, created_at DESC);
CREATE INDEX IF NOT EXISTS fan_team_event_score_events_team_created_idx
  ON public.fan_team_event_score_events (team_id, created_at DESC);

COMMENT ON TABLE public.fan_team_event_score_events IS
  'Append-only Team score / lifecycle audit. Never updated. Idempotency unique.';

ALTER TABLE public.fan_team_event_score_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.fan_team_event_score_events FROM PUBLIC;
REVOKE ALL ON TABLE public.fan_team_event_score_events FROM anon;
REVOKE ALL ON TABLE public.fan_team_event_score_events FROM authenticated;
GRANT SELECT, INSERT ON TABLE public.fan_team_event_score_events TO service_role;

DROP POLICY IF EXISTS fan_team_event_score_events_no_direct ON public.fan_team_event_score_events;
CREATE POLICY fan_team_event_score_events_no_direct
  ON public.fan_team_event_score_events
  FOR ALL
  TO authenticated
  USING (false)
  WITH CHECK (false);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'fan_team_event_score_events'
      AND column_name = 'idempotency_key'
  ) THEN
    RAISE EXCEPTION 'fan_team_event_score_events missing idempotency_key';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'fan_team_event_score_events_idempotency_uidx'
  ) THEN
    RAISE EXCEPTION 'fan_team_event_score_events missing unique idempotency_key';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 3) Block direct client mutation of scoring columns
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.protect_pickup_game_scoring_columns()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  -- Transaction-local GUC set only by scoring RPCs (set_config(..., is_local=true)).
  -- PostgREST clients cannot combine SET + UPDATE in one request. Session leftover
  -- cannot survive COMMIT/ROLLBACK because is_local=true.
  IF current_setting('gameon.fan_team_scoring_rpc', true) = '1' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.team_score := 0;
    NEW.opponent_score := 0;
    NEW.scoring_status := 'scheduled';
    NEW.scoring_finalized_at := NULL;
    RETURN NEW;
  END IF;
  IF NEW.team_score IS DISTINCT FROM OLD.team_score
     OR NEW.opponent_score IS DISTINCT FROM OLD.opponent_score
     OR NEW.scoring_status IS DISTINCT FROM OLD.scoring_status
     OR NEW.scoring_finalized_at IS DISTINCT FROM OLD.scoring_finalized_at THEN
    RAISE EXCEPTION 'Team scores can only be changed via scoring RPC.'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.protect_pickup_game_scoring_columns() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.protect_pickup_game_scoring_columns() FROM anon;
REVOKE ALL ON FUNCTION public.protect_pickup_game_scoring_columns() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.protect_pickup_game_scoring_columns() TO service_role;

DROP TRIGGER IF EXISTS pickup_games_protect_scoring_columns ON public.pickup_games;
CREATE TRIGGER pickup_games_protect_scoring_columns
  BEFORE INSERT OR UPDATE OF team_score, opponent_score, scoring_status, scoring_finalized_at
  ON public.pickup_games
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_pickup_game_scoring_columns();

-- ---------------------------------------------------------------------------
-- 4) Capability + permission helpers (mirror iOS catalog)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_team_sport_is_team_ball(p_sport text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  -- Mirrors iOS FanTeamEventTypeCatalog.sportFamily(.teamBall) positives, minus
  -- running / cycling / climb / aerial / dance / winter / water / martial.
  SELECT
    CASE
      WHEN nullif(btrim(coalesce(p_sport, '')), '') IS NULL THEN true
      ELSE (
        lower(btrim(p_sport)) ~ '(soccer|football|futbol|nba|wnba|basketball|nfl|baseball|mlb|nhl|hockey|volleyball|cricket|rugby|softball|lacrosse|tennis|golf|handball|pickleball|padel|badminton|ping.?pong|bowling|esport)'
        AND lower(btrim(p_sport)) !~ '(running|track|marathon|trail.?run|cycling|bike|biking|climb|bouldering|skydive|paragliding|hang.?glid|paramotor|dance|ballet|ski|snowboard|swim|boxing|mma|ufc|wrestl|martial|judo|karate)'
      )
    END;
$$;

CREATE OR REPLACE FUNCTION public.fan_team_event_is_score_capable(
  p_format text,
  p_sport text
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  SELECT
    lower(btrim(coalesce(p_format, ''))) IN (
      'league_game', 'tournament_game', 'match', 'scrimmage'
    )
    AND public.fan_team_sport_is_team_ball(p_sport);
$$;

CREATE OR REPLACE FUNCTION public.fan_team_viewer_can_score(p_team_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := (SELECT auth.uid());
  v_role text;
BEGIN
  IF me IS NULL OR p_team_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT m.role INTO v_role
  FROM public.fan_team_members m
  WHERE m.team_id = p_team_id
    AND m.user_id = me
    AND m.left_at IS NULL
  LIMIT 1;

  IF v_role IS NULL THEN
    RETURN false;
  END IF;

  IF lower(btrim(v_role)) IN ('owner', 'manager') THEN
    RETURN true;
  END IF;

  RETURN public.fan_team_viewer_has_permission(p_team_id, 'edit_events');
END;
$$;

COMMENT ON FUNCTION public.fan_team_viewer_can_score(uuid) IS
  'Owner, Manager title, or granted edit_events. Captain/member are read-only.';

REVOKE ALL ON FUNCTION public.fan_team_viewer_can_score(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fan_team_viewer_can_score(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.fan_team_viewer_can_score(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_viewer_can_score(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.fan_team_event_has_opponent(p_pickup_game_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT
    nullif(btrim(coalesce(pg.opponent_name, '')), '') IS NOT NULL
    OR EXISTS (
      SELECT 1
      FROM public.fan_team_game_links l
      WHERE l.pickup_game_id = p_pickup_game_id
        AND l.side = 'away'
    )
  FROM public.pickup_games pg
  WHERE pg.id = p_pickup_game_id;
$$;

REVOKE ALL ON FUNCTION public.fan_team_sport_is_team_ball(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fan_team_sport_is_team_ball(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.fan_team_sport_is_team_ball(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_sport_is_team_ball(text) TO service_role;

REVOKE ALL ON FUNCTION public.fan_team_event_is_score_capable(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fan_team_event_is_score_capable(text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.fan_team_event_is_score_capable(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_event_is_score_capable(text, text) TO service_role;

REVOKE ALL ON FUNCTION public.fan_team_event_has_opponent(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fan_team_event_has_opponent(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.fan_team_event_has_opponent(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_event_has_opponent(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 5) Shared score-push enqueue (reuses notify-pickup-game-change)
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
BEGIN
  IF p_pickup_game_id IS NULL OR p_team_id IS NULL OR p_audit_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_kind := lower(btrim(coalesce(p_notification_type, '')));
  IF v_kind NOT IN ('team_event_scored', 'team_event_final') THEN
    RETURN NULL;
  END IF;

  v_score_line :=
    coalesce(nullif(btrim(p_team_name), ''), 'Team')
    || ' '
    || p_team_score::text
    || ' – '
    || p_opponent_score::text
    || ' '
    || coalesce(nullif(btrim(p_opponent_name), ''), 'Opponent');

  IF v_kind = 'team_event_final' THEN
    v_title := 'Final';
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
    'audit_id', p_audit_id,
    'idempotency_key', p_idempotency_key,
    'safe_destination', 'scheduleActivity'
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

-- Matching idempotency lookup. Never returns another event/team's audit row.
CREATE OR REPLACE FUNCTION public.fan_team_score_require_matching_audit(
  p_key text,
  p_event_id uuid,
  p_team_id uuid
)
RETURNS public.fan_team_event_score_events
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_row public.fan_team_event_score_events%ROWTYPE;
BEGIN
  SELECT * INTO v_row
  FROM public.fan_team_event_score_events e
  WHERE e.idempotency_key = p_key;
  IF v_row.id IS NULL THEN
    RETURN v_row;
  END IF;
  IF v_row.event_id IS DISTINCT FROM p_event_id
     OR v_row.team_id IS DISTINCT FROM p_team_id THEN
    RAISE EXCEPTION 'Idempotency key already used for a different event.'
      USING ERRCODE = '23514';
  END IF;
  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public.fan_team_score_require_matching_audit(text, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fan_team_score_require_matching_audit(text, uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.fan_team_score_require_matching_audit(text, uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_score_require_matching_audit(text, uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 6) Authoritative score RPC (deltas, row lock, idempotent)
-- ---------------------------------------------------------------------------
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

  BEGIN
    INSERT INTO public.fan_team_event_score_events (
      team_id, event_id,
      previous_team_score, previous_opponent_score,
      new_team_score, new_opponent_score,
      previous_scoring_status, new_scoring_status,
      kind, changed_by, idempotency_key
    )
    VALUES (
      p_team_id, p_event_id,
      v_prev_view_team, v_prev_view_opp,
      v_view_team, v_view_opp,
      v_pg.scoring_status, v_pg.scoring_status,
      v_kind, me, v_key
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

REVOKE ALL ON FUNCTION public.update_fan_team_event_score(uuid, uuid, integer, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_fan_team_event_score(uuid, uuid, integer, integer, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_fan_team_event_score(uuid, uuid, integer, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_fan_team_event_score(uuid, uuid, integer, integer, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 7) Mark Live / Mark Final
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_fan_team_event_scoring_status(
  p_event_id uuid,
  p_team_id uuid,
  p_status text,
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
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := (SELECT auth.uid());
  v_key text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
  v_status text := lower(btrim(coalesce(p_status, '')));
  v_link_side text;
  v_pg public.pickup_games%ROWTYPE;
  v_view_team integer;
  v_view_opp integer;
  v_kind text;
  v_audit_id uuid;
  v_team_name text;
  v_opponent text;
  v_existing public.fan_team_event_score_events%ROWTYPE;
  v_finalized timestamptz;
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
  IF v_status NOT IN ('live', 'final') THEN
    RAISE EXCEPTION 'Status must be live or final.';
  END IF;

  IF NOT public.fan_team_viewer_can_score(p_team_id) THEN
    RAISE EXCEPTION 'Only an Owner or Manager can change game status.'
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
    IF v_link_side = 'away' THEN
      team_score := v_pg.opponent_score;
      opponent_score := v_pg.team_score;
    ELSE
      team_score := v_pg.team_score;
      opponent_score := v_pg.opponent_score;
    END IF;
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
  IF v_pg.status = 'removed' THEN
    RAISE EXCEPTION 'Cancelled events cannot be scored.';
  END IF;

  IF v_link_side = 'away' THEN
    v_view_team := v_pg.opponent_score;
    v_view_opp := v_pg.team_score;
  ELSE
    v_view_team := v_pg.team_score;
    v_view_opp := v_pg.opponent_score;
  END IF;

  IF v_status = 'live' THEN
    IF v_pg.scoring_status = 'final' THEN
      RAISE EXCEPTION 'Final games cannot be marked Live.';
    END IF;
    IF v_pg.scoring_status = 'live' THEN
      event_id := p_event_id;
      team_id := p_team_id;
      team_score := v_view_team;
      opponent_score := v_view_opp;
      scoring_status := 'live';
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
      replayed := false;
      RETURN NEXT;
      RETURN;
    END IF;
    v_kind := 'mark_live';
    v_finalized := v_pg.scoring_finalized_at;
  ELSE
    IF v_pg.scoring_status = 'final' THEN
      event_id := p_event_id;
      team_id := p_team_id;
      team_score := v_view_team;
      opponent_score := v_view_opp;
      scoring_status := 'final';
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
      replayed := false;
      RETURN NEXT;
      RETURN;
    END IF;
    v_kind := 'mark_final';
    v_finalized := now();
  END IF;

  BEGIN
    INSERT INTO public.fan_team_event_score_events (
      team_id, event_id,
      previous_team_score, previous_opponent_score,
      new_team_score, new_opponent_score,
      previous_scoring_status, new_scoring_status,
      kind, changed_by, idempotency_key
    )
    VALUES (
      p_team_id, p_event_id,
      v_view_team, v_view_opp,
      v_view_team, v_view_opp,
      v_pg.scoring_status, v_status,
      v_kind, me, v_key
    )
    RETURNING id INTO v_audit_id;
  EXCEPTION WHEN unique_violation THEN
    v_existing := public.fan_team_score_require_matching_audit(v_key, p_event_id, p_team_id);
    event_id := p_event_id;
    team_id := p_team_id;
    team_score := v_view_team;
    opponent_score := v_view_opp;
    scoring_status := v_pg.scoring_status;
    scoring_finalized_at := v_pg.scoring_finalized_at;
    opponent_name := nullif(btrim(coalesce(v_pg.opponent_name, '')), '');
    replayed := true;
    RETURN NEXT;
    RETURN;
  END;

  UPDATE public.pickup_games
  SET scoring_status = v_status,
      scoring_finalized_at = v_finalized
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

  IF v_status = 'final' AND v_pg.scoring_status IS DISTINCT FROM 'final' THEN
    PERFORM public.queue_fan_team_event_score_push_notification(
      p_event_id,
      p_team_id,
      me,
      v_audit_id,
      v_key,
      'team_event_final',
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
  scoring_status := v_status;
  scoring_finalized_at := v_finalized;
  opponent_name := v_opponent;
  replayed := false;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.set_fan_team_event_scoring_status(uuid, uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_fan_team_event_scoring_status(uuid, uuid, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_fan_team_event_scoring_status(uuid, uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_fan_team_event_scoring_status(uuid, uuid, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 8) Correct Result after Final (absolute scores, no scored push)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.correct_fan_team_event_final_score(
  p_event_id uuid,
  p_team_id uuid,
  p_team_score integer,
  p_opponent_score integer,
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
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := (SELECT auth.uid());
  v_key text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
  v_link_side text;
  v_pg public.pickup_games%ROWTYPE;
  v_new_view_team integer := coalesce(p_team_score, 0);
  v_new_view_opp integer := coalesce(p_opponent_score, 0);
  v_new_stored_team integer;
  v_new_stored_opp integer;
  v_prev_view_team integer;
  v_prev_view_opp integer;
  v_existing public.fan_team_event_score_events%ROWTYPE;
  v_opponent text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '42501';
  END IF;
  IF v_key IS NULL OR char_length(v_key) < 8 OR char_length(v_key) > 180 THEN
    RAISE EXCEPTION 'Idempotency key is required.';
  END IF;
  IF v_new_view_team < 0 OR v_new_view_opp < 0 THEN
    RAISE EXCEPTION 'Score cannot go below 0.';
  END IF;
  IF p_event_id IS NULL OR p_team_id IS NULL THEN
    RAISE EXCEPTION 'Event and Team are required.';
  END IF;

  IF NOT public.fan_team_viewer_can_score(p_team_id) THEN
    RAISE EXCEPTION 'Only an Owner or Manager can correct the result.'
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
    scoring_status := 'final';
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

  IF v_pg.scoring_status IS DISTINCT FROM 'final' THEN
    RAISE EXCEPTION 'Correct Result is only available after Final.';
  END IF;
  IF NOT public.fan_team_event_is_score_capable(v_pg.game_format, v_pg.sport) THEN
    RAISE EXCEPTION 'This event type does not support scoring.';
  END IF;
  IF v_pg.status = 'removed' THEN
    RAISE EXCEPTION 'Cancelled events cannot be scored.';
  END IF;

  IF v_link_side = 'away' THEN
    v_prev_view_team := v_pg.opponent_score;
    v_prev_view_opp := v_pg.team_score;
    v_new_stored_team := v_new_view_opp;
    v_new_stored_opp := v_new_view_team;
  ELSE
    v_prev_view_team := v_pg.team_score;
    v_prev_view_opp := v_pg.opponent_score;
    v_new_stored_team := v_new_view_team;
    v_new_stored_opp := v_new_view_opp;
  END IF;

  BEGIN
    INSERT INTO public.fan_team_event_score_events (
      team_id, event_id,
      previous_team_score, previous_opponent_score,
      new_team_score, new_opponent_score,
      previous_scoring_status, new_scoring_status,
      kind, changed_by, idempotency_key
    )
    VALUES (
      p_team_id, p_event_id,
      v_prev_view_team, v_prev_view_opp,
      v_new_view_team, v_new_view_opp,
      'final', 'final',
      'correct_final', me, v_key
    );
  EXCEPTION WHEN unique_violation THEN
    v_existing := public.fan_team_score_require_matching_audit(v_key, p_event_id, p_team_id);
    event_id := p_event_id;
    team_id := p_team_id;
    team_score := v_existing.new_team_score;
    opponent_score := v_existing.new_opponent_score;
    scoring_status := 'final';
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

  event_id := p_event_id;
  team_id := p_team_id;
  team_score := v_new_view_team;
  opponent_score := v_new_view_opp;
  scoring_status := 'final';
  scoring_finalized_at := v_pg.scoring_finalized_at;
  opponent_name := v_opponent;
  replayed := false;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.correct_fan_team_event_final_score(uuid, uuid, integer, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.correct_fan_team_event_final_score(uuid, uuid, integer, integer, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.correct_fan_team_event_final_score(uuid, uuid, integer, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.correct_fan_team_event_final_score(uuid, uuid, integer, integer, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 9) Derived W-L-T + paginated Results
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_fan_team_record(p_team_id uuid)
RETURNS TABLE (
  wins integer,
  losses integer,
  ties integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := (SELECT auth.uid());
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF NOT public.fan_team_viewer_can_access_team(p_team_id) THEN
    RAISE EXCEPTION 'Not authorized to view this Team.';
  END IF;

  RETURN QUERY
  SELECT
    count(*) FILTER (
      WHERE CASE WHEN l.side = 'away' THEN pg.opponent_score ELSE pg.team_score END
          > CASE WHEN l.side = 'away' THEN pg.team_score ELSE pg.opponent_score END
    )::integer AS wins,
    count(*) FILTER (
      WHERE CASE WHEN l.side = 'away' THEN pg.opponent_score ELSE pg.team_score END
          < CASE WHEN l.side = 'away' THEN pg.team_score ELSE pg.opponent_score END
    )::integer AS losses,
    count(*) FILTER (
      WHERE CASE WHEN l.side = 'away' THEN pg.opponent_score ELSE pg.team_score END
          = CASE WHEN l.side = 'away' THEN pg.team_score ELSE pg.opponent_score END
    )::integer AS ties
  FROM public.fan_team_game_links l
  JOIN public.pickup_games pg ON pg.id = l.pickup_game_id
  WHERE l.team_id = p_team_id
    AND pg.scoring_status = 'final'
    AND pg.status IS DISTINCT FROM 'removed'
    AND public.fan_team_event_is_score_capable(pg.game_format, pg.sport);
END;
$$;

REVOKE ALL ON FUNCTION public.get_fan_team_record(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_fan_team_record(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_fan_team_record(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_fan_team_record(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.list_fan_team_scored_results(
  p_team_id uuid,
  p_before_completed_at timestamptz DEFAULT NULL,
  p_limit integer DEFAULT 20
)
RETURNS TABLE (
  id uuid,
  team_id uuid,
  created_by uuid,
  game_type text,
  sport text,
  title text,
  starts_at timestamptz,
  ends_at timestamptz,
  venue_name text,
  address text,
  city text,
  state text,
  latitude double precision,
  longitude double precision,
  opponent_team_id uuid,
  opponent_name text,
  status text,
  home_score integer,
  away_score integer,
  pickup_game_id uuid,
  my_side text,
  created_at timestamptz,
  competition_level text,
  description text,
  scoring_status text,
  scoring_finalized_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := (SELECT auth.uid());
  v_limit integer := greatest(1, least(coalesce(p_limit, 20), 50));
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF NOT public.fan_team_viewer_can_access_team(p_team_id) THEN
    RAISE EXCEPTION 'Not authorized to view this Team.';
  END IF;

  RETURN QUERY
  SELECT
    pg.id,
    p_team_id,
    pg.creator_user_id,
    pg.game_format,
    pg.sport,
    pg.title,
    pg.game_start_at,
    pg.end_time,
    pg.address,
    pg.address,
    pg.city,
    pg.state,
    pg.latitude,
    pg.longitude,
    (
      SELECT l2.team_id
      FROM public.fan_team_game_links l2
      WHERE l2.pickup_game_id = pg.id
        AND l2.team_id <> p_team_id
      LIMIT 1
    ),
    coalesce(
      (
        SELECT nullif(btrim(ot.name), '')
        FROM public.fan_team_game_links l2
        JOIN public.fan_teams ot ON ot.id = l2.team_id
        WHERE l2.pickup_game_id = pg.id
          AND l2.team_id <> p_team_id
        LIMIT 1
      ),
      nullif(btrim(pg.opponent_name), '')
    ),
    'completed'::text,
    CASE WHEN l.side = 'away' THEN pg.opponent_score ELSE pg.team_score END,
    CASE WHEN l.side = 'away' THEN pg.team_score ELSE pg.opponent_score END,
    pg.id,
    l.side,
    pg.created_at,
    pg.competition_level,
    nullif(btrim(coalesce(pg.description, '')), ''),
    pg.scoring_status,
    pg.scoring_finalized_at
  FROM public.fan_team_game_links l
  JOIN public.pickup_games pg ON pg.id = l.pickup_game_id
  WHERE l.team_id = p_team_id
    AND pg.scoring_status = 'final'
    AND pg.status IS DISTINCT FROM 'removed'
    AND public.fan_team_event_is_score_capable(pg.game_format, pg.sport)
    AND (p_before_completed_at IS NULL OR pg.scoring_finalized_at < p_before_completed_at)
  ORDER BY pg.scoring_finalized_at DESC NULLS LAST, pg.id DESC
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.list_fan_team_scored_results(uuid, timestamptz, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_fan_team_scored_results(uuid, timestamptz, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.list_fan_team_scored_results(uuid, timestamptz, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_fan_team_scored_results(uuid, timestamptz, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 10) list_fan_team_games — populate scores + scoring_status
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.list_fan_team_games(uuid);

CREATE FUNCTION public.list_fan_team_games(p_team_id uuid)
RETURNS TABLE (
  id uuid,
  team_id uuid,
  created_by uuid,
  game_type text,
  sport text,
  title text,
  starts_at timestamptz,
  ends_at timestamptz,
  venue_name text,
  address text,
  city text,
  state text,
  latitude double precision,
  longitude double precision,
  opponent_team_id uuid,
  opponent_name text,
  status text,
  home_score integer,
  away_score integer,
  pickup_game_id uuid,
  my_side text,
  created_at timestamptz,
  competition_level text,
  description text,
  scoring_status text,
  scoring_finalized_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := auth.uid();
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF NOT public.fan_team_viewer_can_access_team(p_team_id) THEN
    RAISE EXCEPTION 'Not authorized to view this Team.';
  END IF;

  RETURN QUERY
  SELECT
    pg.id,
    p_team_id AS team_id,
    pg.creator_user_id AS created_by,
    pg.game_format AS game_type,
    pg.sport,
    pg.title,
    pg.game_start_at AS starts_at,
    pg.end_time AS ends_at,
    pg.address AS venue_name,
    pg.address,
    pg.city,
    pg.state,
    pg.latitude,
    pg.longitude,
    (
      SELECT l2.team_id
      FROM public.fan_team_game_links l2
      WHERE l2.pickup_game_id = pg.id
        AND l2.team_id <> p_team_id
      LIMIT 1
    ) AS opponent_team_id,
    coalesce(
      (
        SELECT nullif(btrim(ot.name), '')
        FROM public.fan_team_game_links l2
        JOIN public.fan_teams ot ON ot.id = l2.team_id
        WHERE l2.pickup_game_id = pg.id
          AND l2.team_id <> p_team_id
        LIMIT 1
      ),
      nullif(btrim(pg.opponent_name), '')
    ) AS opponent_name,
    CASE
      WHEN pg.status = 'removed' THEN 'cancelled'
      WHEN pg.scoring_status = 'final' THEN 'completed'
      WHEN pg.scoring_status = 'live' THEN 'live'
      WHEN pg.status = 'expired' THEN 'completed'
      WHEN pg.archived_at IS NOT NULL THEN 'completed'
      ELSE 'scheduled'
    END AS status,
    CASE
      WHEN pg.scoring_status IN ('live', 'final') THEN
        CASE WHEN l.side = 'away' THEN pg.opponent_score ELSE pg.team_score END
      ELSE NULL
    END AS home_score,
    CASE
      WHEN pg.scoring_status IN ('live', 'final') THEN
        CASE WHEN l.side = 'away' THEN pg.team_score ELSE pg.opponent_score END
      ELSE NULL
    END AS away_score,
    pg.id AS pickup_game_id,
    l.side AS my_side,
    pg.created_at,
    pg.competition_level,
    nullif(btrim(coalesce(pg.description, '')), '') AS description,
    coalesce(pg.scoring_status, 'scheduled') AS scoring_status,
    pg.scoring_finalized_at
  FROM public.fan_team_game_links l
  JOIN public.pickup_games pg ON pg.id = l.pickup_game_id
  WHERE l.team_id = p_team_id
  ORDER BY pg.game_start_at DESC
  LIMIT 100;
END;
$$;

REVOKE ALL ON FUNCTION public.list_fan_team_games(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_fan_team_games(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.list_fan_team_games(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_fan_team_games(uuid) TO service_role;

COMMENT ON FUNCTION public.list_fan_team_games(uuid) IS
  'Team Schedule list. home_score/away_score are viewing-team vs opponent when Live/Final.';

-- ---------------------------------------------------------------------------
-- 11) Inbox copy for score / final (preserve 20260998 snapshot behavior)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fanout_fan_notification_inbox_for_pickup_update_event(
  p_update_event_id uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_event public.pickup_game_update_events%ROWTYPE;
  v_payload jsonb;
  v_kinds text[];
  v_notification_type text;
  v_title text;
  v_body text;
  v_kind_raw text;
  v_dest text;
  v_dedupe text;
  v_team_id uuid;
  v_team_name text;
  v_game_title text;
  v_uid uuid;
  v_count integer := 0;
  v_is_cancel boolean := false;
  v_override uuid[];
BEGIN
  IF p_update_event_id IS NULL THEN
    RETURN 0;
  END IF;

  SELECT * INTO v_event
  FROM public.pickup_game_update_events e
  WHERE e.id = p_update_event_id;

  IF v_event.id IS NULL THEN
    RETURN 0;
  END IF;

  v_payload := coalesce(v_event.payload, '{}'::jsonb);
  v_kinds := coalesce(v_event.change_kinds, ARRAY[]::text[]);
  v_notification_type := lower(btrim(coalesce(v_payload->>'notification_type', '')));
  IF v_notification_type = '' THEN
    IF 'cancelled' = ANY (v_kinds) OR 'canceled' = ANY (v_kinds) THEN
      v_notification_type := 'cancelled';
    ELSIF 'created' = ANY (v_kinds) THEN
      v_notification_type := 'created';
    ELSIF 'start' = ANY (v_kinds) AND 'location' = ANY (v_kinds) THEN
      v_notification_type := 'time_and_location_changed';
    ELSIF 'start' = ANY (v_kinds) OR 'end' = ANY (v_kinds) THEN
      v_notification_type := 'time_changed';
    ELSIF 'location' = ANY (v_kinds) THEN
      v_notification_type := 'location_changed';
    ELSE
      v_notification_type := 'schedule_change';
    END IF;
  END IF;

  v_is_cancel := v_notification_type IN ('cancelled', 'canceled', 'event_cancelled')
    OR 'cancelled' = ANY (v_kinds)
    OR 'canceled' = ANY (v_kinds);

  v_game_title := nullif(btrim(coalesce(v_payload->>'title', '')), '');
  IF v_game_title IS NULL THEN
    SELECT nullif(btrim(g.title), '') INTO v_game_title
    FROM public.pickup_games g
    WHERE g.id = v_event.pickup_game_id;
  END IF;
  v_game_title := coalesce(v_game_title, 'Event');

  v_team_id := NULLIF(v_payload->>'team_id', '')::uuid;
  IF v_team_id IS NULL THEN
    SELECT l.team_id INTO v_team_id
    FROM public.fan_team_game_links l
    INNER JOIN public.fan_teams t ON t.id = l.team_id AND t.is_active = true
    WHERE l.pickup_game_id = v_event.pickup_game_id
    LIMIT 1;
  END IF;

  v_team_name := nullif(btrim(coalesce(v_payload->>'team_name', '')), '');
  IF v_team_name IS NULL AND v_team_id IS NOT NULL THEN
    SELECT nullif(btrim(t.name), '') INTO v_team_name
    FROM public.fan_teams t
    WHERE t.id = v_team_id;
  END IF;

  IF v_notification_type IN ('join_request_approved', 'join_request_rejected') THEN
    v_title := 'Your request to join';
    v_body := v_game_title
      || CASE
           WHEN v_notification_type = 'join_request_approved' THEN ' was approved.'
           ELSE ' was declined.'
         END;
    v_kind_raw := 'scheduleChange';
    v_dest := 'scheduleActivity';
    v_dedupe := 'join_request_decision:'
      || lower(v_event.pickup_game_id::text)
      || ':'
      || lower(v_event.id::text);
  ELSIF v_notification_type IN ('team_event_scored')
        OR 'team_event_scored' = ANY (v_kinds) THEN
    v_title := coalesce(nullif(btrim(v_payload->>'score_title'), ''), coalesce(v_team_name, 'Team') || ' scored');
    v_body := coalesce(nullif(btrim(v_payload->>'score_line'), ''), v_game_title);
    v_kind_raw := 'scheduleChange';
    v_dest := 'scheduleActivity';
    v_dedupe := 'team_event_score:'
      || lower(v_event.pickup_game_id::text)
      || ':'
      || lower(v_event.id::text);
  ELSIF v_notification_type IN ('team_event_final')
        OR 'team_event_final' = ANY (v_kinds) THEN
    v_title := 'Final';
    v_body := coalesce(nullif(btrim(v_payload->>'score_line'), ''), v_game_title);
    v_kind_raw := 'scheduleChange';
    v_dest := 'scheduleActivity';
    v_dedupe := 'team_event_final:'
      || lower(v_event.pickup_game_id::text)
      || ':'
      || lower(v_event.id::text);
  ELSIF v_notification_type IN ('team_announcement')
     OR (v_payload->>'is_team_announcement')::boolean IS TRUE THEN
    v_title := coalesce(v_team_name, 'Team') || ' announcement';
    v_body := v_game_title;
    v_kind_raw := 'scheduleChange';
    v_dest := 'scheduleActivity';
    v_dedupe := 'pickup_update:'
      || lower(v_event.pickup_game_id::text)
      || ':'
      || lower(v_event.id::text);
  ELSIF v_is_cancel THEN
    v_title := CASE
      WHEN v_team_name IS NOT NULL THEN v_team_name || ' event cancelled'
      ELSE 'Event cancelled'
    END;
    v_body := v_game_title;
    v_kind_raw := 'eventCancellation';
    v_dest := 'scheduleActivity';
    v_dedupe := 'pickup_cancel:'
      || lower(v_event.pickup_game_id::text)
      || ':'
      || lower(v_event.id::text);
  ELSIF v_notification_type IN ('team_game_created', 'created', 'team_event_created')
        OR 'created' = ANY (v_kinds) THEN
    v_title := CASE
      WHEN v_team_name IS NOT NULL THEN v_team_name || ' scheduled an event'
      ELSE 'New event'
    END;
    v_body := v_game_title;
    v_kind_raw := 'scheduleChange';
    v_dest := 'scheduleActivity';
    v_dedupe := 'pickup_update:'
      || lower(v_event.pickup_game_id::text)
      || ':'
      || lower(v_event.id::text);
  ELSIF v_notification_type IN ('time_and_location_changed') THEN
    v_title := CASE
      WHEN v_team_name IS NOT NULL THEN v_team_name || ' updated time & location'
      ELSE 'Time & location updated'
    END;
    v_body := v_game_title;
    v_kind_raw := 'scheduleChange';
    v_dest := 'scheduleActivity';
    v_dedupe := 'pickup_update:'
      || lower(v_event.pickup_game_id::text)
      || ':'
      || lower(v_event.id::text);
  ELSIF v_notification_type IN ('time_changed')
        OR 'start' = ANY (v_kinds) OR 'end' = ANY (v_kinds) THEN
    v_title := CASE
      WHEN v_team_name IS NOT NULL THEN v_team_name || ' updated the time'
      ELSE 'Event time updated'
    END;
    v_body := v_game_title;
    v_kind_raw := 'scheduleChange';
    v_dest := 'scheduleActivity';
    v_dedupe := 'pickup_update:'
      || lower(v_event.pickup_game_id::text)
      || ':'
      || lower(v_event.id::text);
  ELSIF v_notification_type IN ('location_changed') OR 'location' = ANY (v_kinds) THEN
    v_title := CASE
      WHEN v_team_name IS NOT NULL THEN v_team_name || ' updated the location'
      ELSE 'Event location updated'
    END;
    v_body := v_game_title;
    v_kind_raw := 'scheduleChange';
    v_dest := 'scheduleActivity';
    v_dedupe := 'pickup_update:'
      || lower(v_event.pickup_game_id::text)
      || ':'
      || lower(v_event.id::text);
  ELSE
    v_title := CASE
      WHEN v_team_name IS NOT NULL THEN v_team_name || ' updated an event'
      ELSE 'Event updated'
    END;
    v_body := v_game_title;
    v_kind_raw := 'scheduleChange';
    v_dest := 'scheduleActivity';
    v_dedupe := 'pickup_update:'
      || lower(v_event.pickup_game_id::text)
      || ':'
      || lower(v_event.id::text);
  END IF;

  SELECT coalesce(
    array_agg(DISTINCT x.uid) FILTER (WHERE x.uid IS NOT NULL),
    '{}'::uuid[]
  )
  INTO v_override
  FROM (
    SELECT NULLIF(btrim(j), '')::uuid AS uid
    FROM jsonb_array_elements_text(coalesce(v_payload->'recipient_user_ids', '[]'::jsonb)) AS j
  ) x;

  IF cardinality(v_override) > 0 THEN
    FOREACH v_uid IN ARRAY v_override LOOP
      IF public.upsert_fan_notification_inbox(
        p_user_id := v_uid,
        p_notification_type := v_notification_type,
        p_title := v_title,
        p_body := v_body,
        p_kind_raw := v_kind_raw,
        p_destination_raw := v_dest,
        p_deduplication_key := v_dedupe || ':' || lower(v_uid::text),
        p_source_type := 'pickup_game_change_notification',
        p_source_id := v_event.id::text,
        p_team_id := v_team_id,
        p_event_id := v_event.pickup_game_id,
        p_actor_user_id := v_event.editor_user_id,
        p_payload := v_payload || jsonb_build_object(
          'pickup_game_id', v_event.pickup_game_id,
          'pickup_update_event_id', v_event.id,
          'deduplication_key', v_dedupe || ':' || lower(v_uid::text),
          'change_kinds', to_jsonb(v_kinds),
          'safe_destination', v_dest,
          'team_id', v_team_id,
          'team_name', coalesce(v_team_name, v_payload->>'team_name')
        )
      ) IS NOT NULL THEN
        v_count := v_count + 1;
      END IF;
    END LOOP;
  ELSE
    FOR v_uid IN
      SELECT r.user_id
      FROM public.list_fan_notification_inbox_recipient_user_ids_for_pickup_game(
        v_event.pickup_game_id,
        v_event.editor_user_id
      ) r
    LOOP
      IF public.upsert_fan_notification_inbox(
        p_user_id := v_uid,
        p_notification_type := v_notification_type,
        p_title := v_title,
        p_body := v_body,
        p_kind_raw := v_kind_raw,
        p_destination_raw := v_dest,
        p_deduplication_key := v_dedupe,
        p_source_type := 'pickup_game_change_notification',
        p_source_id := v_event.id::text,
        p_team_id := v_team_id,
        p_event_id := v_event.pickup_game_id,
        p_actor_user_id := v_event.editor_user_id,
        p_payload := v_payload || jsonb_build_object(
          'pickup_game_id', v_event.pickup_game_id,
          'pickup_update_event_id', v_event.id,
          'deduplication_key', v_dedupe,
          'change_kinds', to_jsonb(v_kinds),
          'team_id', v_team_id,
          'team_name', coalesce(v_team_name, v_payload->>'team_name')
        )
      ) IS NOT NULL THEN
        v_count := v_count + 1;
      END IF;
    END LOOP;
  END IF;

  RAISE LOG
    '[FanNotificationInbox] pickupFanout update_event_id=% pickup_game_id=% type=% recipients=%',
    p_update_event_id, v_event.pickup_game_id, v_notification_type, v_count;

  RETURN v_count;
END;
$$;

COMMENT ON FUNCTION public.fanout_fan_notification_inbox_for_pickup_update_event(uuid) IS
  'Durable inbox fan-out for pickup/Team schedule + Team score/final events. '
  'Snapshots team_name. Honors payload.recipient_user_ids. Independent of APNs.';

REVOKE ALL ON FUNCTION public.fanout_fan_notification_inbox_for_pickup_update_event(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fanout_fan_notification_inbox_for_pickup_update_event(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.fanout_fan_notification_inbox_for_pickup_update_event(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.fanout_fan_notification_inbox_for_pickup_update_event(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 12) Structural verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_src text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'pickup_games' AND column_name = 'team_score'
  ) THEN
    RAISE EXCEPTION '20261003 missing pickup_games.team_score';
  END IF;
  IF to_regclass('public.fan_team_event_score_events') IS NULL THEN
    RAISE EXCEPTION '20261003 missing fan_team_event_score_events';
  END IF;
  IF to_regprocedure(
       'public.update_fan_team_event_score(uuid, uuid, integer, integer, text)'
     ) IS NULL THEN
    RAISE EXCEPTION '20261003 missing update_fan_team_event_score';
  END IF;
  IF to_regprocedure(
       'public.set_fan_team_event_scoring_status(uuid, uuid, text, text)'
     ) IS NULL THEN
    RAISE EXCEPTION '20261003 missing set_fan_team_event_scoring_status';
  END IF;
  IF to_regprocedure(
       'public.correct_fan_team_event_final_score(uuid, uuid, integer, integer, text)'
     ) IS NULL THEN
    RAISE EXCEPTION '20261003 missing correct_fan_team_event_final_score';
  END IF;
  IF to_regprocedure('public.get_fan_team_record(uuid)') IS NULL THEN
    RAISE EXCEPTION '20261003 missing get_fan_team_record';
  END IF;

  SELECT p.prosrc INTO v_src
  FROM pg_catalog.pg_proc p
  WHERE p.oid = to_regprocedure(
    'public.update_fan_team_event_score(uuid, uuid, integer, integer, text)'
  );
  IF position('fan_team_viewer_can_score' IN v_src) = 0
     OR position('fan_team_score_require_matching_audit' IN v_src) = 0
     OR position('fan_team_viewer_can_score' IN v_src)
          > position('fan_team_score_require_matching_audit' IN v_src)
     OR position('FOR UPDATE' IN v_src) = 0
     OR position('pg_advisory_xact_lock' IN v_src) = 0 THEN
    RAISE EXCEPTION '20261003 update_fan_team_event_score authz/lock/replay order unsafe';
  END IF;

  SELECT p.prosrc INTO v_src
  FROM pg_catalog.pg_proc p
  WHERE p.oid = to_regprocedure(
    'public.set_fan_team_event_scoring_status(uuid, uuid, text, text)'
  );
  IF position('fan_team_viewer_can_score' IN v_src) = 0
     OR position('fan_team_score_require_matching_audit' IN v_src) = 0
     OR position('fan_team_viewer_can_score' IN v_src)
          > position('fan_team_score_require_matching_audit' IN v_src)
     OR position('Final games cannot be marked Live' IN v_src) = 0 THEN
    RAISE EXCEPTION '20261003 set_fan_team_event_scoring_status unsafe';
  END IF;

  SELECT p.prosrc INTO v_src
  FROM pg_catalog.pg_proc p
  WHERE p.oid = to_regprocedure(
    'public.correct_fan_team_event_final_score(uuid, uuid, integer, integer, text)'
  );
  IF position('fan_team_viewer_can_score' IN v_src) = 0
     OR position('fan_team_score_require_matching_audit' IN v_src) = 0
     OR position('fan_team_viewer_can_score' IN v_src)
          > position('fan_team_score_require_matching_audit' IN v_src) THEN
    RAISE EXCEPTION '20261003 correct_fan_team_event_final_score replays before authz';
  END IF;

  SELECT p.prosrc INTO v_src
  FROM pg_catalog.pg_proc p
  WHERE p.oid = to_regprocedure(
    'public.fanout_fan_notification_inbox_for_pickup_update_event(uuid)'
  );
  IF position('team_event_scored' IN v_src) = 0
     OR position('team_event_final' IN v_src) = 0 THEN
    RAISE EXCEPTION '20261003 fanout missing score/final copy';
  END IF;
  IF position('join_request_approved' IN v_src) = 0
     OR position('recipient_user_ids' IN v_src) = 0 THEN
    RAISE EXCEPTION '20261003 fanout lost join-request inbox behavior';
  END IF;
  IF position('coalesce(v_team_name, v_payload' IN v_src) = 0 THEN
    RAISE EXCEPTION '20261003 fanout lost team_name snapshot';
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
