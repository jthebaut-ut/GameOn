-- =============================================================================
-- 20260901: Permanent business owner user-job state consistency
-- Manual apply only. Does NOT mutate production jobs on apply.
-- Does NOT re-run user/business deletion. Does NOT deploy Edge Functions.
--
-- Root cause (20260898):
--   Stage 2 calls start_account_deletion_job + execute_delete_user_account_db
--   then continues to identity retirement + Auth/storage finalization while the
--   child owner account_deletion_jobs row remains status=db_committed /
--   stage=awaiting_storage_finalize. Parent can reach completed without ever
--   advancing the child.
--
-- Fix:
--   1) gameon_permanent_business_sync_owner_user_job — zero-path completes
--      synchronously via advance_account_deletion_job. Non-empty avatar paths
--      claim storage_pending only and require finalize-business-account-deletion
--      (trusted Edge service-role) to delete user-avatars objects. NEVER uses
--      the Vault/pg_net fan finalize queue (known HTTP 401 path).
--   2) Call sync after successful owner user DB cleanup in the orchestrator.
--   3) Gate advance_business_account_deletion_job mark_completed on positive
--      proof that the linked child row exists AND status = completed.
--   4) admin_reconcile_permanent_business_owner_user_deletion_job — narrow
--      validated recovery for stuck bookkeeping-only jobs.
-- =============================================================================

DROP FUNCTION IF EXISTS public.gameon_permanent_business_sync_owner_user_job(uuid, uuid, boolean);

CREATE OR REPLACE FUNCTION public.gameon_permanent_business_sync_owner_user_job(
  p_user_job_id uuid,
  p_business_job_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_job public.account_deletion_jobs%ROWTYPE;
  v_biz_job public.business_account_deletion_jobs%ROWTYPE;
  v_paths text[] := ARRAY[]::text[];
  v_advance jsonb;
  v_path_count integer := 0;
BEGIN
  IF NOT public.gameon_business_deletion_is_service_caller() THEN
    RAISE EXCEPTION 'gameon_permanent_business_sync_owner_user_job is restricted to service_role'
      USING ERRCODE = '42501';
  END IF;

  IF p_user_job_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'skipped', true,
      'reason', 'user_job_id_null'
    );
  END IF;

  SELECT *
    INTO v_user_job
  FROM public.account_deletion_jobs
  WHERE id = p_user_job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Owner user deletion job not found: %', p_user_job_id
      USING ERRCODE = 'P0002';
  END IF;

  -- Strict linkage when a business job id is supplied.
  IF p_business_job_id IS NOT NULL THEN
    SELECT *
      INTO v_biz_job
    FROM public.business_account_deletion_jobs
    WHERE id = p_business_job_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'business deletion job not found: %', p_business_job_id
        USING ERRCODE = 'P0002';
    END IF;

    IF coalesce(v_biz_job.deletion_mode, 'soft') IS DISTINCT FROM 'permanent' THEN
      RAISE EXCEPTION 'business job % is not permanent mode (got %)',
        p_business_job_id, coalesce(v_biz_job.deletion_mode, 'soft')
        USING ERRCODE = 'P0001';
    END IF;

    IF v_biz_job.user_deletion_job_id IS NULL THEN
      RAISE EXCEPTION 'business job % has no linked user_deletion_job_id',
        p_business_job_id
        USING ERRCODE = 'P0001';
    END IF;

    IF v_biz_job.user_deletion_job_id IS DISTINCT FROM p_user_job_id THEN
      RAISE EXCEPTION 'user job % is not linked to business job % (linked %)',
        p_user_job_id, p_business_job_id, v_biz_job.user_deletion_job_id
        USING ERRCODE = 'P0001';
    END IF;

    IF v_biz_job.subject_user_id IS NULL
       OR v_user_job.subject_user_id IS NULL
       OR v_biz_job.subject_user_id IS DISTINCT FROM v_user_job.subject_user_id THEN
      RAISE EXCEPTION 'subject_user_id mismatch between business job % (%) and user job % (%)',
        p_business_job_id, v_biz_job.subject_user_id,
        p_user_job_id, v_user_job.subject_user_id
        USING ERRCODE = 'P0001';
    END IF;
  END IF;

  IF v_user_job.status = 'completed' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'job_id', v_user_job.id,
      'status', v_user_job.status,
      'stage', v_user_job.stage,
      'completed_at', v_user_job.completed_at,
      'idempotent_replay', true,
      'avatar_path_count', coalesce(cardinality(v_user_job.avatar_storage_paths), 0),
      'avatar_cleanup_required', false
    );
  END IF;

  IF v_user_job.status NOT IN ('db_committed', 'storage_pending') THEN
    RAISE EXCEPTION 'Cannot sync owner user job from status %', v_user_job.status
      USING ERRCODE = 'P0001';
  END IF;

  v_paths := coalesce(v_user_job.avatar_storage_paths, ARRAY[]::text[]);
  v_path_count := coalesce(cardinality(v_paths), 0);

  UPDATE public.account_deletion_jobs
  SET affected_counts = coalesce(affected_counts, '{}'::jsonb)
        || jsonb_build_object(
             'permanent_business_owner_cleanup', true,
             'permanent_business_job_id', p_business_job_id,
             'permanent_business_owner_sync_at', now(),
             'avatar_cleanup_required_by_business_finalizer', (v_path_count > 0)
           )
  WHERE id = p_user_job_id
  RETURNING * INTO v_user_job;

  IF v_path_count = 0 THEN
    IF v_user_job.status = 'db_committed' THEN
      v_advance := public.advance_account_deletion_job(
        p_user_job_id,
        'mark_storage_pending',
        NULL,
        'permanent_business_owner_zero_path'
      );
    END IF;

    v_advance := public.advance_account_deletion_job(
      p_user_job_id,
      'mark_completed',
      NULL,
      'permanent_business_owner_zero_path'
    );

    RETURN jsonb_build_object(
      'ok', true,
      'job_id', p_user_job_id,
      'status', coalesce(v_advance ->> 'status', 'completed'),
      'stage', coalesce(v_advance ->> 'stage', 'completed'),
      'completed_at', v_advance -> 'completed_at',
      'avatar_path_count', 0,
      'zero_path_completed', true,
      'avatar_cleanup_required', false
    );
  END IF;

  -- Avatar-bearing child: claim storage_pending only.
  -- finalize-business-account-deletion must delete user-avatars with its
  -- trusted Edge service-role credential, then advance_account_deletion_job.
  -- Never use the Vault/pg_net fan finalize queue (known HTTP 401).
  IF v_user_job.status = 'db_committed' THEN
    v_advance := public.advance_account_deletion_job(
      p_user_job_id,
      'mark_storage_pending',
      NULL,
      'permanent_business_owner_awaiting_edge_avatar_cleanup'
    );
  END IF;

  SELECT *
    INTO v_user_job
  FROM public.account_deletion_jobs
  WHERE id = p_user_job_id;

  RETURN jsonb_build_object(
    'ok', true,
    'job_id', p_user_job_id,
    'status', v_user_job.status,
    'stage', v_user_job.stage,
    'completed_at', v_user_job.completed_at,
    'avatar_path_count', v_path_count,
    'zero_path_completed', false,
    'avatar_cleanup_required', true,
    'message', 'Owner avatar cleanup must be performed by finalize-business-account-deletion using the Edge service-role context; Vault/pg_net queue is not used.'
  );
