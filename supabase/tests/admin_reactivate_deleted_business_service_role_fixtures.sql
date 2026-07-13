-- Service-role fixture tests for admin deleted-business reactivation.
-- Run only with a service_role JWT context (Admin server action / staging automation).
-- Skips automatically when gameon_business_deletion_is_service_caller() is false.
--
-- Not SQL Editor compatible on its own: postgres in the SQL Editor lacks service_role claims.

DO $$
BEGIN
  IF NOT public.gameon_business_deletion_is_service_caller() THEN
    RAISE NOTICE 'SKIP: service-role fixture tests require service_role JWT context';
    RETURN;
  END IF;

  RAISE NOTICE 'BEGIN: service-role business reactivation fixture tests';
END;
$$;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION pg_temp.staging_business_reactivation_create_deleted_business(
  p_job_status text DEFAULT 'completed'
)
RETURNS TABLE(
  business_id uuid,
  owner_user_id uuid,
  deletion_job_id uuid,
  deletion_audit_id uuid,
  original_owner_email text,
  archived_venue_id uuid
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_business_id uuid := gen_random_uuid();
  v_owner_user_id uuid := gen_random_uuid();
  v_job_id uuid := gen_random_uuid();
  v_audit_id uuid := gen_random_uuid();
  v_venue_id uuid := gen_random_uuid();
  v_suffix text := replace(v_business_id::text, '-', '');
  v_original_email text := 'biz-react-staging-' || v_suffix || '@staging-reactivation.test';
  v_tombstone_email text := public.gameon_business_deletion_tombstone_email(v_business_id);
  v_handle text := 'br' || substr(v_suffix, 1, 18);
  v_now timestamptz := now();
  v_snapshot jsonb;
BEGIN
  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    phone_change, phone_change_token, email_change_token_current, reauthentication_token,
    is_super_admin, is_sso_user, is_anonymous
  ) VALUES (
    '00000000-0000-0000-0000-000000000000',
    v_owner_user_id,
    'authenticated',
    'authenticated',
    v_original_email,
    crypt('staging-business-reactivation-test-password', gen_salt('bf')),
    v_now,
    jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
    jsonb_build_object('email_verified', true),
    v_now,
    v_now,
    '', '', '', '', '', '', '', '',
    false, false, false
  );

  INSERT INTO public.account_identities (account_id, email, account_type)
  VALUES (v_owner_user_id, v_original_email, 'business');

  v_snapshot := jsonb_build_object(
    'id', v_business_id,
    'display_name', 'Staging Deleted Business',
    'owner_user_id', v_owner_user_id,
    'owner_email', v_original_email,
    'business_handle', v_handle,
    'admin_status', 'active',
    'plan_type', 'pro_promo',
    'plan_status', 'active',
    'sponsored_enabled', true,
    'statistics_enabled', true
  );

  INSERT INTO public.businesses (
    id, display_name, owner_user_id, owner_email, business_handle, admin_status,
    is_deleted, deleted_at, anonymized_at, deletion_requested_at,
    plan_type, plan_status, sponsored_enabled, statistics_enabled, pro_expires_at
  ) VALUES (
    v_business_id,
    'Deleted Business',
    v_owner_user_id,
    v_tombstone_email,
    NULL,
    'active',
    true,
    v_now,
    v_now,
    v_now,
    'free',
    'expired',
    false,
    false,
    NULL
  );

  INSERT INTO public.venues (
    id, venue_name, business_id, owner_user_id, owner_email,
    admin_status, admin_archived_at, admin_archived_reason, origin_type,
    latitude, longitude
  ) VALUES (
    v_venue_id,
    'Staging Archived Venue',
    v_business_id,
    v_owner_user_id,
    v_original_email,
    'archived',
    v_now,
    'business_account_deleted',
    'business',
    39.7392,
    -104.9903
  );

  INSERT INTO public.business_account_deletion_jobs (
    id, subject_business_id, subject_user_id, request_source, deletion_mode,
    status, stage, idempotency_key, completed_at
  ) VALUES (
    v_job_id,
    v_business_id,
    v_owner_user_id,
    'self_service',
    'soft',
    p_job_status,
    CASE WHEN p_job_status = 'completed' THEN 'completed' ELSE 'awaiting_storage_finalize' END,
    'staging-biz-reactivation-' || v_suffix,
    CASE WHEN p_job_status = 'completed' THEN v_now ELSE NULL END
  );

  INSERT INTO public.business_account_deletion_audit (
    id, business_id, deleted_by, deleted_by_email, business_snapshot,
    archived_venue_ids, deletion_job_id, deletion_mode, deleted_at
  ) VALUES (
    v_audit_id,
    v_business_id,
    v_owner_user_id,
    v_original_email,
    v_snapshot,
    ARRAY[v_venue_id]::uuid[],
    v_job_id,
    'soft',
    v_now
  );

  business_id := v_business_id;
  owner_user_id := v_owner_user_id;
  deletion_job_id := v_job_id;
  deletion_audit_id := v_audit_id;
  original_owner_email := v_original_email;
  archived_venue_id := v_venue_id;
  RETURN NEXT;
