-- Business account deletion storage finalizer.
-- Wires queue_business_account_deletion_finalize to the Edge Function and
-- extends advance_business_account_deletion_job with partial-storage handling.

-- ---------------------------------------------------------------------------
-- 1. Job advancement: partial storage cleanup (parity with fan finalize)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.advance_business_account_deletion_job(
  p_job_id uuid,
  p_action text,
  p_error_code text DEFAULT NULL,
  p_error_detail text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_job public.business_account_deletion_jobs%ROWTYPE;
  v_action text := lower(btrim(coalesce(p_action, '')));
BEGIN
  IF NOT public.gameon_business_deletion_is_service_caller() THEN
    RAISE EXCEPTION 'advance_business_account_deletion_job is restricted to service_role'
      USING ERRCODE = '42501';
  END IF;

  SELECT *
    INTO v_job
  FROM public.business_account_deletion_jobs
  WHERE id = p_job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business deletion job not found: %', p_job_id
      USING ERRCODE = 'P0002';
  END IF;

  IF v_job.status = 'completed' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'job_id', p_job_id,
      'status', v_job.status,
      'stage', v_job.stage,
      'completed_at', v_job.completed_at,
      'idempotent_replay', true
    );
  END IF;

  IF v_action = 'mark_storage_pending' THEN
    UPDATE public.business_account_deletion_jobs
    SET status = 'storage_pending',
        stage = 'storage_cleanup',
        completed_at = NULL,
        error_code = NULL,
        error_detail = NULL
    WHERE id = p_job_id
      AND status IN ('db_committed', 'storage_pending');
  ELSIF v_action = 'mark_completed' THEN
    -- Completion requires confirmed storage finalization (storage_pending only).
    UPDATE public.business_account_deletion_jobs
    SET status = 'completed',
        stage = 'completed',
        completed_at = now(),
        error_code = p_error_code,
        error_detail = p_error_detail
    WHERE id = p_job_id
      AND status = 'storage_pending';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'mark_completed requires job status storage_pending (got %)', v_job.status
        USING ERRCODE = 'P0001';
    END IF;
  ELSIF v_action = 'mark_storage_partial' THEN
    UPDATE public.business_account_deletion_jobs
    SET status = 'storage_pending',
        stage = 'storage_cleanup_partial',
        completed_at = NULL,
        error_code = coalesce(nullif(btrim(p_error_code), ''), 'storage_cleanup_partial'),
        error_detail = p_error_detail
    WHERE id = p_job_id
      AND status = 'storage_pending';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'mark_storage_partial requires job status storage_pending (got %)', v_job.status
        USING ERRCODE = 'P0001';
    END IF;
  ELSIF v_action = 'mark_failed' THEN
    UPDATE public.business_account_deletion_jobs
    SET status = 'failed',
        stage = 'failed',
        error_code = p_error_code,
        error_detail = p_error_detail,
        completed_at = NULL
    WHERE id = p_job_id;
  ELSE
    RAISE EXCEPTION 'Unsupported business deletion job action: %', p_action
      USING ERRCODE = '22023';
  END IF;

  SELECT *
    INTO v_job
  FROM public.business_account_deletion_jobs
  WHERE id = p_job_id;

  RETURN jsonb_build_object(
    'ok', true,
    'job_id', p_job_id,
    'status', v_job.status,
    'stage', v_job.stage,
    'completed_at', v_job.completed_at
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Queue: invoke finalize-business-account-deletion via pg_net
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.queue_business_account_deletion_finalize(p_job_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_job public.business_account_deletion_jobs%ROWTYPE;
  v_url text;
  v_service_role_key text;
BEGIN
  IF NOT public.gameon_business_deletion_is_service_caller() THEN
    RAISE EXCEPTION 'queue_business_account_deletion_finalize is restricted to service_role'
      USING ERRCODE = '42501';
  END IF;

  IF p_job_id IS NULL THEN
    RETURN jsonb_build_object(
      'queued', false,
      'result', 'failed',
      'detail', 'job_id is required',
      'edge_function_deployed', true,
      'job_mutated', false
    );
  END IF;

  SELECT *
    INTO v_job
  FROM public.business_account_deletion_jobs
  WHERE id = p_job_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'queued', false,
      'result', 'job_not_found',
      'job_id', p_job_id,
      'edge_function_deployed', true,
      'job_mutated', false
    );
  END IF;

  IF v_job.status = 'completed' THEN
    RETURN jsonb_build_object(
      'queued', false,
      'result', 'already_completed',
      'job_id', p_job_id,
      'job_status', v_job.status,
      'job_stage', v_job.stage,
      'completed_at', v_job.completed_at,
      'edge_function_deployed', true,
      'job_mutated', false,
      'storage_finalization_pending', false
    );
  END IF;

  IF v_job.status NOT IN ('db_committed', 'storage_pending') THEN
    RETURN jsonb_build_object(
      'queued', false,
      'result', 'job_not_ready_for_finalize',
      'job_id', p_job_id,
      'job_status', v_job.status,
      'job_stage', v_job.stage,
      'edge_function_deployed', true,
      'job_mutated', false,
      'storage_finalization_pending', false
    );
  END IF;

  IF to_regnamespace('net') IS NULL OR to_regclass('vault.decrypted_secrets') IS NULL THEN
    RETURN jsonb_build_object(
      'queued', false,
      'result', 'skipped_pg_net_unavailable',
      'job_id', p_job_id,
      'job_status', v_job.status,
      'job_stage', v_job.stage,
      'edge_function_deployed', true,
      'job_mutated', false,
      'storage_finalization_pending', true
    );
  END IF;

  SELECT rtrim(decrypted_secret, '/')
    INTO v_url
  FROM vault.decrypted_secrets
  WHERE name IN ('fangeo_supabase_url', 'SUPABASE_URL')
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY CASE name WHEN 'fangeo_supabase_url' THEN 0 ELSE 1 END
  LIMIT 1;

  SELECT decrypted_secret
    INTO v_service_role_key
  FROM vault.decrypted_secrets
  WHERE name IN ('fangeo_service_role_key', 'SUPABASE_SERVICE_ROLE_KEY')
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY CASE name WHEN 'fangeo_service_role_key' THEN 0 ELSE 1 END
  LIMIT 1;

  IF v_url IS NULL OR v_service_role_key IS NULL THEN
    RETURN jsonb_build_object(
      'queued', false,
      'result', 'skipped_missing_secrets',
      'job_id', p_job_id,
      'job_status', v_job.status,
      'job_stage', v_job.stage,
      'edge_function_deployed', true,
      'job_mutated', false,
      'storage_finalization_pending', true
    );
  END IF;

  PERFORM net.http_post(
    url := v_url || '/functions/v1/finalize-business-account-deletion',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_service_role_key
    ),
    body := jsonb_build_object('job_id', p_job_id),
    timeout_milliseconds := 60000
  );

  RETURN jsonb_build_object(
    'queued', true,
    'result', 'queued',
    'job_id', p_job_id,
    'job_status', v_job.status,
    'job_stage', v_job.stage,
    'edge_function_deployed', true,
    'job_mutated', false,
    'storage_finalization_pending', true
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'queued', false,
      'result', 'failed',
      'detail', SQLERRM,
      'job_id', p_job_id,
      'edge_function_deployed', true,
      'job_mutated', false
    );
