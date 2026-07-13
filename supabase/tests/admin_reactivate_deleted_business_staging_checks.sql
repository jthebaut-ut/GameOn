-- Staging integrity checks for admin deleted-business reactivation.
-- Run manually on staging after applying:
--   20260851_0001_admin_reactivate_deleted_business.sql
--   20260852_0001_fix_business_reactivation_eligibility_diagnostics.sql
--
-- SQL Editor compatible (postgres role): catalog ACL + pg_get_functiondef only.
-- Does NOT invoke service-role-only RPCs and does not fake request.jwt.claim.role.
--
-- Destructive end-to-end fixture tests live in:
--   admin_reactivate_deleted_business_service_role_fixtures.sql

DO $$
BEGIN
  IF to_regprocedure('public.admin_reactivate_deleted_business(uuid,text,text,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: admin_reactivate_deleted_business missing';
  END IF;

  IF to_regprocedure('public.admin_reactivate_deleted_business_eligibility(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: admin_reactivate_deleted_business_eligibility missing';
  END IF;

  IF to_regclass('public.business_reactivation_events') IS NULL THEN
    RAISE EXCEPTION 'FAIL: business_reactivation_events table missing';
  END IF;

  RAISE NOTICE 'PASS: business reactivation objects present';
END;
$$;

DO $$
DECLARE
  v_fn regprocedure;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    'public.admin_reactivate_deleted_business(uuid,text,text,text,text,text)'::regprocedure,
    'public.admin_reactivate_deleted_business_eligibility(uuid)'::regprocedure,
    'public.gameon_business_reactivation_evaluate_eligibility(uuid,public.businesses,public.account_identities,public.business_account_deletion_jobs,public.business_account_deletion_audit,text)'::regprocedure
  ]
  LOOP
    IF has_function_privilege('authenticated', v_fn, 'EXECUTE') THEN
      RAISE EXCEPTION 'FAIL: authenticated can EXECUTE %', v_fn;
    END IF;

    IF has_function_privilege('anon', v_fn, 'EXECUTE') THEN
      RAISE EXCEPTION 'FAIL: anon can EXECUTE %', v_fn;
    END IF;

    IF NOT has_function_privilege('service_role', v_fn, 'EXECUTE') THEN
      RAISE EXCEPTION 'FAIL: service_role cannot EXECUTE %', v_fn;
    END IF;
  END LOOP;

  RAISE NOTICE 'PASS: business reactivation grant matrix';
END;
$$;

DO $$
DECLARE
  v_def text;
  v_guard text;
  v_job_policy text;
BEGIN
  v_def := pg_get_functiondef('public.admin_reactivate_deleted_business(uuid,text,text,text,text,text)'::regprocedure);
  IF position('gameon_business_reactivation_assert_service_role' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: admin_reactivate_deleted_business missing in-function service_role assertion';
  END IF;

  IF position('gameon.business_account_reactivation_restore' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: admin_reactivate_deleted_business missing identity-guard bypass GUC';
  END IF;

  v_def := pg_get_functiondef('public.admin_reactivate_deleted_business_eligibility(uuid)'::regprocedure);
  IF position('gameon_business_reactivation_assert_service_role' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: admin_reactivate_deleted_business_eligibility missing in-function service_role assertion';
  END IF;

  v_job_policy := pg_get_functiondef('public.gameon_business_reactivation_latest_job_block_reason(public.business_account_deletion_jobs)'::regprocedure);
  IF position('storage_finalization_pending' IN v_job_policy) = 0 THEN
    RAISE EXCEPTION 'FAIL: job policy must block db_committed before completed';
  END IF;

  IF position('completed' IN v_job_policy) = 0 THEN
    RAISE EXCEPTION 'FAIL: job policy must allow completed deletion jobs';
  END IF;

  v_guard := pg_get_functiondef('public.enforce_business_account_identity_guard()'::regprocedure);
  IF v_guard NOT ILIKE '%gameon.business_account_reactivation_restore%' THEN
    RAISE EXCEPTION 'FAIL: identity guard missing reactivation bypass GUC';
  END IF;

  IF v_guard NOT ILIKE '%gameon.business_account_deletion_anonymize%' THEN
    RAISE EXCEPTION 'FAIL: identity guard missing deletion bypass GUC';
  END IF;

  IF v_guard NOT ILIKE '%OLD.is_deleted%'
     OR v_guard NOT ILIKE '%NEW.is_deleted%' THEN
    RAISE EXCEPTION 'FAIL: identity guard must enforce deleted to active transition';
  END IF;

  RAISE NOTICE 'PASS: in-function service_role assertions, job policy, and identity guard present';
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'business_reactivation_events'
      AND c.relrowsecurity
  ) THEN
    RAISE EXCEPTION 'FAIL: business_reactivation_events RLS not enabled';
  END IF;

  IF has_table_privilege('anon', 'public.business_reactivation_events', 'INSERT')
     OR has_table_privilege('anon', 'public.business_reactivation_events', 'UPDATE')
     OR has_table_privilege('anon', 'public.business_reactivation_events', 'DELETE') THEN
    RAISE EXCEPTION 'FAIL: anon has write privileges on business_reactivation_events';
  END IF;

  IF has_table_privilege('authenticated', 'public.business_reactivation_events', 'INSERT')
     OR has_table_privilege('authenticated', 'public.business_reactivation_events', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.business_reactivation_events', 'DELETE') THEN
    RAISE EXCEPTION 'FAIL: authenticated has write privileges on business_reactivation_events';
  END IF;

  IF NOT has_table_privilege('service_role', 'public.business_reactivation_events', 'INSERT') THEN
    RAISE EXCEPTION 'FAIL: service_role cannot INSERT business_reactivation_events';
  END IF;

  IF has_table_privilege('service_role', 'public.business_reactivation_events', 'UPDATE')
     OR has_table_privilege('service_role', 'public.business_reactivation_events', 'DELETE') THEN
    RAISE EXCEPTION 'FAIL: service_role has UPDATE/DELETE on business_reactivation_events';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'business_reactivation_events'
      AND t.tgname = 'business_reactivation_events_immutable_bu'
      AND NOT t.tgisinternal
  ) THEN
    RAISE EXCEPTION 'FAIL: business_reactivation_events immutable trigger missing';
  END IF;

  RAISE NOTICE 'PASS: business_reactivation_events table security';
END;
$$;

DO $$
DECLARE
  v_generated_count integer;
BEGIN
  SELECT count(*)::integer
    INTO v_generated_count
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'businesses'
    AND is_generated = 'ALWAYS';

  IF v_generated_count > 0 THEN
    IF pg_get_functiondef('public.admin_reactivate_deleted_business(uuid,text,text,text,text,text)'::regprocedure)
       ILIKE '%GENERATED%' THEN
      RAISE EXCEPTION 'FAIL: reactivation function references generated columns directly';
    END IF;
  END IF;

  RAISE NOTICE 'PASS: no direct generated-column writes detected in reactivation RPC';
END;
$$;

DO $$
DECLARE
  v_comment text;
BEGIN
  SELECT obj_description(
    'public.admin_reactivate_deleted_business(uuid,text,text,text,text,text)'::regprocedure,
    'pg_proc'
  )
  INTO v_comment;

  IF v_comment IS NULL OR position('p_business_id, p_display_name, p_reason, p_admin_email, p_confirmation, p_business_handle' IN v_comment) = 0 THEN
    RAISE EXCEPTION 'FAIL: admin_reactivate_deleted_business comment must document parameter order';
  END IF;

  RAISE NOTICE 'PASS: RPC signature documented for Admin caller';
END;
$$;

DO $$
BEGIN
  IF to_regprocedure('public.gameon_business_reactivation_diagnostic_flags(uuid,public.account_identities)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: gameon_business_reactivation_diagnostic_flags missing';
  END IF;

  IF to_regprocedure('public.gameon_business_reactivation_eligibility_envelope(jsonb)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: gameon_business_reactivation_eligibility_envelope missing';
  END IF;

  RAISE NOTICE 'PASS: business reactivation diagnostic helpers present';
END;
$$;

DO $$
DECLARE
  v_eval_def text;
  v_admin_def text;
  v_envelope_keys text[] := ARRAY[
    'ok',
    'eligible',
    'block_reason',
    'message',
    'business_id',
    'owner_user_id',
    'auth_user_exists',
    'identity_reserved',
    'deletion_job_id',
    'deletion_job_status',
    'deletion_audit_id'
  ];
  v_key text;
  v_payload jsonb;
  v_flags jsonb;
  v_blocked jsonb;
BEGIN
  v_eval_def := pg_get_functiondef(
    'public.gameon_business_reactivation_evaluate_eligibility(uuid,public.businesses,public.account_identities,public.business_account_deletion_jobs,public.business_account_deletion_audit,text)'::regprocedure
  );

  IF position('gameon_business_reactivation_diagnostic_flags' IN v_eval_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: evaluator missing diagnostic_flags helper';
  END IF;

  IF position('gameon_business_reactivation_eligibility_envelope' IN v_eval_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: evaluator missing eligibility_envelope wrapper';
  END IF;

  IF position('auth_user_exists' IN v_eval_def) = 0
     OR position('identity_reserved' IN v_eval_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: evaluator must reference auth_user_exists and identity_reserved';
  END IF;

  IF position('storage_finalization_pending' IN v_eval_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: evaluator must retain storage_finalization_pending block messaging';
  END IF;

  IF position('gameon_business_reactivation_latest_job_block_reason' IN v_eval_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: evaluator must preserve completed-only job policy delegation';
  END IF;

  v_admin_def := pg_get_functiondef('public.admin_reactivate_deleted_business_eligibility(uuid)'::regprocedure);
  IF position('gameon_business_reactivation_eligibility_envelope' IN v_admin_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: admin eligibility wrapper must use eligibility_envelope';
  END IF;

  v_payload := public.gameon_business_reactivation_eligibility_envelope('{}'::jsonb);
  FOREACH v_key IN ARRAY v_envelope_keys LOOP
    IF NOT v_payload ? v_key THEN
      RAISE EXCEPTION 'FAIL: eligibility_envelope missing canonical key %', v_key;
    END IF;
  END LOOP;

  v_flags := public.gameon_business_reactivation_diagnostic_flags(NULL, NULL::public.account_identities);
  IF v_flags -> 'auth_user_exists' IS DISTINCT FROM 'null'::jsonb
     OR v_flags -> 'identity_reserved' IS DISTINCT FROM 'null'::jsonb THEN
    RAISE EXCEPTION 'FAIL: diagnostic_flags must return JSON null when owner_user_id is missing';
  END IF;

  v_blocked := public.gameon_business_reactivation_eligibility_envelope(
    jsonb_build_object(
      'eligible', false,
      'block_reason', 'storage_finalization_pending',
      'business_id', gen_random_uuid(),
      'owner_user_id', gen_random_uuid(),
      'deletion_job_id', gen_random_uuid(),
      'deletion_job_status', 'db_committed',
      'deletion_audit_id', gen_random_uuid()
    ) || jsonb_build_object(
      'auth_user_exists', true,
      'identity_reserved', true
    )
  );

  IF coalesce((v_blocked ->> 'auth_user_exists')::boolean, false) <> true THEN
    RAISE EXCEPTION 'FAIL: enveloped storage_finalization_pending payload must preserve auth_user_exists=true';
  END IF;

  IF coalesce((v_blocked ->> 'identity_reserved')::boolean, false) <> true THEN
    RAISE EXCEPTION 'FAIL: enveloped storage_finalization_pending payload must preserve identity_reserved=true';
  END IF;

  IF v_blocked ->> 'block_reason' IS DISTINCT FROM 'storage_finalization_pending' THEN
    RAISE EXCEPTION 'FAIL: enveloped blocked payload must preserve block_reason';
  END IF;

  RAISE NOTICE 'PASS: business reactivation eligibility diagnostic payload shape';
END;
$$;