END;
$$;

DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
BEGIN
  IF NOT public.gameon_business_deletion_is_service_caller() THEN
    RETURN;
  END IF;

  SELECT *
    INTO v_fixture
  FROM pg_temp.staging_business_reactivation_create_deleted_business('db_committed');

  v_result := public.admin_reactivate_deleted_business_eligibility(v_fixture.business_id);
  IF coalesce(v_result ->> 'eligible', 'true') = 'true' THEN
    RAISE EXCEPTION 'FAIL: db_committed deletion job should block eligibility';
  END IF;

  IF coalesce(v_result ->> 'block_reason', '') <> 'storage_finalization_pending' THEN
    RAISE EXCEPTION 'FAIL: db_committed should block with storage_finalization_pending, got %', v_result;
  END IF;

  RAISE NOTICE 'PASS: db_committed deletion job blocks reactivation';
END;
$$;

DO $$
DECLARE
  v_fixture record;
  v_eligibility jsonb;
  v_result jsonb;
  v_before_venue_status text;
  v_after_venue_status text;
  v_before_job_status text;
  v_before_audit_deleted_at timestamptz;
  v_event_count integer;
  v_audit_count integer;
  v_new_display_name text := 'Reactivated Staging Business';
  v_new_handle text;
BEGIN
  IF NOT public.gameon_business_deletion_is_service_caller() THEN
    RETURN;
  END IF;

  SELECT *
    INTO v_fixture
  FROM pg_temp.staging_business_reactivation_create_deleted_business('completed');

  v_new_handle := 'rz' || substr(replace(v_fixture.business_id::text, '-', ''), 1, 18);

  v_eligibility := public.admin_reactivate_deleted_business_eligibility(v_fixture.business_id);
  IF coalesce(v_eligibility ->> 'eligible', 'false') <> 'true' THEN
    RAISE EXCEPTION 'FAIL: eligible tombstoned business should be eligible. payload=%', v_eligibility;
  END IF;

  SELECT v.admin_status, j.status, a.deleted_at
    INTO v_before_venue_status, v_before_job_status, v_before_audit_deleted_at
  FROM public.venues v
  CROSS JOIN public.business_account_deletion_jobs j
  CROSS JOIN public.business_account_deletion_audit a
  WHERE v.id = v_fixture.archived_venue_id
    AND j.id = v_fixture.deletion_job_id
    AND a.id = v_fixture.deletion_audit_id;

  v_result := public.admin_reactivate_deleted_business(
    v_fixture.business_id,
    v_new_display_name,
    'Staging reactivation test',
    'admin@staging-reactivation.test',
    format('REACTIVATE BUSINESS %s', lower(v_fixture.business_id::text)),
    v_new_handle
  );

  IF coalesce(v_result ->> 'ok', 'false') <> 'true' THEN
    RAISE EXCEPTION 'FAIL: reactivation should succeed. payload=%', v_result;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.businesses b
    WHERE b.id = v_fixture.business_id
      AND coalesce(b.is_deleted, false) = false
      AND b.deleted_at IS NULL
      AND lower(btrim(b.owner_email)) = lower(v_fixture.original_owner_email)
      AND b.display_name = v_new_display_name
      AND b.owner_user_id = v_fixture.owner_user_id
      AND b.plan_type = 'free'
      AND b.plan_status = 'expired'
      AND b.admin_status = 'active'
  ) THEN
    RAISE EXCEPTION 'FAIL: reactivated business shell fields incorrect';
  END IF;

  SELECT v.admin_status
    INTO v_after_venue_status
  FROM public.venues v
  WHERE v.id = v_fixture.archived_venue_id;

  IF v_after_venue_status IS DISTINCT FROM v_before_venue_status THEN
    RAISE EXCEPTION 'FAIL: archived venue status changed during business reactivation';
  END IF;

  SELECT count(*)::integer
    INTO v_event_count
  FROM public.business_reactivation_events e
  WHERE e.business_id = v_fixture.business_id;

  IF v_event_count < 1 THEN
    RAISE EXCEPTION 'FAIL: business_reactivation_events row missing';
  END IF;

  SELECT count(*)::integer
    INTO v_audit_count
  FROM public.admin_audit_logs l
  WHERE l.target_type = 'business'
    AND l.target_id = v_fixture.business_id::text
    AND l.action = 'reactivate_deleted_business';

  IF v_audit_count < 1 THEN
    RAISE EXCEPTION 'FAIL: admin_audit_logs row missing';
  END IF;

  v_result := public.admin_reactivate_deleted_business(
    v_fixture.business_id,
    v_new_display_name,
    'Staging reactivation repeat',
    'admin@staging-reactivation.test',
    format('REACTIVATE BUSINESS %s', lower(v_fixture.business_id::text)),
    v_new_handle
  );

  IF coalesce(v_result ->> 'ok', 'false') <> 'true'
     OR coalesce(v_result ->> 'idempotent', 'false') <> 'true' THEN
    RAISE EXCEPTION 'FAIL: repeat reactivation should be idempotent. payload=%', v_result;
  END IF;

  RAISE NOTICE 'PASS: end-to-end business reactivation fixture';
