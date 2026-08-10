-- =============================================================================
-- 20260926_0001 — Fan teams ("My Teams") foundation
-- =============================================================================
-- Persistent sports groups for FanGeo fans. NOT a new account type. NOT leagues.
-- Each team owns one private group_conversations row for Team Chat.
--
-- Team games reuse public.pickup_games as the authoritative event (venue, Going /
-- roster via pickup_game_requests, game chat, edit notifications, calendar hooks).
-- Association is via thin fan_team_game_links — NOT a parallel fan_team_games engine.
--
-- Do NOT apply from the agent; review and apply deliberately in Supabase.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Core team tables (approved)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.fan_teams (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  sport text NOT NULL DEFAULT '',
  logo_url text,
  logo_thumbnail_url text,
  color_hex text,
  owner_user_id uuid NOT NULL REFERENCES auth.users (id),
  group_conversation_id uuid NOT NULL UNIQUE
    REFERENCES public.group_conversations (id) ON DELETE RESTRICT,
  -- Reserved for future League support (NULL = independent team).
  league_id uuid,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fan_teams_name_len_ck
    CHECK (char_length(btrim(name)) BETWEEN 1 AND 60),
  CONSTRAINT fan_teams_sport_len_ck
    CHECK (char_length(btrim(sport)) <= 40),
  CONSTRAINT fan_teams_color_hex_ck
    CHECK (
      color_hex IS NULL
      OR color_hex ~* '^#?[0-9A-Fa-f]{6}$'
    )
);

COMMENT ON TABLE public.fan_teams IS
  'FanGeo My Teams — persistent sports groups. Distinct from user_favorite_teams (catalog clubs).';

COMMENT ON COLUMN public.fan_teams.league_id IS
  'Future League membership. Always NULL in v1; teams work independently.';

CREATE TABLE IF NOT EXISTS public.fan_team_members (
  team_id uuid NOT NULL REFERENCES public.fan_teams (id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users (id),
  role text NOT NULL DEFAULT 'member'
    CHECK (role IN ('owner', 'manager', 'captain', 'member')),
  joined_at timestamptz NOT NULL DEFAULT now(),
  left_at timestamptz,
  PRIMARY KEY (team_id, user_id),
  CONSTRAINT fan_team_members_left_after_join_ck
    CHECK (left_at IS NULL OR left_at >= joined_at)
);

COMMENT ON TABLE public.fan_team_members IS
  'Authoritative team roster. Chat access is mirrored into group_conversation_members.';

CREATE INDEX IF NOT EXISTS fan_team_members_active_user_idx
  ON public.fan_team_members (user_id)
  WHERE left_at IS NULL;

CREATE INDEX IF NOT EXISTS fan_team_members_active_team_idx
  ON public.fan_team_members (team_id)
  WHERE left_at IS NULL;

CREATE INDEX IF NOT EXISTS fan_teams_owner_idx
  ON public.fan_teams (owner_user_id)
  WHERE is_active = true;

-- ---------------------------------------------------------------------------
-- 2) Pickup game extensions for Team scheduling (additive only)
-- ---------------------------------------------------------------------------
-- Expand game_format CHECK to include 'match' while keeping existing values.
-- This replaces the CHECK constraint name/body but preserves all prior allowed
-- formats (pickup|practice|scrimmage) and only adds match.
ALTER TABLE public.pickup_games DROP CONSTRAINT IF EXISTS pickup_games_game_format_check;
ALTER TABLE public.pickup_games
  ADD CONSTRAINT pickup_games_game_format_check
  CHECK (game_format IN ('pickup', 'practice', 'scrimmage', 'match'));

COMMENT ON COLUMN public.pickup_games.game_format IS
  'Community/team game format: pickup | practice | scrimmage | match.';

-- Optional free-text opponent for custom (non-FanGeo-team) opponents.
-- Additive nullable column; no default rewrite of existing rows.
ALTER TABLE public.pickup_games
  ADD COLUMN IF NOT EXISTS opponent_name text;

