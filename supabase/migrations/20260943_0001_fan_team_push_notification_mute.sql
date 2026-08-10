-- =============================================================================
-- 20260943_0001 — Per-Team push notification mute (fan_team_members)
-- =============================================================================
-- Product:
--   Members may mute OUTSIDE-APP push for one Team without leaving the Team
--   and without changing global FanGeo notification prefs.
--
-- Model:
--   fan_team_members.push_notifications_muted boolean NOT NULL DEFAULT false
--   Soft-leave/rejoin keeps the membership PK row; mute persists on rejoin
--   (accept_fan_team_invitation ON CONFLICT only clears left_at / role / joined_at).
--
-- Rules:
--   • Non-critical Team pushes honor mute (Team Chat, Team-linked pickup change).
--   • Pending Team invitation push does NOT use this flag (invitee not a member).
--   • Critical lifecycle (Team deleted) IGNORES mute and still delivers.
--   • In-app chat, unread, roster, games, DMs are unaffected.
--
-- Do NOT apply from the agent. Apply manually after 20260942.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Column on membership (smallest fit; persists across soft rejoin)
-- ---------------------------------------------------------------------------
ALTER TABLE public.fan_team_members
  ADD COLUMN IF NOT EXISTS push_notifications_muted boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.fan_team_members.push_notifications_muted IS
  'When true, suppress non-critical Team-scoped APNs for this user+team. '
  'Persists across soft leave/rejoin. Does not affect in-app unread or DMs. '
  'Critical lifecycle pushes (Team deleted) ignore this flag.';

-- ---------------------------------------------------------------------------
-- 2) set_fan_team_notification_muted — actor-only, active membership
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_fan_team_notification_muted(
  p_team_id uuid,
  p_muted boolean
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_muted boolean := coalesce(p_muted, false);
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '42501';
  END IF;

  IF p_team_id IS NULL THEN
    RAISE EXCEPTION 'Team not found.' USING ERRCODE = 'P0002';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.fan_teams t
    WHERE t.id = p_team_id
      AND t.is_active = true
  ) THEN
    RAISE EXCEPTION 'Team not found.' USING ERRCODE = 'P0002';
  END IF;

  IF NOT public.is_active_fan_team_member(p_team_id, me) THEN
    RAISE EXCEPTION 'Not a Team member.' USING ERRCODE = '42501';
  END IF;

  UPDATE public.fan_team_members
  SET push_notifications_muted = v_muted
  WHERE team_id = p_team_id
    AND user_id = me
    AND left_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Not a Team member.' USING ERRCODE = '42501';
  END IF;

  RETURN v_muted;
END;
$$;

REVOKE ALL ON FUNCTION public.set_fan_team_notification_muted(uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_fan_team_notification_muted(uuid, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_fan_team_notification_muted(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_fan_team_notification_muted(uuid, boolean) TO service_role;

COMMENT ON FUNCTION public.set_fan_team_notification_muted(uuid, boolean) IS
  'Active member sets own Team push mute (auth.uid() only). Returns new muted state.';

-- ---------------------------------------------------------------------------
-- 3) list_my_fan_teams — include viewer mute (no N+1)
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
  push_notifications_muted boolean,
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
    coalesce(m.push_notifications_muted, false) AS push_notifications_muted,
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
  'Lists active Fan Teams for auth.uid(). Includes competition_level, '
  'pending_invitation_count (manager/owner), and push_notifications_muted for the viewer.';

REVOKE ALL ON FUNCTION public.list_my_fan_teams() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_my_fan_teams() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_my_fan_teams() TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_my_fan_teams() TO service_role;

COMMIT;

-- Manual verification (do not run from agent):
--   SELECT column_name FROM information_schema.columns
--   WHERE table_name = 'fan_team_members' AND column_name = 'push_notifications_muted';
--   SELECT push_notifications_muted FROM list_my_fan_teams() LIMIT 5;
--   SELECT set_fan_team_notification_muted('<team_id>'::uuid, true);
-- Deploy Edge (manual, after migration):
--   supabase functions deploy notify-chat-message --no-verify-jwt
--   supabase functions deploy notify-direct-message --no-verify-jwt
--   supabase functions deploy notify-pickup-game-change --no-verify-jwt
--   (notify-fan-team-deleted / notify-fan-team-invitation: comment-only; optional redeploy)
