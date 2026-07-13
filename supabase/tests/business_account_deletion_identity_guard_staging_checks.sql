-- Staging checks for business deletion identity-guard tombstone bypass (20260850).
-- Run manually after applying 20260850_0001_fix_business_deletion_identity_guard.sql.
-- SQL Editor compatible: no psql meta-commands.

-- ---------------------------------------------------------------------------
-- 1. Integrity: functions + trigger wiring
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_guard_body text;
  v_core_body text;
BEGIN
  IF to_regprocedure('public.enforce_business_account_identity_guard()') IS NULL THEN
    RAISE EXCEPTION 'FAIL: enforce_business_account_identity_guard missing';
  END IF;

  IF to_regprocedure('public.gameon_business_deletion_soft_delete_core(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: gameon_business_deletion_soft_delete_core missing';
  END IF;

  SELECT pg_get_functiondef('public.enforce_business_account_identity_guard()'::regprocedure)
    INTO v_guard_body;

  IF v_guard_body NOT ILIKE '%gameon.business_account_deletion_anonymize%' THEN
    RAISE EXCEPTION 'FAIL: guard missing deletion anonymize GUC check';
  END IF;

  SELECT pg_get_functiondef('public.gameon_business_deletion_soft_delete_core(uuid,uuid)'::regprocedure)
    INTO v_core_body;

  IF v_core_body NOT ILIKE '%set_config(''gameon.business_account_deletion_anonymize''%' THEN
    RAISE EXCEPTION 'FAIL: soft delete core missing deletion anonymize GUC set';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'businesses'
      AND t.tgname = 'trg_businesses_account_identity_guard'
  ) THEN
    RAISE EXCEPTION 'FAIL: trg_businesses_account_identity_guard missing';
  END IF;

  RAISE NOTICE 'PASS: identity guard fix objects present';
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Guard negatives: mismatched owner email remains blocked
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_owner_id uuid := gen_random_uuid();
  v_business_id uuid := gen_random_uuid();
  v_owner_email text := format('biz-id-guard-%s@example.com', replace(v_owner_id::text, '-', ''));
  v_blocked_update boolean := false;
  v_blocked_insert boolean := false;