COMMENT ON COLUMN public.pickup_games.opponent_name IS
  'Optional display opponent when not linked to another fan_teams row (custom opponent).';

-- Thin link: ONE pickup_games row can be associated with one or two fan teams.
CREATE TABLE IF NOT EXISTS public.fan_team_game_links (
  pickup_game_id uuid NOT NULL
    REFERENCES public.pickup_games (id) ON DELETE CASCADE,
  team_id uuid NOT NULL
    REFERENCES public.fan_teams (id) ON DELETE CASCADE,
  side text NOT NULL
    CHECK (side IN ('home', 'away', 'solo')),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (pickup_game_id, team_id)
);

COMMENT ON TABLE public.fan_team_game_links IS
  'Associates Fan Teams with an authoritative pickup_games event. Team A vs Team B = one pickup row + two link rows.';

-- At most one home / away / solo link per pickup game.
CREATE UNIQUE INDEX IF NOT EXISTS fan_team_game_links_one_home_per_game_uidx
  ON public.fan_team_game_links (pickup_game_id)
  WHERE side = 'home';

CREATE UNIQUE INDEX IF NOT EXISTS fan_team_game_links_one_away_per_game_uidx
  ON public.fan_team_game_links (pickup_game_id)
  WHERE side = 'away';

CREATE UNIQUE INDEX IF NOT EXISTS fan_team_game_links_one_solo_per_game_uidx
  ON public.fan_team_game_links (pickup_game_id)
  WHERE side = 'solo';

CREATE INDEX IF NOT EXISTS fan_team_game_links_team_idx
  ON public.fan_team_game_links (team_id);

-- Meaningful opponent shape is enforced in schedule_fan_team_game (not a tautology CHECK).

-- ---------------------------------------------------------------------------
-- 3) Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_active_fan_team_member(
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
  );
$$;

CREATE OR REPLACE FUNCTION public.fan_team_role_is_manager_or_owner(p_role text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT lower(coalesce(p_role, '')) IN ('owner', 'manager');
$$;

CREATE OR REPLACE FUNCTION public.fan_team_viewer_can_manage(p_team_id uuid)
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
      AND m.user_id = auth.uid()
      AND m.left_at IS NULL
      AND public.fan_team_role_is_manager_or_owner(m.role)
  );
$$;

CREATE OR REPLACE FUNCTION public.is_pickup_game_fan_team_participant(
  p_pickup_game_id uuid,
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
    FROM public.fan_team_game_links l
    JOIN public.fan_team_members m
      ON m.team_id = l.team_id
     AND m.user_id = p_user_id
     AND m.left_at IS NULL
    WHERE l.pickup_game_id = p_pickup_game_id
  );
$$;

-- ---------------------------------------------------------------------------
-- 4) RLS
-- ---------------------------------------------------------------------------
ALTER TABLE public.fan_teams ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fan_team_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fan_team_game_links ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS fan_teams_select_member ON public.fan_teams;
CREATE POLICY fan_teams_select_member ON public.fan_teams
  FOR SELECT TO authenticated
  USING (
    is_active = true
    AND public.is_active_fan_team_member(id, auth.uid())
  );

DROP POLICY IF EXISTS fan_team_members_select_same_team ON public.fan_team_members;
CREATE POLICY fan_team_members_select_same_team ON public.fan_team_members
  FOR SELECT TO authenticated
  USING (public.is_active_fan_team_member(team_id, auth.uid()));

DROP POLICY IF EXISTS fan_team_game_links_select_member ON public.fan_team_game_links;
CREATE POLICY fan_team_game_links_select_member ON public.fan_team_game_links
  FOR SELECT TO authenticated
  USING (public.is_active_fan_team_member(team_id, auth.uid()));