END;
$$;

COMMENT ON FUNCTION public.gameon_permanent_business_sync_owner_user_job(uuid, uuid) IS
  'Service-role only. Zero-path permanent-business owner child jobs advance to completed. Avatar-bearing children claim storage_pending and require Edge finalize-business-account-deletion for user-avatars cleanup. Never uses the Vault/pg_net fan finalize queue. When p_business_job_id is supplied, requires permanent mode + exact user_deletion_job_id + subject_user_id match.';

CREATE OR REPLACE FUNCTION public.admin_reconcile_permanent_business_owner_user_deletion_job(
  p_user_job_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, storage
AS $$
DECLARE
  v_user_job public.account_deletion_jobs%ROWTYPE;
  v_biz_job public.business_account_deletion_jobs%ROWTYPE;
  v_paths text[] := ARRAY[]::text[];
  v_remaining_paths text[] := ARRAY[]::text[];
  v_auth_exists boolean := false;
  v_identity_exists boolean := false;
  v_profile_exists boolean := false;
  v_profile_active boolean := false;
  v_sync jsonb;
BEGIN
  IF NOT public.gameon_business_deletion_is_service_caller() THEN
    RAISE EXCEPTION 'admin_reconcile_permanent_business_owner_user_deletion_job is restricted to service_role'
      USING ERRCODE = '42501';
  END IF;

  IF p_user_job_id IS NULL THEN
    RAISE EXCEPTION 'user_job_id is required' USING ERRCODE = '22023';
  END IF;

  SELECT *
    INTO v_user_job
  FROM public.account_deletion_jobs
  WHERE id = p_user_job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'user_job_not_found',
      'user_deletion_job_id', p_user_job_id
    );
  END IF;

  IF v_user_job.status = 'completed' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'result', 'already_completed',
      'idempotent', true,
      'user_deletion_job_id', v_user_job.id,
      'status', v_user_job.status,
      'stage', v_user_job.stage,
      'completed_at', v_user_job.completed_at
    );
  END IF;

  IF v_user_job.status NOT IN ('db_committed', 'storage_pending') THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'user_job_status_not_reconcileable',
      'user_deletion_job_id', p_user_job_id,
      'status', v_user_job.status,
      'stage', v_user_job.stage,
      'message', 'Reconciliation only allows db_committed or storage_pending source states.'
    );
  END IF;

  SELECT *
    INTO v_biz_job
  FROM public.business_account_deletion_jobs j
  WHERE j.user_deletion_job_id = p_user_job_id
    AND coalesce(j.deletion_mode, 'soft') = 'permanent'
  ORDER BY j.created_at DESC NULLS LAST
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'linked_permanent_business_job_not_found',
      'user_deletion_job_id', p_user_job_id,
      'message', 'Reconciliation requires a permanent business_account_deletion_jobs row linked via user_deletion_job_id.'
    );
  END IF;

  IF v_biz_job.status IS DISTINCT FROM 'completed' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'business_job_not_completed',
      'user_deletion_job_id', p_user_job_id,
      'business_deletion_job_id', v_biz_job.id,
      'business_job_status', v_biz_job.status,
      'message', 'Parent permanent business job must be completed before owner user-job bookkeeping reconciliation.'
    );
  END IF;

  IF v_biz_job.subject_user_id IS NULL
     OR v_user_job.subject_user_id IS NULL
     OR v_biz_job.subject_user_id IS DISTINCT FROM v_user_job.subject_user_id THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'subject_user_mismatch',
      'user_deletion_job_id', p_user_job_id,
      'business_deletion_job_id', v_biz_job.id,
      'business_subject_user_id', v_biz_job.subject_user_id,
      'user_subject_user_id', v_user_job.subject_user_id
    );
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM auth.users au WHERE au.id = v_user_job.subject_user_id
  ) INTO v_auth_exists;

  IF to_regclass('public.account_identities') IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM public.account_identities ai
      WHERE ai.account_id = v_user_job.subject_user_id
    ) INTO v_identity_exists;
  END IF;

  IF to_regclass('public.user_profiles') IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM public.user_profiles up WHERE up.id = v_user_job.subject_user_id
    ) INTO v_profile_exists;

    SELECT EXISTS (
      SELECT 1
      FROM public.user_profiles up
      WHERE up.id = v_user_job.subject_user_id
        AND coalesce(up.is_deleted, false) = false
        AND up.anonymized_at IS NULL
        AND coalesce(up.admin_status, '') IS DISTINCT FROM 'deleted'
    ) INTO v_profile_active;
  END IF;

  IF v_auth_exists OR v_identity_exists OR v_profile_active THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'cleanup_evidence_incomplete',
      'user_deletion_job_id', p_user_job_id,
      'business_deletion_job_id', v_biz_job.id,
      'auth_exists', v_auth_exists,
      'identity_exists', v_identity_exists,
      'profile_exists', v_profile_exists,
      'profile_active', v_profile_active,
      'message', 'Owner Auth/identity/active profile still present; refuse bookkeeping completion.'
    );
  END IF;

  v_paths := coalesce(v_user_job.avatar_storage_paths, ARRAY[]::text[]);

  IF coalesce(cardinality(v_paths), 0) > 0
     AND to_regclass('storage.objects') IS NOT NULL THEN
    SELECT coalesce(array_agg(p ORDER BY p), ARRAY[]::text[])
      INTO v_remaining_paths
    FROM unnest(v_paths) AS p
    WHERE EXISTS (
      SELECT 1
      FROM storage.objects so
      WHERE so.bucket_id = 'user-avatars'
        AND so.name = p
    );
  END IF;

  IF coalesce(cardinality(v_remaining_paths), 0) > 0 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'avatar_storage_still_present',
      'user_deletion_job_id', p_user_job_id,
      'business_deletion_job_id', v_biz_job.id,
      'remaining_avatar_paths', to_jsonb(v_remaining_paths),
      'message', 'Avatar objects remain in user-avatars. Re-run finalize-business-account-deletion (trusted Edge service-role) for this business job; do not force-complete or use Vault/pg_net queue.'
    );
  END IF;

  -- Evidence satisfied. Prefer zero-path sync; otherwise advance via the
  -- authoritative finalization contract (never raw UPDATE status).
  v_sync := public.gameon_permanent_business_sync_owner_user_job(
    p_user_job_id,
    v_biz_job.id
  );

  SELECT *
    INTO v_user_job
  FROM public.account_deletion_jobs
  WHERE id = p_user_job_id;

  IF v_user_job.status IS DISTINCT FROM 'completed' THEN
    IF v_user_job.status = 'db_committed' THEN
      PERFORM public.advance_account_deletion_job(
        p_user_job_id, 'mark_storage_pending', NULL,
        'permanent_business_owner_reconcile_storage_absent'
      );
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.account_deletion_jobs uj
      WHERE uj.id = p_user_job_id AND uj.status = 'storage_pending'
    ) THEN
      PERFORM public.advance_account_deletion_job(
        p_user_job_id, 'mark_completed', NULL,
        'permanent_business_owner_reconcile_storage_absent'
      );
    END IF;

    SELECT * INTO v_user_job
    FROM public.account_deletion_jobs
    WHERE id = p_user_job_id;
  END IF;

  IF v_user_job.status IS DISTINCT FROM 'completed' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'reconcile_advance_failed',
      'user_deletion_job_id', p_user_job_id,
      'status', v_user_job.status,
      'stage', v_user_job.stage,
      'sync', v_sync
    );
  END IF;

  UPDATE public.account_deletion_jobs
  SET affected_counts = coalesce(affected_counts, '{}'::jsonb)
        || jsonb_build_object(
             'permanent_business_owner_reconciled', true,
             'permanent_business_owner_reconciled_at', now(),
             'permanent_business_job_id', v_biz_job.id
           )
  WHERE id = p_user_job_id
  RETURNING * INTO v_user_job;

  RETURN jsonb_build_object(
    'ok', true,
    'result', 'reconciled_completed',
    'user_deletion_job_id', v_user_job.id,
    'business_deletion_job_id', v_biz_job.id,
    'status', v_user_job.status,
    'stage', v_user_job.stage,
    'completed_at', v_user_job.completed_at,
    'auth_exists', false,
    'identity_exists', false,
    'profile_exists', v_profile_exists,
    'profile_active', false,
    'avatar_paths_recorded', coalesce(cardinality(v_paths), 0),
    'avatar_paths_remaining', 0,
    'sync', v_sync
  );
