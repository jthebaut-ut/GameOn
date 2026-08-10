-- =============================================================================
-- 20260930_0001 — list_my_fan_teams: manager-visible pending invitation count
-- =============================================================================
-- Extends list_my_fan_teams() with pending_invitation_count so My Teams cards
-- can show a subtle pending indicator without N+1 network requests.
--
-- Security:
--   • Count is non-zero only when the viewer's active role is owner/manager.
--   • Normal members / captains always receive 0.
--   • Only status = 'pending' and not-yet-expired invitations are counted.
--
-- Prerequisites:
--   • 20260926_0001_fan_teams.sql
--   • 20260929_0001_fan_team_invitations.sql (fan_team_invitations table)
--
-- Do NOT apply from the agent; review and apply deliberately in Supabase.
-- =============================================================================

BEGIN;

-- Changing RETURNS TABLE requires drop + recreate (CREATE OR REPLACE cannot
-- change the result row type).
DROP FUNCTION IF EXISTS public.list_my_fan_teams();

CREATE FUNCTION public.list_my_fan_teams()
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
  'Lists active Fan Teams for auth.uid(). pending_invitation_count is manager/owner-only (0 for other roles). member_count remains active members only.';

REVOKE ALL ON FUNCTION public.list_my_fan_teams() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_my_fan_teams() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_my_fan_teams() TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_my_fan_teams() TO service_role;

COMMIT;

-- =============================================================================
-- MANUAL APPLY NOTES
-- =============================================================================
-- Apply AFTER:
--   1) 20260926_0001_fan_teams.sql
--   2) 20260929_0001_fan_team_invitations.sql
-- Then:
--   3) 20260930_0001_list_my_fan_teams_pending_invitation_count.sql
--
-- Verify:
--   SELECT pg_get_function_result(
--     'public.list_my_fan_teams()'::regprocedure
--   ) ILIKE '%pending_invitation_count%';
-- =============================================================================
