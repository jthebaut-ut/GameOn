-- =============================================================================
-- 20260927_0001 — Allow create_fan_team in assert_rpc_rate_limit allowlist
-- =============================================================================
-- Production assert_rpc_rate_limit rejects unknown buckets with ERRCODE 22023
-- ("rate limit rejected"). My Teams create_fan_team correctly calls:
--
--   PERFORM public.assert_rpc_rate_limit('create_fan_team', 20, 3600);
--
-- but 'create_fan_team' was never added to the allowlist.
--
-- This migration preserves ALL existing buckets and rate-limit semantics, and
-- ONLY adds 'create_fan_team'.
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
    'create_fan_team'
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
  'SECURITY DEFINER fixed-window rate limit with allowlisted buckets (includes search_chat_* and create_fan_team). Raises generic 54000 rate_limit_exceeded. Not granted to authenticated clients.';

REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM anon;
REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.assert_rpc_rate_limit(text, int, int) TO service_role;

COMMIT;

-- =============================================================================
-- MANUAL APPLY NOTES
-- =============================================================================
-- 1) Apply AFTER or AFTER 20260926_0001_fan_teams.sql (order among them is fine;
--    create_fan_team only succeeds once BOTH are applied).
-- 2) Preferred order if applying My Teams now:
--      a) 20260926_0001_fan_teams.sql   (if not yet applied)
--      b) 20260927_0001_create_fan_team_rate_limit_bucket.sql
--    Or apply this allowlist first, then fan teams — both work.
-- 3) Verify allowlist:
--      SELECT pg_get_functiondef(
--        'public.assert_rpc_rate_limit(text,integer,integer)'::regprocedure
--      ) ILIKE '%create_fan_team%';
--      SELECT pg_get_functiondef(
--        'public.assert_rpc_rate_limit(text,integer,integer)'::regprocedure
--      ) ILIKE ALL (ARRAY[
--        '%send_direct_message%',
--        '%send_group_message%',
--        '%friendship_ensure_pending%',
--        '%poke_profile%',
--        '%report_group_message%',
--        '%search_chat_conversations%',
--        '%search_chat_messages%',
--        '%create_fan_team%'
--      ]);
-- 4) Confirm create_fan_team still rate-limits at 20/hour:
--      SELECT pg_get_functiondef(
--        'public.create_fan_team(text,text,uuid[],text,text,text)'::regprocedure
--      ) ILIKE '%assert_rpc_rate_limit%create_fan_team%20%3600%';
-- =============================================================================
