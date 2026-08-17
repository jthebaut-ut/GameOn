-- =============================================================================
-- 20260985_0001 — Flexible Team permissions (role + Owner-granted)
-- =============================================================================
-- Product: keep roles simple; Owner may grant/revoke management permissions
-- per account seat. Managers cannot elevate others.
--
-- Defaults match TODAY's role behavior (backward compatible).
-- Owner always has all permissions (enforced in resolution helpers).
--
-- PREPARE ONLY — do not auto-apply.
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
  IF to_regprocedure('public.list_fan_team_members(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['list_fan_team_members(uuid)'];
  END IF;
  IF to_regprocedure('public.list_my_fan_teams()') IS NULL THEN
    v_missing := v_missing || ARRAY['list_my_fan_teams()'];
  END IF;
  IF to_regprocedure('public.fan_team_viewer_can_manage(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_team_viewer_can_manage(uuid)'];
  END IF;
  IF to_regprocedure('public.fan_team_viewer_can_organize(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_team_viewer_can_organize(uuid)'];
  END IF;
  IF to_regprocedure('public.fan_team_viewer_can_manage_lineup(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_team_viewer_can_manage_lineup(uuid)'];
  END IF;
  IF to_regprocedure('public.assert_rpc_rate_limit(text,int,int)') IS NULL THEN
    v_missing := v_missing || ARRAY['assert_rpc_rate_limit(text,int,int)'];
  END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION
      '20260985_0001 prerequisites missing: %',
      array_to_string(v_missing, ', ');
  END IF;
END $$;

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Columns
-- -----------------------------------------------------------------------------
ALTER TABLE public.fan_team_members
  ADD COLUMN IF NOT EXISTS granted_permissions jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE public.fan_team_members
  ADD COLUMN IF NOT EXISTS use_custom_permissions boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.fan_team_members.granted_permissions IS
  'Owner-custom permission keys (jsonb string array). Used only when use_custom_permissions.';
COMMENT ON COLUMN public.fan_team_members.use_custom_permissions IS
  'When false, effective permissions = role defaults. When true, = granted_permissions.';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fan_team_members_granted_permissions_is_array_ck'
  ) THEN
    ALTER TABLE public.fan_team_members
      ADD CONSTRAINT fan_team_members_granted_permissions_is_array_ck
      CHECK (jsonb_typeof(granted_permissions) = 'array');
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2) Catalog + resolution helpers
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_team_permission_keys()
RETURNS text[]
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  SELECT ARRAY[
    'create_events',
    'edit_events',
    'publish_announcements',
    'invite_members',
    'manage_roster',
    'manage_lineups',
    'manage_managed_players',
    'edit_team_information',
    'moderate_team_chat'
  ]::text[];
$$;

CREATE OR REPLACE FUNCTION public.fan_team_role_default_permissions(p_role text)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  SELECT CASE lower(btrim(coalesce(p_role, 'member')))
    WHEN 'owner' THEN public.fan_team_permission_keys()
    WHEN 'manager' THEN ARRAY[
      'create_events', 'edit_events', 'publish_announcements', 'invite_members',
      'manage_roster', 'manage_lineups', 'manage_managed_players',
      'edit_team_information', 'moderate_team_chat'
    ]::text[]
    WHEN 'head_coach' THEN ARRAY['create_events', 'manage_lineups']::text[]
    WHEN 'assistant_coach' THEN ARRAY['manage_lineups']::text[]
    ELSE ARRAY[]::text[]
  END;
$$;

CREATE OR REPLACE FUNCTION public.fan_team_normalize_permission_keys(p_keys jsonb)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_allow text[] := public.fan_team_permission_keys();
  v_elem text;
  v_out text[] := ARRAY[]::text[];
BEGIN
  IF p_keys IS NULL OR jsonb_typeof(p_keys) <> 'array' THEN
    RETURN ARRAY[]::text[];
  END IF;
  FOR v_elem IN
    SELECT jsonb_array_elements_text(p_keys)
  LOOP
    v_elem := lower(btrim(v_elem));
    IF v_elem = ANY (v_allow) AND NOT (v_elem = ANY (v_out)) THEN
      v_out := array_append(v_out, v_elem);
    END IF;
  END LOOP;
  RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION public.fan_team_effective_permissions(
  p_role text,
  p_use_custom boolean,
  p_granted jsonb
)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  SELECT CASE
    WHEN lower(btrim(coalesce(p_role, ''))) = 'owner'
      THEN public.fan_team_permission_keys()
    WHEN coalesce(p_use_custom, false)
      THEN public.fan_team_normalize_permission_keys(p_granted)
    ELSE public.fan_team_role_default_permissions(p_role)
  END;