-- Additive Team access ONLY. Preserve live production SELECT semantics exactly:
--   creator
--   OR active+visible+(remove_after_at IS NULL OR remove_after_at > now())
--   OR can_read_pickup_game_for_requester(id)
--   OR is_pickup_game_fan_team_participant(id, auth.uid())   -- NEW
-- Do NOT tighten remove_after_at NULL handling. Do NOT drop requester visibility.
DROP POLICY IF EXISTS pickup_games_select_authenticated ON public.pickup_games;
CREATE POLICY pickup_games_select_authenticated
  ON public.pickup_games
  FOR SELECT
  TO authenticated
  USING (
    creator_user_id = auth.uid()
    OR (
      status = 'active'
      AND is_visible
      AND (
        remove_after_at IS NULL
        OR remove_after_at > now()
      )
    )
    OR public.can_read_pickup_game_for_requester(id)
    OR public.is_pickup_game_fan_team_participant(id, auth.uid())
  );

GRANT SELECT ON public.fan_teams TO authenticated;
GRANT SELECT ON public.fan_team_members TO authenticated;
GRANT SELECT ON public.fan_team_game_links TO authenticated;
GRANT ALL ON public.fan_teams TO service_role;
GRANT ALL ON public.fan_team_members TO service_role;
GRANT ALL ON public.fan_team_game_links TO service_role;