END;
$$;

DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
BEGIN
  IF NOT public.gameon_business_deletion_is_service_caller() THEN
    RETURN;
  END IF;

  SELECT *
    INTO v_fixture
  FROM pg_temp.staging_business_reactivation_create_deleted_business('completed');

  INSERT INTO public.business_bans (
    business_id, owner_user_id, owner_email, is_permanent, reason
  ) VALUES (
    v_fixture.business_id,
    v_fixture.owner_user_id,
    v_fixture.original_owner_email,
    true,
    'staging reactivation ban test'
  );

  v_result := public.admin_reactivate_deleted_business_eligibility(v_fixture.business_id);
  IF coalesce(v_result ->> 'eligible', 'true') = 'true' THEN
    RAISE EXCEPTION 'FAIL: active business ban should block eligibility';
  END IF;

  RAISE NOTICE 'PASS: active business ban blocks reactivation';
END;
$$;

DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
  v_other_business_id uuid := gen_random_uuid();
  v_suffix text := replace(v_other_business_id::text, '-', '');
BEGIN
  IF NOT public.gameon_business_deletion_is_service_caller() THEN
    RETURN;
  END IF;

  SELECT *
    INTO v_fixture
  FROM pg_temp.staging_business_reactivation_create_deleted_business('completed');

  INSERT INTO public.businesses (
    id, display_name, owner_user_id, owner_email, admin_status, is_deleted
  ) VALUES (
    v_other_business_id,
    'Conflicting Active Business',
    v_fixture.owner_user_id,
    'conflict-' || v_suffix || '@staging-reactivation.test',
    'active',
    false
  );

  v_result := public.admin_reactivate_deleted_business_eligibility(v_fixture.business_id);
  IF coalesce(v_result ->> 'eligible', 'true') = 'true' THEN
    RAISE EXCEPTION 'FAIL: second active business for owner should block eligibility';
  END IF;

  RAISE NOTICE 'PASS: second active business for owner blocks reactivation';
END;
$$;

DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
  v_other_user_id uuid := gen_random_uuid();
