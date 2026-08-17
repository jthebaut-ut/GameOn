-- =============================================================================
-- 20260954_0001 — Team Event change push: include active Team members
-- =============================================================================
-- Extends 20260946 list_pickup_game_change_push_tokens.
--
-- CODE-PROVEN ROOT CAUSE (physical two-iPhone failure):
--   Team-linked schedule/location edit pushes only selected:
--     • pickup_game_requests approved (Going)
--     • pickup_game_requests pending when Team-linked (Maybe)
--     • pickup_game_invites accepted/maybe
--   Active fan_team_members were NEVER included.
--   Members with No Response (no request row) or Can't Go (withdrawn) received
--   no APNS alert even though the event update + update_event work item fired.
--
-- Product rules AFTER this migration (20260946):
--   Team-linked: Going + Maybe only; Can't Go / No Response excluded
--
-- Product rules AFTER this migration (this file):
--   Standalone Pickup: unchanged (approved joiners + accepted/maybe invites)
--   Team-linked:
--     • ALL active fan_team_members for linked Team(s) (RSVP-independent)
--     • PLUS outside approved joiners / accepted-maybe invitees (recruit path)
--     • Editor still excluded via p_exclude_user_id
--     • Prefs / ban / deleted gates unchanged
--     • Per-Team push mute remains enforced in notify-pickup-game-change Edge
--
-- Meaningful-change detection (game_start_at / end_time / location / status / …)
-- is unchanged — already covers date/time/location/cancel.
--
-- Do NOT apply from the agent. Apply manually after 20260953.
-- Redeploy Edge after apply:
--   supabase functions deploy notify-pickup-game-change --no-verify-jwt
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.list_pickup_game_change_push_tokens(
  p_pickup_game_id uuid,
  p_exclude_user_id uuid
)
RETURNS TABLE (
  token_id uuid,
  user_id uuid,
  token text,
  environment text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH team_linked AS (
    SELECT EXISTS (
      SELECT 1
      FROM public.fan_team_game_links l
      WHERE l.pickup_game_id = p_pickup_game_id
    ) AS is_linked
  ),
  linked_teams AS (
    SELECT DISTINCT l.team_id
    FROM public.fan_team_game_links l
    INNER JOIN public.fan_teams t
      ON t.id = l.team_id
     AND t.is_active = true
    WHERE l.pickup_game_id = p_pickup_game_id
  ),
  affected AS (
    -- Approved / Going participants (standalone + Team + outside recruits).
    SELECT r.requester_user_id AS uid
    FROM public.pickup_game_requests r
    WHERE r.pickup_game_id = p_pickup_game_id
      AND lower(btrim(r.status)) = 'approved'

    UNION

    -- Team-linked Maybe RSVP is stored as request status = pending.
    -- Standalone Pickup pending join requests are NOT notified (not committed).
    SELECT r.requester_user_id AS uid
    FROM public.pickup_game_requests r
    CROSS JOIN team_linked tl
    WHERE r.pickup_game_id = p_pickup_game_id
      AND tl.is_linked
      AND lower(btrim(r.status)) = 'pending'

    UNION

    -- Outside / private invitees who committed or marked maybe.
    SELECT i.invitee_user_id AS uid
    FROM public.pickup_game_invites i
    WHERE i.pickup_game_id = p_pickup_game_id
      AND lower(btrim(i.status)) IN ('accepted', 'maybe')

    UNION

    -- Team-linked: every ACTIVE Team member (Going / Maybe / Can't Go / No Response).
    -- Do not require an RSVP / request row. Soft-left members excluded.
    SELECT m.user_id AS uid
    FROM public.fan_team_members m
    INNER JOIN linked_teams lt ON lt.team_id = m.team_id
    WHERE m.left_at IS NULL
  )
  SELECT DISTINCT ON (t.user_id, t.token, t.environment)
    t.id AS token_id,
    t.user_id,
    t.token,
    t.environment
  FROM public.user_push_tokens t
  INNER JOIN affected a ON a.uid = t.user_id
  LEFT JOIN public.user_notification_preferences p ON p.user_id = t.user_id
  LEFT JOIN public.user_profiles up ON up.id = t.user_id
  WHERE t.is_active = true
    AND (p_exclude_user_id IS NULL OR t.user_id IS DISTINCT FROM p_exclude_user_id)
    AND COALESCE(p.pickup_game_change_notifications_enabled, true) = true
    AND up.deleted_at IS NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.user_bans ub
      WHERE ub.user_id = t.user_id
        AND public.is_user_ban_active(ub.expires_at, ub.lifted_at)
    )
  ORDER BY t.user_id, t.token, t.environment, t.last_seen_at DESC NULLS LAST;
$$;

REVOKE ALL ON FUNCTION public.list_pickup_game_change_push_tokens(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_pickup_game_change_push_tokens(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.list_pickup_game_change_push_tokens(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.list_pickup_game_change_push_tokens(uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.list_pickup_game_change_push_tokens(uuid, uuid) IS
  'Service-role tokens for pickup/Team-event edit pushes. Standalone: approved + accepted/maybe '
  'invites. Team-linked: ALL active fan_team_members (RSVP-independent) plus outside approved/'
  'accepted-maybe; excludes editor, prefs-off, banned, deleted. Multi-device: all active tokens. '
  'Team push mute enforced in notify-pickup-game-change Edge (not this SQL).';

COMMIT;

-- Manual verification (staging):
--   SELECT prosrc LIKE '%fan_team_members%' AND prosrc LIKE '%linked_teams%'
--   FROM pg_proc WHERE proname = 'list_pickup_game_change_push_tokens';
--
--   -- For a Team-linked pickup_game_id, active member with No Response must appear:
--   SELECT COUNT(*) FROM list_pickup_game_change_push_tokens('<pickup_id>', '<editor_id>');
--
-- Redeploy:
--   supabase functions deploy notify-pickup-game-change --no-verify-jwt
