-- 20260903: Link owner user_deletion_job_id BEFORE sync gate
--
-- Production failure (soft tombstone → permanent, Enea bar):
--   business job ec99b500-... has no linked user_deletion_job_id
--
-- Root cause:
--   20260901 gameon_permanent_business_sync_owner_user_job(p_user_job_id,
--   p_business_job_id) correctly requires business_account_deletion_jobs
--   .user_deletion_job_id to already equal p_user_job_id.
--   admin_delete_business_account Stage 2 called sync BEFORE the UPDATE that
--   persists user_deletion_job_id, so every post-20260901 permanent deletion
--   that reaches Stage 2 fails closed at the sync gate (including soft→permanent
--   promotion from 20260902).
--
-- Observed on Enea attempt: exception aborted the RPC transaction; soft job
-- remained soft/db_committed with user_deletion_job_id NULL (full rollback).
--
-- Fix (forward-only, CREATE OR REPLACE orchestrator only):
--   1) Create/adopt owner account_deletion_job via existing start/execute APIs
--   2) Persist user_deletion_job_id (fail closed on conflicting link)
--   3) Then call sync (strict 20260901 gates unchanged)
--   4) Advance to user_db_committed
--   Sync failures after link become resumable at business_db_committed.
--
-- Does NOT weaken missing-child gates.
-- Does NOT mutate existing rows on apply.
-- PREPARED ONLY — manual apply. Do NOT auto-apply.
-- Prerequisites: 20260898, 20260900, 20260901, 20260902.

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

  -- Soft tombstone promotion: move off Edge-ready soft statuses (db_committed /
  -- storage_pending) in the same write that flips deletion_mode to permanent so a
  -- concurrent soft finalizer cannot Auth-delete before permanent DB stages finish.
  -- storage_paths are preserved for the permanent Edge venue-photos cleanup.
  UPDATE public.business_account_deletion_jobs j
  SET deletion_mode = 'permanent',
      request_source = 'admin',
      subject_user_id = coalesce(j.subject_user_id, v_owner),
      permanent_finalize_ready = CASE
        WHEN coalesce(j.deletion_mode, 'soft') <> 'permanent'
             AND j.status IN ('db_committed', 'storage_pending')
          THEN false
        ELSE j.permanent_finalize_ready
      END,
      status = CASE
        WHEN coalesce(j.deletion_mode, 'soft') <> 'permanent'
             AND j.status IN ('db_committed', 'storage_pending')
          THEN 'running'
        ELSE j.status
      END,
      stage = CASE
        WHEN coalesce(j.deletion_mode, 'soft') <> 'permanent'
             AND j.status IN ('db_committed', 'storage_pending')
          THEN 'soft_tombstone_permanent_promotion'
        ELSE j.stage
      END,
      affected_counts = coalesce(j.affected_counts, '{}'::jsonb) || CASE
        WHEN coalesce(j.deletion_mode, 'soft') <> 'permanent'
             AND j.status IN ('db_committed', 'storage_pending')
          THEN jsonb_build_object(
            'soft_to_permanent_promoted', true,
            'prior_soft_status', j.status,
            'prior_soft_stage', j.stage,
            'prior_soft_storage_path_count', coalesce(cardinality(j.storage_paths), 0)
          )
        ELSE '{}'::jsonb
      END
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
      -- Resume: if this business job already links a child, adopt it only after
      -- proving subject_user_id match. Otherwise create/adopt via authoritative
      -- start_account_deletion_job (idempotency key prevents duplicates).
      IF v_job.user_deletion_job_id IS NOT NULL THEN
        v_user_job_id := v_job.user_deletion_job_id;

        IF NOT EXISTS (
          SELECT 1
          FROM public.account_deletion_jobs uj
          WHERE uj.id = v_user_job_id
            AND uj.subject_user_id = v_owner
        ) THEN
          RAISE EXCEPTION 'linked_user_deletion_job_subject_mismatch'
            USING ERRCODE = 'P0001';
        END IF;

        v_user_start := jsonb_build_object(
          'ok', true,
          'job_id', v_user_job_id,
          'adopted_existing_link', true
        );
      ELSE
        v_user_start := public.start_account_deletion_job(
          'admin-permanent-user:' || v_owner::text,
          v_owner
        );
        v_user_job_id := nullif(v_user_start ->> 'job_id', '')::uuid;
      END IF;

      IF v_user_job_id IS NULL THEN
        RAISE EXCEPTION 'user_deletion_job_start_failed'
          USING ERRCODE = 'P0001';
      END IF;

      -- Fail closed if another in-progress user job for this owner is not the
      -- one we are about to link (ambiguous child).
      IF EXISTS (
        SELECT 1
        FROM public.account_deletion_jobs uj
        WHERE uj.subject_user_id = v_owner
          AND uj.id IS DISTINCT FROM v_user_job_id
          AND uj.status NOT IN ('completed', 'failed', 'cancelled')
      ) THEN
        RAISE EXCEPTION 'ambiguous_owner_user_deletion_job'
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

    -- Link the child BEFORE the 20260901 strict sync gate. Sync validates that
    -- business_account_deletion_jobs.user_deletion_job_id already equals the
    -- owner job id; calling sync first raised:
    --   business job % has no linked user_deletion_job_id
    -- for every post-20260901 permanent run (including soft→permanent promotion).
    -- Gate itself is preserved — only ordering is corrected.
    UPDATE public.business_account_deletion_jobs
    SET user_deletion_job_id = v_user_job_id
    WHERE id = v_job_id
      AND (
        user_deletion_job_id IS NULL
        OR user_deletion_job_id = v_user_job_id
      )
    RETURNING * INTO v_job;

    IF NOT FOUND OR v_job.user_deletion_job_id IS DISTINCT FROM v_user_job_id THEN
      UPDATE public.business_account_deletion_jobs
      SET status = 'business_db_committed',
          stage = 'user_job_link_failed',
          error_code = 'ambiguous_or_conflicting_user_deletion_job',
          error_detail = format(
            'Refusing to link owner job %s; business job already linked to %s',
            v_user_job_id,
            (SELECT user_deletion_job_id::text FROM public.business_account_deletion_jobs WHERE id = v_job_id)
          )
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
          'attempted_user_deletion_job_id', v_user_job_id,
          'linked_user_deletion_job_id', v_job.user_deletion_job_id,
          'auth_users_deleted', false,
          'account_identities_deleted', false,
          'source', 'admin_dashboard'
        ),
        v_reason
      );

      RETURN jsonb_build_object(
        'ok', false,
        'error', 'user_job_link_failed',
        'message', 'Owner user cleanup ran, but linking the child job to the business job failed closed due to an ambiguous or conflicting user_deletion_job_id. Resolve the link conflict, then re-run permanent deletion.',
        'business_id', p_business_id,
        'deletion_mode', 'permanent',
        'deletion_job_id', v_job_id,
        'deletion_job_status', v_job.status,
        'deletion_job_stage', v_job.stage,
        'user_deletion_job_id', v_job.user_deletion_job_id,
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
    BEGIN
      PERFORM public.gameon_permanent_business_sync_owner_user_job(
        v_user_job_id,
        v_job_id
      );
    EXCEPTION WHEN OTHERS THEN
      v_stage_error := SQLERRM;
      v_stage_state := SQLSTATE;

      UPDATE public.business_account_deletion_jobs
      SET status = 'business_db_committed',
          stage = 'owner_user_sync_failed',
          user_deletion_job_id = coalesce(user_deletion_job_id, v_user_job_id),
          error_code = coalesce(v_stage_state, 'owner_user_sync_failed'),
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
          'user_deletion_job_id', v_user_job_id,
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
        'error', 'owner_user_sync_failed',
        'message', 'Owner user DB cleanup and child job link succeeded, but synchronizing the owner user job failed. Re-run permanent deletion to resume from business_db_committed.',
        'detail', v_stage_error,
        'business_id', p_business_id,
        'deletion_mode', 'permanent',
        'deletion_job_id', v_job_id,
        'deletion_job_status', v_job.status,
        'deletion_job_stage', v_job.stage,
        'user_deletion_job_id', v_user_job_id,
        'ownership_detached', true,
        'auth_users_deleted', false,
        'auth_delete_pending', false,
        'account_identities_deleted', false,
        'resumable', true,
        'eligibility', v_eligibility,
        'source', 'admin_dashboard'
      );
    END;

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
  -- Permanent jobs must not finalize from soft db_committed (Auth-before-DB risk).
  -- Soft tombstones are promoted to running before Stage 1; Auth/storage only after
  -- identity_retired -> auth_delete_pending with permanent_finalize_ready.
  IF v_job.status IN ('auth_delete_pending', 'storage_pending') THEN
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

