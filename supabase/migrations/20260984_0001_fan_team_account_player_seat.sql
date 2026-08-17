-- =============================================================================
-- 20260984_0001 — Account access vs player seat (`is_player`)
-- =============================================================================
-- Product: a FanGeo account can hold Team access (chat / manage / guardian ops)
-- without the account owner being a rostered *player*.
--
-- Concepts (independently representable):
--   1) Account Team access  → active fan_team_members row with user_id = me
--   2) Myself player seat   → that row with is_player = true
--   3) Managed player seat  → active row with managed_player_id (always is_player)
--
-- Backward compatible: DEFAULT true — existing seats remain players until toggled.
-- PREPARE ONLY — do not auto-apply.
--
-- Does NOT:
--   - remove existing memberships
--   - change leave_fan_team / ownership
--   - invent a second membership system
-- =============================================================================

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.fan_team_members') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_team_members'];
  END IF;
  IF to_regclass('public.fan_teams') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_teams'];
  END IF;
  IF to_regclass('public.fan_team_event_lineup_members') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_team_event_lineup_members'];
  END IF;
  IF to_regprocedure('public.list_fan_team_members(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['list_fan_team_members(uuid)'];
  END IF;
  IF to_regprocedure('public.list_my_fan_teams()') IS NULL THEN
    v_missing := v_missing || ARRAY['list_my_fan_teams()'];
  END IF;
  IF to_regprocedure('public.is_active_fan_team_member(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['is_active_fan_team_member(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.is_active_fan_team_managed_member(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['is_active_fan_team_managed_member(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.fan_team_viewer_can_access_team(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_team_viewer_can_access_team(uuid)'];
  END IF;
  IF to_regprocedure('public.assert_rpc_rate_limit(text,int,int)') IS NULL THEN
    v_missing := v_missing || ARRAY['assert_rpc_rate_limit(text,int,int)'];
  END IF;
  IF to_regprocedure('public.fan_team_role_is_manager_or_owner(text)') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_team_role_is_manager_or_owner(text)'];
  END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION
      '20260984_0001 prerequisites missing: %',
      array_to_string(v_missing, ', ');
  END IF;
END $$;

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Column + constraints
-- -----------------------------------------------------------------------------
ALTER TABLE public.fan_team_members
  ADD COLUMN IF NOT EXISTS is_player boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.fan_team_members.is_player IS
  'True when this seat is a rostered player (lineup / jersey / player attendance). '
  'False = account access only (chat/manage/guardian) without being a player. '
  'Managed-player seats are always players.';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'fan_team_members_managed_is_player_ck'
  ) THEN
    ALTER TABLE public.fan_team_members
      ADD CONSTRAINT fan_team_members_managed_is_player_ck
      CHECK (managed_player_id IS NULL OR is_player IS TRUE);
  END IF;
END $$;

UPDATE public.fan_team_members
SET is_player = true
WHERE managed_player_id IS NOT NULL
  AND is_player IS DISTINCT FROM true;

CREATE OR REPLACE FUNCTION public.fan_team_members_force_managed_is_player()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NEW.managed_player_id IS NOT NULL THEN
    NEW.is_player := true;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS fan_team_members_force_managed_is_player_trg
  ON public.fan_team_members;
CREATE TRIGGER fan_team_members_force_managed_is_player_trg
  BEFORE INSERT OR UPDATE OF managed_player_id, is_player
  ON public.fan_team_members
  FOR EACH ROW
  EXECUTE FUNCTION public.fan_team_members_force_managed_is_player();

-- -----------------------------------------------------------------------------
-- 2) Helpers
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_active_fan_team_player_member(
  p_team_id uuid,
  p_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.fan_team_members m
    WHERE m.team_id = p_team_id
      AND m.user_id = p_user_id
      AND m.left_at IS NULL
      AND m.is_player IS TRUE
  );
$$;

COMMENT ON FUNCTION public.is_active_fan_team_player_member(uuid, uuid) IS
  'True when the account holds an active *player* seat (is_player). '
  'Access-only seats return false; use is_active_fan_team_member for access.';

REVOKE ALL ON FUNCTION public.is_active_fan_team_player_member(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_active_fan_team_player_member(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.is_active_fan_team_player_member(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.is_active_fan_team_player_member(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.fan_team_active_player_count(p_team_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT count(*)::integer
  FROM public.fan_team_members m
  WHERE m.team_id = p_team_id
    AND m.left_at IS NULL
    AND m.is_player IS TRUE;
$$;

COMMENT ON FUNCTION public.fan_team_active_player_count(uuid) IS
  'Active rostered player seats (is_player). Excludes access-only account seats.';

REVOKE ALL ON FUNCTION public.fan_team_active_player_count(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fan_team_active_player_count(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.fan_team_active_player_count(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_active_player_count(uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 3) set_my_fan_team_is_player — toggle Myself without leaving the Team
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_my_fan_team_is_player(
  p_team_id uuid,
  p_is_player boolean
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := (SELECT auth.uid());
  v_membership_id uuid;
  v_was_player boolean;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '42501';
  END IF;
  IF p_team_id IS NULL THEN
    RAISE EXCEPTION 'Team is required.';
  END IF;
  IF p_is_player IS NULL THEN
    RAISE EXCEPTION 'is_player is required.';
  END IF;

  PERFORM public.assert_rpc_rate_limit('set_my_fan_team_is_player', 60, 3600);

  SELECT m.membership_id, m.is_player
  INTO v_membership_id, v_was_player
  FROM public.fan_team_members m
  WHERE m.team_id = p_team_id
    AND m.user_id = me
    AND m.left_at IS NULL
  FOR UPDATE;

  IF v_membership_id IS NULL THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  IF v_was_player IS NOT DISTINCT FROM p_is_player THEN
    RETURN p_is_player;
  END IF;

  IF p_is_player THEN
    UPDATE public.fan_team_members
    SET is_player = true
    WHERE membership_id = v_membership_id
      AND left_at IS NULL;
  ELSE
    UPDATE public.fan_team_members
    SET is_player = false,
        player_number = NULL,
        preferred_position_code = NULL
    WHERE membership_id = v_membership_id
      AND left_at IS NULL;

    -- Remove from near-future / upcoming Team event lineups only.
    DELETE FROM public.fan_team_event_lineup_members lm
    USING public.fan_team_event_lineups l
    JOIN public.pickup_games pg ON pg.id = l.pickup_game_id
    WHERE lm.lineup_id = l.id
      AND l.team_id = p_team_id
      AND lm.user_id = me
      AND pg.game_start_at >= pg_catalog.now() - interval '2 hours';
  END IF;

  -- No removed_from_team / member-left push: account access remains.
  RETURN p_is_player;
END;
$$;

COMMENT ON FUNCTION public.set_my_fan_team_is_player(uuid, boolean) IS
  'Toggle whether the caller''s account seat is a player on the Team. '
  'Does not leave the Team, revoke role, or remove guardian/manager access. '
  'Demotion clears jersey/position and future lineup rows. No membership-left push.';

REVOKE ALL ON FUNCTION public.set_my_fan_team_is_player(uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_my_fan_team_is_player(uuid, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_my_fan_team_is_player(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_my_fan_team_is_player(uuid, boolean) TO service_role;

-- -----------------------------------------------------------------------------
-- 4) list_fan_team_members — emit is_player (+ preferred_position_code)
-- -----------------------------------------------------------------------------
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
  membership_id uuid,
  managed_player_id uuid,
  is_managed_player boolean,
  guardian_display_name text,
  preferred_position_code text,
  is_player boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := (SELECT auth.uid());
  v_can_manage boolean;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_team_id IS NULL OR NOT public.fan_team_viewer_can_access_team(p_team_id) THEN
    RAISE EXCEPTION 'Not a team member.';
  END IF;

  v_can_manage := public.fan_team_viewer_can_manage(p_team_id);

  RETURN QUERY
  SELECT
    m.user_id,
    m.role,
    m.joined_at,
    CASE
      WHEN m.managed_player_id IS NOT NULL
        THEN coalesce(nullif(btrim(mp.display_name), ''), 'Player')
      ELSE coalesce(nullif(btrim(p.display_name), ''), 'Fan')
    END::text,
    p.username,
    CASE WHEN m.managed_player_id IS NOT NULL THEN mp.avatar_url ELSE p.avatar_url END,
    CASE
      WHEN m.managed_player_id IS NOT NULL THEN mp.avatar_thumbnail_url
      ELSE p.avatar_thumbnail_url
    END,
    CASE
      WHEN m.managed_player_id IS NOT NULL THEN NULL
      WHEN p.activity_status_visible IS FALSE THEN NULL
      ELSE p.last_seen_at::text
    END AS last_seen_at,
    CASE WHEN m.is_player THEN m.player_number ELSE NULL END,
    CASE WHEN m.managed_player_id IS NOT NULL THEN NULL ELSE p.gender END,
    m.membership_id,
    m.managed_player_id,
    (m.managed_player_id IS NOT NULL),
    CASE
      WHEN m.managed_player_id IS NOT NULL
        AND (
          v_can_manage
          OR public.is_authorized_managed_player_guardian(m.managed_player_id, me)
        )
        THEN (
          SELECT coalesce(nullif(btrim(gp.display_name), ''), 'Guardian')
          FROM public.fan_managed_player_guardians g
          JOIN public.user_profiles gp ON gp.id = g.guardian_user_id
          WHERE g.managed_player_id = m.managed_player_id
            AND g.revoked_at IS NULL
          ORDER BY (g.role = 'primary_guardian') DESC, g.created_at ASC
          LIMIT 1
        )
      ELSE NULL
    END::text,
    CASE WHEN m.is_player THEN m.preferred_position_code ELSE NULL END,
    m.is_player
  FROM public.fan_team_members m
  LEFT JOIN public.user_profiles p ON p.id = m.user_id
  LEFT JOIN public.fan_managed_players mp ON mp.id = m.managed_player_id
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
    lower(coalesce(mp.display_name, p.display_name, p.username, '')) ASC;
END;
$$;

COMMENT ON FUNCTION public.list_fan_team_members(uuid) IS
  'Active Team seats with is_player. Player attrs null when access-only. '
  'Access-only account seats remain listed for leadership/access.';

REVOKE ALL ON FUNCTION public.list_fan_team_members(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_fan_team_members(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.list_fan_team_members(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_fan_team_members(uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 5) list_my_fan_teams — member_count = player seats; previews = players
-- -----------------------------------------------------------------------------
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
    public.fan_team_active_player_count(t.id) AS member_count,
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
        AND am.is_player IS TRUE
        AND (
          b.access_via = 'account'
          OR (
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
  'Lists active Fan Teams for auth.uid() (account OR guardian-managed access). '
  'member_count = active is_player seats only (access-only account seats excluded). '
  'Avatar previews limited to player seats. access_via unchanged.';

REVOKE ALL ON FUNCTION public.list_my_fan_teams() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_my_fan_teams() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_my_fan_teams() TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_my_fan_teams() TO service_role;

-- -----------------------------------------------------------------------------
-- 6) Lineup — require player seat for account identities (trigger; keeps 20260961 RPC)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_team_event_lineup_members_require_player_seat()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_team_id uuid;
BEGIN
  SELECT l.team_id INTO v_team_id
  FROM public.fan_team_event_lineups l
  WHERE l.id = NEW.lineup_id;

  IF v_team_id IS NULL THEN
    RAISE EXCEPTION 'Lineup not found.';
  END IF;

  IF NEW.user_id IS NOT NULL THEN
    IF NOT public.is_active_fan_team_player_member(v_team_id, NEW.user_id) THEN
      RAISE EXCEPTION 'Lineup player is not an active Team player.';
    END IF;
  ELSIF NEW.managed_player_id IS NOT NULL THEN
    IF NOT public.is_active_fan_team_managed_member(v_team_id, NEW.managed_player_id) THEN
      RAISE EXCEPTION 'Lineup player is not an active Team member.';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS fan_team_event_lineup_members_require_player_seat_trg
  ON public.fan_team_event_lineup_members;
CREATE TRIGGER fan_team_event_lineup_members_require_player_seat_trg
  BEFORE INSERT OR UPDATE OF user_id, managed_player_id, lineup_id
  ON public.fan_team_event_lineup_members
  FOR EACH ROW
  EXECUTE FUNCTION public.fan_team_event_lineup_members_require_player_seat();

COMMIT;
