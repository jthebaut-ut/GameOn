-- =============================================================================
-- 20260976_0001 — Team Schedule type: announcement
-- =============================================================================
-- Extends pickup_games.game_format with 'announcement' (solo Team link).
-- Create/edit/link for announcements requires Owner/Manager (can_manage),
-- not Head Coach organize-only.
-- Create APNs: notification_type = team_announcement via existing
-- pickup_game_update_events → notify-pickup-game-change pipeline.
-- list_fan_team_games: adds description; access via fan_team_viewer_can_access_team.
-- UNAPPLIED — deploy manually with Edge notify-pickup-game-change.
-- =============================================================================

DO $$
BEGIN
  IF to_regclass('public.pickup_games') IS NULL
     OR to_regprocedure('public.link_pickup_game_to_fan_team(uuid, uuid)') IS NULL
     OR to_regprocedure('public.queue_team_event_created_push_notification(uuid, uuid, uuid)') IS NULL
     OR to_regprocedure('public.fan_team_viewer_can_manage(uuid)') IS NULL
  THEN
    RAISE EXCEPTION '20260976_0001 prerequisites missing';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 1) game_format allowlist
-- ---------------------------------------------------------------------------
ALTER TABLE public.pickup_games
  DROP CONSTRAINT IF EXISTS pickup_games_game_format_check;

ALTER TABLE public.pickup_games
  ADD CONSTRAINT pickup_games_game_format_check
  CHECK (
    lower(btrim(game_format)) IN (
      'pickup',
      'practice',
      'scrimmage',
      'match',
      'league_game',
      'tournament_game',
      'tryout',
      'clinic',
      'team_meeting',
      'other',
      'announcement'
    )
  );

COMMENT ON COLUMN public.pickup_games.game_format IS
  'Event format: pickup|practice|scrimmage|match|league_game|tournament_game|tryout|clinic|'
  'team_meeting|other|announcement.';

-- ---------------------------------------------------------------------------
-- 2) Create-push format helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_fan_team_announcement_create_push_format(p_game_format text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  SELECT lower(btrim(coalesce(p_game_format, ''))) = 'announcement';
$$;

REVOKE ALL ON FUNCTION public.is_fan_team_announcement_create_push_format(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_fan_team_announcement_create_push_format(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_fan_team_announcement_create_push_format(text) TO service_role;

COMMENT ON FUNCTION public.is_fan_team_announcement_create_push_format(text) IS
  'True when game_format is announcement (team_announcement APNs).';

-- ---------------------------------------------------------------------------
-- 3) queue_team_event_created_push_notification — games + announcements
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

  IF NOT v_is_announcement
     AND NOT public.is_fan_team_game_create_push_format(v_format) THEN
    RAISE LOG
      '[TeamAnnouncement] createPushSkippedNonEligible team_id=% event_id=% eventType=%',
      p_team_id, p_pickup_game_id, v_format;
    RETURN NULL;
  END IF;

  SELECT nullif(btrim(coalesce(t.name, '')), '')
  INTO v_team_name
  FROM public.fan_teams t
  WHERE t.id = p_team_id
    AND t.is_active = true;

  IF v_team_name IS NULL THEN
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
      'is_team_event_created', true
    );

    RAISE LOG
      '[TeamAnnouncement] publishStart team_id=% announcement_id=% author_id=%',
      p_team_id, p_pickup_game_id, p_editor_user_id;
  ELSE
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
      'is_team_event_created', true
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
      IF v_is_announcement THEN
        RAISE LOG
          '[TeamAnnouncement] notificationFanoutStart idempotent_reuse update_event_id=% team_id=% announcement_id=%',
          v_existing.id, p_team_id, p_pickup_game_id;
      END IF;
      PERFORM public.queue_pickup_game_change_push_notification(v_existing.id);
    END IF;
    RETURN v_existing.id;
  END IF;

  IF v_is_announcement THEN
    RAISE LOG
      '[TeamAnnouncement] persistSuccess announcement_id=% team_id=% notificationFanoutStart update_event_id=%',
      p_pickup_game_id, p_team_id, v_event_id;
  END IF;

  PERFORM public.queue_pickup_game_change_push_notification(v_event_id);
  RETURN v_event_id;
END;
$$;

REVOKE ALL ON FUNCTION public.queue_team_event_created_push_notification(uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.queue_team_event_created_push_notification(uuid, uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.queue_team_event_created_push_notification(uuid, uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.queue_team_event_created_push_notification(uuid, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.queue_team_event_created_push_notification(uuid, uuid, uuid) IS
  'Enqueues create APNs for competitive Team games (team_game_created) or '
  'announcements (team_announcement). Other formats are no-ops.';

-- ---------------------------------------------------------------------------
-- 4) link_pickup_game_to_fan_team — announcement + manage gate
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
  v_is_announcement boolean := false;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_team_id IS NULL OR p_pickup_game_id IS NULL THEN
    RAISE EXCEPTION 'Team and pickup game are required.';
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

  v_is_announcement := (v_format = 'announcement');

  -- Announcements: Owner/Manager only. Other Team events: organize (Owner/Manager/Head Coach).
  IF v_is_announcement THEN
    IF NOT public.fan_team_viewer_can_manage(p_team_id) THEN
      RAISE LOG
        '[TeamAnnouncement] permissionResult=denied team_id=% author_id=%',
        p_team_id, me;
      RAISE EXCEPTION 'Only the owner or a manager can publish Team announcements.';
    END IF;
    RAISE LOG
      '[TeamAnnouncement] permissionResult=allowed team_id=% author_id=%',
      p_team_id, me;
  ELSE
    IF NOT public.fan_team_viewer_can_organize(p_team_id) THEN
      RAISE EXCEPTION 'Only the owner, a manager, or head coach can schedule Team events.';
    END IF;
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
    'other',
    'announcement'
  ) THEN
    RAISE EXCEPTION 'Unsupported Team event format.';
  END IF;

  IF v_is_announcement THEN
    IF nullif(btrim(coalesce(v_title, '')), '') IS NULL THEN
      RAISE EXCEPTION 'Announcement title is required.';
    END IF;
    IF nullif(btrim(coalesce(
      (SELECT g.description FROM public.pickup_games g WHERE g.id = p_pickup_game_id),
      ''
    )), '') IS NULL THEN
      RAISE EXCEPTION 'Announcement message is required.';
    END IF;
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
    WHEN v_format IN ('practice', 'team_meeting', 'other', 'announcement') THEN 'solo'
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

  SELECT t.group_conversation_id INTO v_team_chat
  FROM public.fan_teams t
  WHERE t.id = p_team_id;

  IF v_team_chat IS NOT NULL THEN
    IF v_is_announcement THEN
      v_body := 'Announcement: ' || coalesce(v_title, 'Team announcement');
    ELSE
      v_body := 'Event scheduled: ' || coalesce(v_title, 'Team event');
    END IF;
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
        'is_team_event_created', true,
        'is_team_announcement', v_is_announcement
      )
    );
  END IF;

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
  'Links creator-owned active pickup_games to a Fan Team. Announcements require '
  'Owner/Manager (can_manage). Other formats require organize (Owner/Manager/Head Coach). '
  'announcement/practice/team_meeting/other → solo; fixtures → home.';

-- ---------------------------------------------------------------------------
-- 5) list_fan_team_games — description + access for members/guardians
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
  description text
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
      WHEN pg.status = 'expired' THEN 'completed'
      WHEN pg.archived_at IS NOT NULL THEN 'completed'
      ELSE 'scheduled'
    END AS status,
    NULL::integer AS home_score,
    NULL::integer AS away_score,
    pg.id AS pickup_game_id,
    l.side AS my_side,
    pg.created_at,
    pg.competition_level,
    nullif(btrim(coalesce(pg.description, '')), '') AS description
  FROM public.fan_team_game_links l
  JOIN public.pickup_games pg ON pg.id = l.pickup_game_id
  WHERE l.team_id = p_team_id
  ORDER BY pg.game_start_at DESC
  LIMIT 100;
