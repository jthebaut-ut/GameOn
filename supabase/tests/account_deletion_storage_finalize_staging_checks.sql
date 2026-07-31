-- Staging checks for fan deletion storage finalization (20260899 + Edge contract).
-- Manual run after applying migration / reviewing Edge source. Does not delete users.

DO $$
DECLARE
  v_advance text;
BEGIN
  IF to_regprocedure('public.advance_account_deletion_job(uuid,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: advance_account_deletion_job missing';
  END IF;

  IF to_regprocedure('public.queue_account_deletion_finalize(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: queue_account_deletion_finalize missing';
  END IF;

  SELECT pg_get_functiondef('public.advance_account_deletion_job(uuid,text,text,text)'::regprocedure)
    INTO v_advance;

  IF position('mark_storage_pending' IN v_advance) = 0
     OR position('mark_completed' IN v_advance) = 0
     OR position('mark_storage_partial' IN v_advance) = 0 THEN
    RAISE EXCEPTION 'FAIL: advance missing required actions';
  END IF;

  IF position('Cannot mark completed from status' IN v_advance) = 0 THEN
    RAISE EXCEPTION 'FAIL: mark_completed must require storage_pending';
  END IF;

  IF has_function_privilege('authenticated', 'public.advance_account_deletion_job(uuid,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: authenticated can EXECUTE advance_account_deletion_job';
  END IF;

  IF has_function_privilege('authenticated', 'public.queue_account_deletion_finalize(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: authenticated can EXECUTE queue_account_deletion_finalize';
  END IF;

  RAISE NOTICE 'PASS: finalization advance/queue grants and contracts';
END;
$$;

-- Disposable fixture: db_committed zero-path → pending → completed (no storage objects).
DO $$
DECLARE
  v_job_id uuid := gen_random_uuid();
  v_subject uuid := 'a6089900-0001-4000-8000-000000000099';
  v_row public.account_deletion_jobs%ROWTYPE;
BEGIN
  -- Skip when FK to auth.users would block disposable subject ids.
  BEGIN
    INSERT INTO public.account_deletion_jobs (
      id,
      subject_user_id,
      request_source,
      deletion_mode,
      status,
      stage,
      idempotency_key,
      avatar_storage_paths
    ) VALUES (
      v_job_id,
      v_subject,
      'system',
      'soft',
      'db_committed',
      'awaiting_storage_finalize',
      'staging-finalize-zero-path:' || v_job_id::text,
      ARRAY[]::text[]
    );
  EXCEPTION WHEN foreign_key_violation OR not_null_violation OR check_violation THEN
    RAISE NOTICE 'SKIP: disposable finalize fixture requires insertable account_deletion_jobs row (%).', SQLERRM;
    RETURN;
  END;

  BEGIN
    -- mark_completed from db_committed must fail (zero-path still needs pending claim).
    BEGIN
      PERFORM public.advance_account_deletion_job(v_job_id, 'mark_completed');
      RAISE EXCEPTION 'FAIL: mark_completed should reject db_committed';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM ILIKE '%Cannot mark completed%' OR SQLERRM ILIKE '%storage_pending%' THEN
        NULL;
      ELSE
        RAISE;
      END IF;
    END;

    PERFORM public.advance_account_deletion_job(v_job_id, 'mark_storage_pending');
    SELECT * INTO v_row FROM public.account_deletion_jobs WHERE id = v_job_id;
    IF v_row.status <> 'storage_pending' THEN
      RAISE EXCEPTION 'FAIL: expected storage_pending, got %', v_row.status;
    END IF;

    PERFORM public.advance_account_deletion_job(v_job_id, 'mark_completed');
    SELECT * INTO v_row FROM public.account_deletion_jobs WHERE id = v_job_id;
    IF v_row.status <> 'completed' OR v_row.completed_at IS NULL THEN
      RAISE EXCEPTION 'FAIL: zero-path job did not complete';
    END IF;

    -- Idempotent completed replay
    PERFORM public.advance_account_deletion_job(v_job_id, 'mark_completed');

    RAISE NOTICE 'PASS: zero-path finalization transitions';
    RAISE EXCEPTION 'rollback_fixture';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'rollback_fixture' THEN
        DELETE FROM public.account_deletion_jobs WHERE id = v_job_id;
        RAISE NOTICE 'PASS: fixture rolled back';
      ELSE
        DELETE FROM public.account_deletion_jobs WHERE id = v_job_id;
        RAISE;
      END IF;
  END;
END;
$$;
