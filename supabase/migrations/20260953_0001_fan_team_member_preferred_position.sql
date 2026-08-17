-- =============================================================================
-- 20260953_0001 — Fan Team member preferred_position_code
-- =============================================================================
-- Persistent Team-member preferred/default position (sport-scoped).
-- Distinct from event lineup fan_team_event_lineup_members.position_code.
-- Reuses 20260952 position helpers (normalize / family / is_valid).
--
-- Depends on: 20260952_0001 (position helpers), 20260950 (list_fan_team_members).
-- Do NOT apply from the agent; review and apply deliberately in Supabase.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Schema
-- ---------------------------------------------------------------------------
ALTER TABLE public.fan_team_members
  ADD COLUMN IF NOT EXISTS preferred_position_code text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'fan_team_members_preferred_position_len_ck'
  ) THEN
    ALTER TABLE public.fan_team_members
      ADD CONSTRAINT fan_team_members_preferred_position_len_ck
      CHECK (
        preferred_position_code IS NULL
        OR char_length(btrim(preferred_position_code)) BETWEEN 1 AND 16
      );
  END IF;
END $$;

COMMENT ON COLUMN public.fan_team_members.preferred_position_code IS
  'Optional Team-specific preferred position (canonical FanTeamSportPositions code). NULL = unset. Soft-left rows retain history.';

-- Preserve RPC-mediated writes (SELECT-only for authenticated).
REVOKE INSERT, UPDATE, DELETE ON TABLE public.fan_team_members FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.fan_team_members FROM anon;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.fan_team_members FROM PUBLIC;
GRANT SELECT ON TABLE public.fan_team_members TO authenticated;

-- ---------------------------------------------------------------------------
-- 2) list_fan_team_members — include preferred_position_code
-- ---------------------------------------------------------------------------
-- DROP required: RETURNS TABLE OUT shape change (42P13).
DROP FUNCTION IF EXISTS public.list_fan_team_members(uuid);

CREATE FUNCTION public.list_fan_team_members(p_team_id uuid)
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
  gender text,
  preferred_position_code text
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
    p.gender,
    m.preferred_position_code
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
  'Active Team roster with identity, player_number, preferred_position_code, profile gender, hierarchy sort.';

REVOKE ALL ON FUNCTION public.list_fan_team_members(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_fan_team_members(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.list_fan_team_members(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_fan_team_members(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) set_fan_team_member_preferred_position
--    Auth: Owner / Manager / Head Coach / Assistant Coach (lineup-manager set)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_fan_team_member_preferred_position(
  p_team_id uuid,
  p_user_id uuid,
  p_position_code text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_sport text;
  v_position text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF p_team_id IS NULL OR p_user_id IS NULL THEN
    RAISE EXCEPTION 'Team and user are required.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.fan_teams t
    WHERE t.id = p_team_id
      AND t.is_active = true
  ) THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  IF NOT public.fan_team_viewer_can_manage_lineup(p_team_id) THEN
    RAISE EXCEPTION 'Only coaches and managers can set player positions.';
  END IF;

  IF NOT public.is_active_fan_team_member(p_team_id, p_user_id) THEN
    RAISE EXCEPTION 'User is not an active team member.';
  END IF;

  SELECT t.sport
  INTO v_sport
  FROM public.fan_teams t
  WHERE t.id = p_team_id
    AND t.is_active = true;

  v_position := public.fan_team_event_normalize_position_code(p_position_code);

  IF NOT public.fan_team_event_position_code_is_valid(v_sport, v_position) THEN
    RAISE EXCEPTION 'Invalid position for this sport.';
  END IF;

  UPDATE public.fan_team_members
  SET preferred_position_code = v_position
  WHERE team_id = p_team_id
    AND user_id = p_user_id
    AND left_at IS NULL;
END;
$$;

COMMENT ON FUNCTION public.set_fan_team_member_preferred_position(uuid, uuid, text) IS
  'Owner/Manager/Head Coach/Assistant Coach assigns or clears (NULL) an active member preferred position.';

REVOKE ALL ON FUNCTION public.set_fan_team_member_preferred_position(uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_fan_team_member_preferred_position(uuid, uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_fan_team_member_preferred_position(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_fan_team_member_preferred_position(uuid, uuid, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 4) update_fan_team_identity — clear incompatible preferred positions on sport change
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_fan_team_identity(
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
  v_prev_sport text;
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

  SELECT t.group_conversation_id, t.name, t.sport
  INTO v_conversation_id, v_prev_name, v_prev_sport
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

  -- Clear Team preferred positions that are invalid for the new sport.
  -- Does NOT mutate event lineup position_code rows.
  IF lower(btrim(coalesce(v_prev_sport, ''))) IS DISTINCT FROM lower(btrim(coalesce(v_sport, ''))) THEN
    UPDATE public.fan_team_members m
    SET preferred_position_code = NULL
    WHERE m.team_id = p_team_id
      AND m.left_at IS NULL
      AND m.preferred_position_code IS NOT NULL
      AND NOT public.fan_team_event_position_code_is_valid(v_sport, m.preferred_position_code);
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
  'Owner/Manager: update Team identity. Clears incompatible preferred_position_code on sport change. '
  'competition_level updates only when p_update_competition_level=true.';

COMMIT;