BEGIN
  INSERT INTO auth.users (id, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  VALUES (v_owner_id, v_owner_email, crypt('test-password', gen_salt('bf')), now(), now(), now());

  INSERT INTO public.account_identities (account_id, email, account_type)
  VALUES (v_owner_id, v_owner_email, 'business');

  INSERT INTO public.businesses (
    id, display_name, owner_email, owner_user_id, admin_status, business_origin
  )
  VALUES (
    v_business_id,
    'Identity Guard Test Business',
    v_owner_email,
    v_owner_id,
    'active',
    'owned_account'
  );

  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config('request.jwt.claim.email', v_owner_email, true);

  BEGIN
    UPDATE public.businesses
    SET owner_email = 'mismatch@example.com'
    WHERE id = v_business_id;
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM ILIKE '%Business owner email must match the authenticated user email.%' THEN
        v_blocked_update := true;
      ELSE
        RAISE;
      END IF;
  END;

  IF NOT v_blocked_update THEN
    RAISE EXCEPTION 'FAIL: mismatched owner_email update should be blocked';
  END IF;

  BEGIN
    INSERT INTO public.businesses (
      id, display_name, owner_email, owner_user_id, admin_status, business_origin
    )
    VALUES (
      gen_random_uuid(),
      'Blocked Insert',
      'other-insert@example.com',
      v_owner_id,
      'active',
      'owned_account'
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM ILIKE '%Business owner email must match the authenticated user email.%' THEN
        v_blocked_insert := true;
      ELSE
        RAISE;
      END IF;
  END;

  IF NOT v_blocked_insert THEN
    RAISE EXCEPTION 'FAIL: mismatched owner_email insert should be blocked';
  END IF;

  DELETE FROM public.businesses WHERE id = v_business_id;
  DELETE FROM public.account_identities WHERE account_id = v_owner_id;
  DELETE FROM auth.users WHERE id = v_owner_id;

  RAISE NOTICE 'PASS: normal owner email mismatch remains blocked';
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Bypass negatives: GUC alone is insufficient
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_owner_id uuid := gen_random_uuid();
  v_business_id uuid := gen_random_uuid();
  v_owner_email text := format('biz-id-bypass-%s@example.com', replace(v_owner_id::text, '-', ''));
  v_tombstone text;
  v_blocked_no_guc boolean := false;
  v_blocked_no_is_deleted boolean := false;
BEGIN
  INSERT INTO auth.users (id, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  VALUES (v_owner_id, v_owner_email, crypt('test-password', gen_salt('bf')), now(), now(), now());

  INSERT INTO public.account_identities (account_id, email, account_type)
  VALUES (v_owner_id, v_owner_email, 'business');

  INSERT INTO public.businesses (
    id, display_name, owner_email, owner_user_id, admin_status, business_origin
  )
  VALUES (
    v_business_id,
    'Bypass Negative Business',
    v_owner_email,
    v_owner_id,
    'active',
    'owned_account'
  );

  v_tombstone := public.gameon_business_deletion_tombstone_email(v_business_id);

  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config('request.jwt.claim.email', v_owner_email, true);

  -- Tombstone email without transaction-local deletion GUC must remain blocked.
  BEGIN
    UPDATE public.businesses
    SET owner_email = v_tombstone
    WHERE id = v_business_id;
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM ILIKE '%Business owner email must match the authenticated user email.%' THEN
        v_blocked_no_guc := true;
      ELSE
        RAISE;
      END IF;
  END;

  IF NOT v_blocked_no_guc THEN
    RAISE EXCEPTION 'FAIL: tombstone email without deletion GUC should be blocked';
  END IF;

  -- GUC + tombstone email but is_deleted=false must remain blocked.
  PERFORM set_config('gameon.business_account_deletion_anonymize', v_business_id::text, true);

  BEGIN
    UPDATE public.businesses
    SET owner_email = v_tombstone
    WHERE id = v_business_id;
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM ILIKE '%Business owner email must match the authenticated user email.%' THEN
        v_blocked_no_is_deleted := true;
      ELSE
        RAISE;
      END IF;
  END;

  IF NOT v_blocked_no_is_deleted THEN
    RAISE EXCEPTION 'FAIL: tombstone email with GUC but without is_deleted should be blocked';
  END IF;

  DELETE FROM public.businesses WHERE id = v_business_id;
  DELETE FROM public.account_identities WHERE account_id = v_owner_id;
  DELETE FROM auth.users WHERE id = v_owner_id;

  RAISE NOTICE 'PASS: tombstone bypass requires deletion GUC and is_deleted';
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Phase 2 self-service delete succeeds + retention + idempotency
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_owner_id uuid := gen_random_uuid();
  v_other_owner_id uuid := gen_random_uuid();
  v_business_id uuid := gen_random_uuid();
  v_other_business_id uuid := gen_random_uuid();
  v_owner_email text := format('biz-id-delete-%s@example.com', replace(v_owner_id::text, '-', ''));
  v_other_email text := format('biz-id-other-%s@example.com', replace(v_other_owner_id::text, '-', ''));
  v_result jsonb;
  v_repeat jsonb;
  v_business_row public.businesses%ROWTYPE;
  v_other_row public.businesses%ROWTYPE;
BEGIN
  INSERT INTO auth.users (id, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  VALUES
    (v_owner_id, v_owner_email, crypt('test-password', gen_salt('bf')), now(), now(), now()),
    (v_other_owner_id, v_other_email, crypt('test-password', gen_salt('bf')), now(), now(), now());

  INSERT INTO public.account_identities (account_id, email, account_type)
  VALUES
    (v_owner_id, v_owner_email, 'business'),
    (v_other_owner_id, v_other_email, 'business');

  INSERT INTO public.businesses (
    id, display_name, owner_email, owner_user_id, admin_status, business_origin
  )
  VALUES
    (
      v_business_id,
      'Delete Success Business',
      v_owner_email,
      v_owner_id,
      'active',
      'owned_account'
    ),
    (
      v_other_business_id,
      'Unrelated Active Business',
      v_other_email,
      v_other_owner_id,
      'active',
      'owned_account'
    );

  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config('request.jwt.claim.email', v_owner_email, true);

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

  IF v_business_row.owner_email <> public.gameon_business_deletion_tombstone_email(v_business_id) THEN
    RAISE EXCEPTION 'FAIL: tombstone owner_email not applied';
  END IF;

  IF v_business_row.owner_user_id IS DISTINCT FROM v_owner_id THEN
    RAISE EXCEPTION 'FAIL: owner_user_id changed during deletion';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM auth.users u WHERE u.id = v_owner_id
  ) THEN
    RAISE EXCEPTION 'FAIL: auth.users not retained';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.account_identities ai
    WHERE ai.account_id = v_owner_id
      AND ai.account_type = 'business'
  ) THEN
    RAISE EXCEPTION 'FAIL: account_identities not retained';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.business_account_deletion_jobs j
    WHERE j.subject_business_id = v_business_id
      AND j.status = 'db_committed'
      AND j.stage = 'awaiting_storage_finalize'
  ) THEN
    RAISE EXCEPTION 'FAIL: deletion job not db_committed/awaiting_storage_finalize';
  END IF;

  IF (SELECT count(*) FROM public.business_account_deletion_audit WHERE business_id = v_business_id) <> 1 THEN
    RAISE EXCEPTION 'FAIL: expected exactly one audit row';
  END IF;

  SELECT *
    INTO v_other_row
  FROM public.businesses b
  WHERE b.id = v_other_business_id;

  IF coalesce(v_other_row.is_deleted, false) THEN
    RAISE EXCEPTION 'FAIL: unrelated active business was tombstoned';
  END IF;

  v_repeat := public.delete_business_account_cascade(v_business_id);

  IF coalesce(v_repeat ->> 'ok', 'false') <> 'true' THEN
    RAISE EXCEPTION 'FAIL: idempotent repeat delete failed: %', v_repeat;
  END IF;

  IF (SELECT count(*) FROM public.business_account_deletion_audit WHERE business_id = v_business_id) <> 1 THEN
    RAISE EXCEPTION 'FAIL: repeat delete created duplicate audit rows';
  END IF;

  DELETE FROM public.business_account_deletion_jobs WHERE subject_business_id = v_business_id;
  DELETE FROM public.business_account_deletion_audit WHERE business_id = v_business_id;
  DELETE FROM public.businesses WHERE id IN (v_business_id, v_other_business_id);
  DELETE FROM public.account_identities WHERE account_id IN (v_owner_id, v_other_owner_id);
  DELETE FROM auth.users WHERE id IN (v_owner_id, v_other_owner_id);

  RAISE NOTICE 'PASS: Phase 2 self-service delete succeeds with identity guard bypass';
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. Failed attempt rollback expectation (documentation check)
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  RAISE NOTICE 'NOTE: delete_business_account_cascade is atomic. A trigger failure before this migration rolls back the business row, job row, and audit row together. After this migration, retry requires no manual reset unless a failed job row was persisted outside that transaction.';
END;
$$;