BEGIN
  IF NOT public.gameon_business_deletion_is_service_caller() THEN
    RETURN;
  END IF;

  SELECT *
    INTO v_fixture
  FROM pg_temp.staging_business_reactivation_create_deleted_business('completed');

  INSERT INTO public.account_identities (account_id, email, account_type)
  VALUES (v_other_user_id, v_fixture.original_owner_email, 'fan');

  v_result := public.admin_reactivate_deleted_business_eligibility(v_fixture.business_id);
  IF coalesce(v_result ->> 'eligible', 'true') = 'true' THEN
    RAISE EXCEPTION 'FAIL: owner email reserved to other account should block eligibility';
  END IF;

  RAISE NOTICE 'PASS: owner email conflict blocks reactivation';
END;
$$;

DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
  v_taken_handle text := 'takenbizhandle01';
BEGIN
  IF NOT public.gameon_business_deletion_is_service_caller() THEN
    RETURN;
  END IF;

  SELECT *
    INTO v_fixture
  FROM pg_temp.staging_business_reactivation_create_deleted_business('completed');

  INSERT INTO public.businesses (
    display_name, owner_email, business_handle, admin_status, is_deleted
  ) VALUES (
    'Handle Owner',
    'handle-owner-' || replace(gen_random_uuid()::text, '-', '') || '@staging-reactivation.test',
    v_taken_handle,
    'active',
    false
  );

  v_result := public.admin_reactivate_deleted_business_eligibility(v_fixture.business_id);
  IF coalesce(v_result ->> 'eligible', 'false') <> 'true' THEN
    RAISE EXCEPTION 'FAIL: base eligibility should remain true before handle request';
  END IF;

  v_result := public.gameon_business_reactivation_evaluate_eligibility(
    v_fixture.business_id,
    (SELECT b FROM public.businesses b WHERE b.id = v_fixture.business_id),
    (SELECT ai FROM public.account_identities ai WHERE ai.account_id = v_fixture.owner_user_id),
    (SELECT j FROM public.business_account_deletion_jobs j WHERE j.id = v_fixture.deletion_job_id),
    (SELECT a FROM public.business_account_deletion_audit a WHERE a.id = v_fixture.deletion_audit_id),
    v_taken_handle
  );

  IF coalesce(v_result ->> 'eligible', 'true') = 'true' THEN
    RAISE EXCEPTION 'FAIL: handle conflict should block eligibility when handle requested';
  END IF;

  RAISE NOTICE 'PASS: handle conflict blocks reactivation';
END;
$$;

DO $$
DECLARE
  v_business_id uuid := gen_random_uuid();
  v_owner_user_id uuid := gen_random_uuid();
  v_suffix text := replace(v_business_id::text, '-', '');
  v_email text := 'guard-test-' || v_suffix || '@staging-reactivation.test';
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
    v_owner_user_id,
    'authenticated',
    'authenticated',
    v_email,
    crypt('staging-business-reactivation-test-password', gen_salt('bf')),
    now(),
    jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
    jsonb_build_object('email_verified', true),
    now(),
    now(),
    '', '', '', '', '', '', '', '',
    false, false, false
  );

  INSERT INTO public.account_identities (account_id, email, account_type)
  VALUES (v_owner_user_id, v_email, 'business');

  INSERT INTO public.businesses (
    id, display_name, owner_user_id, owner_email, admin_status, is_deleted
  ) VALUES (
    v_business_id,
    'Guard Test Business',
    v_owner_user_id,
    v_email,
    'active',
    false
  );

  PERFORM set_config('request.jwt.claim.sub', v_owner_user_id::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

  BEGIN
    UPDATE public.businesses
    SET owner_email = 'wrong-' || v_suffix || '@staging-reactivation.test'
    WHERE id = v_business_id;
    RAISE EXCEPTION 'FAIL: identity guard should block arbitrary owner email reassignment';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT ILIKE '%Business owner email must match the authenticated user email.%' THEN
        RAISE;
      END IF;
  END;

  RAISE NOTICE 'PASS: normal business identity guard remains enforced';
END;
$$;
