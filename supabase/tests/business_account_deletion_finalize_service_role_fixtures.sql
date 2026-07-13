-- Service-role fixture tests for business deletion job completion.
-- Run only with a service_role JWT context (Admin automation / staging ops).
-- Skips automatically when gameon_business_deletion_is_service_caller() is false.
--
-- Exercises advance_business_account_deletion_job transitions without invoking Edge Functions.
-- Pair with deployed finalize-business-account-deletion for storage deletion E2E.

DO $$
BEGIN
  IF NOT public.gameon_business_deletion_is_service_caller() THEN
    RAISE NOTICE 'SKIP: business deletion finalize fixture tests require service_role JWT context';
    RETURN;
  END IF;

  RAISE NOTICE 'BEGIN: business deletion finalize service-role fixture tests';
END;
$$;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $$
DECLARE
  v_owner_id uuid := gen_random_uuid();
  v_business_id uuid := gen_random_uuid();
  v_job_id uuid := gen_random_uuid();
  v_audit_id uuid := gen_random_uuid();
  v_suffix text := replace(v_business_id::text, '-', '');
  v_original_email text := 'biz-finalize-' || v_suffix || '@staging-finalize.test';
  v_tombstone_email text := public.gameon_business_deletion_tombstone_email(v_business_id);
  v_advance jsonb;
  v_eligibility jsonb;
  v_auth_count integer;
  v_identity_count integer;
  v_audit_count integer;
BEGIN
  IF NOT public.gameon_business_deletion_is_service_caller() THEN
  RETURN;
  END IF;

  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    phone_change, phone_change_token, email_change_token_current, reauthentication_token,
    is_super_admin, is_sso_user, is_anonymous
  ) VALUES (
    '00000000-0000-0000-0000-000000000000',
    v_owner_id,
    'authenticated',
    'authenticated',
    v_original_email,
    crypt('staging-business-finalize-test-password', gen_salt('bf')),
    now(),
    jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
    jsonb_build_object('email_verified', true),
    now(),
    now(),
    '', '', '', '', '', '', '', '',
    false, false, false
  );

  INSERT INTO public.account_identities (account_id, email, account_type)
  VALUES (v_owner_id, v_original_email, 'business');

  INSERT INTO public.businesses (
    id, display_name, owner_user_id, owner_email, admin_status,
    is_deleted, deleted_at, anonymized_at, deletion_requested_at
  ) VALUES (
    v_business_id,
    'Deleted Business',
    v_owner_id,
    v_tombstone_email,
    'active',
    true,
    now(),
    now(),
    now()
  );

  INSERT INTO public.business_account_deletion_jobs (
    id,
    subject_business_id,
    subject_user_id,
    requested_by_user_id,
    request_source,
    deletion_mode,
    status,
    stage,
    idempotency_key,
    storage_paths,
    preview_snapshot
  ) VALUES (
    v_job_id,
    v_business_id,
    v_owner_id,
    v_owner_id,
    'self_service',
    'soft',
    'db_committed',
    'awaiting_storage_finalize',
    'fixture:finalize:' || v_business_id::text,
    ARRAY[]::text[],
    '{}'::jsonb
  );

  INSERT INTO public.business_account_deletion_audit (
    id,
    business_id,
    deleted_by,
    deleted_by_email,
    business_snapshot,
    deletion_job_id,
    deletion_mode
  ) VALUES (
    v_audit_id,
    v_business_id,
    v_owner_id,
    v_original_email,
    jsonb_build_object(
      'id', v_business_id,
      'display_name', 'Staging Deleted Business',
      'owner_user_id', v_owner_id,
      'owner_email', v_original_email
    ),
    v_job_id,
    'soft'
  );

  v_advance := public.advance_business_account_deletion_job(v_job_id, 'mark_storage_pending');
  IF coalesce(v_advance ->> 'status', '') <> 'storage_pending' THEN
    RAISE EXCEPTION 'FAIL: mark_storage_pending expected storage_pending, got %', v_advance;
  END IF;

  v_advance := public.advance_business_account_deletion_job(v_job_id, 'mark_completed');
  IF coalesce(v_advance ->> 'status', '') <> 'completed' THEN
    RAISE EXCEPTION 'FAIL: mark_completed expected completed, got %', v_advance;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.business_account_deletion_jobs j
    WHERE j.id = v_job_id
      AND j.status = 'completed'
      AND j.stage = 'completed'
      AND j.completed_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: completed job must set completed_at';
  END IF;

  v_advance := public.advance_business_account_deletion_job(v_job_id, 'mark_completed');
  IF coalesce((v_advance ->> 'idempotent_replay')::boolean, false) <> true THEN
    RAISE EXCEPTION 'FAIL: repeat mark_completed must be idempotent';
  END IF;

  SELECT count(*) INTO v_auth_count FROM auth.users u WHERE u.id = v_owner_id;
  SELECT count(*) INTO v_identity_count FROM public.account_identities ai WHERE ai.account_id = v_owner_id;
  SELECT count(*) INTO v_audit_count FROM public.business_account_deletion_audit a WHERE a.business_id = v_business_id;

  IF v_auth_count <> 1 OR v_identity_count <> 1 OR v_audit_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: finalize fixtures must preserve auth, identity, and audit rows';
  END IF;

  IF to_regprocedure('public.admin_reactivate_deleted_business_eligibility(uuid)') IS NOT NULL THEN
    v_eligibility := public.admin_reactivate_deleted_business_eligibility(v_business_id);
    IF coalesce((v_eligibility ->> 'eligible')::boolean, false) <> true THEN
      RAISE EXCEPTION 'FAIL: completed job should make business eligible, got %', v_eligibility;
    END IF;

    IF coalesce((v_eligibility ->> 'auth_user_exists')::boolean, false) <> true
       OR coalesce((v_eligibility ->> 'identity_reserved')::boolean, false) <> true THEN
      RAISE EXCEPTION 'FAIL: eligibility diagnostics must show preserved auth/identity, got %', v_eligibility;
    END IF;
  END IF;

  DELETE FROM public.business_reactivation_events WHERE business_id = v_business_id;
  DELETE FROM public.business_account_deletion_audit WHERE business_id = v_business_id;
  DELETE FROM public.business_account_deletion_jobs WHERE subject_business_id = v_business_id;
  DELETE FROM public.businesses WHERE id = v_business_id;
  DELETE FROM public.account_identities WHERE account_id = v_owner_id;
  DELETE FROM auth.users WHERE id = v_owner_id;

  RAISE NOTICE 'PASS: zero-path business deletion job completion + reactivation eligibility';
END;
$$;
