-- Staging checks for 20260963 managed-player rate-limit allowlist.
-- Run AFTER applying 20260963 (or 20260960 that includes the same allowlist patch).

DO $$
DECLARE
  v_src text;
  v_create text;
BEGIN
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE oid = to_regprocedure('public.assert_rpc_rate_limit(text,int,int)');
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'FAIL: assert_rpc_rate_limit missing';
  END IF;

  FOREACH v_create IN ARRAY ARRAY[
    'create_managed_player',
    'update_managed_player',
    'add_managed_player_to_fan_team',
    'accept_fan_team_invitation_as_managed_player',
    'create_fan_team',
    'resend_fan_team_invitation'
  ]
  LOOP
    IF position(quote_literal(v_create) IN v_src) = 0 THEN
      RAISE EXCEPTION 'FAIL: allowlist missing bucket %', v_create;
    END IF;
  END LOOP;

  -- create_managed_player still rate-limits (security preserved).
  SELECT prosrc INTO v_create
  FROM pg_proc
  WHERE oid = to_regprocedure('public.create_managed_player(text,text,text,int,text,text)');
  IF position('assert_rpc_rate_limit(''create_managed_player''' IN coalesce(v_create, '')) = 0
     AND position('create_managed_player'', 20, 3600' IN coalesce(v_create, '')) = 0 THEN
    RAISE EXCEPTION 'FAIL: create_managed_player no longer calls rate limit';
  END IF;

  RAISE NOTICE 'PASS: managed_player_rate_limit_bucket_checks';
END $$;
