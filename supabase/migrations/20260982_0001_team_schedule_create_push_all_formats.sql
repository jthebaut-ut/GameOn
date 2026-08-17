-- =============================================================================
-- 20260982_0001 — Team Schedule create push for ALL event formats + diagnostics
-- =============================================================================
-- Depends on (must apply first if not already live):
--   20260974_0001_team_schedule_notifications_rsvp_reset.sql
--   20260975_0001_team_game_created_push.sql
--   20260976_0001_team_announcement_schedule_type.sql
--
-- Fixes remaining create-push product gap after 60975/60976:
--   Practice / tryout / clinic / team_meeting / other (and pickup) create APNs
--   were intentionally no-ops. Product now requires create push for ALL Team
--   schedule event types. Announcements remain team_announcement.
--
-- Competitive formats keep notification_type = team_game_created.
-- Non-competitive schedule formats use notification_type = team_event_created.
--
-- Canonical pipeline unchanged:
--   link_pickup_game_to_fan_team
--     → queue_team_event_created_push_notification
--     → pickup_game_update_events
--     → queue_pickup_game_change_push_notification
--     → Edge notify-pickup-game-change
--     → ApnsClient → user_push_tokens
--
-- UNAPPLIED — deploy manually with Edge notify-pickup-game-change.
-- =============================================================================