END;
$$;

COMMENT ON FUNCTION public.admin_reconcile_permanent_business_owner_user_deletion_job(uuid) IS
  'Service-role only. Idempotent bookkeeping reconciliation for owner account_deletion_jobs left at db_committed/storage_pending after a completed permanent business deletion. Validates Auth/identity/profile/storage evidence; advances via advance_account_deletion_job. Never re-deletes users or businesses; never uses Vault/pg_net finalize queue.';

-- ---------------------------------------------------------------------------
-- Patch advance_business_account_deletion_job (mark_completed gate)
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
  v_owner_user_job_status text;
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

  IF v_action = 'mark_auth_pending' THEN
    UPDATE public.business_account_deletion_jobs
    SET status = 'auth_delete_pending',
        stage = 'awaiting_auth_and_storage_finalize',
        permanent_finalize_ready = true,
        completed_at = NULL,
        error_code = NULL,
        error_detail = NULL
    WHERE id = p_job_id
      AND status IN (
        'db_committed',
        'business_db_committed',
        'user_db_committed',
        'identity_retired',
        'auth_delete_pending'
      );
    IF NOT FOUND THEN
      RAISE EXCEPTION 'mark_auth_pending requires a committed job status (got %)', v_job.status
        USING ERRCODE = 'P0001';
    END IF;
  ELSIF v_action = 'mark_auth_deleted' THEN
    -- Edge confirmed auth.users deletion. Status stays auth_delete_pending until
    -- storage cleanup starts; the stage records the confirmation.
    UPDATE public.business_account_deletion_jobs
    SET stage = 'auth_deleted',
        affected_counts = coalesce(affected_counts, '{}'::jsonb)
          || jsonb_build_object('auth_users_deleted', 1),
        error_code = NULL,
        error_detail = NULL
    WHERE id = p_job_id
      AND status IN ('auth_delete_pending', 'storage_pending');
    IF NOT FOUND THEN
      RAISE EXCEPTION 'mark_auth_deleted requires job status auth_delete_pending or storage_pending (got %)', v_job.status
        USING ERRCODE = 'P0001';
    END IF;
  ELSIF v_action = 'mark_storage_pending' THEN
    UPDATE public.business_account_deletion_jobs
    SET status = 'storage_pending',
        stage = 'storage_cleanup',
        completed_at = NULL,
        error_code = NULL,
        error_detail = NULL
    WHERE id = p_job_id
      AND status IN ('db_committed', 'auth_delete_pending', 'storage_pending');
  ELSIF v_action = 'mark_completed' THEN
    -- Completion requires confirmed storage finalization (storage_pending only).
    -- Permanent mode: positive proof that linked owner user job exists and is completed.
    IF coalesce(v_job.deletion_mode, 'soft') = 'permanent'
       AND v_job.user_deletion_job_id IS NOT NULL THEN
      -- Zero-path children can terminalize here; avatar-bearing children must
      -- already have been cleaned by finalize-business-account-deletion.
      PERFORM public.gameon_permanent_business_sync_owner_user_job(
        v_job.user_deletion_job_id,
        p_job_id
      );

      SELECT uj.status
        INTO v_owner_user_job_status
      FROM public.account_deletion_jobs uj
      WHERE uj.id = v_job.user_deletion_job_id;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'permanent business mark_completed blocked: owner user job % is missing',
          v_job.user_deletion_job_id
          USING ERRCODE = 'P0002';
      END IF;

      IF v_owner_user_job_status IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'permanent business mark_completed blocked: owner user job % is not completed (status %)',
          v_job.user_deletion_job_id, v_owner_user_job_status
          USING ERRCODE = 'P0001';
      END IF;
    END IF;

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
    'deletion_mode', v_job.deletion_mode,
    'permanent_finalize_ready', v_job.permanent_finalize_ready,
    'completed_at', v_job.completed_at
  );
