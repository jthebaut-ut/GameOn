-- Staging integrity checks for business account deletion Phase 2.
-- Run manually on staging after applying 20260847_0001_business_account_deletion_phase2.sql.
-- Uses disposable fixtures; cleans up all rows it creates.

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- 1. Schema + RPC presence
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  IF to_regclass('public.business_account_deletion_jobs') IS NULL THEN
    RAISE EXCEPTION 'FAIL: business_account_deletion_jobs table missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'businesses'
      AND column_name = 'is_deleted'
  ) THEN
    RAISE EXCEPTION 'FAIL: businesses.is_deleted missing';
  END IF;

  IF to_regprocedure('public.preview_delete_business_account(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: preview_delete_business_account missing';
  END IF;

  IF to_regprocedure('public.start_business_account_deletion_job(text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: start_business_account_deletion_job missing';
  END IF;

  IF to_regprocedure('public.execute_delete_business_account_db(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: execute_delete_business_account_db missing';
  END IF;

  IF to_regprocedure('public.gameon_business_deletion_soft_delete_core(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: gameon_business_deletion_soft_delete_core missing';
  END IF;

  IF to_regprocedure('public.delete_business_account_cascade(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: delete_business_account_cascade missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'business_account_deletion_jobs_one_active_per_business'
  ) THEN
    RAISE EXCEPTION 'FAIL: partial unique index business_account_deletion_jobs_one_active_per_business missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'business_account_deletion_audit'
      AND column_name = 'deletion_mode'
      AND is_nullable = 'NO'
  ) THEN
    RAISE EXCEPTION 'FAIL: business_account_deletion_audit.deletion_mode must be NOT NULL';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.business_account_deletion_audit
    WHERE deletion_mode IS NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: deletion_mode backfill left NULL rows';
  END IF;

  RAISE NOTICE 'PASS: Phase 2 business deletion objects present';
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Grants
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  IF NOT has_function_privilege('authenticated', 'public.preview_delete_business_account(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: authenticated cannot EXECUTE preview_delete_business_account';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.delete_business_account_cascade(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: authenticated cannot EXECUTE delete_business_account_cascade';
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

  RAISE NOTICE 'PASS: business deletion grant matrix';
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Fixture harness (disposable business + venues + events)
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_owner_id uuid := gen_random_uuid();
  v_business_id uuid := gen_random_uuid();
  v_business_venue_id uuid := gen_random_uuid();
  v_community_venue_id uuid := gen_random_uuid();
  v_future_event_id uuid := gen_random_uuid();
  v_completed_event_id uuid := gen_random_uuid();
  v_claim_id uuid := gen_random_uuid();
  v_placement_id uuid := gen_random_uuid();
  v_job_id uuid;
  v_result jsonb;
  v_repeat jsonb;
  v_completed_count integer;
  v_archived_venue_count integer;
  v_released_venue record;
  v_business_row public.businesses%ROWTYPE;
  v_identity_count integer;
  v_auth_count integer;
  v_audit_count integer;
BEGIN
  -- Minimal auth.users row for ownership FK-less business tests.
  INSERT INTO auth.users (id, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  VALUES (
    v_owner_id,
    format('biz-delete-phase2-%s@example.com', replace(v_owner_id::text, '-', '')),
    crypt('staging-only', gen_salt('bf')),
    now(),
    now(),
    now()
  )
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.account_identities (account_id, email, account_type)
  VALUES (
    v_owner_id,
    format('biz-delete-phase2-%s@example.com', replace(v_owner_id::text, '-', '')),
    'business'
  )
  ON CONFLICT (account_id) DO UPDATE
    SET account_type = EXCLUDED.account_type;

  INSERT INTO public.businesses (
    id, display_name, owner_user_id, owner_email, admin_status,
    plan_type, plan_status, sponsored_enabled, statistics_enabled
  )
  VALUES (
    v_business_id,
    'Phase2 Staging Business',
    v_owner_id,
    format('biz-delete-phase2-%s@example.com', replace(v_owner_id::text, '-', '')),
    'active',
    'pro_promo',
    'active',
    true,
    true
  );

  INSERT INTO public.venues (
    id, venue_name, business_id, owner_user_id, owner_email,
    origin_type, admin_status, latitude, longitude
  )
  VALUES (
    v_business_venue_id,
    'Staging Business Venue',
    v_business_id,
    v_owner_id,
    format('biz-delete-phase2-%s@example.com', replace(v_owner_id::text, '-', '')),
    'business',
    'plan_locked',
    39.7392,
    -104.9903
  );

  INSERT INTO public.venues (
    id, venue_name, business_id, owner_user_id, owner_email,
    origin_type, admin_status, latitude, longitude
  )
  VALUES (
    v_community_venue_id,
    'Staging Community Venue',
    v_business_id,
    v_owner_id,
    format('biz-delete-phase2-%s@example.com', replace(v_owner_id::text, '-', '')),
    'community',
    'active',
    39.7400,
    -104.9910
  );

  INSERT INTO public.venue_claims (
    id, venue_id, business_id, owner_email, venue_name, approval_status
  )
  VALUES (
    v_claim_id,
    v_community_venue_id,
    v_business_id,
    format('biz-delete-phase2-%s@example.com', replace(v_owner_id::text, '-', '')),
    'Staging Community Venue',
    'approved'
  );

  INSERT INTO public.venue_events (
    id, venue_id, venue_name, event_title, sport, event_date, scheduled_start_at, admin_status
  )
  VALUES (
    v_future_event_id,
    v_business_venue_id,
    'Staging Business Venue',
    'Future Game',
    'soccer',
    (current_date + 7),
    now() + interval '7 days',
    'active'
  );

  INSERT INTO public.venue_events (
    id, venue_id, venue_name, event_title, sport, event_date, scheduled_start_at, admin_status
  )
  VALUES (
    v_completed_event_id,
    v_business_venue_id,
    'Staging Business Venue',
    'Completed Game',
    'soccer',
    (current_date - 30),
    now() - interval '30 days',
    'archived'
  );

  INSERT INTO public.sponsored_placements (
    id, venue_id, business_id, placement_key, title, starts_at, ends_at, status
  )
  VALUES (
    v_placement_id,
    v_business_venue_id,
    v_business_id,
    'profile_recommended_near_you',
    'Staging Placement',
    now() - interval '1 day',
    now() + interval '30 days',
    'active'
  );

  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config('request.jwt.claim.email', format('biz-delete-phase2-%s@example.com', replace(v_owner_id::text, '-', '')), true);

  v_result := public.delete_business_account_cascade(v_business_id);

  IF coalesce(v_result ->> 'ok', 'false') <> 'true' THEN
    RAISE EXCEPTION 'FAIL: delete_business_account_cascade returned ok=false: %', v_result;
  END IF;

  SELECT *
    INTO v_business_row
  FROM public.businesses b
  WHERE b.id = v_business_id;

  IF coalesce(v_business_row.is_deleted, false) <> true THEN
    RAISE EXCEPTION 'FAIL: business row not tombstoned';
  END IF;

  IF v_business_row.display_name <> 'Deleted Business' THEN
    RAISE EXCEPTION 'FAIL: business display_name not scrubbed';
  END IF;

  IF v_business_row.plan_status <> 'expired' THEN
    RAISE EXCEPTION 'FAIL: business plan_status not expired';
  END IF;

  SELECT count(*)
    INTO v_archived_venue_count
  FROM public.venues v
  WHERE v.id = v_business_venue_id
    AND lower(btrim(coalesce(v.admin_status, ''))) = 'archived';

  IF v_archived_venue_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: business-created venue not archived';
  END IF;

  SELECT *
    INTO v_released_venue
  FROM public.venues v
  WHERE v.id = v_community_venue_id;

  IF v_released_venue.business_id IS NOT NULL
     OR v_released_venue.owner_user_id IS NOT NULL
     OR lower(btrim(coalesce(v_released_venue.origin_type, ''))) <> 'community' THEN
    RAISE EXCEPTION 'FAIL: community venue not released';
  END IF;

  SELECT count(*)
    INTO v_completed_count
  FROM public.venue_events ve
  WHERE ve.id = v_completed_event_id;

  IF v_completed_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: completed event history was hard-deleted';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.venue_events ve
    WHERE ve.id = v_future_event_id
      AND lower(btrim(coalesce(ve.admin_status, ''))) = 'archived'
  ) THEN
    RAISE EXCEPTION 'FAIL: future event not archived';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.sponsored_placements sp
    WHERE sp.id = v_placement_id
      AND sp.status = 'paused'
  ) THEN
    RAISE EXCEPTION 'FAIL: sponsored placement not paused';
  END IF;

  SELECT count(*)
    INTO v_identity_count
  FROM public.account_identities ai
  WHERE ai.account_id = v_owner_id
    AND ai.account_type = 'business';

  IF v_identity_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: account_identities not retained';
  END IF;

  SELECT count(*)
    INTO v_auth_count
  FROM auth.users u
  WHERE u.id = v_owner_id;

  IF v_auth_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: auth.users not retained';
  END IF;

  SELECT count(*)
    INTO v_audit_count
  FROM public.business_account_deletion_audit a
  WHERE a.business_id = v_business_id
    AND a.deletion_mode = 'soft';

  IF v_audit_count < 1 THEN
    RAISE EXCEPTION 'FAIL: soft deletion audit row missing';
  END IF;

  IF (SELECT count(*) FROM public.business_account_deletion_audit WHERE business_id = v_business_id) <> 1 THEN
    RAISE EXCEPTION 'FAIL: expected exactly one audit row after first delete';
  END IF;

  -- Storage job integrity: DB committed but not completed.
  IF NOT EXISTS (
    SELECT 1
    FROM public.business_account_deletion_jobs j
    WHERE j.subject_business_id = v_business_id
      AND j.status = 'db_committed'
      AND j.stage = 'awaiting_storage_finalize'
      AND j.completed_at IS NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: job must be db_committed/awaiting_storage_finalize with completed_at NULL';
  END IF;

  IF coalesce(v_result ->> 'status', '') <> 'db_committed' THEN
    RAISE EXCEPTION 'FAIL: cascade response status must be db_committed, got %', v_result ->> 'status';
  END IF;

  IF coalesce((v_result ->> 'storage_finalization_pending')::boolean, false) <> true THEN
    RAISE EXCEPTION 'FAIL: cascade response must set storage_finalization_pending=true';
  END IF;

  -- Idempotent repeat delete.
  v_repeat := public.delete_business_account_cascade(v_business_id);
  IF coalesce(v_repeat ->> 'ok', 'false') <> 'true' THEN
    RAISE EXCEPTION 'FAIL: idempotent repeat delete failed: %', v_repeat;
  END IF;

  -- Audit immutability: attempt update should be prevented by app policy; count unchanged.
  IF (SELECT count(*) FROM public.business_account_deletion_audit WHERE business_id = v_business_id) < 1 THEN
    RAISE EXCEPTION 'FAIL: audit row missing after repeat delete';
  END IF;

  IF (SELECT count(*) FROM public.business_account_deletion_audit WHERE business_id = v_business_id) <> 1 THEN
    RAISE EXCEPTION 'FAIL: repeat delete must not create duplicate audit rows';
  END IF;

  -- Cleanup fixtures (business row retained as tombstone for audit linkage tests).
  DELETE FROM public.business_account_deletion_jobs WHERE subject_business_id = v_business_id;
  DELETE FROM public.sponsored_placements WHERE id = v_placement_id;
  DELETE FROM public.venue_events WHERE id IN (v_future_event_id, v_completed_event_id);
  DELETE FROM public.venue_claims WHERE id = v_claim_id;
  DELETE FROM public.venues WHERE id IN (v_business_venue_id, v_community_venue_id);
  DELETE FROM public.business_account_deletion_audit WHERE business_id = v_business_id;
  DELETE FROM public.businesses WHERE id = v_business_id;
  DELETE FROM public.account_identities WHERE account_id = v_owner_id;
  DELETE FROM auth.users WHERE id = v_owner_id;

  RAISE NOTICE 'PASS: business deletion phase 2 fixture scenario (mixed venues, pro, placement, events)';
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. No-venue business fixture
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_owner_id uuid := gen_random_uuid();
  v_business_id uuid := gen_random_uuid();
  v_result jsonb;
BEGIN
  INSERT INTO auth.users (id, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  VALUES (
    v_owner_id,
    format('biz-delete-zero-%s@example.com', replace(v_owner_id::text, '-', '')),
    crypt('staging-only', gen_salt('bf')),
    now(), now(), now()
  );

  INSERT INTO public.account_identities (account_id, email, account_type)
  VALUES (
    v_owner_id,
    format('biz-delete-zero-%s@example.com', replace(v_owner_id::text, '-', '')),
    'business'
  );

  INSERT INTO public.businesses (id, display_name, owner_user_id, owner_email, admin_status)
  VALUES (
    v_business_id,
    'Zero Venue Business',
    v_owner_id,
    format('biz-delete-zero-%s@example.com', replace(v_owner_id::text, '-', '')),
    'active'
  );

  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config('request.jwt.claim.email', format('biz-delete-zero-%s@example.com', replace(v_owner_id::text, '-', '')), true);

  v_result := public.delete_business_account_cascade(v_business_id);

  IF coalesce(v_result ->> 'ok', 'false') <> 'true' THEN
    RAISE EXCEPTION 'FAIL: zero-venue business delete failed: %', v_result;
  END IF;

  DELETE FROM public.business_account_deletion_jobs WHERE subject_business_id = v_business_id;
  DELETE FROM public.business_account_deletion_audit WHERE business_id = v_business_id;
  DELETE FROM public.businesses WHERE id = v_business_id;
  DELETE FROM public.account_identities WHERE account_id = v_owner_id;
  DELETE FROM auth.users WHERE id = v_owner_id;

  RAISE NOTICE 'PASS: zero-venue business deletion';
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. Generated-column safety (businesses/venues/venue_events/user_profiles)
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_body text;
  v_fn text;
  v_generated_cols text[];
BEGIN
  SELECT coalesce(array_agg(column_name ORDER BY column_name), ARRAY[]::text[])
    INTO v_generated_cols
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name IN ('businesses', 'venues', 'venue_events', 'user_profiles')
    AND is_generated = 'ALWAYS';

  FOREACH v_fn IN ARRAY ARRAY[
    'public.gameon_business_deletion_soft_delete_core(uuid,uuid)',
    'public.execute_delete_business_account_db(uuid)',
    'public.delete_business_account_cascade(uuid)'
  ]
  LOOP
    SELECT pg_get_functiondef(v_fn::regprocedure)
      INTO v_body;

  IF v_body ILIKE '%purge_after_at =%' THEN
    RAISE EXCEPTION 'FAIL: % must not assign venue_events.purge_after_at (GENERATED)', v_fn;
  END IF;

  IF v_body ILIKE '%display_name_normalized =%' THEN
    RAISE EXCEPTION 'FAIL: % must not assign display_name_normalized', v_fn;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(v_generated_cols) AS gc(col)
    WHERE position((col || ' =') IN v_body) > 0
  ) THEN
    RAISE EXCEPTION 'FAIL: % appears to assign a GENERATED ALWAYS column', v_fn;
  END IF;
  END LOOP;

  RAISE NOTICE 'PASS: no generated-column assignments in business deletion RPC bodies';
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. deletion_mode classification (legacy hard vs Phase 2 soft)
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_legacy_business_id uuid := gen_random_uuid();
  v_soft_business_id uuid := gen_random_uuid();
  v_owner_id uuid := gen_random_uuid();
  v_result jsonb;
BEGIN
  INSERT INTO public.business_account_deletion_audit (
    business_id,
    deleted_by,
    business_snapshot,
    released_venue_ids,
    hard_deleted_venue_ids,
    deleted_event_ids,
    deleted_storage_paths,
    deleted_counts,
    deletion_mode
  )
  VALUES (
    v_legacy_business_id,
    v_owner_id,
    '{}'::jsonb,
    ARRAY[]::uuid[],
    ARRAY[]::uuid[],
    ARRAY[]::uuid[],
    ARRAY[]::text[],
    '{}'::jsonb,
    'hard'
  );

  IF NOT EXISTS (
    SELECT 1
    FROM public.business_account_deletion_audit
    WHERE business_id = v_legacy_business_id
      AND deletion_mode = 'hard'
  ) THEN
    RAISE EXCEPTION 'FAIL: legacy fixture audit row must remain hard';
  END IF;

  INSERT INTO auth.users (id, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  VALUES (
    v_owner_id,
    format('biz-delete-mode-%s@example.com', replace(v_owner_id::text, '-', '')),
    crypt('staging-only', gen_salt('bf')),
    now(), now(), now()
  );

  INSERT INTO public.businesses (id, display_name, owner_user_id, owner_email, admin_status)
  VALUES (
    v_soft_business_id,
    'Mode Classification Business',
    v_owner_id,
    format('biz-delete-mode-%s@example.com', replace(v_owner_id::text, '-', '')),
    'active'
  );

  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config('request.jwt.claim.email', format('biz-delete-mode-%s@example.com', replace(v_owner_id::text, '-', '')), true);

  v_result := public.delete_business_account_cascade(v_soft_business_id);

  IF coalesce(v_result ->> 'deletion_mode', '') <> 'soft' THEN
    RAISE EXCEPTION 'FAIL: Phase 2 cascade must report deletion_mode=soft';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.business_account_deletion_audit
    WHERE business_id = v_soft_business_id
      AND deletion_mode = 'soft'
  ) THEN
    RAISE EXCEPTION 'FAIL: Phase 2 audit row must be soft';
  END IF;

  DELETE FROM public.business_account_deletion_jobs WHERE subject_business_id = v_soft_business_id;
  DELETE FROM public.business_account_deletion_audit WHERE business_id IN (v_legacy_business_id, v_soft_business_id);
  DELETE FROM public.businesses WHERE id = v_soft_business_id;
  DELETE FROM auth.users WHERE id = v_owner_id;

  RAISE NOTICE 'PASS: deletion_mode legacy=hard, phase2=soft';
END;
$$;

-- ---------------------------------------------------------------------------
-- 7. Storage lifecycle + service_role advance guards
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_owner_id uuid := gen_random_uuid();
  v_business_id uuid := gen_random_uuid();
  v_job_id uuid;
  v_result jsonb;
  v_forge_failed boolean := false;
BEGIN
  INSERT INTO auth.users (id, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  VALUES (
    v_owner_id,
    format('biz-delete-storage-%s@example.com', replace(v_owner_id::text, '-', '')),
    crypt('staging-only', gen_salt('bf')),
    now(), now(), now()
  );

  INSERT INTO public.businesses (id, display_name, owner_user_id, owner_email, admin_status)
  VALUES (
    v_business_id,
    'Storage Lifecycle Business',
    v_owner_id,
    format('biz-delete-storage-%s@example.com', replace(v_owner_id::text, '-', '')),
    'active'
  );

  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config('request.jwt.claim.email', format('biz-delete-storage-%s@example.com', replace(v_owner_id::text, '-', '')), true);

  v_result := public.delete_business_account_cascade(v_business_id);
  v_job_id := (v_result ->> 'job_id')::uuid;

  IF v_job_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: storage lifecycle test missing job_id';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.business_account_deletion_jobs
    WHERE id = v_job_id AND status = 'completed'
  ) THEN
    RAISE EXCEPTION 'FAIL: job must not be completed before storage finalization';
  END IF;

  PERFORM set_config('request.jwt.claim.role', 'service_role', true);

  BEGIN
    PERFORM public.advance_business_account_deletion_job(v_job_id, 'mark_completed');
    RAISE EXCEPTION 'FAIL: mark_completed must not succeed from db_committed';
  EXCEPTION
    WHEN OTHERS THEN
      NULL;
  END;

  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);

  BEGIN
    PERFORM public.advance_business_account_deletion_job(v_job_id, 'mark_completed');
    v_forge_failed := false;
  EXCEPTION
    WHEN OTHERS THEN
      v_forge_failed := true;
  END;

  IF NOT v_forge_failed THEN
    RAISE EXCEPTION 'FAIL: authenticated owner must not advance job to completed';
  END IF;

  PERFORM set_config('request.jwt.claim.role', 'service_role', true);
  PERFORM public.advance_business_account_deletion_job(v_job_id, 'mark_storage_pending');

  IF NOT EXISTS (
    SELECT 1 FROM public.business_account_deletion_jobs
    WHERE id = v_job_id
      AND status = 'storage_pending'
      AND stage = 'storage_cleanup'
      AND completed_at IS NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: service_role mark_storage_pending transition failed';
  END IF;

  BEGIN
    PERFORM public.advance_business_account_deletion_job(v_job_id, 'mark_completed');
  EXCEPTION
    WHEN OTHERS THEN
      RAISE EXCEPTION 'FAIL: mark_completed should succeed from storage_pending: %', SQLERRM;
  END;

  IF NOT EXISTS (
    SELECT 1 FROM public.business_account_deletion_jobs
    WHERE id = v_job_id
      AND status = 'completed'
      AND stage = 'completed'
      AND completed_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: job must be completed only after storage_pending advance';
  END IF;

  v_result := public.queue_business_account_deletion_finalize(v_job_id);
  IF coalesce(v_result ->> 'job_mutated', 'true') = 'true' THEN
    RAISE EXCEPTION 'FAIL: queue_business_account_deletion_finalize stub must not mutate job';
  END IF;

  DELETE FROM public.business_account_deletion_jobs WHERE id = v_job_id;
  DELETE FROM public.business_account_deletion_audit WHERE business_id = v_business_id;
  DELETE FROM public.businesses WHERE id = v_business_id;
  DELETE FROM auth.users WHERE id = v_owner_id;

  RAISE NOTICE 'PASS: storage lifecycle guards and service_role advance path';
END;
$$;

-- ---------------------------------------------------------------------------
-- 8. Ban does not block deletion; dual fan profile preserved
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_owner_id uuid := gen_random_uuid();
  v_business_id uuid := gen_random_uuid();
  v_ban_id uuid := gen_random_uuid();
  v_profile_before public.user_profiles%ROWTYPE;
  v_profile_after public.user_profiles%ROWTYPE;
  v_result jsonb;
BEGIN
  INSERT INTO auth.users (id, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  VALUES (
    v_owner_id,
    format('biz-delete-dual-%s@example.com', replace(v_owner_id::text, '-', '')),
    crypt('staging-only', gen_salt('bf')),
    now(), now(), now()
  );

  INSERT INTO public.user_profiles (id, display_name, email)
  VALUES (
    v_owner_id,
    'Dual Fan Business Owner',
    format('biz-delete-dual-%s@example.com', replace(v_owner_id::text, '-', ''))
  );

  INSERT INTO public.account_identities (account_id, email, account_type)
  VALUES (
    v_owner_id,
    format('biz-delete-dual-%s@example.com', replace(v_owner_id::text, '-', '')),
    'business'
  );

  INSERT INTO public.businesses (id, display_name, owner_user_id, owner_email, admin_status)
  VALUES (
    v_business_id,
    'Dual Account Business',
    v_owner_id,
    format('biz-delete-dual-%s@example.com', replace(v_owner_id::text, '-', '')),
    'active'
  );

  INSERT INTO public.business_bans (
    id, business_id, owner_user_id, owner_email, is_permanent, reason
  )
  VALUES (
    v_ban_id,
    v_business_id,
    v_owner_id,
    format('biz-delete-dual-%s@example.com', replace(v_owner_id::text, '-', '')),
    true,
    'staging active business ban'
  );

  SELECT * INTO v_profile_before FROM public.user_profiles WHERE id = v_owner_id;

  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config('request.jwt.claim.email', format('biz-delete-dual-%s@example.com', replace(v_owner_id::text, '-', '')), true);

  v_result := public.delete_business_account_cascade(v_business_id);

  IF coalesce(v_result ->> 'ok', 'false') <> 'true' THEN
    RAISE EXCEPTION 'FAIL: active business_bans must not block self-service deletion: %', v_result;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.business_bans WHERE id = v_ban_id AND lifted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: business_bans row must be preserved';
  END IF;

  SELECT * INTO v_profile_after FROM public.user_profiles WHERE id = v_owner_id;

  IF coalesce(v_profile_after.is_deleted, false) THEN
    RAISE EXCEPTION 'FAIL: fan user_profiles.is_deleted must not be set by business deletion';
  END IF;

  IF v_profile_after.display_name IS DISTINCT FROM v_profile_before.display_name THEN
    RAISE EXCEPTION 'FAIL: fan display_name must remain unchanged';
  END IF;

  IF v_profile_after.email IS DISTINCT FROM v_profile_before.email THEN
    RAISE EXCEPTION 'FAIL: fan email must remain unchanged';
  END IF;

  DELETE FROM public.business_account_deletion_jobs WHERE subject_business_id = v_business_id;
  DELETE FROM public.business_account_deletion_audit WHERE business_id = v_business_id;
  DELETE FROM public.business_bans WHERE id = v_ban_id;
  DELETE FROM public.businesses WHERE id = v_business_id;
  DELETE FROM public.account_identities WHERE account_id = v_owner_id;
  DELETE FROM public.user_profiles WHERE id = v_owner_id;
  DELETE FROM auth.users WHERE id = v_owner_id;

  RAISE NOTICE 'PASS: bans preserved, dual fan profile unchanged';
END;
$$;

-- ---------------------------------------------------------------------------
-- 9. Completed history preservation predicate
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_owner_id uuid := gen_random_uuid();
  v_business_id uuid := gen_random_uuid();
  v_venue_id uuid := gen_random_uuid();
  v_future_event_id uuid := gen_random_uuid();
  v_completed_event_id uuid := gen_random_uuid();
  v_completed_before public.venue_events%ROWTYPE;
  v_completed_after public.venue_events%ROWTYPE;
  v_archived_venue public.venues%ROWTYPE;
BEGIN
  INSERT INTO auth.users (id, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  VALUES (
    v_owner_id,
    format('biz-delete-history-%s@example.com', replace(v_owner_id::text, '-', '')),
    crypt('staging-only', gen_salt('bf')),
    now(), now(), now()
  );

  INSERT INTO public.businesses (id, display_name, owner_user_id, owner_email, admin_status)
  VALUES (
    v_business_id,
    'History Preservation Business',
    v_owner_id,
    format('biz-delete-history-%s@example.com', replace(v_owner_id::text, '-', '')),
    'active'
  );

  INSERT INTO public.venues (
    id, venue_name, business_id, owner_user_id, owner_email,
    origin_type, admin_status, latitude, longitude, phone, website
  )
  VALUES (
    v_venue_id,
    'History Venue',
    v_business_id,
    v_owner_id,
    format('biz-delete-history-%s@example.com', replace(v_owner_id::text, '-', '')),
    'business',
    'active',
    39.7392,
    -104.9903,
    '555-0200',
    'https://private.example.com'
  );

  INSERT INTO public.venue_events (
    id, venue_id, venue_name, event_title, sport, event_date, scheduled_start_at, admin_status
  )
  VALUES (
    v_future_event_id,
    v_venue_id,
    'History Venue',
    'Future History Game',
    'soccer',
    current_date + 3,
    now() + interval '3 days',
    'active'
  );

  INSERT INTO public.venue_events (
    id, venue_id, venue_name, event_title, sport, event_date, scheduled_start_at, admin_status
  )
  VALUES (
    v_completed_event_id,
    v_venue_id,
    'History Venue',
    'Completed History Game',
    'soccer',
    current_date - 30,
    now() - interval '30 days',
    'archived'
  );

  SELECT * INTO v_completed_before FROM public.venue_events WHERE id = v_completed_event_id;

  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config('request.jwt.claim.email', format('biz-delete-history-%s@example.com', replace(v_owner_id::text, '-', '')), true);

  PERFORM public.delete_business_account_cascade(v_business_id);

  SELECT * INTO v_completed_after FROM public.venue_events WHERE id = v_completed_event_id;
  IF v_completed_after IS NULL THEN
    RAISE EXCEPTION 'FAIL: completed event row must be preserved';
  END IF;

  IF v_completed_after.admin_status IS DISTINCT FROM v_completed_before.admin_status
     OR v_completed_after.event_title IS DISTINCT FROM v_completed_before.event_title THEN
    RAISE EXCEPTION 'FAIL: completed event must remain read-only unchanged';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.venue_events
    WHERE id = v_future_event_id
      AND admin_status = 'archived'
      AND admin_archived_reason = 'business_account_deleted'
  ) THEN
    RAISE EXCEPTION 'FAIL: future/live event must be archived';
  END IF;

  SELECT * INTO v_archived_venue FROM public.venues WHERE id = v_venue_id;
  IF lower(btrim(coalesce(v_archived_venue.admin_status, ''))) <> 'archived' THEN
    RAISE EXCEPTION 'FAIL: business venue must be archived not hard-deleted';
  END IF;

  IF btrim(coalesce(v_archived_venue.phone, '')) <> ''
     OR btrim(coalesce(v_archived_venue.website, '')) <> '' THEN
    RAISE EXCEPTION 'FAIL: archived venue private contact fields must be scrubbed';
  END IF;

  DELETE FROM public.business_account_deletion_jobs WHERE subject_business_id = v_business_id;
  DELETE FROM public.venue_events WHERE id IN (v_future_event_id, v_completed_event_id);
  DELETE FROM public.venues WHERE id = v_venue_id;
  DELETE FROM public.business_account_deletion_audit WHERE business_id = v_business_id;
  DELETE FROM public.businesses WHERE id = v_business_id;
  DELETE FROM auth.users WHERE id = v_owner_id;

  RAISE NOTICE 'PASS: completed history preserved; future archived; venue contacts scrubbed';
END;
$$;

-- ---------------------------------------------------------------------------
-- 10. Documented manual scenarios (run on staging with real owner sessions)
-- ---------------------------------------------------------------------------
-- 10. Pending claim only business: create open pending claim without venue row, delete, expect cancelled.
-- 11. Active user_bans row: deletion should still tombstone business; ban row preserved for moderation.
-- 12. Ownership conflict: two businesses sharing conflicting venue ownership should raise duplicate_venue_other_business.
-- 13. Failed job retry: force execute_delete_business_account_db failure, verify job.status=failed, retry after fix succeeds.
-- 14. Legacy hard-delete audit rows: remain immutable; do not attempt venue resurrection.
-- 15. Admin-disabled business (admin_status=disabled): self-service deletion blocked with business_disabled.

DO $$
BEGIN
  RAISE NOTICE 'INFO: see section 10 comments for additional manual staging scenarios';
  RAISE NOTICE 'ALL business_account_deletion_phase2_staging_checks completed';
END;
$$;