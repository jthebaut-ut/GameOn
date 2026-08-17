-- =============================================================================
-- 20260964_0001 — Team event chat consolidation
-- =============================================================================
-- OBJECTIVE:
--   A Fan Team has exactly ONE persistent Team Chat (`fan_teams.group_conversation_id`).
--   Team-linked events must NOT create/open a separate pickup-game group conversation.
--   Standalone pickups keep ensure_pickup_game_group_conversation behavior.
--
-- CHANGES:
--   1) Helper to resolve Team Chat for a linked pickup game (backend-only)
--   2) Helper to post system notices into Team Chat (backend-only)
--   3) link_pickup_game_to_fan_team — stop ensure_pickup_game_group_conversation;
--      post "event scheduled" into Team Chat instead
--   4) sync_pickup_game_group_membership — never CREATE a new pickup chat when
--      the game is Team-linked (legacy pickup chats still sync if they exist)
--   5) ensure_pickup_game_group_conversation — clear error for Team-linked games
--      with no legacy pickup chat
--   6) notify_pickup_game_updated_from_rows — post edit/cancel notices to Team Chat
--      when Team-linked (falls back to legacy pickup chat if present)
--   7) get_group_inbox_summaries — hide Team-linked pickup chats so inbox shows
--      one Team Chat per Team (no data deletion; CREATE OR REPLACE, no DROP)
--   8) publish_fan_team_event_lineup — preserve user_id XOR managed_player_id;
--      post idempotent "Lineup published" into Team Chat
--
-- Do NOT apply from the agent; review and apply deliberately in Supabase.
-- No schema changes. No destructive data migration.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Resolve Team Chat conversation for a Team-linked pickup game
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_team_chat_conversation_id_for_pickup_game(
  p_pickup_game_id uuid
)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT t.group_conversation_id
  FROM public.fan_team_game_links l
  INNER JOIN public.fan_teams t
    ON t.id = l.team_id
   AND t.is_active = true
  WHERE l.pickup_game_id = p_pickup_game_id
  ORDER BY
    CASE l.side
      WHEN 'solo' THEN 0
      WHEN 'home' THEN 1
      ELSE 2
    END,
    l.created_at ASC NULLS LAST
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.fan_team_chat_conversation_id_for_pickup_game(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fan_team_chat_conversation_id_for_pickup_game(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.fan_team_chat_conversation_id_for_pickup_game(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_chat_conversation_id_for_pickup_game(uuid) TO service_role;

COMMENT ON FUNCTION public.fan_team_chat_conversation_id_for_pickup_game(uuid) IS
  'Backend-only: returns fan_teams.group_conversation_id for a Team-linked pickup game '
  '(prefer solo/home). Not granted to authenticated clients.';

-- ---------------------------------------------------------------------------
-- 2) Post a system message into an existing Team Chat
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.post_fan_team_chat_system_message(
  p_conversation_id uuid,
  p_sender_id uuid,
  p_body text,
  p_system_event text,
  p_payload jsonb DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_message_id uuid;
  v_body text := left(btrim(coalesce(p_body, '')), 500);
BEGIN
  IF p_conversation_id IS NULL OR p_sender_id IS NULL THEN
    RETURN NULL;
  END IF;
  IF v_body = '' THEN
    v_body := 'Team update';
  END IF;

  INSERT INTO public.group_messages (
    conversation_id, sender_id, body, message_type, system_event, system_payload
  )
  VALUES (
    p_conversation_id,
    p_sender_id,
    v_body,
    'system',
    nullif(btrim(coalesce(p_system_event, '')), ''),
    p_payload
  )
  RETURNING id INTO v_message_id;

  UPDATE public.group_conversations
  SET
    last_message_at = now(),
    last_message_preview = left(v_body, 180),
    last_message_sender_id = p_sender_id,
    last_message_type = 'system',
    last_system_event = nullif(btrim(coalesce(p_system_event, '')), ''),
    last_system_payload = p_payload,
    updated_at = now()
  WHERE id = p_conversation_id;

  RETURN v_message_id;
END;
$$;

REVOKE ALL ON FUNCTION public.post_fan_team_chat_system_message(uuid, uuid, text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.post_fan_team_chat_system_message(uuid, uuid, text, text, jsonb) FROM anon;
REVOKE ALL ON FUNCTION public.post_fan_team_chat_system_message(uuid, uuid, text, text, jsonb) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.post_fan_team_chat_system_message(uuid, uuid, text, text, jsonb) TO service_role;

COMMENT ON FUNCTION public.post_fan_team_chat_system_message(uuid, uuid, text, text, jsonb) IS
  'Backend-only helper: inserts a system notice into an existing Team Chat and updates '
  'conversation preview. Callable from SECURITY DEFINER owners / service_role only.';

-- ---------------------------------------------------------------------------
-- 3) link_pickup_game_to_fan_team — no pickup chat; notice Team Chat
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.link_pickup_game_to_fan_team(
  p_team_id uuid,
  p_pickup_game_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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

  RETURN p_pickup_game_id;
END;
$$;

REVOKE ALL ON FUNCTION public.link_pickup_game_to_fan_team(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.link_pickup_game_to_fan_team(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.link_pickup_game_to_fan_team(uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.link_pickup_game_to_fan_team(uuid, uuid) IS
  'Links a creator-owned active pickup_games row to a Fan Team (owner/manager/head coach). '
  'Does NOT create a pickup group chat — posts into the Team Chat instead. '
  'Formats: practice|scrimmage|match|league_game|tournament_game|tryout|clinic|team_meeting|other. '
  'Preserves is_visible. practice/team_meeting/other→solo; fixtures→home.';

-- ---------------------------------------------------------------------------
-- 4) sync_pickup_game_group_membership — no new chat for Team-linked games
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_pickup_game_group_membership(
  p_pickup_game_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_conversation_id uuid;
  v_creator uuid;
  v_game_status text;
  v_archived_at timestamptz;
  v_remove_after_at timestamptz;
  v_chat_live boolean;
  v_title text;
  v_uid uuid;
  v_authorized uuid[] := ARRAY[]::uuid[];
  v_is_team_linked boolean := false;
BEGIN
  SELECT
    g.creator_user_id,
    lower(btrim(g.status)),
    g.archived_at,
    g.remove_after_at,
    left(
      nullif(
        btrim(
          coalesce(
            nullif(btrim(coalesce(g.title, '')), ''),
            nullif(btrim(coalesce(g.sport, '')), '') || ' pickup',
            'Pickup game'
          )
        ),
        ''
      ),
      60
    )
  INTO v_creator, v_game_status, v_archived_at, v_remove_after_at, v_title
  FROM public.pickup_games g
  WHERE g.id = p_pickup_game_id;

  IF v_creator IS NULL THEN
    RAISE EXCEPTION 'Pickup game not found.';
  END IF;

  v_is_team_linked := EXISTS (
    SELECT 1
    FROM public.fan_team_game_links l
    WHERE l.pickup_game_id = p_pickup_game_id
  );

  v_chat_live := (
    v_game_status = 'active'
    AND v_archived_at IS NULL
    AND (v_remove_after_at IS NULL OR v_remove_after_at > now())
  );

  SELECT c.id INTO v_conversation_id
  FROM public.group_conversations c
  WHERE c.pickup_game_id = p_pickup_game_id
  LIMIT 1;

  -- Team events: never create a new pickup-linked conversation.
  IF v_conversation_id IS NULL AND v_is_team_linked THEN
    RETURN NULL;
  END IF;

  IF v_conversation_id IS NULL AND NOT v_chat_live THEN
    RETURN NULL;
  END IF;

  IF v_conversation_id IS NULL THEN
    BEGIN
      INSERT INTO public.group_conversations (
        title,
        created_by,
        pickup_game_id,
        is_active
      ) VALUES (
        coalesce(v_title, 'Pickup game'),
        v_creator,
        p_pickup_game_id,
        true
      )
      RETURNING id INTO v_conversation_id;

      INSERT INTO public.group_conversation_members (
        conversation_id, user_id, role, joined_at, last_read_at
      ) VALUES (
        v_conversation_id, v_creator, 'admin', now(), now()
      );

      INSERT INTO public.group_messages (
        conversation_id, sender_id, body, message_type, system_event
      ) VALUES (
        v_conversation_id,
        v_creator,
        'Pickup game chat created',
        'system',
        'group_created'
      );

      UPDATE public.group_conversations
      SET
        last_message_at = now(),
        last_message_preview = 'Pickup game chat created',
        last_message_sender_id = v_creator,
        last_message_type = 'system',
        updated_at = now()
      WHERE id = v_conversation_id;
    EXCEPTION
      WHEN unique_violation THEN
        SELECT c.id INTO v_conversation_id
        FROM public.group_conversations c
        WHERE c.pickup_game_id = p_pickup_game_id
        LIMIT 1;

        IF v_conversation_id IS NULL THEN
          RAISE;
        END IF;
    END;
  END IF;

  IF NOT v_chat_live THEN
    UPDATE public.group_conversation_members
    SET left_at = coalesce(left_at, now())
    WHERE conversation_id = v_conversation_id
      AND left_at IS NULL;

    UPDATE public.group_conversations
    SET is_active = false, updated_at = now()
    WHERE id = v_conversation_id;

    RETURN v_conversation_id;
  END IF;

  UPDATE public.group_conversations
  SET
    is_active = true,
    title = coalesce(v_title, title),
    updated_at = now()
  WHERE id = v_conversation_id;

  SELECT coalesce(array_agg(DISTINCT a.user_id), ARRAY[]::uuid[])
    INTO v_authorized
  FROM public.pickup_game_chat_authorized_user_ids(p_pickup_game_id) a
  WHERE public.pickup_game_chat_member_age_ok(a.user_id);

  UPDATE public.group_conversation_members m
  SET left_at = now()
  WHERE m.conversation_id = v_conversation_id
    AND m.left_at IS NULL
    AND NOT (m.user_id = ANY (v_authorized));

  FOREACH v_uid IN ARRAY v_authorized LOOP
    INSERT INTO public.group_conversation_members (
      conversation_id,
      user_id,
      role,
      joined_at,
      last_read_at
    ) VALUES (
      v_conversation_id,
      v_uid,
      CASE WHEN v_uid = v_creator THEN 'admin' ELSE 'member' END,
      now(),
      CASE WHEN v_uid = v_creator THEN now() ELSE NULL END
    )
    ON CONFLICT (conversation_id, user_id) DO UPDATE
      SET
        left_at = NULL,
        role = CASE
          WHEN public.group_conversation_members.user_id = v_creator THEN 'admin'
          ELSE 'member'
        END,
        joined_at = CASE
          WHEN public.group_conversation_members.left_at IS NOT NULL THEN now()
          ELSE public.group_conversation_members.joined_at
        END,
        muted_until = CASE
          WHEN public.group_conversation_members.left_at IS NOT NULL THEN NULL
          ELSE public.group_conversation_members.muted_until
        END,
        last_read_at = CASE
          WHEN public.group_conversation_members.left_at IS NOT NULL THEN NULL
          ELSE public.group_conversation_members.last_read_at
        END
    WHERE public.group_conversation_members.left_at IS NOT NULL
       OR public.group_conversation_members.role IS DISTINCT FROM
          (CASE WHEN EXCLUDED.user_id = v_creator THEN 'admin' ELSE 'member' END);
  END LOOP;

  RETURN v_conversation_id;
END;
$$;

COMMENT ON FUNCTION public.sync_pickup_game_group_membership(uuid) IS
  'Mirrors organizer + approved joiners into group_conversation_members. '
  'Does not create a new pickup chat when the game is Team-linked (Team Chat is authoritative).';

-- ---------------------------------------------------------------------------
-- 5) ensure_pickup_game_group_conversation — Team-linked guard
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ensure_pickup_game_group_conversation(
  p_pickup_game_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_conversation_id uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF p_pickup_game_id IS NULL THEN
    RAISE EXCEPTION 'Pickup game id required.';
  END IF;

  PERFORM public.assert_age_access_allows_social(me);

  IF NOT public.is_pickup_game_chat_authorized(p_pickup_game_id, me) THEN
    RAISE EXCEPTION 'Not authorized for this pickup game chat.'
      USING ERRCODE = '42501';
  END IF;

  v_conversation_id := public.sync_pickup_game_group_membership(p_pickup_game_id);

  IF v_conversation_id IS NULL THEN
    IF EXISTS (
      SELECT 1
      FROM public.fan_team_game_links l
      WHERE l.pickup_game_id = p_pickup_game_id
    ) THEN
      RAISE EXCEPTION 'Team events use Team Chat.'
        USING ERRCODE = 'P0001';
    END IF;
    RAISE EXCEPTION 'Pickup game chat is unavailable.';
  END IF;

  IF NOT public.is_active_group_member(v_conversation_id, me) THEN
    RAISE EXCEPTION 'Not authorized for this pickup game chat.'
      USING ERRCODE = '42501';
  END IF;

  RETURN v_conversation_id;
END;
$$;

COMMENT ON FUNCTION public.ensure_pickup_game_group_conversation(uuid) IS
  'Idempotent open/create of the private chat for a standalone pickup game. '
  'Team-linked events raise P0001 (use Team Chat) when no legacy pickup chat exists.';

-- ---------------------------------------------------------------------------
-- 6) notify_pickup_game_updated_from_rows — Team Chat for linked events
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notify_pickup_game_updated_from_rows(
  p_old public.pickup_games,
  p_new public.pickup_games,
  p_editor uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
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
      'before_start', p_old.game_start_at,
      'after_start', p_new.game_start_at,
      'before_location', public.pickup_location_label(p_old.address, p_old.city, p_old.state),
      'after_location', public.pickup_location_label(p_new.address, p_new.city, p_new.state),
      'before_players_needed', p_old.players_needed,
      'after_players_needed', p_new.players_needed,
      'before_status', p_old.status,
      'after_status', p_new.status
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
    'before_start', p_old.game_start_at,
    'after_start', p_new.game_start_at,
    'before_location', public.pickup_location_label(p_old.address, p_old.city, p_old.state),
    'after_location', public.pickup_location_label(p_new.address, p_new.city, p_new.state),
    'before_players_needed', p_old.players_needed,
    'after_players_needed', p_new.players_needed,
    'before_status', p_old.status,
    'after_status', p_new.status,
    'title', p_new.title,
    'is_cancellation', v_is_cancel
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

  PERFORM public.queue_pickup_game_change_push_notification(v_event_id);
  RETURN v_event_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 7) get_group_inbox_summaries — hide Team-linked pickup chats
-- ---------------------------------------------------------------------------
-- Signature unchanged since 20260893 (includes pickup_game_id). Prefer
-- CREATE OR REPLACE — no DROP required (avoids brief grant/dependency gaps).
CREATE OR REPLACE FUNCTION public.get_group_inbox_summaries()
RETURNS TABLE (
  conversation_id uuid,
  title text,
  member_count integer,
  last_message_body text,
  last_message_sender_id uuid,
  last_message_created_at timestamptz,
  last_message_type text,
  last_system_event text,
  last_system_payload jsonb,
  unread_count integer,
  is_muted boolean,
  pickup_game_id uuid
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH me AS (
    SELECT auth.uid() AS uid
  ),
  visible_last AS (
    SELECT DISTINCT ON (gm.conversation_id)
      gm.conversation_id,
      gm.body,
      gm.sender_id,
      gm.created_at,
      gm.message_type,
      gm.system_event,
      gm.system_payload
    FROM public.group_messages gm
    INNER JOIN me ON true
    INNER JOIN public.group_conversation_members m
      ON m.conversation_id = gm.conversation_id
     AND m.user_id = me.uid
     AND m.left_at IS NULL
    WHERE gm.deleted_at IS NULL
      AND COALESCE(gm.is_deleted, false) = false
      AND gm.created_at >= m.joined_at
      AND (m.left_at IS NULL OR gm.created_at <= m.left_at)
      AND public.group_viewer_can_see_sender_message(me.uid, gm.sender_id, gm.message_type)
    ORDER BY gm.conversation_id, gm.created_at DESC, gm.id DESC
  )
  SELECT
    c.id AS conversation_id,
    c.title,
    (
      SELECT count(*)::integer
      FROM public.group_conversation_members am
      WHERE am.conversation_id = c.id
        AND am.left_at IS NULL
    ) AS member_count,
    CASE
      WHEN vl.conversation_id IS NOT NULL THEN vl.body
      WHEN public.group_viewer_can_see_sender_message(me.uid, c.last_message_sender_id, c.last_message_type)
        THEN c.last_message_preview
      ELSE NULL
    END AS last_message_body,
    CASE
      WHEN vl.conversation_id IS NOT NULL THEN vl.sender_id
      WHEN public.group_viewer_can_see_sender_message(me.uid, c.last_message_sender_id, c.last_message_type)
        THEN c.last_message_sender_id
      ELSE NULL
    END AS last_message_sender_id,
    CASE
      WHEN vl.conversation_id IS NOT NULL THEN vl.created_at
      WHEN public.group_viewer_can_see_sender_message(me.uid, c.last_message_sender_id, c.last_message_type)
        THEN c.last_message_at
      ELSE NULL
    END AS last_message_created_at,
    CASE
      WHEN vl.conversation_id IS NOT NULL THEN vl.message_type
      WHEN public.group_viewer_can_see_sender_message(me.uid, c.last_message_sender_id, c.last_message_type)
        THEN coalesce(c.last_message_type, 'text')
      ELSE NULL
    END AS last_message_type,
    CASE
      WHEN vl.conversation_id IS NOT NULL THEN vl.system_event
      WHEN public.group_viewer_can_see_sender_message(me.uid, c.last_message_sender_id, c.last_message_type)
        THEN c.last_system_event
      ELSE NULL
    END AS last_system_event,
    CASE
      WHEN vl.conversation_id IS NOT NULL THEN vl.system_payload
      WHEN public.group_viewer_can_see_sender_message(me.uid, c.last_message_sender_id, c.last_message_type)
        THEN c.last_system_payload
      ELSE NULL
    END AS last_system_payload,
    (
      SELECT count(*)::integer
      FROM public.group_messages gm
      WHERE gm.conversation_id = c.id
        AND gm.deleted_at IS NULL
        AND COALESCE(gm.is_deleted, false) = false
        AND gm.message_type = 'text'
        AND gm.sender_id IS DISTINCT FROM me.uid
        AND gm.created_at > COALESCE(m.last_read_at, 'epoch'::timestamptz)
        AND gm.created_at >= m.joined_at
        AND (m.left_at IS NULL OR gm.created_at <= m.left_at)
        AND public.group_viewer_can_see_sender_message(me.uid, gm.sender_id, gm.message_type)
    ) AS unread_count,
    (m.muted_until IS NOT NULL AND m.muted_until > now()) AS is_muted,
    c.pickup_game_id
  FROM me
  INNER JOIN public.group_conversation_members m
    ON m.user_id = me.uid
   AND m.left_at IS NULL
  INNER JOIN public.group_conversations c
    ON c.id = m.conversation_id
   AND c.is_active = true
   -- Hide per-event pickup chats that belong to a Team (Team Chat is the single row).
   AND (
     c.pickup_game_id IS NULL
     OR NOT EXISTS (
       SELECT 1
       FROM public.fan_team_game_links l
       WHERE l.pickup_game_id = c.pickup_game_id
     )
   )
  LEFT JOIN visible_last vl ON vl.conversation_id = c.id
  ORDER BY coalesce(vl.created_at, c.last_message_at) DESC NULLS LAST, c.created_at DESC;
$$;

REVOKE ALL ON FUNCTION public.get_group_inbox_summaries() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_group_inbox_summaries() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_group_inbox_summaries() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_group_inbox_summaries() TO service_role;

-- ---------------------------------------------------------------------------
-- 8) publish_fan_team_event_lineup — preserve managed seats + Team Chat notice
-- ---------------------------------------------------------------------------
-- Authoritative member contract is post-20260961 save_fan_team_event_lineup:
-- each element carries user_id XOR managed_player_id (never user_id-only rebuild).
-- 20260952 publish rebuilt user_id-only and would DROP managed seats on publish.
CREATE OR REPLACE FUNCTION public.publish_fan_team_event_lineup(
  p_pickup_game_id uuid,
  p_team_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_lineup_id uuid;
  v_members jsonb;
  v_formation text;
  v_prior_status text;
  v_result uuid;
  v_team_chat uuid;
  v_title text;
  v_body text;
  v_fingerprint text;
  v_already_notified boolean := false;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  SELECT l.id, l.formation, l.status
  INTO v_lineup_id, v_formation, v_prior_status
  FROM public.fan_team_event_lineups l
  WHERE l.team_id = p_team_id
    AND l.pickup_game_id = p_pickup_game_id;

  IF v_lineup_id IS NULL THEN
    RAISE EXCEPTION 'No lineup to publish.';
  END IF;

  -- Preserve account XOR managed identity exactly as stored (20260961 contract).
  SELECT coalesce(
    jsonb_agg(
      jsonb_strip_nulls(
        jsonb_build_object(
          'user_id', m.user_id,
          'managed_player_id', m.managed_player_id,
          'lineup_status', m.lineup_status,
          'position_code', m.position_code,
          'sort_order', m.sort_order
        )
      )
      ORDER BY m.sort_order, coalesce(m.user_id, m.managed_player_id)
    ),
    '[]'::jsonb
  )
  INTO v_members
  FROM public.fan_team_event_lineup_members m
  WHERE m.lineup_id = v_lineup_id;

  v_fingerprint := md5(
    v_lineup_id::text || '|' ||
    coalesce(v_formation, '') || '|' ||
    coalesce(v_members::text, '[]')
  );

  -- save_… with status=published refreshes published_at / published_by to now()/me.
  v_result := public.save_fan_team_event_lineup(
    p_pickup_game_id,
    p_team_id,
    'published',
    v_formation,
    v_members
  );

  SELECT t.group_conversation_id INTO v_team_chat
  FROM public.fan_teams t
  WHERE t.id = p_team_id;

  IF v_team_chat IS NOT NULL THEN
    -- Idempotency: one notice per distinct published lineup fingerprint.
    -- Covers transaction retries and unchanged re-publish spam.
    SELECT EXISTS (
      SELECT 1
      FROM public.group_messages gm
      WHERE gm.conversation_id = v_team_chat
        AND gm.deleted_at IS NULL
        AND COALESCE(gm.is_deleted, false) = false
        AND gm.message_type = 'system'
        AND gm.system_payload->>'is_lineup_published' = 'true'
        AND gm.system_payload->>'pickup_game_id' = p_pickup_game_id::text
        AND gm.system_payload->>'team_id' = p_team_id::text
        AND gm.system_payload->>'lineup_fingerprint' = v_fingerprint
    )
    INTO v_already_notified;

    IF NOT coalesce(v_already_notified, false) THEN
      SELECT left(
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
      INTO v_title
      FROM public.pickup_games g
      WHERE g.id = p_pickup_game_id;

      v_body := 'Lineup published' ||
        CASE
          WHEN v_title IS NULL OR v_title = '' THEN ''
          ELSE ': ' || v_title
        END;

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
          'is_lineup_published', true,
          'lineup_id', v_result,
          'lineup_fingerprint', v_fingerprint,
          'prior_status', v_prior_status,
          'title', coalesce(v_title, 'Team event')
        )
      );
    END IF;
  END IF;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.publish_fan_team_event_lineup(uuid, uuid) IS
  'Publishes the current Team event lineup via save_fan_team_event_lineup, preserving '
  'user_id XOR managed_player_id seats. Posts one idempotent Team Chat notice per '
  'distinct lineup fingerprint.';

REVOKE ALL ON FUNCTION public.publish_fan_team_event_lineup(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.publish_fan_team_event_lineup(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.publish_fan_team_event_lineup(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.publish_fan_team_event_lineup(uuid, uuid) TO service_role;

COMMIT;
