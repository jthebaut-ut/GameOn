-- Staging integrity checks for admin deleted-account reactivation.
-- Run manually on staging after applying:
--   20260844_0001_admin_reactivate_deleted_user.sql
--   20260846_0001_fix_admin_reactivation_generated_column.sql
--
-- Supabase SQL Editor compatible (no psql meta-commands).
-- Each block uses RAISE EXCEPTION on failure, which stops the run.

DO $$
BEGIN
  IF to_regprocedure('public.admin_reactivate_deleted_user(uuid,text,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: admin_reactivate_deleted_user missing';
  END IF;

  IF to_regprocedure('public.admin_reactivate_deleted_user_eligibility(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: admin_reactivate_deleted_user_eligibility missing';
  END IF;

  IF to_regclass('public.account_reactivation_events') IS NULL THEN
    RAISE EXCEPTION 'FAIL: account_reactivation_events table missing';
  END IF;

  RAISE NOTICE 'PASS: reactivation objects present';
END;
$$;

DO $$
BEGIN
  IF has_function_privilege('authenticated', 'public.admin_reactivate_deleted_user(uuid,text,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: authenticated can EXECUTE admin_reactivate_deleted_user';
  END IF;

  IF has_function_privilege('authenticated', 'public.admin_reactivate_deleted_user_eligibility(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: authenticated can EXECUTE admin_reactivate_deleted_user_eligibility';
  END IF;

  IF NOT has_function_privilege('service_role', 'public.admin_reactivate_deleted_user(uuid,text,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: service_role cannot EXECUTE admin_reactivate_deleted_user';
  END IF;

  IF NOT has_function_privilege('service_role', 'public.admin_reactivate_deleted_user_eligibility(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: service_role cannot EXECUTE admin_reactivate_deleted_user_eligibility';
  END IF;

  RAISE NOTICE 'PASS: reactivation grant matrix';
END;
$$;

DO $$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef('public.admin_reactivate_deleted_user(uuid,text,text,text,text)'::regprocedure);
  IF position('gameon_reactivation_assert_service_role' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: admin_reactivate_deleted_user missing in-function service_role assertion';
  END IF;

  v_def := pg_get_functiondef('public.admin_reactivate_deleted_user_eligibility(uuid)'::regprocedure);
  IF position('gameon_reactivation_assert_service_role' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: admin_reactivate_deleted_user_eligibility missing in-function service_role assertion';
  END IF;

  RAISE NOTICE 'PASS: in-function service_role assertions present';
END;
$$;

DO $$
DECLARE
  v_result jsonb;
BEGIN
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

  BEGIN
    PERFORM public.admin_reactivate_deleted_user_eligibility(gen_random_uuid());
    RAISE EXCEPTION 'FAIL: authenticated caller should not execute eligibility RPC';
  EXCEPTION
    WHEN insufficient_privilege THEN
      NULL;
    WHEN OTHERS THEN
      IF SQLERRM NOT ILIKE '%restricted to service_role%' THEN
        RAISE;
      END IF;
  END;

  RAISE NOTICE 'PASS: authenticated caller blocked inside eligibility RPC';
END;
$$;

DO $$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.admin_reactivate_deleted_user_eligibility(gen_random_uuid());
  IF coalesce(v_result ->> 'eligible', 'true') = 'true' THEN
    RAISE EXCEPTION 'FAIL: random uuid should not be eligible';
  END IF;

  RAISE NOTICE 'PASS: nonexistent profile blocked';
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
  WHERE COALESCE(up.is_deleted, false) = false
    AND up.deleted_at IS NULL
    AND up.anonymized_at IS NULL
    AND lower(coalesce(up.email, '')) NOT LIKE '%@deleted.fangeo.local'
  ORDER BY up.created_at DESC NULLS LAST
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE NOTICE 'SKIP: no active profile for idempotent eligibility test';
    RETURN;
  END IF;

  v_result := public.admin_reactivate_deleted_user_eligibility(v_user_id);
  IF coalesce(v_result ->> 'eligible', 'true') = 'true' THEN
    RAISE EXCEPTION 'FAIL: active profile should not be eligible for reactivation';
  END IF;

  RAISE NOTICE 'PASS: active profile blocked from reactivation';
END;
$$;

-- Session-scoped fixtures for latest-job tests: deleted fan profile with auth + identity.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION pg_temp.staging_reactivation_create_deleted_fan()
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_user_id uuid := gen_random_uuid();
  v_suffix text := replace(v_user_id::text, '-', '');
  v_original_email text := 'react-staging-' || v_suffix || '@staging-reactivation.test';
  v_tombstone_email text := 'deleted-user-' || v_suffix || '@deleted.fangeo.local';
  v_handle text := 'rst' || substr(v_suffix, 1, 17);
  v_now timestamptz := now();
BEGIN
  INSERT INTO auth.users (
    instance_id,
    id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at,
    updated_at,
    confirmation_token,
    recovery_token,
    email_change_token_new,
    email_change,
    phone_change,
    phone_change_token,
    email_change_token_current,
    reauthentication_token,
    is_super_admin,
    is_sso_user,
    is_anonymous
  ) VALUES (
    '00000000-0000-0000-0000-000000000000',
    v_user_id,
    'authenticated',
    'authenticated',
    v_tombstone_email,
    crypt('staging-reactivation-test-password', gen_salt('bf')),
    v_now,
    jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
    jsonb_build_object('email_verified', true),
    v_now,
    v_now,
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    false,
    false,
    false
  );

  INSERT INTO public.account_identities (account_id, email, account_type)
  VALUES (v_user_id, v_original_email, 'fan');

  INSERT INTO public.user_profiles (
    id,
    email,
    display_name,
    username,
    handle,
    is_business_account,
    admin_status,
    is_deleted,
    deleted_at,
    anonymized_at
  ) VALUES (
    v_user_id,
    v_tombstone_email,
    'Reactivation Staging Test',
    v_handle,
    v_handle,
    false,
    'active',
    true,
    v_now,
    v_now
  );

  RETURN v_user_id;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.staging_reactivation_create_eligible_deleted_fan()
RETURNS TABLE(subject_user_id uuid, deletion_job_id uuid, original_email text)
LANGUAGE plpgsql
AS $$
DECLARE
  v_user_id uuid;
  v_job_id uuid;
  v_original_email text;
BEGIN
  v_user_id := pg_temp.staging_reactivation_create_deleted_fan();

  SELECT lower(btrim(ai.email))
    INTO v_original_email
  FROM public.account_identities ai
  WHERE ai.account_id = v_user_id;

  INSERT INTO public.account_deletion_jobs (
    subject_user_id,
    requested_by_user_id,
    request_source,
    deletion_mode,
    status,
    stage,
    idempotency_key,
    preview_snapshot,
    created_at,
    completed_at
  ) VALUES (
    v_user_id,
    v_user_id,
    'system',
    'soft',
    'completed',
    'completed',
    'reactivation-mutation-check-' || gen_random_uuid()::text,
    jsonb_build_object('normalized_email', v_original_email),
    now() - interval '1 hour',
    now() - interval '1 hour'
  )
  RETURNING id INTO v_job_id;

  subject_user_id := v_user_id;
  deletion_job_id := v_job_id;
  original_email := v_original_email;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.staging_reactivation_teardown(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF p_user_id IS NULL THEN
    RETURN;
  END IF;

  DELETE FROM public.account_deletion_jobs
  WHERE subject_user_id = p_user_id;

  DELETE FROM public.account_reactivation_events
  WHERE subject_user_id = p_user_id;

  IF to_regclass('public.admin_audit_logs') IS NOT NULL THEN
    DELETE FROM public.admin_audit_logs
    WHERE action = 'reactivate_deleted_user'
      AND target_id = p_user_id::text;
  END IF;

  DELETE FROM public.user_profiles
  WHERE id = p_user_id;

  DELETE FROM public.account_identities
  WHERE account_id = p_user_id;

  DELETE FROM auth.users
  WHERE id = p_user_id;
END;
$$;

-- Latest-job logic: older failed job must not block when latest job is completed.
DO $$
DECLARE
  v_user_id uuid;
  v_failed_job_id uuid;
  v_completed_job_id uuid;
  v_result jsonb;
BEGIN
  v_user_id := pg_temp.staging_reactivation_create_deleted_fan();

  BEGIN
    INSERT INTO public.account_deletion_jobs (
      subject_user_id,
      requested_by_user_id,
      request_source,
      deletion_mode,
      status,
      stage,
      idempotency_key,
      created_at
    ) VALUES (
      v_user_id,
      v_user_id,
      'system',
      'soft',
      'failed',
      'storage_cleanup',
      'reactivation-check-failed-' || gen_random_uuid()::text,
      now() - interval '2 days'
    )
    RETURNING id INTO v_failed_job_id;

    INSERT INTO public.account_deletion_jobs (
      subject_user_id,
      requested_by_user_id,
      request_source,
      deletion_mode,
      status,
      stage,
      idempotency_key,
      created_at,
      completed_at
    ) VALUES (
      v_user_id,
      v_user_id,
      'system',
      'soft',
      'completed',
      'completed',
      'reactivation-check-completed-' || gen_random_uuid()::text,
      now() - interval '1 day',
      now() - interval '1 day'
    )
    RETURNING id INTO v_completed_job_id;

    v_result := public.admin_reactivate_deleted_user_eligibility(v_user_id);

    IF coalesce(v_result ->> 'block_reason', '') = 'active_deletion_job'
       OR coalesce(v_result ->> 'block_reason', '') = 'deletion_job_not_completed' THEN
      RAISE EXCEPTION 'FAIL: older failed job blocked eligibility despite newer completed job. block_reason=%', v_result ->> 'block_reason';
    END IF;

    IF coalesce(v_result ->> 'block_reason', '') = 'profile_not_deleted' THEN
      RAISE EXCEPTION 'FAIL: latest-job test fixture was not deleted. block_reason=%', v_result ->> 'block_reason';
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      PERFORM pg_temp.staging_reactivation_teardown(v_user_id);
      RAISE;
  END;

  PERFORM pg_temp.staging_reactivation_teardown(v_user_id);

  RAISE NOTICE 'PASS: older failed job ignored when latest job is completed';
END;
$$;

-- Latest incomplete failed job must block.
DO $$
DECLARE
  v_user_id uuid;
  v_failed_job_id uuid;
  v_result jsonb;
BEGIN
  v_user_id := pg_temp.staging_reactivation_create_deleted_fan();

  BEGIN
    INSERT INTO public.account_deletion_jobs (
      subject_user_id,
      requested_by_user_id,
      request_source,
      deletion_mode,
      status,
      stage,
      idempotency_key
    ) VALUES (
      v_user_id,
      v_user_id,
      'system',
      'soft',
      'failed',
      'storage_cleanup',
      'reactivation-check-latest-failed-' || gen_random_uuid()::text
    )
    RETURNING id INTO v_failed_job_id;

    v_result := public.admin_reactivate_deleted_user_eligibility(v_user_id);

    IF coalesce(v_result ->> 'block_reason', '') = 'profile_not_deleted' THEN
      RAISE EXCEPTION 'FAIL: latest-job test fixture was not deleted. block_reason=%', v_result ->> 'block_reason';
    END IF;

    IF coalesce(v_result ->> 'block_reason', '') <> 'deletion_job_not_completed' THEN
      RAISE EXCEPTION 'FAIL: latest failed job should block with deletion_job_not_completed, got %', v_result ->> 'block_reason';
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      PERFORM pg_temp.staging_reactivation_teardown(v_user_id);
      RAISE;
  END;

  PERFORM pg_temp.staging_reactivation_teardown(v_user_id);

  RAISE NOTICE 'PASS: latest failed job blocks reactivation';
END;
$$;

DO $$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef('public.enforce_fan_account_identity_guard()'::regprocedure);
  IF position('gameon.account_reactivation_restore' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: enforce_fan_account_identity_guard missing reactivation bypass';
  END IF;

  RAISE NOTICE 'PASS: identity guard reactivation bypass present';
END;
$$;

DO $$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef('public.admin_reactivate_deleted_user(uuid,text,text,text,text)'::regprocedure);
  IF position('display_name_normalized =' IN v_def) > 0 THEN
    RAISE EXCEPTION 'FAIL: admin_reactivate_deleted_user still assigns display_name_normalized directly';
  END IF;

  RAISE NOTICE 'PASS: reactivation mutation does not assign display_name_normalized';
END;
$$;

-- End-to-end reactivation: generated display_name_normalized, profile shell restore, idempotency.
DO $$
DECLARE
  v_fixture record;
  v_user_id uuid;
  v_job_id uuid;
  v_original_email text;
  v_admin_display_name text := 'Reactivated Staging Name';
  v_result jsonb;
  v_repeat jsonb;
  v_profile public.user_profiles%ROWTYPE;
  v_job_before public.account_deletion_jobs%ROWTYPE;
  v_job_after public.account_deletion_jobs%ROWTYPE;
  v_event_count integer;
  v_expected_normalized text;
BEGIN
  SELECT *
    INTO v_fixture
  FROM pg_temp.staging_reactivation_create_eligible_deleted_fan();

  v_user_id := v_fixture.subject_user_id;
  v_job_id := v_fixture.deletion_job_id;
  v_original_email := v_fixture.original_email;
  v_expected_normalized := nullif(lower(btrim(v_admin_display_name)), '');

  SELECT * INTO v_job_before
  FROM public.account_deletion_jobs j
  WHERE j.id = v_job_id;

  BEGIN
    v_result := public.admin_reactivate_deleted_user(
      v_user_id,
      v_admin_display_name,
      'staging reactivation mutation check',
      NULL,
      'staging-admin@reactivation.test'
    );

    IF coalesce(v_result ->> 'ok', 'false') <> 'true' THEN
      RAISE EXCEPTION 'FAIL: eligible deleted fan reactivation failed: %', v_result;
    END IF;

    IF coalesce(v_result ->> 'idempotent', 'true') = 'true' THEN
      RAISE EXCEPTION 'FAIL: first reactivation should not be idempotent: %', v_result;
    END IF;

    SELECT * INTO v_profile
    FROM public.user_profiles up
    WHERE up.id = v_user_id;

    IF coalesce(v_profile.is_deleted, false) <> false THEN
      RAISE EXCEPTION 'FAIL: is_deleted should be false after reactivation';
    END IF;

    IF v_profile.deleted_at IS NOT NULL OR v_profile.anonymized_at IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL: deleted_at/anonymized_at should be cleared after reactivation';
    END IF;

    IF lower(btrim(v_profile.email)) <> v_original_email THEN
      RAISE EXCEPTION 'FAIL: profile email not restored. expected %, got %', v_original_email, v_profile.email;
    END IF;

    IF btrim(v_profile.display_name) <> v_admin_display_name THEN
      RAISE EXCEPTION 'FAIL: display_name not set to admin value';
    END IF;

    IF v_profile.display_name_normalized IS DISTINCT FROM v_expected_normalized THEN
      RAISE EXCEPTION 'FAIL: display_name_normalized not derived from display_name. expected %, got %',
        v_expected_normalized, v_profile.display_name_normalized;
    END IF;

    SELECT count(*) INTO v_event_count
    FROM public.account_reactivation_events e
    WHERE e.subject_user_id = v_user_id;

    IF v_event_count <> 1 THEN
      RAISE EXCEPTION 'FAIL: expected exactly one reactivation event, got %', v_event_count;
    END IF;

    v_repeat := public.admin_reactivate_deleted_user(
      v_user_id,
      v_admin_display_name,
      'staging reactivation idempotency check',
      NULL,
      'staging-admin@reactivation.test'
    );

    IF coalesce(v_repeat ->> 'ok', 'false') <> 'true'
       OR coalesce(v_repeat ->> 'idempotent', 'false') <> 'true' THEN
      RAISE EXCEPTION 'FAIL: repeat reactivation should be idempotent: %', v_repeat;
    END IF;

    SELECT count(*) INTO v_event_count
    FROM public.account_reactivation_events e
    WHERE e.subject_user_id = v_user_id;

    IF v_event_count <> 1 THEN
      RAISE EXCEPTION 'FAIL: repeat submit created duplicate reactivation event, count=%', v_event_count;
    END IF;

    SELECT * INTO v_job_after
    FROM public.account_deletion_jobs j
    WHERE j.id = v_job_id;

    IF v_job_after IS DISTINCT FROM v_job_before THEN
      RAISE EXCEPTION 'FAIL: completed deletion job changed after reactivation';
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      PERFORM pg_temp.staging_reactivation_teardown(v_user_id);
      RAISE;
  END;

  PERFORM pg_temp.staging_reactivation_teardown(v_user_id);

  RAISE NOTICE 'PASS: eligible deleted fan reactivation succeeds with derived display_name_normalized';
END;
$$;

-- Manual verification templates:
-- 1. moderation-disabled deleted user -> block_reason=moderation_disable_requires_resolution
-- 2. active user_bans row -> block_reason=active_moderation_ban
-- 3. unrelated auth.users.banned_until -> auth_ban_preserved=true and ban remains
-- 4. auth.users raw_app_meta_data.banned_for_account_deletion=true -> auth_ban_clear_eligible=true only then
-- 5. repeat successful admin_reactivate_deleted_user -> idempotent=true with no duplicate account_reactivation_events
-- 6. account_deletion_jobs rows unchanged after reactivation
-- 7. handle conflict returns error=handle_conflict without uncaught unique_violation