COMMENT ON FUNCTION public.admin_delete_business_account(uuid, text, text, text, boolean) IS
  'Admin permanent business-account deletion orchestrator. Soft Phase-2 tombstones may promote an in-progress soft job in place. Stage 2 links user_deletion_job_id before gameon_permanent_business_sync_owner_user_job. DB-first; Auth/storage via Edge after identity retirement. service_role only.';

REVOKE ALL ON FUNCTION public.admin_delete_business_account(uuid, text, text, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_delete_business_account(uuid, text, text, text, boolean) FROM anon;
REVOKE ALL ON FUNCTION public.admin_delete_business_account(uuid, text, text, text, boolean) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_business_account(uuid, text, text, text, boolean) TO service_role;

DO $integrity$
DECLARE
  v_orch text;
  v_sync text;
BEGIN
  IF to_regprocedure('public.admin_delete_business_account(uuid, text, text, text, boolean)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: admin_delete_business_account missing';
  END IF;

  SELECT pg_get_functiondef('public.admin_delete_business_account(uuid, text, text, text, boolean)'::regprocedure)
    INTO v_orch;
  SELECT pg_get_functiondef('public.gameon_permanent_business_sync_owner_user_job(uuid,uuid)'::regprocedure)
    INTO v_sync;

  IF position('user_job_link_failed' IN v_orch) = 0 THEN
    RAISE EXCEPTION 'FAIL: orchestrator missing user_deletion_job_id link-before-sync ordering';
  END IF;
  IF position('owner_user_sync_failed' IN v_orch) = 0 THEN
    RAISE EXCEPTION 'FAIL: orchestrator missing resumable owner sync failure path';
  END IF;
  IF position('has no linked user_deletion_job_id' IN v_sync) = 0 THEN
    RAISE EXCEPTION 'FAIL: sync missing-child gate must remain intact';
  END IF;
  IF has_function_privilege('anon', 'public.admin_delete_business_account(uuid, text, text, text, boolean)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.admin_delete_business_account(uuid, text, text, text, boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: orchestrator must not be executable by anon/authenticated';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.admin_delete_business_account(uuid, text, text, text, boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: orchestrator must be executable by service_role';
  END IF;
END;
$integrity$;