$$;

CREATE OR REPLACE FUNCTION public.fan_team_viewer_has_permission(
  p_team_id uuid,
  p_permission text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := (SELECT auth.uid());
  v_role text;
  v_custom boolean;
  v_granted jsonb;
  v_key text := lower(btrim(coalesce(p_permission, '')));
  v_effective text[];
BEGIN
  IF me IS NULL OR p_team_id IS NULL OR v_key = '' THEN
    RETURN false;
  END IF;

  SELECT m.role, m.use_custom_permissions, m.granted_permissions
  INTO v_role, v_custom, v_granted
  FROM public.fan_team_members m
  WHERE m.team_id = p_team_id
    AND m.user_id = me
    AND m.left_at IS NULL
  LIMIT 1;

  IF v_role IS NULL THEN
    RETURN false;
  END IF;

  v_effective := public.fan_team_effective_permissions(v_role, v_custom, v_granted);
  RETURN v_key = ANY (v_effective);
END;
$$;

COMMENT ON FUNCTION public.fan_team_viewer_has_permission(uuid, text) IS
  'True when the authenticated account seat has the permission (role defaults or Owner custom).';

REVOKE ALL ON FUNCTION public.fan_team_viewer_has_permission(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fan_team_viewer_has_permission(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.fan_team_viewer_has_permission(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_viewer_has_permission(uuid, text) TO service_role;

-- -----------------------------------------------------------------------------
-- 3) Widen existing authorization helpers (backward-compatible names)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_team_viewer_can_organize(p_team_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT public.fan_team_viewer_has_permission(p_team_id, 'create_events');
$$;

CREATE OR REPLACE FUNCTION public.fan_team_viewer_can_manage_lineup(p_team_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT public.fan_team_viewer_has_permission(p_team_id, 'manage_lineups');
$$;

-- Broad "manage" used by invite/roster/identity/announce RPCs.
-- True for classic Owner/Manager OR any of the management permission keys.
CREATE OR REPLACE FUNCTION public.fan_team_viewer_can_manage(p_team_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT
    public.fan_team_viewer_has_permission(p_team_id, 'invite_members')
    OR public.fan_team_viewer_has_permission(p_team_id, 'manage_roster')
    OR public.fan_team_viewer_has_permission(p_team_id, 'publish_announcements')
    OR public.fan_team_viewer_has_permission(p_team_id, 'edit_team_information')
    OR public.fan_team_viewer_has_permission(p_team_id, 'manage_managed_players')
    OR public.fan_team_viewer_has_permission(p_team_id, 'edit_events')
    OR public.fan_team_viewer_has_permission(p_team_id, 'moderate_team_chat');
$$;

-- -----------------------------------------------------------------------------
-- 4) Owner-only set permissions RPC
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_fan_team_member_permissions(
  p_team_id uuid,
  p_membership_id uuid,
  p_permissions jsonb
)
RETURNS text[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := (SELECT auth.uid());
  v_owner uuid;
  v_target_role text;
  v_target_user uuid;
  v_target_managed uuid;
  v_keys text[];
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '42501';
  END IF;
  IF p_team_id IS NULL OR p_membership_id IS NULL THEN
    RAISE EXCEPTION 'Team and membership are required.';
  END IF;

  PERFORM public.assert_rpc_rate_limit('set_fan_team_member_permissions', 60, 3600);

  SELECT t.owner_user_id INTO v_owner
  FROM public.fan_teams t
  WHERE t.id = p_team_id
    AND t.is_active IS TRUE;

  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Team is no longer available.';
  END IF;
  IF v_owner IS DISTINCT FROM me THEN
    RAISE EXCEPTION 'Only the Team Owner can manage permissions.' USING ERRCODE = '42501';
  END IF;

  SELECT m.role, m.user_id, m.managed_player_id
  INTO v_target_role, v_target_user, v_target_managed
  FROM public.fan_team_members m
  WHERE m.membership_id = p_membership_id
    AND m.team_id = p_team_id
    AND m.left_at IS NULL
  FOR UPDATE;

  IF v_target_role IS NULL THEN
    RAISE EXCEPTION 'Member not found.';
  END IF;
  IF v_target_managed IS NOT NULL THEN
    RAISE EXCEPTION 'Managed player seats do not receive account permissions.';
  END IF;
  IF lower(btrim(v_target_role)) = 'owner' THEN
    RAISE EXCEPTION 'Owner permissions cannot be changed.';
  END IF;
  IF v_target_user IS NOT DISTINCT FROM me THEN
    RAISE EXCEPTION 'Owner permissions cannot be changed.';
  END IF;

  v_keys := public.fan_team_normalize_permission_keys(p_permissions);

  UPDATE public.fan_team_members
  SET granted_permissions = to_jsonb(v_keys),
      use_custom_permissions = true
  WHERE membership_id = p_membership_id
    AND left_at IS NULL;

  -- Keep Team Chat admin flag aligned with moderate_team_chat when conversation exists.
  UPDATE public.group_conversation_members gcm
  SET role = CASE
        WHEN 'moderate_team_chat' = ANY (v_keys) THEN 'admin'
        ELSE 'member'
      END
  FROM public.fan_teams t
  WHERE t.id = p_team_id
    AND gcm.conversation_id = t.group_conversation_id
    AND gcm.user_id = v_target_user;

  RETURN v_keys;
END;
$$;

COMMENT ON FUNCTION public.set_fan_team_member_permissions(uuid, uuid, jsonb) IS
  'Owner-only: set custom permission keys for an account seat. '
  'Does not change role. Owner target rejected. Syncs chat admin from moderate_team_chat.';

REVOKE ALL ON FUNCTION public.set_fan_team_member_permissions(uuid, uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_fan_team_member_permissions(uuid, uuid, jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_fan_team_member_permissions(uuid, uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_fan_team_member_permissions(uuid, uuid, jsonb) TO service_role;

-- -----------------------------------------------------------------------------
-- 5) list_fan_team_members — emit permission fields
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
  is_player boolean,
  use_custom_permissions boolean,
  granted_permissions text[],
  effective_permissions text[]
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
    CASE WHEN coalesce(m.is_player, true) THEN m.player_number ELSE NULL END,
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
    CASE WHEN coalesce(m.is_player, true) THEN m.preferred_position_code ELSE NULL END,
    coalesce(m.is_player, true),
    coalesce(m.use_custom_permissions, false),
    public.fan_team_normalize_permission_keys(m.granted_permissions),
    public.fan_team_effective_permissions(
      m.role,
      coalesce(m.use_custom_permissions, false),
      m.granted_permissions
    )
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

REVOKE ALL ON FUNCTION public.list_fan_team_members(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_fan_team_members(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.list_fan_team_members(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_fan_team_members(uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 6) list_my_fan_teams — add my_permissions (effective for viewer)
-- -----------------------------------------------------------------------------
-- Additive OUT column requires DROP + CREATE. Preserve 20260984 body + my_permissions.

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
  via_managed_player_names text[],
  my_permissions text[]
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
      0 AS priority,
      public.fan_team_effective_permissions(
        m.role,
        coalesce(m.use_custom_permissions, false),
        m.granted_permissions
      ) AS my_permissions
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
      1 AS priority,
      ARRAY[]::text[] AS my_permissions
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
        SELECT 1 FROM account_seats a WHERE a.team_id = m.team_id
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
      s.access_via,
      s.my_permissions
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
    CASE
      WHEN to_regprocedure('public.fan_team_active_player_count(uuid)') IS NOT NULL
        THEN public.fan_team_active_player_count(t.id)
      ELSE (
        SELECT count(*)::integer
        FROM public.fan_team_members am
        WHERE am.team_id = t.id
          AND am.left_at IS NULL
      )
    END AS member_count,
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
    coalesce(via_names.names, ARRAY[]::text[]) AS via_managed_player_names,
    coalesce(b.my_permissions, ARRAY[]::text[]) AS my_permissions
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
        AND coalesce(am.is_player, true) IS TRUE
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
  'Lists viewer Teams with my_permissions (effective). member_count prefers player seats when 20260984 is applied.';

REVOKE ALL ON FUNCTION public.list_my_fan_teams() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_my_fan_teams() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_my_fan_teams() TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_my_fan_teams() TO service_role;

COMMIT;
