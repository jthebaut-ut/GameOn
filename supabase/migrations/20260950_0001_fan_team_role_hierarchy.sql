-- =============================================================================
-- 20260950_0001 — Fan Team role hierarchy expansion
-- =============================================================================
-- Adds: head_coach, assistant_coach, assistant_captain
-- Preserves existing owner / manager / captain / member tokens (no data rewrite).
--
-- Also:
--   • Owner OR Manager may assign non-owner roles
--   • Owner / Manager / Head Coach may organize Team games (link path)
--   • Roster ORDER BY matches client hierarchy
--
-- Do NOT apply from the agent; review and apply deliberately in Supabase.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Expand fan_team_members.role CHECK
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT c.conname
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'public'
      AND t.relname = 'fan_team_members'
      AND c.contype = 'c'
      AND pg_get_constraintdef(c.oid) ILIKE '%role%'
      AND pg_get_constraintdef(c.oid) ILIKE '%owner%'
  LOOP
    EXECUTE format('ALTER TABLE public.fan_team_members DROP CONSTRAINT IF EXISTS %I', r.conname);
  END LOOP;
END $$;

ALTER TABLE public.fan_team_members
  ADD CONSTRAINT fan_team_members_role_check
  CHECK (
    role IN (
      'owner',
      'manager',
      'head_coach',
      'assistant_coach',
      'captain',
      'assistant_captain',
      'member'
    )
  );

COMMENT ON COLUMN public.fan_team_members.role IS
  'Team hierarchy: owner, manager, head_coach, assistant_coach, captain, assistant_captain, member.';

-- ---------------------------------------------------------------------------
-- 2) Organize helper (schedule / link) — broader than manage
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_team_role_can_organize(p_role text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT lower(coalesce(p_role, '')) IN ('owner', 'manager', 'head_coach');
$$;

CREATE OR REPLACE FUNCTION public.fan_team_viewer_can_organize(p_team_id uuid)
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
      AND public.fan_team_role_can_organize(m.role)
  );
$$;

REVOKE ALL ON FUNCTION public.fan_team_role_can_organize(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fan_team_role_can_organize(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_role_can_organize(text) TO service_role;

REVOKE ALL ON FUNCTION public.fan_team_viewer_can_organize(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fan_team_viewer_can_organize(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_viewer_can_organize(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) set_fan_team_member_role — new roles + Manager may assign
-- ---------------------------------------------------------------------------
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
  IF v_role NOT IN (
    'manager',
    'head_coach',
    'assistant_coach',
    'captain',
    'assistant_captain',
    'member'
  ) THEN
    RAISE EXCEPTION 'Invalid role.';
  END IF;

  SELECT t.owner_user_id, t.group_conversation_id
  INTO v_owner, v_conversation_id
  FROM public.fan_teams t
  WHERE t.id = p_team_id AND t.is_active = true;

  IF v_conversation_id IS NULL THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  IF NOT public.fan_team_viewer_can_manage(p_team_id) THEN
    RAISE EXCEPTION 'Only the owner or a manager can change roles.';
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

  -- Group-chat `admin` is a privileged chat role (invite/remove members, update
  -- conversation settings, moderate messages). Map ONLY Team Manager → chat admin.
  -- Head Coach / coaches / captains are Team leadership or organizers, not chat admins.
  -- Owner is never targeted by this RPC (see guard above); owner stays chat admin
  -- from create_fan_team insertion.
  v_group_role := CASE
    WHEN v_role = 'manager' THEN 'admin'
    ELSE 'member'
  END;

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
-- 4) list_fan_team_members — hierarchy ORDER BY
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
  last_seen_at text,
  player_number smallint,
  gender text
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
    END AS last_seen_at,
    m.player_number,
    p.gender
  FROM public.fan_team_members m
  LEFT JOIN public.user_profiles p ON p.id = m.user_id
  WHERE m.team_id = p_team_id
    AND m.left_at IS NULL
  ORDER BY
    CASE m.role
      WHEN 'owner' THEN 0
      WHEN 'manager' THEN 1
      WHEN 'head_coach' THEN 2
      WHEN 'assistant_coach' THEN 3
      WHEN 'captain' THEN 4
      WHEN 'assistant_captain' THEN 5
      ELSE 6
    END,
    lower(coalesce(p.display_name, p.username, '')) ASC;
END;
$$;

COMMENT ON FUNCTION public.list_fan_team_members(uuid) IS
  'Active Team roster with identity, Team player_number, profile gender, hierarchy sort.';

REVOKE ALL ON FUNCTION public.list_fan_team_members(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_fan_team_members(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.list_fan_team_members(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_fan_team_members(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 5) link_pickup_game_to_fan_team — Head Coach may organize (preserve 20260939)
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
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_team_id IS NULL OR p_pickup_game_id IS NULL THEN
    RAISE EXCEPTION 'Team and pickup game are required.';
  END IF;
  IF NOT public.fan_team_viewer_can_organize(p_team_id) THEN
    RAISE EXCEPTION 'Only the owner, a manager, or head coach can schedule games.';
  END IF;

  SELECT g.creator_user_id, lower(btrim(coalesce(g.game_format, ''))), lower(btrim(coalesce(g.status, '')))
  INTO v_creator, v_format, v_status
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
    'clinic'
  ) THEN
    RAISE EXCEPTION 'Team games must use practice, scrimmage, league_game, tournament_game, tryout, clinic, or legacy match.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.fan_teams t
    WHERE t.id = p_team_id AND t.is_active = true
  ) THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  -- Idempotent: already linked to this Team. Preserve is_visible.
  IF EXISTS (
    SELECT 1
    FROM public.fan_team_game_links l
    WHERE l.pickup_game_id = p_pickup_game_id
      AND l.team_id = p_team_id
  ) THEN
    RETURN p_pickup_game_id;
  END IF;

  v_side := CASE WHEN v_format = 'practice' THEN 'solo' ELSE 'home' END;

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

  -- Do NOT mutate is_visible — organizer choice from insert/update stands.

  INSERT INTO public.fan_team_game_links (pickup_game_id, team_id, side)
  VALUES (p_pickup_game_id, p_team_id, v_side);

  BEGIN
    PERFORM public.ensure_pickup_game_group_conversation(p_pickup_game_id);
  EXCEPTION
    WHEN undefined_function THEN
      NULL;
    WHEN OTHERS THEN
      NULL;
  END;

  RETURN p_pickup_game_id;
END;
$$;

REVOKE ALL ON FUNCTION public.link_pickup_game_to_fan_team(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.link_pickup_game_to_fan_team(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.link_pickup_game_to_fan_team(uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.link_pickup_game_to_fan_team(uuid, uuid) IS
  'Links a creator-owned active pickup_games row to a Fan Team (owner/manager/head coach). '
  'Preserves pickup_games.is_visible. Writes fan_team_game_links (practice=solo, else home).';

COMMIT;
