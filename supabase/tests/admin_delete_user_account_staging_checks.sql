-- Staging integrity checks for admin fan account deletion.
-- Run manually after applying 20260849_0001_admin_delete_user_account.sql.

\set ON_ERROR_STOP on

DO $$
BEGIN
  IF to_regprocedure('public.admin_delete_user_account_eligibility(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: admin_delete_user_account_eligibility missing';
  END IF;

  IF to_regprocedure('public.admin_delete_user_account(uuid,text,text,text,boolean)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: admin_delete_user_account missing';
  END IF;

  RAISE NOTICE 'PASS: admin delete RPCs present';
END;
$$;

DO $$
BEGIN
  IF has_function_privilege('authenticated', 'public.admin_delete_user_account_eligibility(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: authenticated can EXECUTE admin_delete_user_account_eligibility';
  END IF;

  IF has_function_privilege('authenticated', 'public.admin_delete_user_account(uuid,text,text,text,boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: authenticated can EXECUTE admin_delete_user_account';
  END IF;

  IF has_function_privilege('anon', 'public.admin_delete_user_account_eligibility(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: anon can EXECUTE admin_delete_user_account_eligibility';
  END IF;

  IF has_function_privilege('anon', 'public.admin_delete_user_account(uuid,text,text,text,boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: anon can EXECUTE admin_delete_user_account';
  END IF;

  IF NOT has_function_privilege('service_role', 'public.admin_delete_user_account_eligibility(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: service_role cannot EXECUTE admin_delete_user_account_eligibility';
  END IF;

  IF NOT has_function_privilege('service_role', 'public.admin_delete_user_account(uuid,text,text,text,boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: service_role cannot EXECUTE admin_delete_user_account';
  END IF;

  RAISE NOTICE 'PASS: admin delete grant matrix';
END;
$$;

DO $$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef('public.admin_delete_user_account_eligibility(uuid)'::regprocedure);
  IF position('gameon_reactivation_assert_service_role' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: admin_delete_user_account_eligibility missing service_role assertion';
  END IF;

  v_def := pg_get_functiondef('public.admin_delete_user_account(uuid,text,text,text,boolean)'::regprocedure);
  IF position('gameon_reactivation_assert_service_role' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: admin_delete_user_account missing service_role assertion';
  END IF;

  IF position('start_account_deletion_job' IN v_def) = 0
     OR position('execute_delete_user_account_db' IN v_def) = 0
     OR position('queue_account_deletion_finalize' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: admin_delete_user_account missing Phase 2 orchestration calls';
  END IF;

  IF position('''source'', ''admin_dashboard''' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: admin_delete_user_account missing admin_dashboard audit source metadata';
  END IF;

  IF position('''deletion_job_status''' IN v_def) = 0
     OR position('''deletion_job_stage''' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: admin_delete_user_account missing deletion job audit metadata';
  END IF;

  RAISE NOTICE 'PASS: admin delete in-function assertions, orchestration, and audit source metadata';
END;
$$;

DO $$
DECLARE
  v_user_id uuid;
  v_result jsonb;
BEGIN
  IF to_regclass('public.businesses') IS NULL THEN
    RAISE NOTICE 'SKIP: businesses table not present for admin delete business-owner blocker test';
    RETURN;
  END IF;

  SELECT b.owner_user_id
    INTO v_user_id
  FROM public.businesses b
  WHERE b.owner_user_id IS NOT NULL
    AND coalesce(b.is_deleted, false) = false
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE NOTICE 'SKIP: no active business owner profile for admin delete blocker test';
    RETURN;
  END IF;

  v_result := public.admin_delete_user_account_eligibility(v_user_id);
  IF coalesce(v_result ->> 'can_delete', 'true') = 'true' THEN
    RAISE EXCEPTION 'FAIL: business owner should be blocked from admin delete eligibility: %', v_result;
  END IF;

  IF coalesce(v_result ->> 'block_reason', '') NOT LIKE 'business_%' THEN
    RAISE EXCEPTION 'FAIL: expected business_* block_reason, got %', v_result ->> 'block_reason';
  END IF;

  RAISE NOTICE 'PASS: business-owner blocker enforced in admin delete eligibility';
END;
$$;

DO $$
DECLARE
  v_user_id uuid;
  v_result jsonb;
BEGIN
  SELECT up.id
    INTO v_user_id
  FROM public.user_profiles up
  WHERE (
      lower(btrim(coalesce(up.admin_status, ''))) = 'disabled'
      OR up.admin_disabled_at IS NOT NULL
    )
    AND coalesce(up.is_deleted, false) = false
    AND up.deleted_at IS NULL
    AND up.anonymized_at IS NULL
  ORDER BY up.admin_disabled_at DESC NULLS LAST, up.created_at DESC
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE NOTICE 'SKIP: no admin-disabled active profile for acknowledgment test';
    RETURN;
  END IF;

  v_result := public.admin_delete_user_account(
    v_user_id,
    'staging admin delete acknowledgment test',
    'staging-admin@test.local',
    'staging-admin-disabled-' || v_user_id::text,
    false
  );

  IF coalesce(v_result ->> 'error', '') <> 'admin_disabled_requires_acknowledgment' THEN
    RAISE EXCEPTION 'FAIL: admin-disabled delete without acknowledgment should be blocked, got %', v_result;
  END IF;

  RAISE NOTICE 'PASS: admin-disabled acknowledgment required before admin delete';
END;
$$;

DO $$
DECLARE
  v_user_id uuid;
  v_result jsonb;
BEGIN
  SELECT up.id
    INTO v_user_id
  FROM public.user_profiles up
  WHERE coalesce(up.is_deleted, false) = true
     OR up.deleted_at IS NOT NULL
     OR up.anonymized_at IS NOT NULL
     OR lower(coalesce(up.email, '')) LIKE '%@deleted.fangeo.local'
  ORDER BY up.deleted_at DESC NULLS LAST, up.anonymized_at DESC NULLS LAST
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE NOTICE 'SKIP: no deleted profile for admin delete idempotency test';
    RETURN;
  END IF;

  v_result := public.admin_delete_user_account_eligibility(v_user_id);
  IF coalesce(v_result ->> 'block_reason', '') <> 'already_deleted' THEN
    RAISE EXCEPTION 'FAIL: deleted profile should report already_deleted, got %', v_result;
  END IF;

  v_result := public.admin_delete_user_account(
    v_user_id,
    'staging admin delete idempotency test',
    'staging-admin@test.local',
    'staging-already-deleted-' || v_user_id::text,
    false
  );

  IF coalesce(v_result ->> 'ok', 'false') <> 'true'
     OR coalesce(v_result ->> 'idempotent', 'false') <> 'true' THEN
    RAISE EXCEPTION 'FAIL: already-deleted admin delete should be idempotent, got %', v_result;
  END IF;

  RAISE NOTICE 'PASS: already-deleted admin delete idempotency';
END;
$$;

DO $$
DECLARE
  v_result jsonb;
BEGIN
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

  BEGIN
    PERFORM public.admin_delete_user_account_eligibility(gen_random_uuid());
    RAISE EXCEPTION 'FAIL: authenticated caller should not execute admin delete eligibility RPC';
  EXCEPTION
    WHEN insufficient_privilege THEN
      NULL;
    WHEN OTHERS THEN
      IF SQLERRM NOT ILIKE '%restricted to service_role%' THEN
        RAISE;
      END IF;
  END;

  RAISE NOTICE 'PASS: authenticated caller blocked inside admin delete eligibility RPC';
END;
$$;

DO $$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.admin_delete_user_account_eligibility(gen_random_uuid());
  IF coalesce(v_result ->> 'eligible', 'true') = 'true' THEN
    RAISE EXCEPTION 'FAIL: random uuid should not be eligible for admin delete';
  END IF;

  RAISE NOTICE 'PASS: nonexistent profile blocked from admin delete';
END;
$$;

-- Manual verification templates after apply:
-- 1. active fan -> admin_delete_user_account returns deletion_in_progress with storage_pending or db_committed
-- 2. suspended fan -> deletion allowed; user_bans rows preserved
-- 3. disabled fan without p_acknowledge_admin_disabled -> admin_disabled_requires_acknowledgment
-- 4. disabled fan with acknowledgment -> allowed
-- 5. business owner -> block_reason business_*
-- 6. already deleted fan -> idempotent already_deleted
-- 7. failed db_cleanup job -> retry via execute_delete_user_account_db when profile not anonymized
-- 8. completed deletion job -> immutable; admin_delete_user_account idempotent already_deleted
-- 9. admin_audit_logs row action=admin_delete_user_account with after_data.source=admin_dashboard
-- 10. finalize-account-deletion edge function advances job to completed asynchronously
-- 11. deleted user disappears from /users directory filter
-- 12. deleted user appears in /deleted-accounts
