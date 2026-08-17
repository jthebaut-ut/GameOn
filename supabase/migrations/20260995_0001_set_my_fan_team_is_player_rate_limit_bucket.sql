-- =============================================================================
-- 20260995_0001 — Allowlist `set_my_fan_team_is_player` in assert_rpc_rate_limit
-- =============================================================================
-- LIVE FAILURE (Remove Myself / set is_player=false):
--   HTTP 400
--   PostgREST code    = 22023
--   message           = rate limit rejected
--   detail / hint     = null
--
-- set_my_fan_team_is_player (20260984) starts with:
--   PERFORM public.assert_rpc_rate_limit('set_my_fan_team_is_player', 60, 3600);
--
-- Latest allowlist is 20260967. That rewrite (and every later migration
-- through 20260993) never added this bucket. Unknown buckets raise 22023
-- BEFORE the membership UPDATE — same class of bug as 20260963.
--
-- Owner / Manager / Member are all rejected identically. No row is written.
-- Inbox is not cleared. No Removed-from-Team notification is emitted.
--
-- This migration:
--   * Preserves 20260967 buckets and fixed-window semantics
--   * Adds ONLY the Team membership buckets introduced after 67 that already
--     call assert_rpc_rate_limit:
--       - set_my_fan_team_is_player          (20260984)  PROVEN this bug
--       - set_fan_team_member_permissions    (20260985/86/90) same hole
--       - set_fan_team_membership_role       (20260994) same hole when applied
--
-- Does NOT change set_my_fan_team_is_player body, constraints, or triggers.
-- Owner remains allowed to be access-only (is_player=false).
-- PREPARE ONLY — do not auto-apply. No Edge deploy.
-- =============================================================================

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regprocedure('public.assert_rpc_rate_limit(text,int,int)') IS NULL THEN
    v_missing := v_missing || ARRAY['assert_rpc_rate_limit(text,int,int)'];
  END IF;
  IF to_regprocedure('public.set_my_fan_team_is_player(uuid, boolean)') IS NULL THEN
    v_missing := v_missing || ARRAY['set_my_fan_team_is_player(uuid, boolean)'];
  END IF;
  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION
      '20260995_0001 prerequisite missing: %',
      array_to_string(v_missing, ', ');
  END IF;
END $$;

BEGIN;

CREATE OR REPLACE FUNCTION public.assert_rpc_rate_limit(
  p_bucket text,
  p_max int,
  p_window_seconds int
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_bucket text := nullif(btrim(coalesce(p_bucket, '')), '');
  v_window_start timestamptz;
  v_count int;
  v_allowed_buckets text[] := ARRAY[
    'send_direct_message',
    'send_group_message',
    'friendship_ensure_pending',
    'poke_profile',
    'report_group_message',
    'search_chat_conversations',
    'search_chat_messages',
    'create_fan_team',
    'invite_fan_team_members',
    'accept_fan_team_invitation',
    'decline_fan_team_invitation',
    'report_fan_team',
    'leave_fan_team',
    'delete_fan_team',
    'resend_fan_team_invitation',
    'create_managed_player',
    'update_managed_player',
    'add_managed_player_to_fan_team',
    'accept_fan_team_invitation_as_managed_player',
    'accept_fan_team_invitation_for_participants',
    'set_my_teams_profile_visibility',
    -- 20260984 Remove Myself / access-only account seat
    'set_my_fan_team_is_player',
    -- 20260985/86/90 Team Administrator permissions write
    'set_fan_team_member_permissions',
    -- 20260994 membership-scoped Team role (account + managed)
    'set_fan_team_membership_role'
  ];
BEGIN
  IF coalesce(auth.role(), '') = 'service_role' AND me IS NULL THEN
    RETURN;
  END IF;

  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF v_bucket IS NULL OR NOT (v_bucket = ANY (v_allowed_buckets)) THEN
    RAISE EXCEPTION 'rate limit rejected' USING ERRCODE = '22023';
  END IF;

  IF p_max IS NULL OR p_max < 1 OR p_max > 100000 THEN
    RAISE EXCEPTION 'rate limit rejected' USING ERRCODE = '22023';
  END IF;

  IF p_window_seconds IS NULL OR p_window_seconds < 1 OR p_window_seconds > 86400 THEN
    RAISE EXCEPTION 'rate limit rejected' USING ERRCODE = '22023';
  END IF;

  v_window_start := to_timestamp(
    floor(extract(epoch FROM now()) / p_window_seconds::double precision)
      * p_window_seconds::double precision
  );

  INSERT INTO public.rpc_rate_limits AS r (actor_uid, bucket, window_start, count)
  VALUES (me, v_bucket, v_window_start, 1)
  ON CONFLICT (actor_uid, bucket, window_start)
  DO UPDATE SET count = LEAST(r.count + 1, 1000000)
  RETURNING r.count INTO v_count;

  IF v_count > p_max THEN
    RAISE EXCEPTION 'rate_limit_exceeded'
      USING ERRCODE = '54000';
  END IF;

  IF (random() < 0.01) THEN
    DELETE FROM public.rpc_rate_limits
    WHERE window_start < (now() - interval '7 days');
  END IF;
END;
$$;

COMMENT ON FUNCTION public.assert_rpc_rate_limit(text, int, int) IS
  'SECURITY DEFINER fixed-window rate limit with allowlisted buckets. '
  '20260995 adds set_my_fan_team_is_player (Remove Myself) + related Team '
  'membership writes introduced after 20260967.';

DO $$
DECLARE
  v_src text;
BEGIN
  SELECT p.prosrc INTO v_src
  FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.assert_rpc_rate_limit(text,int,int)'::regprocedure;
  IF v_src IS NULL OR position('set_my_fan_team_is_player' IN v_src) = 0 THEN
    RAISE EXCEPTION '20260995 allowlist missing set_my_fan_team_is_player';
  END IF;
END $$;

COMMIT;
