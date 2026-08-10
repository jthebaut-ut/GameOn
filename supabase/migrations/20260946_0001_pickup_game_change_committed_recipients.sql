-- =============================================================================
-- 20260946_0001 — Pickup game-change push: committed / RSVP recipients
-- =============================================================================
-- Extends 20260911 list_pickup_game_change_push_tokens.
--
-- Authoritative Team RSVP mapping (set_fan_team_game_rsvp):
--   going   → pickup_game_requests.status = 'approved'
--   maybe   → pickup_game_requests.status = 'pending'
--   cant_go → pickup_game_requests.status = 'withdrawn'
--
-- Product rules for schedule/location (and other meaningful edit) pushes:
--   • Normal Pickup: approved joiners only (NOT pending join requests)
--   • Team-linked: approved (Going) + pending (Maybe); withdrawn/cant_go excluded
--   • Invites: accepted + maybe only (NOT unanswered pending invites)
--   • Editor excluded; prefs / bans / deleted gates unchanged
--
-- Do NOT apply from the agent. Apply manually after 20260945.
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
  affected AS (
    -- Approved / Going participants (normal + Team).
    SELECT r.requester_user_id AS uid
    FROM public.pickup_game_requests r
    WHERE r.pickup_game_id = p_pickup_game_id
      AND lower(btrim(r.status)) = 'approved'

    UNION

    -- Team-linked Maybe RSVP is stored as request status = pending.
    -- Normal Pickup pending join requests are NOT notified (not committed).
    SELECT r.requester_user_id AS uid
    FROM public.pickup_game_requests r
    CROSS JOIN team_linked t
    WHERE r.pickup_game_id = p_pickup_game_id
      AND t.is_linked
      AND lower(btrim(r.status)) = 'pending'

    UNION

    -- Outside / private invitees who committed or marked maybe.
    SELECT i.invitee_user_id AS uid
    FROM public.pickup_game_invites i
    WHERE i.pickup_game_id = p_pickup_game_id
      AND lower(btrim(i.status)) IN ('accepted', 'maybe')
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
  'Service-role token list for pickup edit pushes. Approved (+ Team-linked Maybe/pending) '
  'request participants and accepted/maybe invitees; excludes editor, unanswered pending '
  'invites, withdrawn/rejected, prefs-off, banned, and deleted users. Returns ALL active '
  'tokens per user (multi-device).';

COMMIT;

-- Manual verification:
--   SELECT prosrc LIKE '%fan_team_game_links%'
--   FROM pg_proc WHERE proname = 'list_pickup_game_change_push_tokens';
-- Redeploy Edge (multi-device + mute ledger + copy):
--   supabase functions deploy notify-pickup-game-change --no-verify-jwt
