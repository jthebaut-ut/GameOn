-- =============================================================================
-- 20260963_0001 — Allow managed-player buckets in assert_rpc_rate_limit
-- =============================================================================
-- ROOT CAUSE:
--   create_managed_player / update_managed_player / add_managed_player_to_fan_team /
--   accept_fan_team_invitation_as_managed_player call:
--
--     PERFORM public.assert_rpc_rate_limit('<bucket>', …);
--
--   but those bucket names were never added to assert_rpc_rate_limit's allowlist
--   (same class of bug as 20260927 create_fan_team).
--
--   Unknown buckets raise ERRCODE 22023:
--     RAISE EXCEPTION 'rate limit rejected'
--   BEFORE any per-user counter is consulted. So the FIRST Save on Add Player
--   fails with "rate limit rejected" even though the form is valid and the user
--   has never hit a real limit.
--
-- THIS MIGRATION:
--   Preserves ALL existing allowlisted buckets + fixed-window semantics.
--   Adds ONLY the four managed-player buckets introduced in 20260960.
--
-- Limits (unchanged intent from 20260960 call sites; per auth.uid(), not global):
--   create_managed_player                         20 / 3600s
--   update_managed_player                         60 / 3600s
--   add_managed_player_to_fan_team                 30 / 3600s
--   accept_fan_team_invitation_as_managed_player   60 / 3600s
--
-- Do NOT apply from the agent; review and apply deliberately in Supabase.
-- =============================================================================

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
    -- 20260960 managed-player buckets (missing until this migration)
    'create_managed_player',
    'update_managed_player',
    'add_managed_player_to_fan_team',
    'accept_fan_team_invitation_as_managed_player'
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
  'SECURITY DEFINER fixed-window rate limit with allowlisted buckets '
  '(includes Fan Team + managed-player buckets). Raises generic 54000 '
  'rate_limit_exceeded when over limit; 22023 rate limit rejected for '
  'unknown buckets / bad args. Not granted to authenticated clients.';

REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM anon;
REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.assert_rpc_rate_limit(text, int, int) TO service_role;

DO $$
DECLARE
  v_src text;
BEGIN
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE oid = to_regprocedure('public.assert_rpc_rate_limit(text,int,int)');

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'assert_failed: assert_rpc_rate_limit missing';
  END IF;
  IF position('''create_managed_player''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'assert_failed: create_managed_player bucket missing from allowlist';
  END IF;
  IF position('''update_managed_player''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'assert_failed: update_managed_player bucket missing from allowlist';
  END IF;
  IF position('''add_managed_player_to_fan_team''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'assert_failed: add_managed_player_to_fan_team bucket missing';
  END IF;
  IF position('''accept_fan_team_invitation_as_managed_player''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'assert_failed: accept_fan_team_invitation_as_managed_player bucket missing';
  END IF;
  -- Preserve prior Fan Team buckets
  IF position('''create_fan_team''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'assert_failed: create_fan_team bucket regress';
  END IF;
  IF position('''resend_fan_team_invitation''' IN v_src) = 0 THEN
    RAISE EXCEPTION 'assert_failed: resend_fan_team_invitation bucket regress';
  END IF;
END $$;

COMMIT;

-- =============================================================================
-- MANUAL APPLY NOTES
-- =============================================================================
-- 1) Apply AFTER 20260960 (and ideally after 20260961/20260962 if those are queued).
-- 2) Verify:
--      SELECT prosrc ILIKE '%create_managed_player%'
--        FROM pg_proc
--       WHERE oid = 'public.assert_rpc_rate_limit(text,integer,integer)'::regprocedure;
-- 3) Then retry Add Player Save — should succeed (or raise a real validation error).
-- =============================================================================