DO $$
BEGIN
  IF to_regprocedure('public.queue_team_event_created_push_notification(uuid, uuid, uuid)') IS NULL
     OR to_regprocedure('public.queue_pickup_game_change_push_notification(uuid)') IS NULL
     OR to_regprocedure('public.is_fan_team_game_create_push_format(text)') IS NULL
     OR to_regprocedure('public.is_fan_team_announcement_create_push_format(text)') IS NULL
     OR to_regclass('public.pickup_game_update_events') IS NULL
     OR to_regclass('public.fan_team_member_change_events') IS NULL
     OR to_regclass('public.fan_team_member_change_push_deliveries') IS NULL
     OR to_regclass('public.fan_team_invitations') IS NULL
  THEN
    RAISE EXCEPTION
      '20260982_0001 prerequisites missing — apply 20260954/58/61/74/75/76 (+ invitations) first';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 1) All Team Schedule formats that enqueue a create APNs (except announcement)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_fan_team_schedule_create_push_format(p_game_format text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  SELECT lower(btrim(coalesce(p_game_format, ''))) IN (
    'league_game',
    'tournament_game',
    'match',
    'scrimmage',
    'practice',
    'tryout',
    'clinic',
    'team_meeting',
    'other',
    'pickup'
  );
$$;

REVOKE ALL ON FUNCTION public.is_fan_team_schedule_create_push_format(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_fan_team_schedule_create_push_format(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_fan_team_schedule_create_push_format(text) TO service_role;

COMMENT ON FUNCTION public.is_fan_team_schedule_create_push_format(text) IS
  'True for Team Schedule formats that enqueue create APNs '
  '(games + practice/tryout/clinic/meeting/other/pickup). Announcement excluded.';

-- ---------------------------------------------------------------------------
-- 2) queue_team_event_created_push_notification — games + practices + announcements
-- ---------------------------------------------------------------------------
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
  v_notification_type text;
  v_is_announcement boolean := false;
  v_is_competitive boolean := false;
  v_body_preview text;
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
  v_is_announcement := public.is_fan_team_announcement_create_push_format(v_format);
  v_is_competitive := public.is_fan_team_game_create_push_format(v_format);

  IF NOT v_is_announcement
     AND NOT public.is_fan_team_schedule_create_push_format(v_format) THEN
    RAISE LOG
      '[TeamScheduleNotification] createPushSkippedNonEligible team_id=% event_id=% eventType=%',
      p_team_id, p_pickup_game_id, v_format;
    RETURN NULL;
  END IF;

  SELECT nullif(btrim(coalesce(t.name, '')), '')
  INTO v_team_name
  FROM public.fan_teams t
  WHERE t.id = p_team_id
    AND t.is_active = true;

  IF v_team_name IS NULL THEN
    RAISE LOG
      '[TeamScheduleNotification] createPushSkippedInactiveTeam team_id=% event_id=%',
      p_team_id, p_pickup_game_id;
    RETURN NULL;
  END IF;

  IF v_is_announcement THEN
    v_notification_type := 'team_announcement';
    v_fingerprint := md5(
      p_pickup_game_id::text || '|team_announcement|' || p_team_id::text
    );
    v_body_preview := left(
      nullif(btrim(coalesce(v_game.description, '')), ''),
      160
    );
    v_payload := jsonb_build_object(
      'title', v_game.title,
      'notification_type', v_notification_type,
      'team_id', p_team_id,
      'team_name', v_team_name,
      'game_format', v_game.game_format,
      'after_start', v_game.game_start_at,
      'after_location', public.pickup_location_label(v_game.address, v_game.city, v_game.state),
      'description_preview', v_body_preview,
      'after_status', v_game.status,
      'before_status', v_game.status,
      'rsvp_reset_required', false,
      'is_team_announcement', true,
      'is_team_event_created', true,
      'editor_user_id', p_editor_user_id
    );

    RAISE LOG
      '[TeamAnnouncement] publishStart team_id=% announcement_id=% author_id=%',
      p_team_id, p_pickup_game_id, p_editor_user_id;
  ELSIF v_is_competitive THEN
    v_notification_type := 'team_game_created';
    v_opponent := nullif(btrim(coalesce(v_game.opponent_name, '')), '');
    IF v_opponent IS NOT NULL THEN
      v_matchup := v_team_name || ' vs ' || v_opponent;
    ELSE
      v_matchup := NULL;
    END IF;
    v_fingerprint := md5(
      p_pickup_game_id::text || '|team_game_created|' || p_team_id::text
    );
    v_payload := jsonb_build_object(
      'title', v_game.title,
      'notification_type', v_notification_type,
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
      'is_team_event_created', true,
      'editor_user_id', p_editor_user_id
    );
  ELSE
    -- practice / tryout / clinic / team_meeting / other / pickup
    v_notification_type := 'team_event_created';
    v_fingerprint := md5(
      p_pickup_game_id::text || '|team_event_created|' || p_team_id::text
    );
    v_payload := jsonb_build_object(
      'title', v_game.title,
      'notification_type', v_notification_type,
      'team_id', p_team_id,
      'team_name', v_team_name,
      'game_format', v_game.game_format,
      'after_start', v_game.game_start_at,
      'after_location', public.pickup_location_label(v_game.address, v_game.city, v_game.state),
      'after_opponent', nullif(btrim(coalesce(v_game.opponent_name, '')), ''),
      'after_status', v_game.status,
      'before_status', v_game.status,
      'rsvp_reset_required', false,
      'is_team_event_created', true,
      'editor_user_id', p_editor_user_id
    );
  END IF;

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
        '[TeamScheduleNotification] createFanoutIdempotentReuse update_event_id=% team_id=% pickup=% type=%',
        v_existing.id, p_team_id, p_pickup_game_id, v_notification_type;
      PERFORM public.queue_pickup_game_change_push_notification(v_existing.id);
    ELSE
      RAISE LOG
        '[TeamScheduleNotification] createFanoutSkippedAlreadySent update_event_id=% team_id=% pickup=% type=% status=%',
        v_existing.id, p_team_id, p_pickup_game_id, v_notification_type, v_existing.push_delivery_status;
    END IF;
    RETURN v_existing.id;
  END IF;

  RAISE LOG
    '[TeamScheduleNotification] createFanoutStart update_event_id=% team_id=% pickup=% type=% editor=%',
    v_event_id, p_team_id, p_pickup_game_id, v_notification_type, p_editor_user_id;

  PERFORM public.queue_pickup_game_change_push_notification(v_event_id);
  RETURN v_event_id;
END;
$$;

REVOKE ALL ON FUNCTION public.queue_team_event_created_push_notification(uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.queue_team_event_created_push_notification(uuid, uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.queue_team_event_created_push_notification(uuid, uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.queue_team_event_created_push_notification(uuid, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.queue_team_event_created_push_notification(uuid, uuid, uuid) IS
  'Enqueues create APNs for Team Schedule: team_game_created (competitive), '
  'team_event_created (practice/tryout/clinic/meeting/other/pickup), '
  'team_announcement. Idempotent via pickup_game_update_events fingerprint.';

-- ---------------------------------------------------------------------------
-- 3) Operator diagnostics — recent Team-related push events (service_role)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.fan_team_push_delivery_diagnostics AS
SELECT
  'pickup_game_change'::text AS pipeline,
  e.id AS event_id,
  e.pickup_game_id AS entity_id,
  (e.payload ->> 'team_id')::uuid AS team_id,
  e.editor_user_id AS actor_user_id,
  coalesce(e.payload ->> 'notification_type', e.change_kinds[1]) AS notification_type,
  e.change_kinds,
  e.fingerprint AS dedupe_key,
  e.push_delivery_status,
  e.push_sent_at,
  e.push_attempt_count,
  e.push_last_error,
  e.created_at AS event_created_at,
  e.payload
FROM public.pickup_game_update_events e
WHERE (e.payload ? 'team_id')
   OR (e.payload ->> 'is_team_event_created') = 'true'
   OR (e.payload ->> 'is_team_game_created') = 'true'
   OR (e.payload ->> 'is_team_announcement') = 'true'
UNION ALL
SELECT
  'fan_team_member_change'::text AS pipeline,
  m.id AS event_id,
  m.target_user_id AS entity_id,
  m.team_id,
  m.actor_user_id,
  m.kind AS notification_type,
  ARRAY[m.kind]::text[] AS change_kinds,
  m.id::text AS dedupe_key,
  d.delivery_status AS push_delivery_status,
  d.updated_at AS push_sent_at,
  NULL::integer AS push_attempt_count,
  d.failure_reason AS push_last_error,
  m.created_at AS event_created_at,
  m.payload
FROM public.fan_team_member_change_events m
LEFT JOIN LATERAL (
  SELECT d0.delivery_status, d0.updated_at, d0.skip_reason AS failure_reason
  FROM public.fan_team_member_change_push_deliveries d0
  WHERE d0.event_id = m.id
  ORDER BY d0.created_at DESC
  LIMIT 1
) d ON true
UNION ALL
SELECT
  'fan_team_invitation'::text AS pipeline,
  i.id AS event_id,
  i.id AS entity_id,
  i.team_id,
  i.inviter_user_id AS actor_user_id,
  'team_invitation'::text AS notification_type,
  ARRAY['invitation']::text[] AS change_kinds,
  i.id::text AS dedupe_key,
  NULL::text AS push_delivery_status,
  NULL::timestamptz AS push_sent_at,
  NULL::integer AS push_attempt_count,
  NULL::text AS push_last_error,
  i.created_at AS event_created_at,
  jsonb_build_object(
    'invitee_user_id', i.invitee_user_id,
    'status', i.status
  ) AS payload
FROM public.fan_team_invitations i;

REVOKE ALL ON public.fan_team_push_delivery_diagnostics FROM PUBLIC;
REVOKE ALL ON public.fan_team_push_delivery_diagnostics FROM anon;
REVOKE ALL ON public.fan_team_push_delivery_diagnostics FROM authenticated;
GRANT SELECT ON public.fan_team_push_delivery_diagnostics TO service_role;

COMMENT ON VIEW public.fan_team_push_delivery_diagnostics IS
  'Operator view: Team push pipelines (schedule change/create, member-change, invitations). '
  'Inspect push_delivery_status / push_last_error after a failed APNs test. service_role only.';

-- ---------------------------------------------------------------------------
-- Self-check helpers (SQL comments for operators)
-- ---------------------------------------------------------------------------
-- SELECT * FROM public.fan_team_push_delivery_diagnostics
--  WHERE event_created_at > now() - interval '1 hour'
--  ORDER BY event_created_at DESC LIMIT 50;
--
-- SELECT * FROM public.pickup_game_update_events
--  WHERE payload->>'notification_type' IN
--    ('team_game_created','team_event_created','team_announcement')
--  ORDER BY created_at DESC LIMIT 20;
--
-- SELECT * FROM public.fan_team_member_change_events
--  WHERE kind IN ('removed_from_team','team_role_changed')
--  ORDER BY created_at DESC LIMIT 20;
--
-- SELECT user_id, left(token,8)||'…', environment, is_active, last_seen_at
--   FROM public.user_push_tokens
--  WHERE user_id = '<recipient_uuid>' AND is_active = true;
