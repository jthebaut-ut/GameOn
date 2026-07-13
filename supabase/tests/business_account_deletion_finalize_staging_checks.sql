-- Staging integrity checks for business account deletion storage finalizer.
-- Run manually after applying:
--   20260847_0001_business_account_deletion_phase2.sql
--   20260853_0001_business_account_deletion_finalize.sql
--
-- SQL Editor compatible (postgres role): catalog ACL + pg_get_functiondef only.

DO $$
BEGIN
  IF to_regprocedure('public.advance_business_account_deletion_job(uuid,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: advance_business_account_deletion_job missing';
  END IF;

  IF to_regprocedure('public.queue_business_account_deletion_finalize(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: queue_business_account_deletion_finalize missing';
  END IF;

  RAISE NOTICE 'PASS: business deletion finalize RPCs present';
END;
$$;

DO $$
DECLARE
  v_advance_def text;
  v_queue_def text;
BEGIN
  v_advance_def := pg_get_functiondef(
    'public.advance_business_account_deletion_job(uuid,text,text,text)'::regprocedure
  );

  IF position('mark_storage_pending' IN v_advance_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: advance missing mark_storage_pending';
  END IF;

  IF position('mark_completed' IN v_advance_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: advance missing mark_completed';
  END IF;

  IF position('mark_storage_partial' IN v_advance_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: advance missing mark_storage_partial';
  END IF;

  IF position('completed_at = now()' IN v_advance_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: mark_completed must set completed_at';
  END IF;

  IF position('mark_completed requires job status storage_pending' IN v_advance_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: mark_completed must require storage_pending (completed-only reactivation policy)';
  END IF;

  v_queue_def := pg_get_functiondef('public.queue_business_account_deletion_finalize(uuid)'::regprocedure);

  IF position('gameon_business_deletion_is_service_caller' IN v_queue_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: queue missing service_role assertion';
  END IF;

  IF position('finalize-business-account-deletion' IN v_queue_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: queue must target finalize-business-account-deletion Edge Function';
  END IF;

  IF position('edge_function_not_deployed' IN v_queue_def) > 0 THEN
    RAISE EXCEPTION 'FAIL: queue must not remain stubbed as edge_function_not_deployed';
  END IF;

  IF has_function_privilege('authenticated', 'public.advance_business_account_deletion_job(uuid,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: authenticated can EXECUTE advance_business_account_deletion_job';
  END IF;

  IF has_function_privilege('authenticated', 'public.queue_business_account_deletion_finalize(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: authenticated can EXECUTE queue_business_account_deletion_finalize';
  END IF;

  IF NOT has_function_privilege('service_role', 'public.advance_business_account_deletion_job(uuid,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: service_role cannot EXECUTE advance_business_account_deletion_job';
  END IF;

  IF NOT has_function_privilege('service_role', 'public.queue_business_account_deletion_finalize(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: service_role cannot EXECUTE queue_business_account_deletion_finalize';
  END IF;

  RAISE NOTICE 'PASS: business deletion finalize security and job policy';
END;
$$;