END;
$$;
;


-- ---------------------------------------------------------------------------
-- Patch admin_delete_business_account (sync after owner user DB)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_delete_business_account(
  p_business_id uuid,
  p_reason text,
  p_admin_email text DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL,
  p_acknowledge_admin_disabled boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_admin_email text := lower(btrim(coalesce(p_admin_email, 'unknown')));
  v_reason text := btrim(coalesce(p_reason, ''));
  v_key text;
  v_business public.businesses%ROWTYPE;
  v_before jsonb;
  v_job public.business_account_deletion_jobs%ROWTYPE;
  v_existing public.business_account_deletion_jobs%ROWTYPE;
  v_job_id uuid;
  v_owner uuid;
  v_eligibility jsonb;
  v_preview jsonb := '{}'::jsonb;
  v_soft jsonb := '{}'::jsonb;
  v_detach jsonb := '{}'::jsonb;
  v_user_start jsonb := '{}'::jsonb;
  v_user_execute jsonb := '{}'::jsonb;
  v_user_job_id uuid;
  v_identities_deleted integer := 0;
  v_finalize jsonb := '{}'::jsonb;
  v_finalize_queued boolean := false;
  v_stage_error text;
  v_stage_state text;
BEGIN
  IF NOT public.gameon_business_deletion_is_service_caller() THEN
    RAISE EXCEPTION 'service_role required'
      USING ERRCODE = '42501';
  END IF;

  IF p_business_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'invalid_business_id',
      'message', 'A valid business id is required.'
    );
  END IF;

  IF char_length(v_reason) < 3 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'invalid_reason',
      'message', 'An audit reason of at least 3 characters is required.'
    );
  END IF;

  SELECT * INTO v_business
  FROM public.businesses b
  WHERE b.id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'business_not_found',
      'message', 'Business account not found.'
    );
  END IF;

  v_before := to_jsonb(v_business);

  SELECT * INTO v_job
  FROM public.business_account_deletion_jobs j
  WHERE j.subject_business_id = p_business_id
    AND j.deletion_mode = 'permanent'
  ORDER BY j.created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    v_job.id := NULL;
  END IF;

  -- Idempotent replay: permanent deletion already finished.
  IF v_business.permanently_deleted_at IS NOT NULL
     AND v_job.id IS NOT NULL
     AND v_job.status = 'completed' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'idempotent', true,
      'result', 'already_permanently_deleted',
      'message', 'This business account was already permanently deleted.',
      'business_id', p_business_id,
      'deletion_mode', 'permanent',
      'deletion_job_id', v_job.id,
      'deletion_job_status', v_job.status,
      'deletion_job_stage', v_job.stage,
      'user_deletion_job_id', v_job.user_deletion_job_id,
      'permanent_non_reactivatable', true,
      'permanently_deleted_at', v_business.permanently_deleted_at,
      'auth_users_deleted', true,
      'auth_delete_pending', false,
      'account_identities_deleted', true,
      'source', 'admin_dashboard'
    );
  END IF;

  v_eligibility := public.admin_delete_business_account_eligibility(p_business_id);

  IF coalesce(v_eligibility ->> 'can_delete', 'false') <> 'true'
     AND coalesce(v_eligibility ->> 'can_resume', 'false') <> 'true' THEN
    RETURN jsonb_build_object(
      'ok', coalesce(v_eligibility ->> 'idempotent', 'false') = 'true',
      'idempotent', coalesce(v_eligibility ->> 'idempotent', 'false') = 'true',
      'error', coalesce(v_eligibility ->> 'block_reason', 'not_eligible'),
      'message', coalesce(
        v_eligibility ->> 'message',
        'This business account is not eligible for permanent admin deletion.'
      ),
      'business_id', p_business_id,
      'deletion_mode', 'permanent',
      'eligibility', v_eligibility
    );
  END IF;

  IF coalesce(v_eligibility ->> 'requires_admin_disabled_acknowledgment', 'false') = 'true'
     AND NOT coalesce(p_acknowledge_admin_disabled, false) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'admin_disabled_requires_acknowledgment',
      'message', 'This business is admin-disabled. Acknowledge the disabled state before permanent deletion.',
      'business_id', p_business_id,
      'deletion_mode', 'permanent',
      'eligibility', v_eligibility
    );
  END IF;

  -- subject_user_id on the job is NOT NULL: capture the owner BEFORE detach, and
  -- fall back to the job row when resuming after ownership was already cleared.
  v_owner := coalesce(v_business.owner_user_id, v_job.subject_user_id);

  IF v_owner IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'missing_owner',
      'message', 'This business has no owner_user_id to retire, so permanent account deletion cannot run.',
      'business_id', p_business_id,
      'deletion_mode', 'permanent',
      'eligibility', v_eligibility
    );
  END IF;

  v_key := coalesce(
    nullif(btrim(p_idempotency_key), ''),
    'admin-permanent:' || p_business_id::text
  );

  IF v_job.id IS NULL THEN
    SELECT * INTO v_existing
    FROM public.business_account_deletion_jobs j
    WHERE j.idempotency_key = v_key
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
      v_job := v_existing;
    ELSE
      SELECT * INTO v_existing
      FROM public.business_account_deletion_jobs j
      WHERE j.subject_business_id = p_business_id
        AND j.status NOT IN ('completed', 'failed', 'cancelled')
      ORDER BY j.created_at DESC
      LIMIT 1
      FOR UPDATE;

      IF FOUND THEN
        v_job := v_existing;
      ELSE
        BEGIN
          v_preview := public.preview_delete_business_account(p_business_id);
        EXCEPTION WHEN OTHERS THEN
          v_preview := jsonb_build_object('ok', false, 'error', SQLSTATE, 'detail', SQLERRM);
        END;

        INSERT INTO public.business_account_deletion_jobs (
          subject_business_id,
          subject_user_id,
          requested_by_user_id,
          request_source,
          deletion_mode,
          status,
          stage,
          idempotency_key,
          preview_snapshot
        )
        VALUES (
          p_business_id,
          v_owner,
          NULL,
          'admin',
          'permanent',
          'previewed',
          'previewed',
          v_key,
          v_preview
        )
        RETURNING * INTO v_job;
      END IF;
    END IF;
  END IF;

  v_job_id := v_job.id;

  UPDATE public.business_account_deletion_jobs j
  SET deletion_mode = 'permanent',
      request_source = 'admin',
      subject_user_id = coalesce(j.subject_user_id, v_owner)
  WHERE j.id = v_job_id
  RETURNING * INTO v_job;

  PERFORM set_config('gameon.business_deletion_actor_email', v_admin_email, true);

  -- -------------------------------------------------------------------------
  -- Stage 1: business DB cleanup + ownership detach
  -- -------------------------------------------------------------------------
  IF v_job.status IN ('queued', 'previewed', 'running', 'db_committed', 'storage_pending') THEN
    IF NOT coalesce(v_business.is_deleted, false) THEN
      BEGIN
        v_soft := public.gameon_business_deletion_soft_delete_core(p_business_id, v_job_id);
      EXCEPTION WHEN OTHERS THEN
        v_stage_error := SQLERRM;
        v_stage_state := SQLSTATE;
        v_soft := jsonb_build_object('ok', false, 'error', v_stage_state, 'detail', v_stage_error);
      END;

      IF coalesce(v_soft ->> 'ok', 'false') <> 'true' THEN
        UPDATE public.business_account_deletion_jobs
        SET status = 'failed',
            stage = 'business_db_cleanup_failed',
            error_code = coalesce(v_stage_state, 'business_soft_delete_failed'),
            error_detail = v_stage_error
        WHERE id = v_job_id;

        RETURN jsonb_build_object(
          'ok', false,
          'error', 'business_soft_delete_failed',
          'message', coalesce(v_stage_error, 'Business database cleanup failed. The business account was not modified.'),
          'business_id', p_business_id,
          'deletion_mode', 'permanent',
          'deletion_job_id', v_job_id,
          'deletion_job_status', 'failed',
          'deletion_job_stage', 'business_db_cleanup_failed',
          'auth_users_deleted', false,
          'auth_delete_pending', false,
          'account_identities_deleted', false,
          'resumable', false,
          'eligibility', v_eligibility,
          'source', 'admin_dashboard'
        );
      END IF;
    ELSE
      v_soft := jsonb_build_object('ok', true, 'idempotent_replay', true, 'deletion_mode', 'soft');
    END IF;

    BEGIN
      v_detach := public.gameon_business_deletion_permanent_detach_ownership(p_business_id, v_job_id);
    EXCEPTION WHEN OTHERS THEN
      v_stage_error := SQLERRM;
      v_stage_state := SQLSTATE;
      v_detach := jsonb_build_object('ok', false, 'error', v_stage_state, 'detail', v_stage_error);
    END;

    IF coalesce(v_detach ->> 'ok', 'false') <> 'true' THEN
      -- Soft tombstone already committed: keep the job resumable (running) so Stage 1
      -- can retry detach without creating a second permanent job.
      UPDATE public.business_account_deletion_jobs
      SET status = 'running',
          stage = 'ownership_detach_failed',
          error_code = coalesce(v_stage_state, 'ownership_detach_failed'),
          error_detail = v_stage_error
      WHERE id = v_job_id;

      RETURN jsonb_build_object(
        'ok', false,
        'error', 'ownership_detach_failed',
        'message', coalesce(v_stage_error, 'Ownership detach failed. The business remains soft-deleted and is not restored. Re-run permanent deletion to retry detach.'),
        'business_id', p_business_id,
        'deletion_mode', 'permanent',
        'deletion_job_id', v_job_id,
        'deletion_job_status', 'running',
        'deletion_job_stage', 'ownership_detach_failed',
        'auth_users_deleted', false,
        'auth_delete_pending', false,
        'account_identities_deleted', false,
        'resumable', true,
        'eligibility', v_eligibility,
        'source', 'admin_dashboard'
      );
    END IF;

    UPDATE public.business_account_deletion_jobs
    SET status = 'business_db_committed',
        stage = 'business_db_committed',
        deletion_mode = 'permanent',
        permanent_finalize_ready = false,
        error_code = NULL,
        error_detail = NULL,
        completed_at = NULL
    WHERE id = v_job_id
    RETURNING * INTO v_job;
  END IF;

  -- -------------------------------------------------------------------------
  -- Stage 2: fan-side cleanup for the former owner user
  -- -------------------------------------------------------------------------
  IF v_job.status = 'business_db_committed' THEN
    PERFORM set_config('gameon.permanent_business_account_deletion', p_business_id::text, true);

    v_stage_error := NULL;
    v_stage_state := NULL;

    BEGIN
      v_user_start := public.start_account_deletion_job(
        'admin-permanent-user:' || v_owner::text,
        v_owner
      );
      v_user_job_id := nullif(v_user_start ->> 'job_id', '')::uuid;

      IF v_user_job_id IS NULL THEN
        RAISE EXCEPTION 'user_deletion_job_start_failed'
          USING ERRCODE = 'P0001';
      END IF;

      v_user_execute := public.execute_delete_user_account_db(v_user_job_id);

      IF coalesce(v_user_execute ->> 'ok', 'false') <> 'true' THEN
        RAISE EXCEPTION 'user_deletion_db_failed: %', coalesce(v_user_execute ->> 'error_detail', 'unknown')
          USING ERRCODE = 'P0001';
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_stage_error := SQLERRM;
      v_stage_state := SQLSTATE;
    END;

    IF v_stage_error IS NOT NULL THEN
      -- Business is already closed and must not be restored: keep the job at the
      -- last good stage so the user stage can be retried.
      UPDATE public.business_account_deletion_jobs
      SET status = 'business_db_committed',
          stage = 'user_db_cleanup_failed',
          error_code = coalesce(v_stage_state, 'user_cleanup_failed'),
          error_detail = v_stage_error
      WHERE id = v_job_id
      RETURNING * INTO v_job;

      INSERT INTO public.admin_audit_logs (
        admin_email, action, target_type, target_id, before_data, after_data, reason
      ) VALUES (
        v_admin_email,
        'admin_permanent_delete_business_account',
        'business',
        p_business_id::text,
        jsonb_build_object('business', v_before, 'eligibility', v_eligibility),
        jsonb_build_object(
          'deletion_job_id', v_job_id,
          'deletion_job_status', v_job.status,
          'deletion_job_stage', v_job.stage,
          'soft_delete', v_soft,
          'ownership_detach', v_detach,
          'user_start', v_user_start,
          'user_execute', v_user_execute,
          'stage_error', v_stage_error,
          'stage_error_code', v_stage_state,
          'auth_users_deleted', false,
          'account_identities_deleted', false,
          'source', 'admin_dashboard'
        ),
        v_reason
      );

      RETURN jsonb_build_object(
        'ok', false,
        'error', 'user_cleanup_failed',
        'message', 'Business closure is committed, but the owner user cleanup failed. Re-run permanent deletion to retry the user stage.',
        'detail', v_stage_error,
        'business_id', p_business_id,
        'deletion_mode', 'permanent',
        'deletion_job_id', v_job_id,
        'deletion_job_status', v_job.status,
        'deletion_job_stage', v_job.stage,
        'ownership_detached', true,
        'auth_users_deleted', false,
        'auth_delete_pending', false,
        'account_identities_deleted', false,
        'resumable', true,
        'eligibility', v_eligibility,
        'source', 'admin_dashboard'
      );
    END IF;

    -- Zero-path: terminalize child now. Avatar-bearing: claim storage_pending;
    -- Edge finalize-business-account-deletion deletes user-avatars with its
    -- trusted service-role credential (never Vault/pg_net queue).
    PERFORM public.gameon_permanent_business_sync_owner_user_job(
      v_user_job_id,
      v_job_id
    );

    UPDATE public.business_account_deletion_jobs
    SET status = 'user_db_committed',
        stage = 'user_db_committed',
        user_deletion_job_id = coalesce(v_user_job_id, user_deletion_job_id),
        error_code = NULL,
        error_detail = NULL
    WHERE id = v_job_id
    RETURNING * INTO v_job;
  END IF;

  -- -------------------------------------------------------------------------
  -- Stage 3: retire the account identity (frees the reserved email)
  -- -------------------------------------------------------------------------
  IF v_job.status = 'user_db_committed' THEN
    v_stage_error := NULL;
    v_stage_state := NULL;

    BEGIN
      DELETE FROM public.account_identities ai
      WHERE ai.account_id = v_owner;
      GET DIAGNOSTICS v_identities_deleted = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN
      v_stage_error := SQLERRM;
      v_stage_state := SQLSTATE;
    END;

    IF v_stage_error IS NOT NULL THEN
      UPDATE public.business_account_deletion_jobs
      SET status = 'user_db_committed',
          stage = 'identity_retire_failed',
          error_code = coalesce(v_stage_state, 'identity_retire_failed'),
          error_detail = v_stage_error
      WHERE id = v_job_id
      RETURNING * INTO v_job;

      RETURN jsonb_build_object(
        'ok', false,
        'error', 'identity_retire_failed',
        'message', 'Business and owner user cleanup are committed, but retiring the account identity failed. Re-run permanent deletion to retry.',
        'detail', v_stage_error,
        'business_id', p_business_id,
        'deletion_mode', 'permanent',
        'deletion_job_id', v_job_id,
        'deletion_job_status', v_job.status,
        'deletion_job_stage', v_job.stage,
        'auth_users_deleted', false,
        'auth_delete_pending', false,
        'account_identities_deleted', false,
        'resumable', true,
        'eligibility', v_eligibility,
        'source', 'admin_dashboard'
      );
    END IF;

    UPDATE public.business_account_deletion_jobs
    SET status = 'identity_retired',
        stage = 'identity_retired',
        affected_counts = coalesce(affected_counts, '{}'::jsonb)
          || jsonb_build_object('account_identities_deleted', v_identities_deleted),
        error_code = NULL,
        error_detail = NULL
    WHERE id = v_job_id;

    UPDATE public.business_account_deletion_jobs
    SET status = 'auth_delete_pending',
        stage = 'awaiting_auth_and_storage_finalize',
        permanent_finalize_ready = true
    WHERE id = v_job_id
    RETURNING * INTO v_job;
  END IF;

  -- -------------------------------------------------------------------------
  -- Stage 4: queue the Edge finalizer (Auth delete + storage cleanup)
  -- -------------------------------------------------------------------------
  IF v_job.status IN ('auth_delete_pending', 'db_committed', 'storage_pending') THEN
    BEGIN
      v_finalize := public.queue_business_account_deletion_finalize(v_job_id);
      v_finalize_queued := coalesce((v_finalize ->> 'queued')::boolean, false);
    EXCEPTION WHEN OTHERS THEN
      v_finalize := jsonb_build_object('queued', false, 'error', SQLERRM);
      v_finalize_queued := false;
    END;

    IF v_finalize_queued THEN
      UPDATE public.business_account_deletion_jobs
      SET stage = 'auth_and_storage_finalize_queued'
      WHERE id = v_job_id
        AND status = 'auth_delete_pending'
      RETURNING * INTO v_job;
    END IF;
  END IF;

  SELECT * INTO v_job
  FROM public.business_account_deletion_jobs
  WHERE id = v_job_id;

  SELECT * INTO v_business
  FROM public.businesses b
  WHERE b.id = p_business_id;

  INSERT INTO public.admin_audit_logs (
    admin_email,
    action,
    target_type,
    target_id,
    before_data,
    after_data,
    reason
  ) VALUES (
    v_admin_email,
    'admin_permanent_delete_business_account',
    'business',
    p_business_id::text,
    jsonb_build_object(
      'business', v_before,
      'eligibility', v_eligibility
    ),
    jsonb_build_object(
      'deletion_mode', 'permanent',
      'deletion_job_id', v_job_id,
      'deletion_job_status', v_job.status,
      'deletion_job_stage', v_job.stage,
      'user_deletion_job_id', v_job.user_deletion_job_id,
      'soft_delete', v_soft,
      'ownership_detach', v_detach,
      'user_start', v_user_start,
      'user_execute', v_user_execute,
      'account_identities_deleted_count', v_identities_deleted,
      'finalize_queue', v_finalize,
      'finalize_queued', v_finalize_queued,
      'permanently_deleted_at', v_business.permanently_deleted_at,
      'permanent_non_reactivatable', true,
      'admin_disabled_acknowledged', coalesce(p_acknowledge_admin_disabled, false),
      'auth_users_deleted', false,
      'auth_delete_pending', v_job.status = 'auth_delete_pending',
      'source', 'admin_dashboard'
    ),
    v_reason
  );

  RETURN jsonb_build_object(
    'ok', true,
    'idempotent', false,
    'result', CASE
      WHEN v_job.status = 'completed' THEN 'completed'
      WHEN v_job.status = 'failed' THEN 'failed'
      ELSE 'permanent_deletion_in_progress'
    END,
    'message', CASE
      WHEN v_job.status = 'auth_delete_pending' AND v_finalize_queued THEN
        'Business account permanently closed in the database. Auth user deletion and storage cleanup have been queued.'
      WHEN v_job.status = 'auth_delete_pending' THEN
        'Business account permanently closed in the database. Auth user deletion and storage cleanup are still pending (finalizer not queued) — re-run to retry.'
      WHEN v_job.status = 'storage_pending' THEN
        'Business account permanently closed. Storage cleanup is pending.'
      WHEN v_job.status = 'completed' THEN
        'Business account permanently deleted.'
      ELSE
        'Permanent business account deletion is in progress.'
    END,
    'business_id', p_business_id,
    'business_name', v_before ->> 'display_name',
    'deletion_mode', 'permanent',
    'deletion_job_id', v_job_id,
    'deletion_job_status', v_job.status,
    'deletion_job_stage', v_job.stage,
    'user_deletion_job_id', v_job.user_deletion_job_id,
    'permanent_finalize_ready', v_job.permanent_finalize_ready,
    'permanently_deleted_at', v_business.permanently_deleted_at,
    'permanent_non_reactivatable', true,
    'ownership_detached', v_business.owner_user_id IS NULL,
    'account_identities_deleted', v_identities_deleted > 0
      OR v_job.status IN ('identity_retired', 'auth_delete_pending', 'storage_pending', 'completed'),
    'auth_users_deleted', false,
    'auth_delete_pending', v_job.status = 'auth_delete_pending',
    'finalize_queued', v_finalize_queued,
    'finalize_queue', v_finalize,
    'soft_delete', v_soft,
    'ownership_detach', v_detach,
    'admin_email', v_admin_email,
    'reason', v_reason,
    'eligibility', v_eligibility,
    'resumable', v_job.status NOT IN ('completed', 'failed'),
    'source', 'admin_dashboard'
  );
