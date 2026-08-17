-- =============================================================================
-- 20260974_0001 — Team Schedule: create push + schedule-time RSVP invalidation
-- =============================================================================
-- Reuses pickup_game_update_events → queue_pickup_game_change_push_notification
-- → notify-pickup-game-change (no parallel push stack).
--
-- Gaps closed:
--   1) Team event create (link_pickup_game_to_fan_team) never enqueued APNs.
--   2) Date/time edits never invalidated authoritative RSVPs (Needs Response).
--   3) opponent_name changes were not meaningful for push detection.
--
-- RSVP rules:
--   • start/end change on Team-linked event → delete account + managed RSVPs
--   • location-only → notify, keep RSVP
--   • Recipients remain membership/guardian based (20260954/61); not RSVP-filtered
--
-- UNAPPLIED — deploy manually when ready.
-- =============================================================================

DO $$
BEGIN
  IF to_regclass('public.pickup_games') IS NULL
     OR to_regclass('public.pickup_game_update_events') IS NULL
     OR to_regclass('public.fan_team_game_links') IS NULL
     OR to_regprocedure('public.pickup_meaningful_change_kinds(public.pickup_games, public.pickup_games)') IS NULL
     OR to_regprocedure('public.queue_pickup_game_change_push_notification(uuid)') IS NULL
     OR to_regprocedure('public.link_pickup_game_to_fan_team(uuid, uuid)') IS NULL
     OR to_regprocedure('public.notify_pickup_game_updated_from_rows(public.pickup_games, public.pickup_games, uuid)') IS NULL
  THEN
    RAISE EXCEPTION
      '20260974_0001 prerequisites missing (pickup_games / update events / Team link / notify helpers)';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 1) Meaningful change kinds — include opponent_name
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pickup_meaningful_change_kinds(
  p_old public.pickup_games,
  p_new public.pickup_games
)
RETURNS text[]
LANGUAGE plpgsql
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_kinds text[] := ARRAY[]::text[];
BEGIN
  IF public.pickup_norm_text(p_old.title) IS DISTINCT FROM public.pickup_norm_text(p_new.title) THEN
    v_kinds := v_kinds || ARRAY['title'];
  END IF;
  IF public.pickup_norm_text(p_old.sport) IS DISTINCT FROM public.pickup_norm_text(p_new.sport)
     OR public.pickup_norm_text(p_old.game_format) IS DISTINCT FROM public.pickup_norm_text(p_new.game_format) THEN
    v_kinds := v_kinds || ARRAY['sport'];
  END IF;
  IF p_old.game_start_at IS DISTINCT FROM p_new.game_start_at THEN
    v_kinds := v_kinds || ARRAY['start'];
  END IF;
  IF p_old.end_time IS DISTINCT FROM p_new.end_time THEN
    v_kinds := v_kinds || ARRAY['end'];
  END IF;
  IF public.pickup_location_identity(
       p_old.address, p_old.city, p_old.state, p_old.latitude, p_old.longitude
     ) IS DISTINCT FROM public.pickup_location_identity(
       p_new.address, p_new.city, p_new.state, p_new.latitude, p_new.longitude
     ) THEN
    v_kinds := v_kinds || ARRAY['location'];
  END IF;
  IF public.pickup_norm_text(p_old.opponent_name)
       IS DISTINCT FROM public.pickup_norm_text(p_new.opponent_name) THEN
    v_kinds := v_kinds || ARRAY['opponent'];
  END IF;
  IF p_old.players_needed IS DISTINCT FROM p_new.players_needed
     OR p_old.max_players IS DISTINCT FROM p_new.max_players THEN
    v_kinds := v_kinds || ARRAY['capacity'];
  END IF;
  IF public.pickup_norm_text(p_old.participant_preference)
       IS DISTINCT FROM public.pickup_norm_text(p_new.participant_preference)
     OR p_old.age_min IS DISTINCT FROM p_new.age_min
     OR p_old.age_max IS DISTINCT FROM p_new.age_max THEN
    v_kinds := v_kinds || ARRAY['welcome'];
  END IF;
  IF public.pickup_norm_text(p_old.skill_level) IS DISTINCT FROM public.pickup_norm_text(p_new.skill_level) THEN
    v_kinds := v_kinds || ARRAY['skill'];
  END IF;
  IF public.pickup_norm_text(p_old.play_environment)
       IS DISTINCT FROM public.pickup_norm_text(p_new.play_environment) THEN
    v_kinds := v_kinds || ARRAY['environment'];
  END IF;
  IF p_old.is_free IS DISTINCT FROM p_new.is_free
     OR coalesce(p_old.entry_fee_amount, 0) IS DISTINCT FROM coalesce(p_new.entry_fee_amount, 0) THEN
    v_kinds := v_kinds || ARRAY['cost'];
  END IF;
  IF public.pickup_norm_text(p_old.status) IS DISTINCT FROM public.pickup_norm_text(p_new.status) THEN
    v_kinds := v_kinds || ARRAY['status'];
  END IF;
  IF p_old.is_visible IS DISTINCT FROM p_new.is_visible THEN
    v_kinds := v_kinds || ARRAY['visibility'];
  END IF;
  RETURN v_kinds;
