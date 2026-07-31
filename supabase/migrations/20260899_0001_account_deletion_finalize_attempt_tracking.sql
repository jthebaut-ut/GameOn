-- Forward-only safety net for fan account deletion finalization.
-- Manual apply only. Does NOT queue or finalize production jobs.
--
-- Complements the Edge Function fix in finalize-account-deletion:
--   always mark_storage_pending before mark_completed (including zero-path jobs).
--
-- This migration:
--   1) Documents / preserves advance_account_deletion_job contract
--   2) Adds optional finalize attempt counters on account_deletion_jobs
--   3) Makes mark_storage_pending / mark_completed / mark_storage_partial
--      record attempt metadata without re-running DB cleanup

ALTER TABLE public.account_deletion_jobs
  ADD COLUMN IF NOT EXISTS finalize_attempt_count integer NOT NULL DEFAULT 0;

ALTER TABLE public.account_deletion_jobs
  ADD COLUMN IF NOT EXISTS last_finalize_attempt_at timestamptz;

COMMENT ON COLUMN public.account_deletion_jobs.finalize_attempt_count IS
  'Number of storage-finalization advance attempts (pending/partial/completed). DB cleanup is never re-run by these counters.';

COMMENT ON COLUMN public.account_deletion_jobs.last_finalize_attempt_at IS
  'Timestamp of the most recent storage-finalization advance attempt.';

CREATE OR REPLACE FUNCTION public.advance_account_deletion_job(
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
  v_job public.account_deletion_jobs%ROWTYPE;
  v_action text := lower(btrim(coalesce(p_action, '')));
BEGIN
  IF NOT public.gameon_account_deletion_is_service_caller() THEN
    RAISE EXCEPTION 'advance_account_deletion_job is restricted to service_role'
      USING ERRCODE = '42501';
  END IF;

  IF p_job_id IS NULL THEN
    RAISE EXCEPTION 'job_id is required' USING ERRCODE = '22023';
  END IF;

  IF v_action NOT IN ('mark_storage_pending', 'mark_completed', 'mark_storage_partial') THEN
    RAISE EXCEPTION 'Invalid account deletion job action: %', p_action
      USING ERRCODE = '22023';
  END IF;

  SELECT *
    INTO v_job
  FROM public.account_deletion_jobs
  WHERE id = p_job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Account deletion job not found: %', p_job_id USING ERRCODE = 'P0002';
  END IF;

  IF v_job.status = 'completed' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'job_id', v_job.id,
      'status', v_job.status,
      'stage', v_job.stage,
      'completed_at', v_job.completed_at,
      'finalize_attempt_count', v_job.finalize_attempt_count,
      'idempotent_replay', true
    );
  END IF;

  -- Finalization-only: never touches soft-delete core / DB cleanup.
  IF v_job.status NOT IN ('db_committed', 'storage_pending') THEN
    RAISE EXCEPTION 'Cannot advance finalization from status %', v_job.status
      USING ERRCODE = 'P0001';
  END IF;

  IF v_action = 'mark_storage_pending' THEN
    UPDATE public.account_deletion_jobs
    SET status = 'storage_pending',
        stage = 'storage_cleanup',
        error_code = NULL,
        error_detail = NULL,
        finalize_attempt_count = coalesce(finalize_attempt_count, 0) + 1,
        last_finalize_attempt_at = now()
    WHERE id = p_job_id
    RETURNING * INTO v_job;
  ELSIF v_action = 'mark_completed' THEN
    -- Require storage_pending so zero-path Edge must claim pending first.
    IF v_job.status <> 'storage_pending' THEN
      RAISE EXCEPTION 'Cannot mark completed from status %', v_job.status
        USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.account_deletion_jobs
    SET status = 'completed',
        stage = 'completed',
        error_code = NULL,
        error_detail = NULL,
        completed_at = coalesce(completed_at, now()),
        finalize_attempt_count = coalesce(finalize_attempt_count, 0) + 1,
        last_finalize_attempt_at = now()
    WHERE id = p_job_id
    RETURNING * INTO v_job;
  ELSIF v_action = 'mark_storage_partial' THEN
    IF v_job.status <> 'storage_pending' THEN
      RAISE EXCEPTION 'Cannot mark storage partial failure from status %', v_job.status
        USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.account_deletion_jobs
    SET status = 'storage_pending',
        stage = 'storage_cleanup_partial',
        error_code = coalesce(nullif(btrim(p_error_code), ''), 'storage_cleanup_partial'),
        error_detail = p_error_detail,
        finalize_attempt_count = coalesce(finalize_attempt_count, 0) + 1,
        last_finalize_attempt_at = now()
    WHERE id = p_job_id
    RETURNING * INTO v_job;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'job_id', v_job.id,
    'status', v_job.status,
    'stage', v_job.stage,
    'completed_at', v_job.completed_at,
    'finalize_attempt_count', v_job.finalize_attempt_count,
    'last_finalize_attempt_at', v_job.last_finalize_attempt_at,
    'idempotent_replay', false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.advance_account_deletion_job(uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.advance_account_deletion_job(uuid, text, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.advance_account_deletion_job(uuid, text, text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.advance_account_deletion_job(uuid, text, text, text) TO service_role;

COMMENT ON FUNCTION public.advance_account_deletion_job(uuid, text, text, text) IS
  'Service-role only. Whitelisted finalization transitions only (mark_storage_pending, mark_completed, mark_storage_partial). Never re-runs DB soft-delete.';

DO $$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef('public.advance_account_deletion_job(uuid,text,text,text)'::regprocedure)
    INTO v_def;

  IF position('finalize_attempt_count' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: advance_account_deletion_job missing finalize_attempt_count updates';
  END IF;

  IF position('Cannot mark completed from status' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: mark_completed must still require storage_pending';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'account_deletion_jobs'
      AND column_name = 'finalize_attempt_count'
  ) THEN
    RAISE EXCEPTION 'FAIL: finalize_attempt_count column missing';
  END IF;
END;
$$;