END;
$$;

COMMENT ON FUNCTION public.advance_business_account_deletion_job(uuid, text, text, text) IS
  'Service-role only. Advances business_account_deletion_jobs through storage cleanup and completion. Does not delete auth.users.';

COMMENT ON FUNCTION public.queue_business_account_deletion_finalize(uuid) IS
  'Service-role only. Enqueues finalize-business-account-deletion Edge Function via pg_net.';

-- ---------------------------------------------------------------------------
-- 3. Post-apply integrity checks
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_advance_def text;
  v_queue_def text;
BEGIN
  IF to_regprocedure('public.advance_business_account_deletion_job(uuid,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'Integrity fail: advance_business_account_deletion_job missing';
  END IF;

  IF to_regprocedure('public.queue_business_account_deletion_finalize(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Integrity fail: queue_business_account_deletion_finalize missing';
  END IF;

  v_advance_def := pg_get_functiondef(
    'public.advance_business_account_deletion_job(uuid,text,text,text)'::regprocedure
  );

  IF position('mark_storage_partial' IN v_advance_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: advance_business_account_deletion_job missing mark_storage_partial';
  END IF;

  IF position('mark_completed requires job status storage_pending' IN v_advance_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: mark_completed must require storage_pending';
  END IF;

  IF position('completed_at = now()' IN v_advance_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: mark_completed must set completed_at';
  END IF;

  v_queue_def := pg_get_functiondef('public.queue_business_account_deletion_finalize(uuid)'::regprocedure);

  IF position('finalize-business-account-deletion' IN v_queue_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: queue must target finalize-business-account-deletion';
  END IF;

  IF position('net.http_post' IN v_queue_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: queue must invoke pg_net http_post';
  END IF;

  IF has_function_privilege('authenticated', 'public.queue_business_account_deletion_finalize(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Integrity fail: authenticated can EXECUTE queue_business_account_deletion_finalize';
  END IF;

  IF NOT has_function_privilege('service_role', 'public.queue_business_account_deletion_finalize(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Integrity fail: service_role cannot EXECUTE queue_business_account_deletion_finalize';
  END IF;
END;
$$;