END;
$$;

COMMENT ON FUNCTION public.pickup_meaningful_change_kinds(public.pickup_games, public.pickup_games) IS
  'Member-facing pickup/Team event field diffs for chat + APNs. Includes opponent_name. '
  'Ignores updated_at / approved_join_count / other bookkeeping.';

-- ---------------------------------------------------------------------------
-- 2) Authoritative RSVP invalidation (Team-linked schedule time change)
-- ---------------------------------------------------------------------------
-- Unanswered = no row (account: pickup_game_requests; managed: fan_team_event_rsvps).
CREATE OR REPLACE FUNCTION public.invalidate_team_linked_pickup_rsvps_on_schedule_change(
  p_pickup_game_id uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_is_linked boolean := false;
  v_account_deleted integer := 0;
  v_managed_deleted integer := 0;
BEGIN
  IF p_pickup_game_id IS NULL THEN
    RETURN 0;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.fan_team_game_links l
    WHERE l.pickup_game_id = p_pickup_game_id
  ) INTO v_is_linked;

  IF NOT v_is_linked THEN
    RETURN 0;
  END IF;

  WITH deleted AS (
    DELETE FROM public.pickup_game_requests r
    WHERE r.pickup_game_id = p_pickup_game_id
    RETURNING 1
  )
  SELECT count(*)::integer INTO v_account_deleted FROM deleted;

  IF to_regclass('public.fan_team_event_rsvps') IS NOT NULL THEN
    WITH deleted AS (
      DELETE FROM public.fan_team_event_rsvps e
      WHERE e.pickup_game_id = p_pickup_game_id
      RETURNING 1
    )
    SELECT count(*)::integer INTO v_managed_deleted FROM deleted;
  END IF;

  RAISE LOG
    '[TeamScheduleNotification] rsvpRecordsInvalidated pickup_game_id=% account=% managed=%',
    p_pickup_game_id, v_account_deleted, v_managed_deleted;

  RETURN coalesce(v_account_deleted, 0) + coalesce(v_managed_deleted, 0);
END;
$$;