END;
$$;

REVOKE ALL ON FUNCTION public.list_fan_team_games(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_fan_team_games(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_fan_team_games(uuid) TO service_role;

COMMENT ON FUNCTION public.list_fan_team_games(uuid) IS
  'Team Schedule list. Includes description for announcements. Access: fan_team_viewer_can_access_team.';

-- ---------------------------------------------------------------------------
-- 6) UPDATE gate — Team-linked announcements require Owner/Manager
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_fan_team_announcement_manage_on_pickup_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_team_id uuid;
  v_was_announcement boolean;
  v_is_announcement boolean;
BEGIN
  v_was_announcement := lower(btrim(coalesce(OLD.game_format, ''))) = 'announcement';
  v_is_announcement := lower(btrim(coalesce(NEW.game_format, ''))) = 'announcement';

  IF NOT v_was_announcement AND NOT v_is_announcement THEN
    RETURN NEW;
  END IF;

  SELECT l.team_id INTO v_team_id
  FROM public.fan_team_game_links l
  WHERE l.pickup_game_id = NEW.id
  ORDER BY CASE WHEN l.side = 'solo' THEN 0 ELSE 1 END
  LIMIT 1;

  IF v_team_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF NOT public.fan_team_viewer_can_manage(v_team_id) THEN
    RAISE LOG
      '[TeamAnnouncement] permissionResult=denied_update team_id=% announcement_id=% author_id=%',
      v_team_id, NEW.id, auth.uid();
    RAISE EXCEPTION 'Only the owner or a manager can edit or remove Team announcements.';
  END IF;

  IF v_is_announcement THEN
    IF nullif(btrim(coalesce(NEW.title, '')), '') IS NULL THEN
      RAISE EXCEPTION 'Announcement title is required.';
    END IF;
    IF nullif(btrim(coalesce(NEW.description, '')), '') IS NULL THEN
      RAISE EXCEPTION 'Announcement message is required.';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_fan_team_announcement_manage_on_pickup_update
  ON public.pickup_games;
CREATE TRIGGER trg_fan_team_announcement_manage_on_pickup_update
  BEFORE UPDATE ON public.pickup_games
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_fan_team_announcement_manage_on_pickup_update();

REVOKE ALL ON FUNCTION public.enforce_fan_team_announcement_manage_on_pickup_update() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.enforce_fan_team_announcement_manage_on_pickup_update() TO authenticated;
GRANT EXECUTE ON FUNCTION public.enforce_fan_team_announcement_manage_on_pickup_update() TO service_role;

COMMENT ON FUNCTION public.enforce_fan_team_announcement_manage_on_pickup_update() IS
  'Team-linked announcement create/edit/remove requires fan_team_viewer_can_manage (Owner/Manager).';
