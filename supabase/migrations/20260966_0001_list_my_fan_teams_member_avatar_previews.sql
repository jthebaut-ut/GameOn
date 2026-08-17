-- =============================================================================
-- 20260966_0001 — My Teams card member avatar previews (batched, no N+1)
-- =============================================================================
-- Extends list_my_fan_teams with member_avatar_previews jsonb:
--   up to 4 active-member safe presentation objects for the Teams home card stack.
--
-- Includes managed-player avatars (same projection as list_fan_team_members).
-- Does NOT expose birth_year, guardian ids, or other private managed-player data.
--
-- Do NOT apply from the agent.
-- =============================================================================

BEGIN;

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
  push_notifications_muted boolean,
  next_game_starts_at timestamptz,
  next_game_title text,
  next_game_venue text,
  created_at timestamptz,
  member_avatar_previews jsonb
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
    coalesce(m.push_notifications_muted, false) AS push_notifications_muted,
    ng.game_start_at,
    coalesce(nullif(btrim(ng.title), ''), ng.game_format),
    coalesce(nullif(btrim(ng.address), ''), nullif(btrim(ng.city), '')),
    t.created_at,
    coalesce(previews.member_avatar_previews, '[]'::jsonb) AS member_avatar_previews
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
  LEFT JOIN LATERAL (
    SELECT coalesce(
      jsonb_agg(
        jsonb_strip_nulls(
          jsonb_build_object(
            'membership_id', ranked.membership_id,
            'display_name', ranked.display_name,
            'avatar_url', ranked.avatar_url,
            'avatar_thumbnail_url', ranked.avatar_thumbnail_url,
            'role', ranked.role,
            'is_managed_player', ranked.is_managed_player
          )
        )
        ORDER BY ranked.rank_order
      ),
      '[]'::jsonb
    ) AS member_avatar_previews
    FROM (
      SELECT
        am.membership_id,
        am.role,
        CASE
          WHEN am.managed_player_id IS NOT NULL
            THEN coalesce(nullif(btrim(mp.display_name), ''), 'Player')
          ELSE coalesce(nullif(btrim(up.display_name), ''), 'Fan')
        END AS display_name,
        CASE
          WHEN am.managed_player_id IS NOT NULL THEN mp.avatar_url
          ELSE up.avatar_url
        END AS avatar_url,
        CASE
          WHEN am.managed_player_id IS NOT NULL THEN mp.avatar_thumbnail_url
          ELSE up.avatar_thumbnail_url
        END AS avatar_thumbnail_url,
        (am.managed_player_id IS NOT NULL) AS is_managed_player,
        ROW_NUMBER() OVER (
          ORDER BY
            CASE am.role
              WHEN 'owner' THEN 0
              WHEN 'manager' THEN 1
              WHEN 'head_coach' THEN 2
              WHEN 'assistant_coach' THEN 3
              WHEN 'captain' THEN 4
              WHEN 'assistant_captain' THEN 5
              ELSE 6
            END,
            am.joined_at ASC NULLS LAST,
            lower(
              coalesce(
                nullif(btrim(mp.display_name), ''),
                nullif(btrim(up.display_name), ''),
                nullif(btrim(up.username), ''),
                ''
              )
            ) ASC
        ) AS rank_order
      FROM public.fan_team_members am
      LEFT JOIN public.user_profiles up ON up.id = am.user_id
      LEFT JOIN public.fan_managed_players mp ON mp.id = am.managed_player_id
      WHERE am.team_id = t.id
        AND am.left_at IS NULL
    ) ranked
    WHERE ranked.rank_order <= 4
  ) previews ON true
  WHERE t.is_active = true
  ORDER BY t.name ASC;
END;
$$;

COMMENT ON FUNCTION public.list_my_fan_teams() IS
  'Lists active Fan Teams for auth.uid(). Includes competition_level, '
  'pending_invitation_count (manager/owner), push_notifications_muted, and '
  'member_avatar_previews (up to 4 active seats, hierarchy-ordered; safe avatar '
  'projection for account + managed players).';

REVOKE ALL ON FUNCTION public.list_my_fan_teams() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_my_fan_teams() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_my_fan_teams() TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_my_fan_teams() TO service_role;

COMMIT;

-- Manual verification:
--   SELECT member_count, member_avatar_previews FROM list_my_fan_teams();
--   -- previews length <= 4; no birth_year / guardian keys
--   SELECT jsonb_object_keys(elem)
--   FROM list_my_fan_teams() t,
--        LATERAL jsonb_array_elements(t.member_avatar_previews) elem
--   LIMIT 20;