END;
$$;
;


-- ---------------------------------------------------------------------------
-- Patch reactivation eligibility (permanent owner cleanup visibility)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_reactivate_deleted_business_eligibility(
  p_business_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_business public.businesses%ROWTYPE;
  v_identity public.account_identities%ROWTYPE;
  v_job public.business_account_deletion_jobs;
  v_audit public.business_account_deletion_audit;
  v_perm_job public.business_account_deletion_jobs%ROWTYPE;
  v_owner_job public.account_deletion_jobs%ROWTYPE;
  v_former_owner uuid;
  v_auth_exists boolean := false;
  v_identity_exists boolean := false;
  v_profile_exists boolean := false;
BEGIN
  PERFORM public.gameon_business_reactivation_assert_service_role();

  IF p_business_id IS NULL THEN
    RETURN public.gameon_business_reactivation_eligibility_envelope(
      jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', 'invalid_business_id',
        'message', 'A valid business id is required.'
      )
    );
  END IF;

  SELECT * INTO v_business
  FROM public.businesses b
  WHERE b.id = p_business_id;

  IF NOT FOUND THEN
    RETURN public.gameon_business_reactivation_eligibility_envelope(
      jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', 'business_not_found',
        'message', 'Business not found.',
        'business_id', p_business_id
      )
    );
  END IF;

  -- Permanent Admin deletion (20260898) is irreversible.
  IF v_business.permanently_deleted_at IS NOT NULL THEN
    SELECT *
      INTO v_perm_job
    FROM public.business_account_deletion_jobs j
    WHERE j.subject_business_id = p_business_id
      AND coalesce(j.deletion_mode, 'soft') = 'permanent'
    ORDER BY j.created_at DESC NULLS LAST
    LIMIT 1;

    v_former_owner := coalesce(v_perm_job.subject_user_id, v_business.owner_user_id);

    IF v_perm_job.user_deletion_job_id IS NOT NULL THEN
      SELECT * INTO v_owner_job
      FROM public.account_deletion_jobs uj
      WHERE uj.id = v_perm_job.user_deletion_job_id;
    END IF;

    IF v_former_owner IS NOT NULL THEN
      SELECT EXISTS (
        SELECT 1 FROM auth.users au WHERE au.id = v_former_owner
      ) INTO v_auth_exists;

      IF to_regclass('public.account_identities') IS NOT NULL THEN
        SELECT EXISTS (
          SELECT 1 FROM public.account_identities ai WHERE ai.account_id = v_former_owner
        ) INTO v_identity_exists;
      END IF;

      IF to_regclass('public.user_profiles') IS NOT NULL THEN
        SELECT EXISTS (
          SELECT 1 FROM public.user_profiles up WHERE up.id = v_former_owner
        ) INTO v_profile_exists;
      END IF;
    END IF;

    RETURN public.gameon_business_reactivation_eligibility_envelope(
      jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', 'permanently_deleted',
        'message', 'This business account was permanently deleted by an admin and can never be reactivated.',
        'business_id', p_business_id,
        'owner_user_id', v_business.owner_user_id,
        'former_owner_user_id', v_former_owner,
        'permanently_deleted_at', v_business.permanently_deleted_at,
        'permanent_non_reactivatable', true,
        'deletion_job_id', v_perm_job.id,
        'deletion_job_status', v_perm_job.status,
        'user_deletion_job_id', v_perm_job.user_deletion_job_id,
        'owner_user_job_status', v_owner_job.status,
        'owner_user_job_stage', v_owner_job.stage,
        'owner_user_job_completed', (v_owner_job.status = 'completed'),
        'owner_auth_removed', (v_former_owner IS NOT NULL AND NOT v_auth_exists),
        'owner_identity_removed', (v_former_owner IS NOT NULL AND NOT v_identity_exists),
        'owner_profile_removed', (v_former_owner IS NOT NULL AND NOT v_profile_exists),
        'owner_user_cleanup_complete', (
          v_former_owner IS NOT NULL
          AND NOT v_auth_exists
          AND NOT v_identity_exists
          AND NOT v_profile_exists
          AND (v_owner_job.id IS NULL OR v_owner_job.status = 'completed')
        )
      )
    );
  END IF;

  IF to_regclass('public.account_identities') IS NULL THEN
    RETURN public.gameon_business_reactivation_eligibility_envelope(
      jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', 'identity_table_missing',
        'message', 'account_identities table is unavailable.',
        'business_id', p_business_id,
        'owner_user_id', v_business.owner_user_id
      ) || public.gameon_business_reactivation_diagnostic_flags(
        v_business.owner_user_id,
        v_identity
      )
    );
  END IF;

  IF v_business.owner_user_id IS NOT NULL THEN
    SELECT * INTO v_identity
    FROM public.account_identities ai
    WHERE ai.account_id = v_business.owner_user_id;
  END IF;

  IF NOT FOUND THEN
    v_identity.account_id := NULL;
  END IF;

  v_job := public.gameon_business_reactivation_latest_deletion_job(p_business_id);
  v_audit := public.gameon_business_reactivation_latest_soft_audit(p_business_id);

  RETURN public.gameon_business_reactivation_evaluate_eligibility(
    p_business_id,
    v_business,
    v_identity,
    v_job,
    v_audit,
    NULL
  );
