-- =============================================================================
-- 20260972_0001 — list_my_fan_teams includes managed-player guardian access
-- =============================================================================
-- Root cause: accept_fan_team_invitation_for_participants with p_include_self=false
-- inserts a managed seat (user_id NULL, managed_player_id set) and intentionally
-- does NOT add the guardian as a Team member. list_my_fan_teams only joined
-- m.user_id = auth.uid(), so Emma-only joins never appeared in My Teams.
--
-- Fix: UNION Teams where the viewer has an active account seat OR is an active
-- guardian of an active managed-player seat. Deduplicate (account wins).
-- Do NOT insert the guardian into fan_team_members. Member counts stay seat-based.
-- Chat / mute / manage remain gated on account seats (access_via = 'account').
--
-- Privacy: access_via=managed_player avatar previews are limited to this
-- guardian's own active managed seats on the Team (not the full roster).
-- Next-event fields remain visible so guardians can follow the child's schedule.
--
-- Review-ready; do NOT auto-apply from the agent.
-- =============================================================================

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.fan_teams') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_teams'];
  END IF;
  IF to_regclass('public.fan_team_members') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_team_members'];
  END IF;
  IF to_regclass('public.fan_managed_players') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_managed_players'];
  END IF;
  IF to_regclass('public.fan_managed_player_guardians') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_managed_player_guardians'];
  END IF;
  IF to_regprocedure('public.fan_team_role_is_manager_or_owner(text)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.fan_team_role_is_manager_or_owner(text)'];
  END IF;
  IF to_regprocedure('public.list_my_fan_teams()') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.list_my_fan_teams()'];
  END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION
      '20260972_0001 prerequisites missing: %',
      array_to_string(v_missing, ', ');
  END IF;
END $$;

BEGIN;

-- RETURNS TABLE changed (additive columns) → DROP + CREATE required.
-- Do NOT use CASCADE. No views/triggers depend on this RPC (client RPC only).
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
  member_avatar_previews jsonb,
  -- Additive: 'account' | 'managed_player'. Older clients ignore unknown columns
  -- when using keyed JSON decoding; Swift uses decodeIfPresent.
  access_via text,
  via_managed_player_names text[]
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

  RETURN QUERY
  WITH account_seats AS (
    SELECT
      m.team_id,
      m.role AS my_role,
      coalesce(m.push_notifications_muted, false) AS push_notifications_muted,
      'account'::text AS access_via,
      0 AS priority
    FROM public.fan_team_members m
    WHERE m.user_id = me
      AND m.left_at IS NULL
  ),
  managed_seats AS (
    SELECT DISTINCT
      m.team_id,
      -- Synthetic placeholder for non-null clients. MUST NOT be treated as a roster
      -- seat; authoritative classification is access_via = 'managed_player'.
      'member'::text AS my_role,
      false AS push_notifications_muted,
      'managed_player'::text AS access_via,
      1 AS priority
    FROM public.fan_team_members m
    JOIN public.fan_managed_player_guardians g
      ON g.managed_player_id = m.managed_player_id
     AND g.guardian_user_id = me
     AND g.revoked_at IS NULL
    JOIN public.fan_managed_players mp
      ON mp.id = m.managed_player_id
     AND mp.archived_at IS NULL
    WHERE m.managed_player_id IS NOT NULL
      AND m.left_at IS NULL
      AND NOT EXISTS (
        SELECT 1
        FROM account_seats a
        WHERE a.team_id = m.team_id
      )
  ),
  viewer_seats AS (
    SELECT * FROM account_seats
    UNION ALL
    SELECT * FROM managed_seats
  ),
  best AS (
    SELECT DISTINCT ON (s.team_id)
      s.team_id,
      s.my_role,
      s.push_notifications_muted,
      s.access_via
    FROM viewer_seats s
    ORDER BY s.team_id, s.priority ASC
  )
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
    b.my_role,
    (
      SELECT count(*)::integer
      FROM public.fan_team_members am
      WHERE am.team_id = t.id
        AND am.left_at IS NULL
    ) AS member_count,
    CASE
      WHEN public.fan_team_role_is_manager_or_owner(b.my_role)
           AND b.access_via = 'account' THEN (
        SELECT count(*)::integer
        FROM public.fan_team_invitations i
        WHERE i.team_id = t.id
          AND i.status = 'pending'
          AND (i.expires_at IS NULL OR i.expires_at > now())
      )
      ELSE 0
    END AS pending_invitation_count,
    CASE
      WHEN b.access_via = 'account' THEN b.push_notifications_muted
      ELSE false
    END AS push_notifications_muted,
    ng.game_start_at,
    coalesce(nullif(btrim(ng.title), ''), ng.game_format),
    coalesce(nullif(btrim(ng.address), ''), nullif(btrim(ng.city), '')),
    t.created_at,
    coalesce(previews.member_avatar_previews, '[]'::jsonb) AS member_avatar_previews,
    b.access_via,
    coalesce(via_names.names, ARRAY[]::text[]) AS via_managed_player_names
  FROM public.fan_teams t
  JOIN best b ON b.team_id = t.id
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
            'managed_player_id', ranked.managed_player_id,
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
        am.managed_player_id,
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
        AND (
          -- Account seats: existing full roster preview (unchanged).
          b.access_via = 'account'
          OR (
            -- Guardian-only: only this guardian's active managed seats (privacy).
            b.access_via = 'managed_player'
            AND am.managed_player_id IS NOT NULL
            AND mp.archived_at IS NULL
            AND EXISTS (
              SELECT 1
              FROM public.fan_managed_player_guardians gx
              WHERE gx.managed_player_id = am.managed_player_id
                AND gx.guardian_user_id = me
                AND gx.revoked_at IS NULL
            )
          )
        )
    ) ranked
    WHERE ranked.rank_order <= 4
  ) previews ON true
  LEFT JOIN LATERAL (
    SELECT array_agg(label ORDER BY lower(label)) AS names
    FROM (
      SELECT DISTINCT
        coalesce(
          nullif(btrim(mp.first_name), ''),
          nullif(btrim(mp.display_name), ''),
          'Player'
        ) AS label
      FROM public.fan_team_members m2
      JOIN public.fan_managed_player_guardians g2
        ON g2.managed_player_id = m2.managed_player_id
       AND g2.guardian_user_id = me
       AND g2.revoked_at IS NULL
      JOIN public.fan_managed_players mp
        ON mp.id = m2.managed_player_id
       AND mp.archived_at IS NULL
      WHERE m2.team_id = t.id
        AND m2.managed_player_id IS NOT NULL
        AND m2.left_at IS NULL
    ) labeled
  ) via_names ON true
  WHERE t.is_active = true
  ORDER BY t.name ASC;
END;
$$;

COMMENT ON FUNCTION public.list_my_fan_teams() IS
  'Lists active Fan Teams for auth.uid(): direct account seats UNION Teams where '
  'an active managed player under this guardian has a seat. Deduped (account wins). '
  'access_via=account|managed_player. via_managed_player_names for home badges. '
  'Guardian-only avatar previews limited to own managed seats. '
  'Does not grant chat/manage rights for managed_player access.';

REVOKE ALL ON FUNCTION public.list_my_fan_teams() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_my_fan_teams() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_my_fan_teams() TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_my_fan_teams() TO service_role;

COMMIT;
