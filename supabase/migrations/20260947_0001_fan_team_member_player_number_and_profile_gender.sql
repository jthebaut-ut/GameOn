-- =============================================================================
-- 20260947_0001 — Fan Team roster player_number + user_profiles.gender
-- =============================================================================
--
-- PLAYER NUMBER (Team-specific):
--   • fan_team_members.player_number smallint NULL (0–99)
--   • Partial unique index: one active member per Team may hold a given number
--   • Soft-left rows do not block reuse of a number
--   • Soft-rejoin keeps historical number when still free; otherwise clears it
--     (BEFORE trigger) so unique index never blocks rejoin
--   • RPC set_fan_team_member_player_number — owner/manager only
--
-- GENDER (user-specific):
--   • user_profiles.gender text NULL
--   • Values: male | female | non_binary | other | prefer_not_to_say
--   • Exposed on list_fan_team_members for roster display only
--   • User edits own gender via profile update (RLS); Team managers cannot
--
-- list_fan_team_members RETURNS TABLE shape change:
--   PostgreSQL cannot CREATE OR REPLACE when OUT/RETURNS TABLE columns change
--   (error 42P13). This migration DROP FUNCTION then recreates with grants.
--
-- Wrapped in BEGIN/COMMIT so a failed apply rolls back atomically.
-- Safe to retry after a previous failed attempt that may have left columns
-- (ADD COLUMN IF NOT EXISTS / IF NOT EXISTS constraints).
--
-- DO NOT apply from the agent. Apply manually in Supabase after review.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Schema
-- ---------------------------------------------------------------------------
ALTER TABLE public.fan_team_members
  ADD COLUMN IF NOT EXISTS player_number smallint;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'fan_team_members_player_number_range_ck'
  ) THEN
    ALTER TABLE public.fan_team_members
      ADD CONSTRAINT fan_team_members_player_number_range_ck
      CHECK (
        player_number IS NULL
        OR (player_number >= 0 AND player_number <= 99)
      );
  END IF;
END $$;

COMMENT ON COLUMN public.fan_team_members.player_number IS
  'Optional Team-specific jersey/player number (0–99). NULL = unassigned. Soft-left rows retain history.';

CREATE UNIQUE INDEX IF NOT EXISTS fan_team_members_active_player_number_uidx
  ON public.fan_team_members (team_id, player_number)
  WHERE left_at IS NULL AND player_number IS NOT NULL;

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS gender text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'user_profiles_gender_ck'
  ) THEN
    ALTER TABLE public.user_profiles
      ADD CONSTRAINT user_profiles_gender_ck
      CHECK (
        gender IS NULL
        OR gender IN (
          'male',
          'female',
          'non_binary',
          'other',
          'prefer_not_to_say'
        )
      );
  END IF;
END $$;

COMMENT ON COLUMN public.user_profiles.gender IS
  'Optional self-declared gender. prefer_not_to_say / NULL = hide on Team roster.';

-- Soft-rejoin: if historical number is taken by another active member, clear it.
CREATE OR REPLACE FUNCTION public.fan_team_members_resolve_player_number_on_activate()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.left_at IS NULL
     AND NEW.player_number IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.fan_team_members o
       WHERE o.team_id = NEW.team_id
         AND o.left_at IS NULL
         AND o.user_id IS DISTINCT FROM NEW.user_id
         AND o.player_number = NEW.player_number
     )
  THEN
    NEW.player_number := NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS fan_team_members_resolve_player_number_trg
  ON public.fan_team_members;
CREATE TRIGGER fan_team_members_resolve_player_number_trg
  BEFORE INSERT OR UPDATE OF left_at, player_number
  ON public.fan_team_members
  FOR EACH ROW
  EXECUTE FUNCTION public.fan_team_members_resolve_player_number_on_activate();

-- ---------------------------------------------------------------------------
-- 2) list_fan_team_members — include player_number + gender
-- ---------------------------------------------------------------------------
-- DROP required: RETURNS TABLE OUT shape changed (added player_number, gender).
-- No CASCADE: repository has no DB views/functions depending on this RPC
-- (iOS client calls it by name only).
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
      WHEN 'captain' THEN 2
      ELSE 3
    END,
    lower(coalesce(p.display_name, p.username, '')) ASC;
END;
$$;

COMMENT ON FUNCTION public.list_fan_team_members(uuid) IS
  'Active Team roster with identity, Team player_number, and profile gender.';

-- Grants do not survive DROP FUNCTION — restore authoritative policy from 20260926.
REVOKE ALL ON FUNCTION public.list_fan_team_members(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_fan_team_members(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.list_fan_team_members(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_fan_team_members(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) set_fan_team_member_player_number — owner/manager only
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_fan_team_member_player_number(
  p_team_id uuid,
  p_user_id uuid,
  p_player_number integer
)
RETURNS void
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

  IF NOT public.fan_team_viewer_can_manage(p_team_id) THEN
    RAISE EXCEPTION 'Only the owner or a manager can set player numbers.';
  END IF;

  IF NOT public.is_active_fan_team_member(p_team_id, p_user_id) THEN
    RAISE EXCEPTION 'User is not an active team member.';
  END IF;

  IF p_player_number IS NOT NULL
     AND (p_player_number < 0 OR p_player_number > 99)
  THEN
    RAISE EXCEPTION 'Player number must be between 0 and 99.';
  END IF;

  IF p_player_number IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.fan_team_members o
       WHERE o.team_id = p_team_id
         AND o.left_at IS NULL
         AND o.user_id <> p_user_id
         AND o.player_number = p_player_number::smallint
     )
  THEN
    RAISE EXCEPTION 'That player number is already assigned on this Team.';
  END IF;

  UPDATE public.fan_team_members
  SET player_number = p_player_number::smallint
  WHERE team_id = p_team_id
    AND user_id = p_user_id
    AND left_at IS NULL;
END;
$$;

COMMENT ON FUNCTION public.set_fan_team_member_player_number(uuid, uuid, integer) IS
  'Owner/manager assigns or clears (NULL) an active member Team-specific player number (0–99).';

REVOKE ALL ON FUNCTION public.set_fan_team_member_player_number(uuid, uuid, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_fan_team_member_player_number(uuid, uuid, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_fan_team_member_player_number(uuid, uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_fan_team_member_player_number(uuid, uuid, integer) TO service_role;

COMMIT;

-- =============================================================================
-- Manual apply notes
-- =============================================================================
-- 1) Apply AFTER 20260946 (and any later applied migrations that precede this
--    file in your project history). Do NOT apply 20260948 before this if both
--    are pending — apply in filename order.
-- 2) Pre-check (read-only) — see agent report for full queries.
-- 3) Post-check: player_number + gender columns, list_fan_team_members OUT args
--    include player_number/gender, set_fan_team_member_player_number EXECUTE.
-- =============================================================================