END;
$$;
;


REVOKE ALL ON FUNCTION public.gameon_permanent_business_sync_owner_user_job(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_permanent_business_sync_owner_user_job(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.gameon_permanent_business_sync_owner_user_job(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.gameon_permanent_business_sync_owner_user_job(uuid, uuid) TO service_role;

REVOKE ALL ON FUNCTION public.admin_reconcile_permanent_business_owner_user_deletion_job(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_reconcile_permanent_business_owner_user_deletion_job(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.admin_reconcile_permanent_business_owner_user_deletion_job(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reconcile_permanent_business_owner_user_deletion_job(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.advance_business_account_deletion_job(uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.advance_business_account_deletion_job(uuid, text, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.advance_business_account_deletion_job(uuid, text, text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.advance_business_account_deletion_job(uuid, text, text, text) TO service_role;

REVOKE ALL ON FUNCTION public.admin_delete_business_account(uuid, text, text, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_delete_business_account(uuid, text, text, text, boolean) FROM anon;
REVOKE ALL ON FUNCTION public.admin_delete_business_account(uuid, text, text, text, boolean) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_business_account(uuid, text, text, text, boolean) TO service_role;

REVOKE ALL ON FUNCTION public.admin_reactivate_deleted_business_eligibility(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_reactivate_deleted_business_eligibility(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.admin_reactivate_deleted_business_eligibility(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reactivate_deleted_business_eligibility(uuid) TO service_role;


DO $integrity$
DECLARE
  v_def text;
BEGIN
  IF to_regprocedure('public.gameon_permanent_business_sync_owner_user_job(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'Integrity fail: sync helper missing';
  END IF;

  IF to_regprocedure('public.gameon_permanent_business_sync_owner_user_job(uuid,uuid,boolean)') IS NOT NULL THEN
    RAISE EXCEPTION 'Integrity fail: obsolete 3-arg sync helper still present';
  END IF;

  SELECT pg_get_functiondef('public.gameon_permanent_business_sync_owner_user_job(uuid,uuid)'::regprocedure)
    INTO v_def;
  IF position('queue_account_deletion_finalize' IN v_def) > 0 THEN
    RAISE EXCEPTION 'Integrity fail: sync helper must not use queue_account_deletion_finalize';
  END IF;
  IF position('business deletion job not found' IN v_def) = 0
     OR position('subject_user_id mismatch' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: sync helper missing strict business-link validation';
  END IF;

  IF to_regprocedure('public.admin_reconcile_permanent_business_owner_user_deletion_job(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Integrity fail: reconcile RPC missing';
  END IF;

  SELECT pg_get_functiondef('public.admin_reconcile_permanent_business_owner_user_deletion_job(uuid)'::regprocedure)
    INTO v_def;
  IF position('user_job_status_not_reconcileable' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: reconcile missing permitted source-state check';
  END IF;

  SELECT pg_get_functiondef('public.admin_delete_business_account(uuid,text,text,text,boolean)'::regprocedure)
    INTO v_def;
  IF position('gameon_permanent_business_sync_owner_user_job' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: orchestrator missing owner user job sync';
  END IF;

  SELECT pg_get_functiondef('public.advance_business_account_deletion_job(uuid,text,text,text)'::regprocedure)
    INTO v_def;
  IF position('owner user job % is missing' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: mark_completed missing owner user job missing check';
  END IF;
  IF position('owner user job % is not completed (status %)' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: mark_completed missing owner user job status gate';
  END IF;

  SELECT pg_get_functiondef('public.admin_reactivate_deleted_business_eligibility(uuid)'::regprocedure)
    INTO v_def;
  IF position('owner_user_cleanup_complete' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: reactivation eligibility missing owner cleanup fields';
  END IF;

  RAISE NOTICE '20260901 permanent business owner user-job consistency OK';
  RAISE NOTICE 'REMINDER: deploy finalize-business-account-deletion after applying (sync child before mark_completed).';
  RAISE NOTICE 'RECOVERY: call service_role admin_reconcile_permanent_business_owner_user_deletion_job(<user_job_id>) for each stuck job.';
END;
$integrity$;
