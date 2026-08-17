-- =============================================================================
-- 20260975_0001 — Team Game Created APNs (game-type only)
-- =============================================================================
-- Narrows 20260974 queue_team_event_created_push_notification:
--   • Only competitive game formats (league_game, tournament_game, match, scrimmage)
--   • notification_type = team_game_created
--   • Practice / tryout / clinic / meeting / other → Team Chat only (no create APNs)
-- Recipients unchanged: list_pickup_game_change_push_tokens (members + guardians).
-- UNAPPLIED — deploy with notify-pickup-game-change Edge Function.
-- =============================================================================

DO $$
BEGIN
  IF to_regprocedure('public.queue_team_event_created_push_notification(uuid, uuid, uuid)') IS NULL
     OR to_regprocedure('public.queue_pickup_game_change_push_notification(uuid)') IS NULL
     OR to_regclass('public.pickup_game_update_events') IS NULL
  THEN
    RAISE EXCEPTION
      '20260975_0001 prerequisites missing (apply 20260974 / pickup change push first)';
  END IF;
END $$;

-- Authoritative game-create push formats (mirrors FanTeamEventFormatPolicy.requiresOpponent).
CREATE OR REPLACE FUNCTION public.is_fan_team_game_create_push_format(p_game_format text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  SELECT lower(btrim(coalesce(p_game_format, ''))) IN (
    'league_game',
    'tournament_game',
    'match',
    'scrimmage'
  );
$$;

REVOKE ALL ON FUNCTION public.is_fan_team_game_create_push_format(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_fan_team_game_create_push_format(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_fan_team_game_create_push_format(text) TO service_role;

COMMENT ON FUNCTION public.is_fan_team_game_create_push_format(text) IS
  'True for Team Schedule formats that enqueue team_game_created APNs '
  '(league_game, tournament_game, match, scrimmage). Practice/tryout/etc. excluded.';

CREATE OR REPLACE FUNCTION public.queue_team_event_created_push_notification(
  p_pickup_game_id uuid,
  p_team_id uuid,
  p_editor_user_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_game public.pickup_games%ROWTYPE;
  v_team_name text;
  v_format text;
  v_opponent text;
  v_matchup text;
  v_fingerprint text;
  v_event_id uuid;
  v_existing public.pickup_game_update_events%ROWTYPE;
  v_payload jsonb;
BEGIN
  IF p_pickup_game_id IS NULL OR p_team_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.fan_team_game_links l
    WHERE l.pickup_game_id = p_pickup_game_id
      AND l.team_id = p_team_id
  ) THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_game
  FROM public.pickup_games g
  WHERE g.id = p_pickup_game_id;

  IF v_game.id IS NULL THEN
    RETURN NULL;
  END IF;

  v_format := lower(btrim(coalesce(v_game.game_format, '')));

  -- Practice / tryout / clinic / meeting / other: no game-created APNs.
  IF NOT public.is_fan_team_game_create_push_format(v_format) THEN
    RAISE LOG
      '[TeamGameNotification] gameCreateSkippedNonGame team_id=% event_id=% creator_id=% eventType=%',
      p_team_id, p_pickup_game_id, p_editor_user_id, v_format;
    RETURN NULL;
  END IF;

  SELECT nullif(btrim(coalesce(t.name, '')), '')
  INTO v_team_name
  FROM public.fan_teams t
  WHERE t.id = p_team_id
    AND t.is_active = true;

  IF v_team_name IS NULL THEN
    RAISE LOG
      '[TeamGameNotification] gameCreateSkippedInactiveTeam team_id=% event_id=%',
      p_team_id, p_pickup_game_id;
    RETURN NULL;
  END IF;

  v_opponent := nullif(btrim(coalesce(v_game.opponent_name, '')), '');
  IF v_opponent IS NOT NULL THEN
    v_matchup := v_team_name || ' vs ' || v_opponent;
  ELSE
    v_matchup := NULL;
  END IF;

  -- Idempotency: one create fan-out per persisted game + team link.
  v_fingerprint := md5(
    p_pickup_game_id::text || '|team_game_created|' || p_team_id::text
  );

  v_payload := jsonb_build_object(
    'title', v_game.title,
    'notification_type', 'team_game_created',
    'team_id', p_team_id,
    'team_name', v_team_name,
    'game_format', v_game.game_format,
    'after_start', v_game.game_start_at,
    'after_location', public.pickup_location_label(v_game.address, v_game.city, v_game.state),
    'after_opponent', v_opponent,
    'matchup', v_matchup,
    'after_status', v_game.status,
    'before_status', v_game.status,
    'rsvp_reset_required', false,
    'is_team_game_created', true,
    'is_team_event_created', true
  );

  RAISE LOG
    '[TeamGameNotification] gameCreatePersisted team_id=% event_id=% creator_id=% eventType=% matchup=% gameDate=%',
    p_team_id,
    p_pickup_game_id,
    p_editor_user_id,
    v_format,
    coalesce(v_matchup, '(none)'),
    coalesce(v_game.game_start_at::text, '(none)');

  INSERT INTO public.pickup_game_update_events AS e (
    pickup_game_id, editor_user_id, fingerprint, change_kinds, payload, push_delivery_status
  )
  VALUES (
    p_pickup_game_id,
    p_editor_user_id,
    v_fingerprint,
    ARRAY['created']::text[],
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
      RAISE LOG
        '[TeamGameNotification] fanoutStart idempotent_reuse update_event_id=% team_id=% event_id=%',
        v_existing.id, p_team_id, p_pickup_game_id;
      PERFORM public.queue_pickup_game_change_push_notification(v_existing.id);
    ELSE
      RAISE LOG
        '[TeamGameNotification] fanoutSkippedAlreadySent update_event_id=% team_id=% event_id=%',
        v_existing.id, p_team_id, p_pickup_game_id;
    END IF;
    RETURN v_existing.id;
  END IF;

  RAISE LOG
    '[TeamGameNotification] fanoutStart update_event_id=% team_id=% event_id=% notificationType=team_game_created',
    v_event_id, p_team_id, p_pickup_game_id;

  PERFORM public.queue_pickup_game_change_push_notification(v_event_id);
  RETURN v_event_id;
END;
$$;

REVOKE ALL ON FUNCTION public.queue_team_event_created_push_notification(uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.queue_team_event_created_push_notification(uuid, uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.queue_team_event_created_push_notification(uuid, uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.queue_team_event_created_push_notification(uuid, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.queue_team_event_created_push_notification(uuid, uuid, uuid) IS
  'Enqueues one idempotent team_game_created APNs for competitive Team games only '
  '(league_game|tournament_game|match|scrimmage). Practice/tryout/etc. are no-ops. '
  'Fingerprint: team_game_created:<pickup_game_id>:<team_id>.';