REVOKE ALL ON FUNCTION public.invalidate_team_linked_pickup_rsvps_on_schedule_change(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.invalidate_team_linked_pickup_rsvps_on_schedule_change(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.invalidate_team_linked_pickup_rsvps_on_schedule_change(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.invalidate_team_linked_pickup_rsvps_on_schedule_change(uuid) TO service_role;

COMMENT ON FUNCTION public.invalidate_team_linked_pickup_rsvps_on_schedule_change(uuid) IS
  'Team-linked only: clears account (pickup_game_requests) + managed (fan_team_event_rsvps) '
  'RSVPs so UI shows Needs Response / unanswered. Call only when start/end changed.';

-- ---------------------------------------------------------------------------
-- 3) Create-time Team schedule push (same update_events + Edge pipeline)
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

  v_fingerprint := md5(
    p_pickup_game_id::text || '|created|' ||
    coalesce(v_game.created_at::text, '') || '|' ||
    p_team_id::text
  );

  v_payload := jsonb_build_object(
    'title', v_game.title,
    'notification_type', 'team_event_created',
    'team_id', p_team_id,
    'game_format', v_game.game_format,
    'after_start', v_game.game_start_at,
    'after_location', public.pickup_location_label(v_game.address, v_game.city, v_game.state),
    'after_opponent', nullif(btrim(coalesce(v_game.opponent_name, '')), ''),
    'after_status', v_game.status,
    'before_status', v_game.status,
    'rsvp_reset_required', false,
    'is_team_event_created', true
  );

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
      PERFORM public.queue_pickup_game_change_push_notification(v_existing.id);
    END IF;

    RAISE LOG
      '[TeamScheduleNotification] eventCreate idempotent_reuse event_id=% team_id=% pickup=%',
      v_existing.id, p_team_id, p_pickup_game_id;
    RETURN v_existing.id;
  END IF;

  RAISE LOG
    '[TeamScheduleNotification] eventCreate team_id=% event_id=% pickup=% creator_id=% notificationType=team_event_created',
    p_team_id, v_event_id, p_pickup_game_id, p_editor_user_id;

  PERFORM public.queue_pickup_game_change_push_notification(v_event_id);
  RETURN v_event_id;
END;
$$;

REVOKE ALL ON FUNCTION public.queue_team_event_created_push_notification(uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.queue_team_event_created_push_notification(uuid, uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.queue_team_event_created_push_notification(uuid, uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.queue_team_event_created_push_notification(uuid, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.queue_team_event_created_push_notification(uuid, uuid, uuid) IS
  'Enqueues one idempotent Team Schedule create push via pickup_game_update_events '
  '(change_kinds=created). Callable from SECURITY DEFINER owners / service_role.';

-- ---------------------------------------------------------------------------
-- 4) link_pickup_game_to_fan_team — also queue create APNs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.link_pickup_game_to_fan_team(
  p_team_id uuid,
  p_pickup_game_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := auth.uid();
  v_creator uuid;
  v_format text;
  v_status text;
  v_side text;
  v_existing_side text;
  v_team_chat uuid;
  v_title text;
  v_body text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_team_id IS NULL OR p_pickup_game_id IS NULL THEN
    RAISE EXCEPTION 'Team and pickup game are required.';
  END IF;
  IF NOT public.fan_team_viewer_can_organize(p_team_id) THEN
    RAISE EXCEPTION 'Only the owner, a manager, or head coach can schedule Team events.';
  END IF;

  SELECT
    g.creator_user_id,
    lower(btrim(coalesce(g.game_format, ''))),
    lower(btrim(coalesce(g.status, ''))),
    left(
      nullif(
        btrim(
          coalesce(
            nullif(btrim(coalesce(g.title, '')), ''),
            nullif(btrim(coalesce(g.game_format, '')), ''),
            'Team event'
          )
        ),
        ''
      ),
      80
    )
  INTO v_creator, v_format, v_status, v_title
  FROM public.pickup_games g
  WHERE g.id = p_pickup_game_id;

  IF v_creator IS NULL THEN
    RAISE EXCEPTION 'Pickup game not found.';
  END IF;
  IF v_creator <> me THEN
    RAISE EXCEPTION 'Only the creator can link this pickup game to a Team.';
  END IF;
  IF v_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'Only active pickup games can be linked to a Team.';
  END IF;

  IF v_format NOT IN (
    'practice',
    'scrimmage',
    'match',
    'league_game',
    'tournament_game',
    'tryout',
    'clinic',
    'team_meeting',
    'other'
  ) THEN
    RAISE EXCEPTION 'Team events must use practice, scrimmage, league_game, tournament_game, tryout, clinic, match, team_meeting, or other.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.fan_teams t
    WHERE t.id = p_team_id AND t.is_active = true
  ) THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.fan_team_game_links l
    WHERE l.pickup_game_id = p_pickup_game_id
      AND l.team_id = p_team_id
  ) THEN
    RETURN p_pickup_game_id;
  END IF;

  v_side := CASE
    WHEN v_format IN ('practice', 'team_meeting', 'other') THEN 'solo'
    ELSE 'home'
  END;

  IF v_side = 'solo' THEN
    IF EXISTS (
      SELECT 1
      FROM public.fan_team_game_links l
      WHERE l.pickup_game_id = p_pickup_game_id
    ) THEN
      RAISE EXCEPTION 'This pickup game is already linked to a Team.';
    END IF;
  ELSE
    SELECT l.side INTO v_existing_side
    FROM public.fan_team_game_links l
    WHERE l.pickup_game_id = p_pickup_game_id
      AND l.side IN ('home', 'solo')
    LIMIT 1;

    IF v_existing_side IS NOT NULL THEN
      RAISE EXCEPTION 'This pickup game already has a % Team link.', v_existing_side;
    END IF;
  END IF;

  INSERT INTO public.fan_team_game_links (pickup_game_id, team_id, side)
  VALUES (p_pickup_game_id, p_team_id, v_side);

  -- Team Chat only — do NOT create a per-event pickup conversation.
  SELECT t.group_conversation_id INTO v_team_chat
  FROM public.fan_teams t
  WHERE t.id = p_team_id;

  IF v_team_chat IS NOT NULL THEN
    v_body := 'Event scheduled: ' || coalesce(v_title, 'Team event');
    PERFORM public.post_fan_team_chat_system_message(
      v_team_chat,
      me,
      v_body,
      'pickup_game_updated',
      jsonb_build_object(
        'event', 'pickup_game_updated',
        'pickup_game_id', p_pickup_game_id,
        'team_id', p_team_id,
        'summary_lines', jsonb_build_array(v_body),
        'title', coalesce(v_title, 'Team event'),
        'is_team_event_created', true
      )
    );
  END IF;

  -- Remote APNs for all eligible Team users (RSVP-independent recipients).
  PERFORM public.queue_team_event_created_push_notification(
    p_pickup_game_id,
    p_team_id,
    me
  );

  RETURN p_pickup_game_id;
END;
$$;

REVOKE ALL ON FUNCTION public.link_pickup_game_to_fan_team(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.link_pickup_game_to_fan_team(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.link_pickup_game_to_fan_team(uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.link_pickup_game_to_fan_team(uuid, uuid) IS
  'Links a creator-owned active pickup_games row to a Fan Team (owner/manager/head coach). '
  'Posts Team Chat notice and enqueues Team Schedule create APNs via pickup_game_update_events. '
  'Formats: practice|scrimmage|match|league_game|tournament_game|tryout|clinic|team_meeting|other. '
  'Preserves is_visible. practice/team_meeting/other→solo; fixtures→home.';

-- ---------------------------------------------------------------------------
-- 5) notify_pickup_game_updated_from_rows — RSVP reset + richer payload
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notify_pickup_game_updated_from_rows(
  p_old public.pickup_games,
  p_new public.pickup_games,
  p_editor uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_kinds text[];
  v_fingerprint text;
  v_event_id uuid;
  v_existing public.pickup_game_update_events%ROWTYPE;
  v_conversation_id uuid;
  v_message_id uuid;
  v_is_cancel boolean;
  v_body text := 'Pickup game updated';
  v_payload jsonb;
  v_technical_sender uuid;
  v_team_id uuid;
  v_schedule_time_changed boolean := false;
  v_location_changed boolean := false;
  v_rsvp_reset_required boolean := false;
  v_rsvp_invalidated integer := 0;
  v_notification_type text := 'team_event_updated';
BEGIN
  IF pg_trigger_depth() IS NULL OR pg_trigger_depth() < 1 THEN
    RAISE EXCEPTION 'notify_pickup_game_updated_from_rows is trigger-only'
      USING ERRCODE = '42501';
  END IF;

  IF p_new.id IS NULL OR p_old.id IS DISTINCT FROM p_new.id THEN
    RETURN NULL;
  END IF;

  v_kinds := public.pickup_meaningful_change_kinds(p_old, p_new);
  IF coalesce(array_length(v_kinds, 1), 0) = 0 THEN
    RETURN NULL;
  END IF;

  v_technical_sender := coalesce(p_editor, p_new.creator_user_id);

  SELECT l.team_id INTO v_team_id
  FROM public.fan_team_game_links l
  INNER JOIN public.fan_teams t
    ON t.id = l.team_id
   AND t.is_active = true
  WHERE l.pickup_game_id = p_new.id
  ORDER BY CASE l.side WHEN 'home' THEN 0 WHEN 'solo' THEN 1 ELSE 2 END, l.created_at ASC NULLS LAST
  LIMIT 1;

  v_schedule_time_changed := ('start' = ANY (v_kinds)) OR ('end' = ANY (v_kinds));
  v_location_changed := ('location' = ANY (v_kinds));
  v_rsvp_reset_required := (v_team_id IS NOT NULL) AND v_schedule_time_changed;

  IF v_rsvp_reset_required THEN
    v_rsvp_invalidated := public.invalidate_team_linked_pickup_rsvps_on_schedule_change(p_new.id);
  END IF;

  IF v_team_id IS NOT NULL THEN
    IF v_schedule_time_changed AND v_location_changed THEN
      v_notification_type := 'team_event_updated';
    ELSIF v_schedule_time_changed THEN
      v_notification_type := 'team_event_time_changed';
    ELSIF v_location_changed THEN
      v_notification_type := 'team_event_location_changed';
    ELSE
      v_notification_type := 'team_event_updated';
    END IF;
  ELSE
    v_notification_type := 'pickup_game_updated';
  END IF;

  RAISE LOG
    '[TeamScheduleNotification] eventUpdateStart team_id=% event_id_pending pickup=% creator_id=% '
    'changedFields=% dateChanged=% timeChanged=% locationChanged=% rsvpResetRequired=% rsvpRecordsInvalidated=% notificationType=%',
    v_team_id,
    p_new.id,
    p_editor,
    array_to_string(v_kinds, ','),
    ('start' = ANY (v_kinds)),
    v_schedule_time_changed,
    v_location_changed,
    v_rsvp_reset_required,
    v_rsvp_invalidated,
    v_notification_type;

  v_fingerprint := md5(
    p_new.id::text || '|' ||
    array_to_string(v_kinds, ',') || '|' ||
    coalesce(p_new.updated_at::text, '') || '|' ||
    public.pickup_location_identity(
      p_new.address, p_new.city, p_new.state, p_new.latitude, p_new.longitude
    ) || '|' ||
    coalesce(p_new.game_start_at::text, '') || '|' ||
    coalesce(p_new.end_time::text, '') || '|' ||
    coalesce(p_new.status, '') || '|' ||
    coalesce(p_new.players_needed::text, '') || '|' ||
    coalesce(p_new.max_players::text, '') || '|' ||
    public.pickup_norm_text(p_new.title) || '|' ||
    public.pickup_norm_text(p_new.sport) || '|' ||
    public.pickup_norm_text(p_new.skill_level) || '|' ||
    public.pickup_norm_text(p_new.play_environment) || '|' ||
    public.pickup_norm_text(p_new.participant_preference) || '|' ||
    public.pickup_norm_text(p_new.opponent_name) || '|' ||
    coalesce(p_new.is_free::text, '') || '|' ||
    coalesce(p_new.entry_fee_amount::text, '') || '|' ||
    coalesce(p_new.is_visible::text, '')
  );

  INSERT INTO public.pickup_game_update_events AS e (
    pickup_game_id, editor_user_id, fingerprint, change_kinds, payload, push_delivery_status
  )
  VALUES (
    p_new.id,
    p_editor,
    v_fingerprint,
    v_kinds,
    jsonb_build_object(
      'title', p_new.title,
      'notification_type', v_notification_type,
      'team_id', to_jsonb(v_team_id),
      'game_format', p_new.game_format,
      'before_start', p_old.game_start_at,
      'after_start', p_new.game_start_at,
      'before_end', p_old.end_time,
      'after_end', p_new.end_time,
      'before_location', public.pickup_location_label(p_old.address, p_old.city, p_old.state),
      'after_location', public.pickup_location_label(p_new.address, p_new.city, p_new.state),
      'before_opponent', nullif(btrim(coalesce(p_old.opponent_name, '')), ''),
      'after_opponent', nullif(btrim(coalesce(p_new.opponent_name, '')), ''),
      'before_players_needed', p_old.players_needed,
      'after_players_needed', p_new.players_needed,
      'before_status', p_old.status,
      'after_status', p_new.status,
      'rsvp_reset_required', v_rsvp_reset_required,
      'rsvp_records_invalidated', v_rsvp_invalidated
    ),
    'pending'
  )
  ON CONFLICT (pickup_game_id, fingerprint) DO NOTHING
  RETURNING id INTO v_event_id;

  IF v_event_id IS NULL THEN
    SELECT * INTO v_existing
    FROM public.pickup_game_update_events
    WHERE pickup_game_id = p_new.id AND fingerprint = v_fingerprint;

    IF v_existing.id IS NULL THEN
      RETURN NULL;
    END IF;

    IF v_existing.push_sent_at IS NULL
       AND v_existing.push_delivery_status IN ('pending', 'queued', 'retryable', 'failed') THEN
      PERFORM public.queue_pickup_game_change_push_notification(v_existing.id);
    END IF;
    RETURN v_existing.id;
  END IF;

  v_is_cancel := lower(coalesce(p_old.status, '')) <> 'removed'
             AND lower(coalesce(p_new.status, '')) = 'removed';

  v_body := 'Pickup game updated';

  v_payload := jsonb_build_object(
    'event', 'pickup_game_updated',
    'pickup_game_id', p_new.id,
    'update_event_id', v_event_id,
    'change_kinds', to_jsonb(v_kinds),
    'summary_lines', jsonb_build_array(v_body),
    'actor_user_id', to_jsonb(p_editor),
    'editor_is_system', (p_editor IS NULL),
    'notification_type', v_notification_type,
    'team_id', to_jsonb(v_team_id),
    'game_format', p_new.game_format,
    'before_start', p_old.game_start_at,
    'after_start', p_new.game_start_at,
    'before_end', p_old.end_time,
    'after_end', p_new.end_time,
    'before_location', public.pickup_location_label(p_old.address, p_old.city, p_old.state),
    'after_location', public.pickup_location_label(p_new.address, p_new.city, p_new.state),
    'before_opponent', nullif(btrim(coalesce(p_old.opponent_name, '')), ''),
    'after_opponent', nullif(btrim(coalesce(p_new.opponent_name, '')), ''),
    'before_players_needed', p_old.players_needed,
    'after_players_needed', p_new.players_needed,
    'before_status', p_old.status,
    'after_status', p_new.status,
    'title', p_new.title,
    'is_cancellation', v_is_cancel,
    'rsvp_reset_required', v_rsvp_reset_required,
    'rsvp_records_invalidated', v_rsvp_invalidated
  );

  -- Prefer Team Chat for Team-linked events; else legacy pickup chat.
  v_conversation_id := public.fan_team_chat_conversation_id_for_pickup_game(p_new.id);
  IF v_conversation_id IS NULL THEN
    SELECT c.id INTO v_conversation_id
    FROM public.group_conversations c
    WHERE c.pickup_game_id = p_new.id
    LIMIT 1;
  END IF;

  IF v_conversation_id IS NOT NULL AND v_technical_sender IS NOT NULL THEN
    v_message_id := public.post_fan_team_chat_system_message(
      v_conversation_id,
      v_technical_sender,
      v_body,
      'pickup_game_updated',
      v_payload
    );

    UPDATE public.pickup_game_update_events
    SET chat_message_id = v_message_id,
        payload = payload || jsonb_build_object('chat_message_id', v_message_id) || v_payload
    WHERE id = v_event_id;
  ELSE
    UPDATE public.pickup_game_update_events
    SET payload = payload || v_payload
    WHERE id = v_event_id;
  END IF;

  RAISE LOG
    '[TeamScheduleNotification] fanoutStart update_event_id=% notificationType=% team_id=%',
    v_event_id, v_notification_type, v_team_id;

  PERFORM public.queue_pickup_game_change_push_notification(v_event_id);
  RETURN v_event_id;
END;
$$;

COMMENT ON FUNCTION public.notify_pickup_game_updated_from_rows(public.pickup_games, public.pickup_games, uuid) IS
  'Trigger-only: meaningful pickup/Team edits → update_events + Team/pickup chat + APNs queue. '
  'Team-linked start/end changes invalidate RSVPs in the same transaction before fan-out.';
