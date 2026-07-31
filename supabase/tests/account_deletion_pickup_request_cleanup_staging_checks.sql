-- Staging / preflight checks for 20260897 pickup-request deletion cleanup.
-- Run manually after applying 20260897_0001_fix_account_deletion_pickup_request_cleanup.sql.
-- Does NOT delete production users. Disposable fixture block is optional and rolls back.

-- ---------------------------------------------------------------------------
-- Static definition checks
-- ---------------------------------------------------------------------------

DO $staging_static$
DECLARE
  v_soft text;
  v_trigger text;
  v_helper text;
BEGIN
  IF to_regprocedure('public.gameon_account_deletion_close_pickup_requests(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: gameon_account_deletion_close_pickup_requests missing';
  END IF;

  SELECT pg_get_functiondef('public.gameon_account_deletion_soft_delete_core(uuid,text)'::regprocedure) INTO v_soft;
  SELECT pg_get_functiondef('public.pickup_game_requests_before_update_status()'::regprocedure) INTO v_trigger;
  SELECT pg_get_functiondef('public.gameon_account_deletion_close_pickup_requests(uuid)'::regprocedure) INTO v_helper;

  IF position('gameon_account_deletion_close_pickup_requests' IN v_soft) = 0 THEN
    RAISE EXCEPTION 'FAIL: soft-delete core does not call status-aware pickup closer';
  END IF;

  IF position('gameon.account_deletion_anonymize' IN v_trigger) = 0 THEN
    RAISE EXCEPTION 'FAIL: pickup trigger missing deletion GUC allowlist';
  END IF;

  IF position('auth.uid()' IN v_trigger) = 0 THEN
    RAISE EXCEPTION 'FAIL: pickup trigger lost interactive auth.uid() rules';
  END IF;

  -- Stable result keys + doubled-quote filters as rendered by pg_get_functiondef.
  -- Do NOT use position('status = ''approved''' ...) — that looks for status = 'approved'
  -- and falsely fails against format()-escaped source containing status = ''approved''.
  -- Integrity needles below use the distinct tag needle so they cannot close this DO body.
  IF position('pickup_game_requests_approved_withdrawn' IN v_helper) = 0
     OR position('pickup_game_requests_pending_cancelled' IN v_helper) = 0
     OR position('pickup_game_requests_cancelled_for_created_games' IN v_helper) = 0 THEN
    RAISE EXCEPTION 'FAIL: closer missing status-aware result keys';
  END IF;

  IF position($needle$AND status = ''approved''$needle$ IN v_helper) = 0
     OR position($needle$AND status = ''pending''$needle$ IN v_helper) = 0
     OR position($needle$status IN (''pending'', ''approved'')$needle$ IN v_helper) = 0
     OR position($needle$status IN (''removed'', ''expired'')$needle$ IN v_helper) = 0 THEN
    RAISE EXCEPTION 'FAIL: closer missing approved/pending/organizer filters';
  END IF;

  IF position($needle$AND status = ''cancelled''$needle$ IN v_helper) > 0
     OR position($needle$AND status = ''withdrawn''$needle$ IN v_helper) > 0
     OR position($needle$AND status = ''rejected''$needle$ IN v_helper) > 0 THEN
    RAISE EXCEPTION 'FAIL: closer must not rewrite cancelled/withdrawn/rejected requester rows';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.role_routine_grants g
    WHERE g.specific_schema = 'public'
      AND g.routine_name = 'gameon_account_deletion_close_pickup_requests'
      AND g.privilege_type = 'EXECUTE'
      AND g.grantee IN ('PUBLIC', 'anon', 'authenticated')
  ) OR has_function_privilege('authenticated', 'public.gameon_account_deletion_close_pickup_requests(uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.gameon_account_deletion_close_pickup_requests(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: authenticated/anon/PUBLIC can EXECUTE pickup closer';
  END IF;

  RAISE NOTICE 'PASS: 20260897 static definition / grant checks';
END;
$staging_static$;

-- ---------------------------------------------------------------------------
-- Optional disposable fixture simulation (rolls back).
-- Skips when pickup tables are missing.
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_subject uuid := 'a6098970-0001-4000-8000-000000000097';
  v_other uuid := 'a6098970-0002-4000-8000-000000000097';
  v_game_owned uuid := 'a6098970-1001-4000-8000-000000000097';
  v_game_other uuid := 'a6098970-1002-4000-8000-000000000097';
  v_counts jsonb;
  v_status text;
BEGIN
  IF to_regclass('public.pickup_games') IS NULL
     OR to_regclass('public.pickup_game_requests') IS NULL THEN
    RAISE NOTICE 'SKIP: pickup tables not present';
    RETURN;
  END IF;

  -- Use a nested transaction so we never leave fixtures behind.
  BEGIN
    -- Minimal auth.users stubs if FK requires them (skip if insert forbidden).
    BEGIN
      INSERT INTO auth.users (id, email)
      VALUES
        (v_subject, 'deletion-pickup-fixture-subject@example.invalid'),
        (v_other, 'deletion-pickup-fixture-other@example.invalid')
      ON CONFLICT (id) DO NOTHING;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'SKIP: cannot insert auth.users fixtures (%).', SQLERRM;
      RETURN;
    END;

    INSERT INTO public.pickup_games (
      id, creator_user_id, title, sport, status, is_visible, game_start_at, players_needed
    )
    VALUES
      (v_game_owned, v_subject, 'Fixture Owned', 'Soccer', 'active', true, now() + interval '1 day', 5),
      (v_game_other, v_other, 'Fixture Other', 'Soccer', 'active', true, now() + interval '1 day', 5)
    ON CONFLICT (id) DO NOTHING;

    -- Mixed requester history for subject on other user's game + pending on owned game from other.
    INSERT INTO public.pickup_game_requests (
      id, pickup_game_id, requester_user_id, requester_skill_level, status
    )
    VALUES
      (gen_random_uuid(), v_game_other, v_subject, 'casual', 'approved'),
      (gen_random_uuid(), v_game_other, v_subject, 'casual', 'pending'),
      (gen_random_uuid(), v_game_other, v_subject, 'casual', 'cancelled'),
      (gen_random_uuid(), v_game_other, v_subject, 'casual', 'withdrawn'),
      (gen_random_uuid(), v_game_other, v_subject, 'casual', 'rejected'),
      (gen_random_uuid(), v_game_owned, v_other, 'casual', 'approved'),
      (gen_random_uuid(), v_game_owned, v_other, 'casual', 'pending')
    ON CONFLICT DO NOTHING;

    -- Simulate soft-delete pickup portion: remove owned games, then close requests.
    UPDATE public.pickup_games
    SET status = 'removed', is_visible = false
    WHERE creator_user_id = v_subject;

    v_counts := public.gameon_account_deletion_close_pickup_requests(v_subject);

    IF coalesce((v_counts ->> 'pickup_game_requests_approved_withdrawn')::int, 0) < 1 THEN
      RAISE EXCEPTION 'FAIL: expected approved→withdrawn count >= 1, got %', v_counts;
    END IF;
    IF coalesce((v_counts ->> 'pickup_game_requests_pending_cancelled')::int, 0) < 1 THEN
      RAISE EXCEPTION 'FAIL: expected pending→cancelled count >= 1, got %', v_counts;
    END IF;
    IF coalesce((v_counts ->> 'pickup_game_requests_cancelled_for_created_games')::int, 0) < 1 THEN
      RAISE EXCEPTION 'FAIL: expected organizer cancel count >= 1, got %', v_counts;
    END IF;

    -- Idempotent retry
    v_counts := public.gameon_account_deletion_close_pickup_requests(v_subject);
    IF coalesce((v_counts ->> 'pickup_game_requests_closed_total')::int, -1) <> 0 THEN
      RAISE EXCEPTION 'FAIL: retry should close 0 rows, got %', v_counts;
    END IF;

    SELECT status INTO v_status
    FROM public.pickup_game_requests
    WHERE requester_user_id = v_subject AND status = 'rejected'
    LIMIT 1;
    IF v_status IS DISTINCT FROM 'rejected' THEN
      RAISE EXCEPTION 'FAIL: rejected requester row was rewritten';
    END IF;

    -- Interactive rule still blocks unauthorized cancel without deletion GUC.
    PERFORM set_config('gameon.account_deletion_anonymize', '', true);
    BEGIN
      UPDATE public.pickup_game_requests
      SET status = 'cancelled'
      WHERE pickup_game_id = v_game_other
        AND requester_user_id = v_subject
        AND status = 'withdrawn';
      RAISE EXCEPTION 'FAIL: expected interactive cancel of withdrawn to be forbidden';
    EXCEPTION WHEN check_violation THEN
      NULL; -- expected pickup_request_cancel_forbidden / status forbidden
    END;

    RAISE NOTICE 'PASS: 20260897 disposable fixture status-aware cleanup';
    RAISE EXCEPTION 'rollback_fixture';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'rollback_fixture' THEN
        RAISE NOTICE 'PASS: fixture rolled back';
      ELSE
        RAISE;
      END IF;
  END;
END;
$$;

-- Retry guidance (manual):
-- Failed jobs with status=failed, stage=db_cleanup, error_detail=pickup_request_cancel_forbidden
-- and profile NOT anonymized can be retried via:
--   SELECT public.execute_delete_user_account_db('<job_id>'::uuid);
-- after this migration. Do not auto-retry from this script.
