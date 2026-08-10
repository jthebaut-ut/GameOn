-- =============================================================================
-- 20260941_0001 — fan_teams.competition_level (Team default; games still use
--                  pickup_games.competition_level with optional per-game override)
-- =============================================================================
-- Reuses the exact PickupCompetitionLevel token set. Does NOT modify historical
-- pickup_games rows. Existing Teams remain NULL (Not specified).
--
-- Do NOT apply from the agent. Apply after 20260930 (list_my_fan_teams) and
-- preferably after 20260940 (pickup competition_level tokens documented).
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Column on fan_teams (nullable, same tokens as pickup_games)
-- ---------------------------------------------------------------------------
ALTER TABLE public.fan_teams
  ADD COLUMN IF NOT EXISTS competition_level text;

ALTER TABLE public.fan_teams
  DROP CONSTRAINT IF EXISTS fan_teams_competition_level_check;

ALTER TABLE public.fan_teams
  ADD CONSTRAINT fan_teams_competition_level_check
  CHECK (
    competition_level IS NULL
    OR lower(btrim(competition_level)) IN (
      'youth',
      'high_school',
      'college_university',
      'adult_recreational',
      'adult_competitive',
      'semi_pro',
      'professional'
    )
  );

COMMENT ON COLUMN public.fan_teams.competition_level IS
  'Optional Team default competition level (same tokens as pickup_games.competition_level). '
  'Null = Not specified. New Team games may inherit; per-game override stays on pickup_games.';

