-- Staging integrity checks for fan account deletion Phase 2.
-- Run manually on staging after applying 20260843_0001_user_account_deletion_phase2.sql.
-- Does not delete real users; validates schema, RPC presence, grants, and blocker logic.

\set ON_ERROR_STOP on

DO $$
BEGIN
  IF to_regclass('public.account_deletion_jobs') IS NULL THEN
    RAISE EXCEPTION 'FAIL: account_deletion_jobs table missing';
  END IF;

  IF to_regprocedure('public.preview_delete_user_account(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: preview_delete_user_account missing';
  END IF;

  IF to_regprocedure('public.start_account_deletion_job(text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: start_account_deletion_job missing';
  END IF;

  IF to_regprocedure('public.execute_delete_user_account_db(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: execute_delete_user_account_db missing';
  END IF;

  IF to_regprocedure('public.advance_account_deletion_job(uuid,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: advance_account_deletion_job(uuid,text,text,text) missing';
  END IF;

  IF to_regprocedure('public.advance_account_deletion_job(uuid,text,text,text,text,boolean)') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: legacy advance_account_deletion_job overload still present';
  END IF;

  IF to_regprocedure('public.queue_account_deletion_finalize(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: queue_account_deletion_finalize missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'account_deletion_jobs_one_active_per_subject'
  ) THEN
    RAISE EXCEPTION 'FAIL: partial unique index account_deletion_jobs_one_active_per_subject missing';
  END IF;

  RAISE NOTICE 'PASS: Phase 2 deletion objects present';
END;
$$;

-- Grants: authenticated must not execute advance_account_deletion_job or queue finalize.
DO $$
BEGIN
  IF has_function_privilege('authenticated', 'public.advance_account_deletion_job(uuid,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: authenticated can EXECUTE advance_account_deletion_job';
  END IF;

  IF has_function_privilege('authenticated', 'public.queue_account_deletion_finalize(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: authenticated can EXECUTE queue_account_deletion_finalize';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.preview_delete_user_account(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: authenticated cannot EXECUTE preview_delete_user_account';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.request_delete_my_account()', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: authenticated cannot EXECUTE request_delete_my_account';
  END IF;

  IF NOT has_function_privilege('service_role', 'public.advance_account_deletion_job(uuid,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: service_role cannot EXECUTE advance_account_deletion_job';
  END IF;

  RAISE NOTICE 'PASS: grant matrix for advance/queue RPCs';
END;
$$;

-- advance_account_deletion_job transition whitelist (service_role simulation via direct call).
DO $$
DECLARE
  v_job_id uuid;
  v_user_id uuid;
  v_result jsonb;
BEGIN
  SELECT id INTO v_user_id FROM auth.users ORDER BY created_at LIMIT 1;
  IF v_user_id IS NULL THEN
    RAISE NOTICE 'SKIP: no auth.users row for advance transition test';
    RETURN;
  END IF;

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
    'db_committed',
    'awaiting_storage_finalize',
    'staging-check-' || gen_random_uuid()::text
  )
  RETURNING id INTO v_job_id;

  PERFORM set_config('request.jwt.claim.role', 'service_role', true);

  v_result := public.advance_account_deletion_job(v_job_id, 'mark_storage_pending');
  IF coalesce(v_result ->> 'status', '') <> 'storage_pending' THEN
    RAISE EXCEPTION 'FAIL: mark_storage_pending expected storage_pending, got %', v_result ->> 'status';
  END IF;

  v_result := public.advance_account_deletion_job(v_job_id, 'mark_completed');
  IF coalesce(v_result ->> 'status', '') <> 'completed' THEN
    RAISE EXCEPTION 'FAIL: mark_completed expected completed, got %', v_result ->> 'status';
  END IF;

  BEGIN
    v_result := public.advance_account_deletion_job(v_job_id, 'mark_storage_pending');
    IF coalesce(v_result ->> 'idempotent_replay', 'false') <> 'true'
       OR coalesce(v_result ->> 'status', '') <> 'completed' THEN
      RAISE EXCEPTION 'FAIL: completed job should be terminal/idempotent, got %', v_result;
    END IF;
  END;

  DELETE FROM public.account_deletion_jobs WHERE id = v_job_id;
  RAISE NOTICE 'PASS: advance_account_deletion_job transition whitelist';
END;
$$;

-- Blocker smoke: business account_type should block preview.
DO $$
DECLARE
  v_user_id uuid;
  v_preview jsonb;
BEGIN
  IF to_regclass('public.account_identities') IS NULL THEN
    RAISE NOTICE 'SKIP: account_identities not present';
    RETURN;
  END IF;

  SELECT ai.account_id
    INTO v_user_id
  FROM public.account_identities ai
  WHERE ai.account_type = 'business'
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE NOTICE 'SKIP: no business account_identities row for blocker smoke test';
    RETURN;
  END IF;

  PERFORM set_config('request.jwt.claim.role', 'service_role', true);
  v_preview := public.preview_delete_user_account(v_user_id);

  IF coalesce(v_preview ->> 'blocked', 'false') <> 'true' THEN
    RAISE EXCEPTION 'FAIL: business account should be blocked in preview';
  END IF;

  IF v_preview ->> 'block_reason' NOT IN (
    'business_account_type', 'business_ownership', 'business_email_ownership',
    'business_profile_flag', 'venue_ownership', 'pending_venue_claim'
  ) THEN
    RAISE EXCEPTION 'FAIL: unexpected business block reason: %', v_preview ->> 'block_reason';
  END IF;

  RAISE NOTICE 'PASS: business blocker preview smoke test';
END;
$$;

-- Blocker smoke: owned business (any admin_status) blocks deletion.
DO $$
DECLARE
  v_user_id uuid;
  v_reason text;
BEGIN
  IF to_regclass('public.businesses') IS NULL THEN
    RAISE NOTICE 'SKIP: businesses table not present';
    RETURN;
  END IF;

  SELECT b.owner_user_id
    INTO v_user_id
  FROM public.businesses b
  WHERE b.owner_user_id IS NOT NULL
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE NOTICE 'SKIP: no businesses.owner_user_id row for ownership blocker test';
    RETURN;
  END IF;

  v_reason := public.gameon_account_deletion_block_reason(v_user_id);
  IF v_reason IS DISTINCT FROM 'business_ownership' THEN
    RAISE EXCEPTION 'FAIL: expected business_ownership, got %', v_reason;
  END IF;

  RAISE NOTICE 'PASS: business_ownership blocker';
END;
$$;

-- Blocker smoke: email-only business ownership.
DO $$
DECLARE
  v_email text;
  v_user_id uuid;
  v_reason text;
BEGIN
  IF to_regclass('public.businesses') IS NULL OR to_regclass('public.user_profiles') IS NULL THEN
    RAISE NOTICE 'SKIP: businesses/user_profiles not present';
    RETURN;
  END IF;

  SELECT lower(btrim(b.owner_email))
    INTO v_email
  FROM public.businesses b
  WHERE b.owner_user_id IS NULL
    AND coalesce(btrim(b.owner_email), '') <> ''
  LIMIT 1;

  IF v_email IS NULL THEN
    RAISE NOTICE 'SKIP: no email-only business row';
    RETURN;
  END IF;

  SELECT up.id
    INTO v_user_id
  FROM public.user_profiles up
  WHERE lower(btrim(up.email)) = v_email
    AND coalesce(up.is_deleted, false) = false
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE NOTICE 'SKIP: no fan profile matching email-only business owner_email';
    RETURN;
  END IF;

  v_reason := public.gameon_account_deletion_block_reason(v_user_id);
  IF v_reason NOT IN ('business_email_ownership', 'business_ownership', 'business_account_type') THEN
    RAISE EXCEPTION 'FAIL: expected email-only business blocker, got %', v_reason;
  END IF;

  RAISE NOTICE 'PASS: business_email_ownership blocker';
END;
$$;

-- Blocker smoke: venue ownership.
DO $$
DECLARE
  v_user_id uuid;
  v_reason text;
BEGIN
  IF to_regclass('public.venues') IS NULL THEN
    RAISE NOTICE 'SKIP: venues table not present';
    RETURN;
  END IF;

  SELECT v.owner_user_id
    INTO v_user_id
  FROM public.venues v
  WHERE v.owner_user_id IS NOT NULL
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE NOTICE 'SKIP: no venues.owner_user_id row';
    RETURN;
  END IF;

  v_reason := public.gameon_account_deletion_block_reason(v_user_id);
  IF v_reason NOT IN ('venue_ownership', 'business_ownership', 'business_account_type') THEN
    RAISE EXCEPTION 'FAIL: expected venue/business ownership blocker, got %', v_reason;
  END IF;

  RAISE NOTICE 'PASS: venue_ownership blocker';
END;
$$;

-- Identity guard bypass is present in enforce_fan_account_identity_guard.
DO $$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef('public.enforce_fan_account_identity_guard()'::regprocedure)
    INTO v_def;

  IF position('gameon.account_deletion_anonymize' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: enforce_fan_account_identity_guard missing anonymization bypass';
  END IF;

  RAISE NOTICE 'PASS: identity guard anonymization bypass present';
END;
$$;

-- Soft-delete invariant: request_delete_my_account wrapper must not advertise auth deletion.
DO $$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef('public.request_delete_my_account()'::regprocedure)
    INTO v_def;

  IF position('auth.users' IN lower(v_def)) > 0 AND position('delete' IN lower(v_def)) > 0 THEN
    RAISE EXCEPTION 'FAIL: request_delete_my_account appears to reference auth.users deletion';
  END IF;

  IF position('finalize_queued' IN v_def) = 0 OR position('finalize_queue' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: request_delete_my_account missing accurate finalize queue reporting';
  END IF;

  RAISE NOTICE 'PASS: request_delete_my_account response shape';
END;
$$;

-- execute_delete_user_account_db returns structured failure without rethrow on db_cleanup errors.
DO $$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef('public.execute_delete_user_account_db(uuid)'::regprocedure)
    INTO v_def;

  IF position('RETURN jsonb_build_object' IN v_def) = 0
     OR position('''ok'', false' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: execute_delete_user_account_db missing structured failure return';
  END IF;

  IF position('RAISE;' IN v_def) > 0 THEN
    RAISE EXCEPTION 'FAIL: execute_delete_user_account_db may rethrow after failure persistence';
  END IF;

  RAISE NOTICE 'PASS: execute_delete_user_account_db failure handling';
END;
$$;

-- PII clearing: soft-delete core clears location/national-team fields when present.
DO $$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef('public.gameon_account_deletion_soft_delete_core(uuid,text)'::regprocedure)
    INTO v_def;

  IF position('home_city' IN v_def) = 0
     OR position('national_team_country_code' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: soft-delete core missing location/national-team PII clears';
  END IF;

  IF position('gameon.account_deletion_anonymize' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: soft-delete core missing identity-guard bypass GUC';
  END IF;

  RAISE NOTICE 'PASS: soft-delete core PII clearing and bypass GUC';
END;
$$;

-- Post-delete integrity template (run manually against a dedicated staging test user after a test deletion):
-- SELECT is_deleted, email LIKE '%@deleted.fangeo.local' AS anonymized_email,
--        home_city, home_region, national_team_country_code, last_seen_at
-- FROM public.user_profiles WHERE id = '<test-user-uuid>';
-- SELECT count(*) FROM public.user_push_tokens WHERE user_id = '<test-user-uuid>';  -- expect 0
-- SELECT count(*) FROM public.direct_messages WHERE sender_id = '<test-user-uuid>'; -- expect preserved >= prior
-- SELECT status, stage FROM public.account_deletion_jobs WHERE subject_user_id = '<test-user-uuid>' ORDER BY created_at DESC LIMIT 1;
-- Manual: failed db_cleanup retry — create job with status failed/stage db_cleanup for non-anonymized user, re-run execute_delete_user_account_db and expect ok=true.