-- ---------------------------------------------------------------------------
-- 5) create_fan_team
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_fan_team(
  p_name text,
  p_sport text DEFAULT '',
  p_member_ids uuid[] DEFAULT ARRAY[]::uuid[],
  p_color_hex text DEFAULT NULL,
  p_logo_url text DEFAULT NULL,
  p_logo_thumbnail_url text DEFAULT NULL
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
      RAISE EXCEPTION 'One or more members are not eligible.';
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

  FOREACH v_uid IN ARRAY v_unique LOOP
    INSERT INTO public.group_conversation_members (
      conversation_id, user_id, role, joined_at, last_read_at
    ) VALUES (
      v_conversation_id, v_uid, 'member', now(), now()
    )
    ON CONFLICT (conversation_id, user_id) DO UPDATE
      SET left_at = NULL,
          role = EXCLUDED.role,
          joined_at = CASE
            WHEN public.group_conversation_members.left_at IS NOT NULL THEN now()
            ELSE public.group_conversation_members.joined_at
          END;
  END LOOP;

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

  INSERT INTO public.fan_teams (
    name,
    sport,
    logo_url,
    logo_thumbnail_url,
    color_hex,
    owner_user_id,
    group_conversation_id
  ) VALUES (
    v_name,
    v_sport,
    nullif(btrim(coalesce(p_logo_url, '')), ''),
    nullif(btrim(coalesce(p_logo_thumbnail_url, '')), ''),
    v_color,
    me,
    v_conversation_id
  )
  RETURNING id INTO v_team_id;

  INSERT INTO public.fan_team_members (team_id, user_id, role)
  VALUES (v_team_id, me, 'owner');

  FOREACH v_uid IN ARRAY v_unique LOOP
    INSERT INTO public.fan_team_members (team_id, user_id, role)
    VALUES (v_team_id, v_uid, 'member')
    ON CONFLICT (team_id, user_id) DO UPDATE
      SET left_at = NULL,
          role = 'member',
          joined_at = CASE
            WHEN public.fan_team_members.left_at IS NOT NULL THEN now()
            ELSE public.fan_team_members.joined_at
          END;
  END LOOP;

  RETURN v_team_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_fan_team(text, text, uuid[], text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_fan_team(text, text, uuid[], text, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.create_fan_team(text, text, uuid[], text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_fan_team(text, text, uuid[], text, text, text) TO service_role;

COMMENT ON FUNCTION public.create_fan_team(text, text, uuid[], text, text, text) IS
  'Create a FanGeo team + linked group chat. Creator is owner; optional friends become members immediately.';

-- ---------------------------------------------------------------------------
-- 6) list_my_fan_teams (next game from pickup_games via links)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_my_fan_teams()
RETURNS TABLE (
  team_id uuid,
  name text,
  sport text,
  logo_url text,
  logo_thumbnail_url text,
  color_hex text,
  owner_user_id uuid,
  group_conversation_id uuid,
  my_role text,
  member_count integer,
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
    t.owner_user_id,
    t.group_conversation_id,
    m.role,
    (
      SELECT count(*)::integer
      FROM public.fan_team_members am
      WHERE am.team_id = t.id
        AND am.left_at IS NULL
    ) AS member_count,
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

REVOKE ALL ON FUNCTION public.list_my_fan_teams() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_my_fan_teams() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_my_fan_teams() TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_my_fan_teams() TO service_role;

-- ---------------------------------------------------------------------------
-- 7) Roster / membership management
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_fan_team_members(p_team_id uuid)
RETURNS TABLE (
  user_id uuid,
  role text,
  joined_at timestamptz,
  display_name text,
  username text,
  avatar_url text,
  avatar_thumbnail_url text,
  last_seen_at text
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
  IF p_team_id IS NULL OR NOT public.is_active_fan_team_member(p_team_id, me) THEN
    RAISE EXCEPTION 'Not a team member.';
  END IF;

  RETURN QUERY
  SELECT
    m.user_id,
    m.role,
    m.joined_at,
    coalesce(nullif(btrim(p.display_name), ''), 'Fan')::text,
    p.username,
    p.avatar_url,
    p.avatar_thumbnail_url,
    CASE
      WHEN p.activity_status_visible IS FALSE THEN NULL
      ELSE p.last_seen_at::text
    END AS last_seen_at
  FROM public.fan_team_members m
  LEFT JOIN public.user_profiles p ON p.id = m.user_id
  WHERE m.team_id = p_team_id
    AND m.left_at IS NULL
  ORDER BY
    CASE m.role
      WHEN 'owner' THEN 0
      WHEN 'manager' THEN 1
      WHEN 'captain' THEN 2
      ELSE 3
    END,
    lower(coalesce(p.display_name, p.username, '')) ASC;
END;
$$;

REVOKE ALL ON FUNCTION public.list_fan_team_members(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_fan_team_members(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_fan_team_members(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.add_fan_team_members(
  p_team_id uuid,
  p_member_ids uuid[]
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_uid uuid;
  v_unique uuid[] := ARRAY[]::uuid[];
  v_conversation_id uuid;
  v_added integer := 0;
  v_active_count integer;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF NOT public.fan_team_viewer_can_manage(p_team_id) THEN
    RAISE EXCEPTION 'Only the owner or a manager can add members.';
  END IF;

  SELECT t.group_conversation_id INTO v_conversation_id
  FROM public.fan_teams t
  WHERE t.id = p_team_id AND t.is_active = true;

  IF v_conversation_id IS NULL THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  FOREACH v_uid IN ARRAY coalesce(p_member_ids, ARRAY[]::uuid[]) LOOP
    IF v_uid IS NULL OR v_uid = me THEN
      CONTINUE;
    END IF;
    IF NOT (v_uid = ANY (v_unique)) THEN
      v_unique := array_append(v_unique, v_uid);
    END IF;
  END LOOP;

  SELECT count(*)::integer INTO v_active_count
  FROM public.fan_team_members
  WHERE team_id = p_team_id AND left_at IS NULL;

  IF v_active_count + coalesce(array_length(v_unique, 1), 0) > 50 THEN
    RAISE EXCEPTION 'A team may have at most 50 members.';
  END IF;

  FOREACH v_uid IN ARRAY v_unique LOOP
    IF NOT public.group_add_member_eligible(me, v_uid) THEN
      CONTINUE;
    END IF;
    IF public.is_active_fan_team_member(p_team_id, v_uid) THEN
      CONTINUE;
    END IF;

    INSERT INTO public.fan_team_members (team_id, user_id, role)
    VALUES (p_team_id, v_uid, 'member')
    ON CONFLICT (team_id, user_id) DO UPDATE
      SET left_at = NULL,
          role = COALESCE(public.fan_team_members.role, 'member'),
          joined_at = now();

    INSERT INTO public.group_conversation_members (
      conversation_id, user_id, role, joined_at, last_read_at
    ) VALUES (
      v_conversation_id, v_uid, 'member', now(), now()
    )
    ON CONFLICT (conversation_id, user_id) DO UPDATE
      SET left_at = NULL,
          joined_at = CASE
            WHEN public.group_conversation_members.left_at IS NOT NULL THEN now()
            ELSE public.group_conversation_members.joined_at
          END;

    v_added := v_added + 1;
  END LOOP;

  RETURN v_added;
END;
$$;

REVOKE ALL ON FUNCTION public.add_fan_team_members(uuid, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.add_fan_team_members(uuid, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.add_fan_team_members(uuid, uuid[]) TO service_role;

CREATE OR REPLACE FUNCTION public.remove_fan_team_member(
  p_team_id uuid,
  p_user_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_target_role text;
  v_conversation_id uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'User is required.';
  END IF;

  SELECT t.group_conversation_id INTO v_conversation_id
  FROM public.fan_teams t
  WHERE t.id = p_team_id AND t.is_active = true;

  IF v_conversation_id IS NULL THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  SELECT m.role INTO v_target_role
  FROM public.fan_team_members m
  WHERE m.team_id = p_team_id
    AND m.user_id = p_user_id
    AND m.left_at IS NULL;

  IF v_target_role IS NULL THEN
    RETURN;
  END IF;

  IF v_target_role = 'owner' THEN
    RAISE EXCEPTION 'The team owner cannot be removed.';
  END IF;

  IF p_user_id <> me AND NOT public.fan_team_viewer_can_manage(p_team_id) THEN
    RAISE EXCEPTION 'Only the owner or a manager can remove members.';
  END IF;

  UPDATE public.fan_team_members
  SET left_at = now()
  WHERE team_id = p_team_id
    AND user_id = p_user_id
    AND left_at IS NULL;

  UPDATE public.group_conversation_members
  SET left_at = now()
  WHERE conversation_id = v_conversation_id
    AND user_id = p_user_id
    AND left_at IS NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.remove_fan_team_member(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.remove_fan_team_member(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_fan_team_member(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.set_fan_team_member_role(
  p_team_id uuid,
  p_user_id uuid,
  p_role text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_role text := lower(btrim(coalesce(p_role, '')));
  v_owner uuid;
  v_conversation_id uuid;
  v_group_role text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF v_role NOT IN ('manager', 'captain', 'member') THEN
    RAISE EXCEPTION 'Invalid role.';
  END IF;

  SELECT t.owner_user_id, t.group_conversation_id
  INTO v_owner, v_conversation_id
  FROM public.fan_teams t
  WHERE t.id = p_team_id AND t.is_active = true;

  IF v_conversation_id IS NULL THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  IF me <> v_owner THEN
    RAISE EXCEPTION 'Only the team owner can change roles.';
  END IF;

  IF p_user_id = v_owner THEN
    RAISE EXCEPTION 'Cannot change the owner role this way.';
  END IF;

  IF NOT public.is_active_fan_team_member(p_team_id, p_user_id) THEN
    RAISE EXCEPTION 'User is not an active team member.';
  END IF;

  UPDATE public.fan_team_members
  SET role = v_role
  WHERE team_id = p_team_id
    AND user_id = p_user_id
    AND left_at IS NULL;

  v_group_role := CASE WHEN v_role IN ('manager', 'captain') THEN 'admin' ELSE 'member' END;

  UPDATE public.group_conversation_members
  SET role = v_group_role
  WHERE conversation_id = v_conversation_id
    AND user_id = p_user_id
    AND left_at IS NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.set_fan_team_member_role(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_fan_team_member_role(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_fan_team_member_role(uuid, uuid, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 8) Team games on pickup_games (authoritative)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.schedule_fan_team_game(
  p_team_id uuid,
  p_game_type text,
  p_starts_at timestamptz,
  p_venue_name text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_state text DEFAULT NULL,
  p_latitude double precision DEFAULT NULL,
  p_longitude double precision DEFAULT NULL,
  p_opponent_team_id uuid DEFAULT NULL,
  p_opponent_name text DEFAULT NULL,
  p_title text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_type text := lower(btrim(coalesce(p_game_type, 'match')));
  v_pickup_id uuid;
  v_home_name text;
  v_home_sport text;
  v_opp_team_name text;
  v_opp_name text := nullif(btrim(coalesce(p_opponent_name, '')), '');
  v_title text;
  v_address text;
  v_email text;
  v_remove_after timestamptz;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF NOT public.fan_team_viewer_can_manage(p_team_id) THEN
    RAISE EXCEPTION 'Only the owner or a manager can schedule games.';
  END IF;
  IF v_type NOT IN ('match', 'scrimmage', 'practice') THEN
    RAISE EXCEPTION 'Invalid game type.';
  END IF;
  IF p_starts_at IS NULL THEN
    RAISE EXCEPTION 'Start time is required.';
  END IF;

  SELECT nullif(btrim(t.name), ''), nullif(btrim(t.sport), '')
  INTO v_home_name, v_home_sport
  FROM public.fan_teams t
  WHERE t.id = p_team_id AND t.is_active = true;

  IF v_home_name IS NULL THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  -- Opponent shape:
  -- practice  → no opponent team, no custom name
  -- match/scrimmage → FanGeo opponent XOR custom name XOR neither (open)
  IF v_type = 'practice' THEN
    IF p_opponent_team_id IS NOT NULL OR v_opp_name IS NOT NULL THEN
      RAISE EXCEPTION 'Practice games cannot have an opponent.';
    END IF;
  ELSE
    IF p_opponent_team_id IS NOT NULL AND v_opp_name IS NOT NULL THEN
      RAISE EXCEPTION 'Provide either a FanGeo opponent team or a custom opponent name, not both.';
    END IF;
  END IF;

  IF p_opponent_team_id IS NOT NULL THEN
    IF p_opponent_team_id = p_team_id THEN
      RAISE EXCEPTION 'Opponent cannot be the same team.';
    END IF;
    SELECT nullif(btrim(t.name), '') INTO v_opp_team_name
    FROM public.fan_teams t
    WHERE t.id = p_opponent_team_id AND t.is_active = true;
    IF v_opp_team_name IS NULL THEN
      RAISE EXCEPTION 'Opponent team not found.';
    END IF;
    v_opp_name := v_opp_team_name;
  END IF;

  v_title := nullif(btrim(coalesce(p_title, '')), '');
  IF v_title IS NULL THEN
    IF v_type = 'practice' THEN
      v_title := v_home_name || ' Practice';
    ELSIF v_opp_name IS NOT NULL THEN
      v_title := v_home_name || ' vs ' || v_opp_name;
    ELSE
      v_title := v_home_name || ' ' || initcap(v_type);
    END IF;
  END IF;

  v_address := coalesce(
    nullif(btrim(coalesce(p_venue_name, '')), ''),
    nullif(btrim(coalesce(p_address, '')), '')
  );
  v_remove_after := p_starts_at + interval '12 hours';

  SELECT nullif(btrim(u.email), '') INTO v_email
  FROM auth.users u
  WHERE u.id = me;

  INSERT INTO public.pickup_games (
    creator_user_id,
    creator_email,
    title,
    sport,
    description,
    game_format,
    skill_level,
    game_start_at,
    end_time,
    address,
    city,
    state,
    latitude,
    longitude,
    is_visible,
    players_needed,
    play_environment,
    participant_preference,
    is_free,
    entry_fee_amount,
    max_players,
    status,
    cleanup_delay_hours,
    remove_after_at,
    opponent_name,
    poll_create_permission
  ) VALUES (
    me,
    v_email,
    v_title,
    coalesce(v_home_sport, 'Soccer'),
    CASE
      WHEN v_type = 'practice' THEN 'Fan team practice'
      WHEN p_opponent_team_id IS NOT NULL THEN 'Fan team match'
      WHEN v_opp_name IS NOT NULL THEN 'Fan team match vs custom opponent'
      ELSE 'Fan team ' || v_type
    END,
    v_type,
    'casual',
    p_starts_at,
    p_starts_at + interval '2 hours',
    v_address,
    nullif(btrim(coalesce(p_city, '')), ''),
    nullif(btrim(coalesce(p_state, '')), ''),
    p_latitude,
    p_longitude,
    false, -- team-private: off Discover; team members read via RLS helper
    1,
    'either',
    'everyone',
    true,
    NULL,
    50,
    'active',
    12,
    v_remove_after,
    v_opp_name,
    'organizer_only'
  )
  RETURNING id INTO v_pickup_id;

  IF v_type = 'practice' THEN
    INSERT INTO public.fan_team_game_links (pickup_game_id, team_id, side)
    VALUES (v_pickup_id, p_team_id, 'solo');
  ELSE
    INSERT INTO public.fan_team_game_links (pickup_game_id, team_id, side)
    VALUES (v_pickup_id, p_team_id, 'home');

    IF p_opponent_team_id IS NOT NULL THEN
      INSERT INTO public.fan_team_game_links (pickup_game_id, team_id, side)
      VALUES (v_pickup_id, p_opponent_team_id, 'away');
    END IF;
  END IF;

  -- Organizer is Going (approved request) so existing roster/chat machinery applies.
  IF NOT EXISTS (
    SELECT 1 FROM public.pickup_game_requests r
    WHERE r.pickup_game_id = v_pickup_id
      AND r.requester_user_id = me
  ) THEN
    INSERT INTO public.pickup_game_requests (
      pickup_game_id,
      requester_user_id,
      requester_email,
      requester_display_name,
      requester_skill_level,
      status,
      responded_at
    ) VALUES (
      v_pickup_id,
      me,
      v_email,
      coalesce(
        (SELECT nullif(btrim(p.display_name), '') FROM public.user_profiles p WHERE p.id = me),
        'Fan'
      ),
      'casual',
      'approved',
      now()
    );
  END IF;

  -- Best-effort game chat (same infrastructure as pickup).
  BEGIN
    PERFORM public.ensure_pickup_game_group_conversation(v_pickup_id);
  EXCEPTION
    WHEN undefined_function THEN
      NULL;
    WHEN OTHERS THEN
      NULL;
  END;

  RETURN v_pickup_id;
END;
$$;

REVOKE ALL ON FUNCTION public.schedule_fan_team_game(
  uuid, text, timestamptz, text, text, text, text, double precision, double precision, uuid, text, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.schedule_fan_team_game(
  uuid, text, timestamptz, text, text, text, text, double precision, double precision, uuid, text, text
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.schedule_fan_team_game(
  uuid, text, timestamptz, text, text, text, text, double precision, double precision, uuid, text, text
) TO service_role;

COMMENT ON FUNCTION public.schedule_fan_team_game(
  uuid, text, timestamptz, text, text, text, text, double precision, double precision, uuid, text, text
) IS
  'Schedules a Fan Team practice/scrimmage/match as ONE pickup_games row + fan_team_game_links. Team A vs Team B shares the same pickup id.';

CREATE OR REPLACE FUNCTION public.list_fan_team_games(p_team_id uuid)
RETURNS TABLE (
  id uuid,
  team_id uuid,
  created_by uuid,
  game_type text,
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
  my_side text
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
  IF NOT public.is_active_fan_team_member(p_team_id, me) THEN
    RAISE EXCEPTION 'Not a team member.';
  END IF;

  RETURN QUERY
  SELECT
    pg.id,
    p_team_id AS team_id,
    pg.creator_user_id AS created_by,
    pg.game_format AS game_type,
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
    l.side AS my_side
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

-- RSVP reuses pickup Going (approved requests) + pending/withdrawn for maybe/cant_go.
CREATE OR REPLACE FUNCTION public.set_fan_team_game_rsvp(
  p_game_id uuid,
  p_status text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_status text := lower(btrim(coalesce(p_status, '')));
  v_request_status text;
  v_email text;
  v_display text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF v_status NOT IN ('going', 'maybe', 'cant_go') THEN
    RAISE EXCEPTION 'Invalid RSVP status.';
  END IF;

  IF NOT public.is_pickup_game_fan_team_participant(p_game_id, me) THEN
    RAISE EXCEPTION 'Not a participant for this team game.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.pickup_games pg
    WHERE pg.id = p_game_id
      AND pg.status = 'active'
      AND pg.archived_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Game not found.';
  END IF;

  v_request_status := CASE v_status
    WHEN 'going' THEN 'approved'
    WHEN 'maybe' THEN 'pending'
    ELSE 'withdrawn'
  END;

  SELECT nullif(btrim(u.email), '') INTO v_email
  FROM auth.users u WHERE u.id = me;

  SELECT coalesce(nullif(btrim(p.display_name), ''), 'Fan') INTO v_display
  FROM public.user_profiles p WHERE p.id = me;

  UPDATE public.pickup_game_requests
  SET
    status = v_request_status,
    responded_at = CASE WHEN v_request_status = 'pending' THEN NULL ELSE now() END,
    updated_at = now(),
    requester_display_name = coalesce(v_display, requester_display_name),
    requester_email = coalesce(v_email, requester_email)
  WHERE pickup_game_id = p_game_id
    AND requester_user_id = me;

  IF NOT FOUND THEN
    INSERT INTO public.pickup_game_requests (
      pickup_game_id,
      requester_user_id,
      requester_email,
      requester_display_name,
      requester_skill_level,
      status,
      responded_at
    ) VALUES (
      p_game_id,
      me,
      v_email,
      coalesce(v_display, 'Fan'),
      'casual',
      v_request_status,
      CASE WHEN v_request_status = 'pending' THEN NULL ELSE now() END
    );
  END IF;

  BEGIN
    PERFORM public.sync_pickup_game_group_membership(p_game_id);
  EXCEPTION
    WHEN undefined_function THEN
      NULL;
    WHEN OTHERS THEN
      NULL;
  END;
END;
$$;

REVOKE ALL ON FUNCTION public.set_fan_team_game_rsvp(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_fan_team_game_rsvp(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_fan_team_game_rsvp(uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION public.get_fan_team_game_rsvp(
  p_game_id uuid
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_req text;
BEGIN
  IF me IS NULL THEN
    RETURN NULL;
  END IF;

  IF NOT public.is_pickup_game_fan_team_participant(p_game_id, me) THEN
    RETURN NULL;
  END IF;

  SELECT r.status INTO v_req
  FROM public.pickup_game_requests r
  WHERE r.pickup_game_id = p_game_id
    AND r.requester_user_id = me;

  IF v_req IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN CASE v_req
    WHEN 'approved' THEN 'going'
    WHEN 'pending' THEN 'maybe'
    WHEN 'withdrawn' THEN 'cant_go'
    WHEN 'cancelled' THEN 'cant_go'
    WHEN 'rejected' THEN 'cant_go'
    ELSE NULL
  END;
END;
$$;

REVOKE ALL ON FUNCTION public.get_fan_team_game_rsvp(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_fan_team_game_rsvp(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_fan_team_game_rsvp(uuid) TO service_role;

COMMIT;

-- =============================================================================
-- MANUAL APPLY NOTES
-- =============================================================================
-- 1) Apply this file in Supabase SQL editor after prior pending migrations.
-- 2) No Edge Function deploy required for Team Chat (reuses group push).
-- 3) Team games inherit pickup edit notifications / game chat when those
--    features are already deployed for pickup_games.
-- 4) Verify:
--    SELECT to_regclass('public.fan_teams');
--    SELECT to_regclass('public.fan_team_game_links');
--    SELECT to_regprocedure('public.schedule_fan_team_game(uuid,text,timestamptz,text,text,text,text,double precision,double precision,uuid,text,text)');
--    SELECT to_regprocedure('public.list_fan_team_games(uuid)');
-- 5) There is NO fan_team_games / fan_team_game_rsvps table in this revision.
-- 6) pickup_games_select_authenticated is additive vs production:
--      keeps can_read_pickup_game_for_requester(id)
--      keeps (remove_after_at IS NULL OR remove_after_at > now())
--      only adds is_pickup_game_fan_team_participant(id, auth.uid())
-- =============================================================================