-- ---------------------------------------------------------------------------
-- 2) Normalize helper (shared validation)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_team_normalize_competition_level(p_raw text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v text := lower(btrim(coalesce(p_raw, '')));
BEGIN
  IF v = '' THEN
    RETURN NULL;
  END IF;
  IF v IN (
    'youth',
    'high_school',
    'college_university',
    'adult_recreational',
    'adult_competitive',
    'semi_pro',
    'professional'
  ) THEN
    RETURN v;
  END IF;
  RAISE EXCEPTION 'Invalid competition level.';
END;
$$;

REVOKE ALL ON FUNCTION public.fan_team_normalize_competition_level(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fan_team_normalize_competition_level(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_normalize_competition_level(text) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) create_fan_team — optional p_competition_level (DEFAULT NULL)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.create_fan_team(text, text, uuid[], text, text, text);

CREATE FUNCTION public.create_fan_team(
  p_name text,
  p_sport text DEFAULT '',
  p_member_ids uuid[] DEFAULT ARRAY[]::uuid[],
  p_color_hex text DEFAULT NULL,
  p_logo_url text DEFAULT NULL,
  p_logo_thumbnail_url text DEFAULT NULL,
  p_competition_level text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_name text := btrim(coalesce(p_name, ''));
  v_sport text := btrim(coalesce(p_sport, ''));
  v_ids uuid[];
  v_unique uuid[] := ARRAY[]::uuid[];
  v_uid uuid;
  v_conversation_id uuid;
  v_team_id uuid;
  v_payload jsonb;
  v_color text := nullif(btrim(coalesce(p_color_hex, '')), '');
  v_level text := public.fan_team_normalize_competition_level(p_competition_level);
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  PERFORM public.assert_rpc_rate_limit('create_fan_team', 20, 3600);

  IF char_length(v_name) < 1 OR char_length(v_name) > 60 THEN
    RAISE EXCEPTION 'Team name must be between 1 and 60 characters.';
  END IF;

  IF char_length(v_sport) > 40 THEN
    RAISE EXCEPTION 'Sport label is too long.';
  END IF;

  IF v_color IS NOT NULL AND v_color !~* '^#?[0-9A-Fa-f]{6}$' THEN
    RAISE EXCEPTION 'Invalid team color.';
  END IF;
  IF v_color IS NOT NULL AND left(v_color, 1) <> '#' THEN
    v_color := '#' || v_color;
  END IF;

  v_ids := coalesce(p_member_ids, ARRAY[]::uuid[]);
  FOREACH v_uid IN ARRAY v_ids LOOP
    IF v_uid IS NULL OR v_uid = me THEN
      CONTINUE;
    END IF;
    IF NOT (v_uid = ANY (v_unique)) THEN
      v_unique := array_append(v_unique, v_uid);
    END IF;
  END LOOP;

  IF 1 + coalesce(array_length(v_unique, 1), 0) > 50 THEN
    RAISE EXCEPTION 'A team may have at most 50 members.';
  END IF;

  FOREACH v_uid IN ARRAY v_unique LOOP
    IF NOT public.group_add_member_eligible(me, v_uid) THEN
      RAISE EXCEPTION 'One or more invitees are not eligible.';
    END IF;
  END LOOP;

  INSERT INTO public.group_conversations (title, created_by)
  VALUES (v_name, me)
  RETURNING id INTO v_conversation_id;

  INSERT INTO public.group_conversation_members (
    conversation_id, user_id, role, joined_at, last_read_at
  ) VALUES (
    v_conversation_id, me, 'admin', now(), now()
  );

  v_payload := jsonb_build_object(
    'event', 'group_created',
    'actor_user_id', me,
    'fan_team', true
  );

  INSERT INTO public.group_messages (
    conversation_id, sender_id, body, message_type, system_event, system_payload
  ) VALUES (
    v_conversation_id, me, 'Team created', 'system', 'group_created', v_payload
  );

  UPDATE public.group_conversations
  SET
    last_message_at = now(),
    last_message_preview = 'Team created',
    last_message_sender_id = me,
    last_message_type = 'system',
    last_system_event = 'group_created',
    last_system_payload = v_payload,
    updated_at = now()
  WHERE id = v_conversation_id;

  IF nullif(btrim(coalesce(p_logo_url, '')), '') IS NOT NULL
     OR nullif(btrim(coalesce(p_logo_thumbnail_url, '')), '') IS NOT NULL THEN
    RAISE NOTICE 'create_fan_team ignored logo URL args; use update_fan_team_identity after upload';
  END IF;

  INSERT INTO public.fan_teams (
    name,
    sport,
    logo_url,
    logo_thumbnail_url,
    color_hex,
    competition_level,
    owner_user_id,
    group_conversation_id
  ) VALUES (
    v_name,
    v_sport,
    NULL,
    NULL,
    v_color,
    v_level,
    me,
    v_conversation_id
  )
  RETURNING id INTO v_team_id;

  INSERT INTO public.fan_team_members (team_id, user_id, role)
  VALUES (v_team_id, me, 'owner');

  FOREACH v_uid IN ARRAY v_unique LOOP
    PERFORM public.fan_team_insert_pending_invitation(v_team_id, me, v_uid, true);
  END LOOP;

  RETURN v_team_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_fan_team(text, text, uuid[], text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_fan_team(text, text, uuid[], text, text, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.create_fan_team(text, text, uuid[], text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_fan_team(text, text, uuid[], text, text, text, text) TO service_role;

COMMENT ON FUNCTION public.create_fan_team(text, text, uuid[], text, text, text, text) IS
  'Create Fan Team + linked chat. Optional p_competition_level uses pickup tokens (nullable). '
  'p_member_ids receive PENDING invitations. Logo URLs ignored at create.';

-- ---------------------------------------------------------------------------
-- 4) update_fan_team_identity — opt-in competition_level update
-- ---------------------------------------------------------------------------
-- p_update_competition_level DEFAULT false preserves older clients that omit
-- the new args (would otherwise wipe competition_level to NULL).
DROP FUNCTION IF EXISTS public.update_fan_team_identity(uuid, text, text, text, text, text);

CREATE FUNCTION public.update_fan_team_identity(
  p_team_id uuid,
  p_name text,
  p_sport text DEFAULT '',
  p_color_hex text DEFAULT NULL,
  p_logo_url text DEFAULT NULL,
  p_logo_thumbnail_url text DEFAULT NULL,
  p_competition_level text DEFAULT NULL,
  p_update_competition_level boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_name text := btrim(coalesce(p_name, ''));
  v_sport text := btrim(coalesce(p_sport, ''));
  v_color text := nullif(btrim(coalesce(p_color_hex, '')), '');
  v_logo text := nullif(btrim(coalesce(p_logo_url, '')), '');
  v_logo_thumb text := nullif(btrim(coalesce(p_logo_thumbnail_url, '')), '');
  v_level text := NULL;
  v_conversation_id uuid;
  v_prev_name text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF p_team_id IS NULL THEN
    RAISE EXCEPTION 'Team is required.';
  END IF;

  IF NOT public.fan_team_viewer_can_manage(p_team_id) THEN
    RAISE EXCEPTION 'Only the team owner or a manager can edit team identity.';
  END IF;

  IF char_length(v_name) < 1 OR char_length(v_name) > 60 THEN
    RAISE EXCEPTION 'Team name must be between 1 and 60 characters.';
  END IF;

  IF char_length(v_sport) > 40 THEN
    RAISE EXCEPTION 'Sport label is too long.';
  END IF;

  IF v_color IS NOT NULL AND v_color !~* '^#?[0-9A-Fa-f]{6}$' THEN
    RAISE EXCEPTION 'Invalid team color.';
  END IF;
  IF v_color IS NOT NULL AND left(v_color, 1) <> '#' THEN
    v_color := '#' || upper(v_color);
  ELSIF v_color IS NOT NULL THEN
    v_color := '#' || upper(substr(v_color, 2));
  END IF;

  IF v_logo IS NULL THEN
    v_logo_thumb := NULL;
  END IF;

  IF v_logo IS NOT NULL
     AND NOT public.gameon_is_fan_team_logo_public_url(p_team_id, v_logo) THEN
    RAISE EXCEPTION 'Invalid team logo URL.';
  END IF;

  IF v_logo_thumb IS NOT NULL
     AND NOT public.gameon_is_fan_team_logo_public_url(p_team_id, v_logo_thumb) THEN
    RAISE EXCEPTION 'Invalid team logo thumbnail URL.';
  END IF;

  IF coalesce(p_update_competition_level, false) THEN
    v_level := public.fan_team_normalize_competition_level(p_competition_level);
  END IF;

  SELECT t.group_conversation_id, t.name
  INTO v_conversation_id, v_prev_name
  FROM public.fan_teams t
  WHERE t.id = p_team_id
    AND t.is_active = true;

  IF v_conversation_id IS NULL THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  UPDATE public.fan_teams
  SET
    name = v_name,
    sport = v_sport,
    color_hex = v_color,
    logo_url = v_logo,
    logo_thumbnail_url = v_logo_thumb,
    competition_level = CASE
      WHEN coalesce(p_update_competition_level, false) THEN v_level
      ELSE competition_level
    END,
    updated_at = now()
  WHERE id = p_team_id
    AND is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  IF v_prev_name IS DISTINCT FROM v_name THEN
    UPDATE public.group_conversations
    SET
      title = v_name,
      updated_at = now()
    WHERE id = v_conversation_id;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.update_fan_team_identity(uuid, text, text, text, text, text, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_fan_team_identity(uuid, text, text, text, text, text, text, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_fan_team_identity(uuid, text, text, text, text, text, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_fan_team_identity(uuid, text, text, text, text, text, text, boolean) TO service_role;

COMMENT ON FUNCTION public.update_fan_team_identity(uuid, text, text, text, text, text, text, boolean) IS
  'Owner/Manager: update Team identity. competition_level updates only when '
  'p_update_competition_level=true (preserves older clients).';

-- ---------------------------------------------------------------------------
-- 5) list_my_fan_teams — include competition_level
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.list_my_fan_teams();

CREATE FUNCTION public.list_my_fan_teams()
RETURNS TABLE (
  team_id uuid,
  name text,
  sport text,
  logo_url text,
  logo_thumbnail_url text,
  color_hex text,
  competition_level text,
  owner_user_id uuid,
  group_conversation_id uuid,
  my_role text,
  member_count integer,
  pending_invitation_count integer,
  next_game_starts_at timestamptz,
  next_game_title text,
  next_game_venue text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  RETURN QUERY
  SELECT
    t.id,
    t.name,
    t.sport,
    t.logo_url,
    t.logo_thumbnail_url,
    t.color_hex,
    t.competition_level,
    t.owner_user_id,
    t.group_conversation_id,
    m.role,
    (
      SELECT count(*)::integer
      FROM public.fan_team_members am
      WHERE am.team_id = t.id
        AND am.left_at IS NULL
    ) AS member_count,
    CASE
      WHEN public.fan_team_role_is_manager_or_owner(m.role) THEN (
        SELECT count(*)::integer
        FROM public.fan_team_invitations i
        WHERE i.team_id = t.id
          AND i.status = 'pending'
          AND (i.expires_at IS NULL OR i.expires_at > now())
      )
      ELSE 0
    END AS pending_invitation_count,
    ng.game_start_at,
    coalesce(nullif(btrim(ng.title), ''), ng.game_format),
    coalesce(nullif(btrim(ng.address), ''), nullif(btrim(ng.city), '')),
    t.created_at
  FROM public.fan_teams t
  JOIN public.fan_team_members m
    ON m.team_id = t.id
   AND m.user_id = me
   AND m.left_at IS NULL
  LEFT JOIN LATERAL (
    SELECT
      pg.game_start_at,
      pg.title,
      pg.game_format,
      pg.address,
      pg.city
    FROM public.fan_team_game_links l
    JOIN public.pickup_games pg ON pg.id = l.pickup_game_id
    WHERE l.team_id = t.id
      AND pg.status = 'active'
      AND pg.archived_at IS NULL
      AND pg.game_start_at >= now() - interval '2 hours'
    ORDER BY pg.game_start_at ASC
    LIMIT 1
  ) ng ON true
  WHERE t.is_active = true
  ORDER BY t.name ASC;
END;
$$;

COMMENT ON FUNCTION public.list_my_fan_teams() IS
  'Lists active Fan Teams for auth.uid(). Includes competition_level (nullable Team default). '
  'pending_invitation_count is manager/owner-only.';

REVOKE ALL ON FUNCTION public.list_my_fan_teams() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_my_fan_teams() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_my_fan_teams() TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_my_fan_teams() TO service_role;

COMMIT;
