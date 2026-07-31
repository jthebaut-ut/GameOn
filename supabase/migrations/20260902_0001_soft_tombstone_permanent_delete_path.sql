-- Soft tombstone → permanent business deletion (forward-only).
--
-- Problem:
--   Phase 2 soft tombstones (is_deleted=true, permanently_deleted_at IS NULL) with an
--   in-progress soft job at db_committed/storage_pending were refused by
--   admin_delete_business_account_eligibility (block_reason=active_soft_deletion_job).
--   Admin Deleted Business Details therefore could not permanently retire them without
--   reactivating first. Fan deletion stayed blocked by business_account_type.
--
-- Architecture (B): promote the existing soft job in place to deletion_mode=permanent.
--   - Unique active-job index forbids creating a second parent job.
--   - Soft audit history is preserved.
--   - Soft storage_paths are retained for permanent Edge venue-photos cleanup
--     (missing objects remain idempotent success).
--   - Soft jobs still early (queued/previewed/running without promotable state) stay blocked.
--
-- Safety hardening:
--   - On soft→permanent promotion, bump status off Edge-ready soft statuses
--     (db_committed/storage_pending → running / soft_tombstone_permanent_promotion)
--     in the same UPDATE that sets deletion_mode=permanent.
--   - Permanent Stage 4 no longer queues finalize from db_committed (Auth-before-DB risk).
--   - Edge finalize-business-account-deletion must drop permanent db_committed readiness
--     (deploy with this migration).
--
-- Does NOT weaken active-business permanent eligibility or normal soft reactivation.
-- Idempotent CREATE OR REPLACE. PREPARED ONLY — manual apply. Do NOT auto-apply.
-- Prerequisites: 20260898, 20260900, 20260901.

CREATE OR REPLACE FUNCTION public.admin_delete_business_account_eligibility(
  p_business_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_business public.businesses%ROWTYPE;
  v_job public.business_account_deletion_jobs%ROWTYPE;
  v_perm public.business_account_deletion_jobs%ROWTYPE;
  v_preview jsonb := '{}'::jsonb;
  v_user_preview jsonb := '{}'::jsonb;
  v_owner uuid;
  v_identity_type text;
  v_active_ban boolean := false;
  v_admin_disabled boolean := false;
  v_active_venues integer := 0;
  v_archived_venues integer := 0;
  v_claims integer := 0;
  v_pending_claims integer := 0;
  v_future_events integer := 0;
  v_completed_events integer := 0;
  v_in_progress text[] := ARRAY[
    'queued', 'previewed', 'running',
    'business_db_committed', 'user_db_committed', 'identity_retired',
    'auth_delete_pending', 'db_committed', 'storage_pending'
  ];
  v_base jsonb;
  v_already_permanent boolean := false;
  v_soft_promotable boolean := false;
  v_auth_exists boolean := false;
  v_profile_exists boolean := false;
  v_identity_exists boolean := false;
  v_storage_path_count integer := 0;
  v_original_owner_email text;
  v_soft_audit_email text;
BEGIN
  IF NOT public.gameon_business_deletion_is_service_caller() THEN
    RAISE EXCEPTION 'service_role required'
      USING ERRCODE = '42501';
  END IF;

  IF p_business_id IS NULL THEN
    RETURN jsonb_build_object(
      'eligible', false,
      'can_delete', false,
      'can_resume', false,
      'deletion_mode', 'permanent',
      'block_reason', 'invalid_business_id',
      'message', 'A valid business id is required.'
    );
  END IF;

  SELECT * INTO v_business
  FROM public.businesses b
  WHERE b.id = p_business_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'eligible', false,
      'can_delete', false,
      'can_resume', false,
      'deletion_mode', 'permanent',
      'block_reason', 'business_not_found',
      'message', 'Business account not found.'
    );
  END IF;

  SELECT * INTO v_job
  FROM public.business_account_deletion_jobs j
  WHERE j.subject_business_id = p_business_id
  ORDER BY j.created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    v_job.id := NULL;
  END IF;

  SELECT * INTO v_perm
  FROM public.business_account_deletion_jobs j
  WHERE j.subject_business_id = p_business_id
    AND j.deletion_mode = 'permanent'
  ORDER BY j.created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    v_perm.id := NULL;
  END IF;

  v_owner := coalesce(v_business.owner_user_id, v_perm.subject_user_id);
  v_admin_disabled := lower(btrim(coalesce(v_business.admin_status, ''))) = 'disabled';

  SELECT EXISTS (
    SELECT 1
    FROM public.business_bans bb
    WHERE bb.business_id = p_business_id
      AND bb.lifted_at IS NULL
      AND (bb.is_permanent = true OR bb.banned_until IS NULL OR bb.banned_until > now())
  ) INTO v_active_ban;

  SELECT ai.account_type
    INTO v_identity_type
  FROM public.account_identities ai
  WHERE (
      (v_owner IS NOT NULL AND ai.account_id = v_owner)
      OR (
        btrim(coalesce(v_business.owner_email, '')) <> ''
        AND lower(btrim(ai.email)) = lower(btrim(v_business.owner_email))
      )
    )
  ORDER BY CASE WHEN ai.account_type = 'business' THEN 0 ELSE 1 END
  LIMIT 1;

  SELECT
    count(*) FILTER (WHERE lower(btrim(coalesce(v.admin_status, 'active'))) = 'active'),
    count(*) FILTER (
      WHERE lower(btrim(coalesce(v.admin_status, ''))) = 'archived'
         OR v.admin_archived_at IS NOT NULL
    )
  INTO v_active_venues, v_archived_venues
  FROM public.venues v
  WHERE v.business_id = p_business_id
     OR (v_owner IS NOT NULL AND v.owner_user_id = v_owner)
     OR (
       btrim(coalesce(v_business.owner_email, '')) <> ''
       AND lower(btrim(coalesce(v.owner_email, ''))) = lower(btrim(v_business.owner_email))
     );

  SELECT
    count(*),
    count(*) FILTER (
      WHERE coalesce(lower(btrim(vc.approval_status)), '') NOT IN (
        'approved', 'released', 'business_deleted', 'cancelled', 'withdrawn', 'rejected'
      )
    )
  INTO v_claims, v_pending_claims
  FROM public.venue_claims vc
  WHERE vc.business_id = p_business_id;

  SELECT
    count(*) FILTER (
      WHERE NOT public.gameon_business_deletion_event_is_completed(
        ve.scheduled_start_at, ve.event_date, ve.admin_status
      )
    ),
    count(*) FILTER (
      WHERE public.gameon_business_deletion_event_is_completed(
        ve.scheduled_start_at, ve.event_date, ve.admin_status
      )
    )
  INTO v_future_events, v_completed_events
  FROM public.venue_events ve
  JOIN public.venues v ON v.id = ve.venue_id
  WHERE v.business_id = p_business_id;

  -- Soft-audit original owner email (tombstone owner_email is often anonymized).
  SELECT btrim(coalesce(a.business_snapshot ->> 'owner_email', ''))
    INTO v_soft_audit_email
  FROM public.business_account_deletion_audit a
  WHERE a.business_id = p_business_id
    AND coalesce(a.deletion_mode, 'soft') = 'soft'
  ORDER BY a.deleted_at DESC NULLS LAST, a.id DESC
  LIMIT 1;

  v_original_owner_email := nullif(v_soft_audit_email, '');
  IF v_original_owner_email IS NULL
     AND btrim(coalesce(v_business.owner_email, '')) <> ''
     AND position('@deleted.fangeo.local' in lower(v_business.owner_email)) = 0 THEN
    v_original_owner_email := btrim(v_business.owner_email);
  END IF;

  IF v_owner IS NOT NULL THEN
    SELECT EXISTS(SELECT 1 FROM auth.users u WHERE u.id = v_owner) INTO v_auth_exists;
    IF to_regclass('public.user_profiles') IS NOT NULL THEN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'is_deleted'
      ) THEN
        SELECT EXISTS(
          SELECT 1 FROM public.user_profiles up
          WHERE up.id = v_owner AND coalesce(up.is_deleted, false) = false
        ) INTO v_profile_exists;
      ELSE
        SELECT EXISTS(SELECT 1 FROM public.user_profiles up WHERE up.id = v_owner)
          INTO v_profile_exists;
      END IF;
    ELSE
      v_profile_exists := false;
    END IF;
    SELECT EXISTS(SELECT 1 FROM public.account_identities ai WHERE ai.account_id = v_owner)
      INTO v_identity_exists;
  END IF;

  IF v_job.id IS NOT NULL AND v_job.storage_paths IS NOT NULL THEN
    BEGIN
      v_storage_path_count := coalesce(cardinality(v_job.storage_paths), 0);
    EXCEPTION WHEN OTHERS THEN
      v_storage_path_count := 0;
    END;
  END IF;

  -- Previews must never hard-fail eligibility.
  BEGIN
    v_preview := public.preview_delete_business_account(p_business_id);
  EXCEPTION WHEN OTHERS THEN
    v_preview := jsonb_build_object('ok', false, 'error', SQLSTATE, 'detail', SQLERRM);
  END;

  IF v_owner IS NOT NULL THEN
    BEGIN
      v_user_preview := public.preview_delete_user_account(v_owner);
    EXCEPTION WHEN OTHERS THEN
      v_user_preview := jsonb_build_object('ok', false, 'error', SQLSTATE, 'detail', SQLERRM);
    END;
  ELSE
    v_user_preview := jsonb_build_object('ok', false, 'error', 'missing_owner');
  END IF;

  v_base := jsonb_build_object(
    'deletion_mode', 'permanent',
    'business_id', p_business_id,
    'business_name', v_business.display_name,
    'business_handle', v_business.business_handle,
    'owner_email', coalesce(v_original_owner_email, v_business.owner_email),
    'owner_user_id', v_owner,
    'original_owner_email', v_original_owner_email,
    'auth_user_exists', v_auth_exists,
    'active_profile_exists', v_profile_exists,
    'account_identity_exists', v_identity_exists,
    'storage_path_count', v_storage_path_count,
    'soft_tombstone', coalesce(v_business.is_deleted, false)
      AND v_business.permanently_deleted_at IS NULL,
    'account_status', v_business.admin_status,
    'account_identity_type', v_identity_type,
    'is_deleted', coalesce(v_business.is_deleted, false),
    'is_archived', lower(btrim(coalesce(v_business.admin_status, ''))) = 'archived'
      OR v_business.admin_archived_at IS NOT NULL,
    'permanently_deleted_at', v_business.permanently_deleted_at,
    'permanent_non_reactivatable', true,
    'auth_users_will_be_deleted', true,
    'auth_users_deleted', false,
    'account_identity_will_be_retired', true,
    'account_identities_deleted', false,
    'plan_type', v_business.plan_type,
    'plan_status', v_business.plan_status,
    'pro_expires_at', v_business.pro_expires_at,
    'active_venue_count', v_active_venues,
    'archived_venue_count', v_archived_venues,
    'claim_count', v_claims,
    'pending_claim_count', v_pending_claims,
    'future_event_count', v_future_events,
    'completed_event_count', v_completed_events,
    'active_business_ban', v_active_ban,
    'admin_disabled', v_admin_disabled,
    'requires_admin_disabled_acknowledgment', v_admin_disabled,
    'preview', v_preview,
    'user_preview', v_user_preview,
    'user_preview_block_reason', v_user_preview ->> 'block_reason',
    'deletion_job_id', v_job.id,
    'deletion_job_status', v_job.status,
    'deletion_job_stage', v_job.stage,
    'deletion_job_mode', v_job.deletion_mode,
    'permanent_job_id', v_perm.id,
    'permanent_job_status', v_perm.status,
    'permanent_job_stage', v_perm.stage,
    'user_deletion_job_id', v_perm.user_deletion_job_id
  );

  v_already_permanent :=
    v_business.permanently_deleted_at IS NOT NULL
    OR (
      coalesce(v_business.is_deleted, false)
      AND v_perm.id IS NOT NULL
      AND v_perm.status = 'completed'
    );

  IF v_already_permanent
     AND (v_perm.id IS NULL OR v_perm.status NOT IN (
       'queued', 'previewed', 'running',
       'business_db_committed', 'user_db_committed', 'identity_retired',
       'auth_delete_pending', 'db_committed', 'storage_pending'
     )) THEN
    RETURN v_base || jsonb_build_object(
      'eligible', false,
      'can_delete', false,
      'can_resume', false,
      'idempotent', true,
      'block_reason', 'already_permanently_deleted',
      'message', 'This business account was already permanently deleted. It cannot be deleted again and cannot be reactivated.'
    );
  END IF;

  IF v_perm.id IS NOT NULL AND v_perm.status = ANY(v_in_progress) THEN
    RETURN v_base || jsonb_build_object(
      'eligible', false,
      'can_delete', false,
      'can_resume', true,
      'idempotent', false,
      'resume_job_id', v_perm.id,
      'resume_status', v_perm.status,
      'resume_stage', v_perm.stage,
      'block_reason', 'permanent_deletion_in_progress',
      'message', format(
        'A permanent deletion job is already in progress at status %s (stage %s). Re-run admin_delete_business_account to resume it.',
        v_perm.status,
        coalesce(v_perm.stage, 'unknown')
      )
    );
  END IF;

  -- Soft tombstone with soft job already past DB commit may be promoted in-place
  -- to permanent (same job row; unique active-job index forbids a second parent).
  v_soft_promotable :=
    coalesce(v_business.is_deleted, false)
    AND v_business.permanently_deleted_at IS NULL
    AND v_job.id IS NOT NULL
    AND coalesce(v_job.deletion_mode, 'soft') <> 'permanent'
    AND v_job.status IN ('db_committed', 'storage_pending');

  IF v_job.id IS NOT NULL
     AND coalesce(v_job.deletion_mode, 'soft') <> 'permanent'
     AND v_job.status = ANY(v_in_progress)
     AND NOT v_soft_promotable THEN
    RETURN v_base || jsonb_build_object(
      'eligible', false,
      'can_delete', false,
      'can_resume', false,
      'idempotent', false,
      'soft_job_promotable', false,
      'block_reason', 'active_soft_deletion_job',
      'message', 'A non-permanent business deletion job is still in progress for this account. Let soft DB cleanup finish (reach db_committed/storage_pending with is_deleted=true), or fail the soft job, before permanent deletion.'
    );
  END IF;

  IF v_owner IS NULL THEN
    RETURN v_base || jsonb_build_object(
      'eligible', false,
      'can_delete', false,
      'can_resume', false,
      'idempotent', false,
      'block_reason', 'missing_owner',
      'message', 'This business has no owner_user_id, so there is no account identity or Auth user to permanently delete. Resolve ownership first.'
    );
  END IF;

  RETURN v_base || jsonb_build_object(
    'eligible', true,
    'can_delete', true,
    'can_resume', v_perm.id IS NOT NULL AND v_perm.status = ANY(v_in_progress),
    'idempotent', false,
    'soft_job_promotable', v_soft_promotable,
    'soft_tombstone_to_permanent', coalesce(v_business.is_deleted, false)
      AND v_business.permanently_deleted_at IS NULL,
    'block_reason', NULL,
    'message', CASE
      WHEN v_soft_promotable THEN
        'This business is a soft-deleted recoverable tombstone with an in-progress soft deletion job. Permanent deletion will promote that soft job in place, detach ownership, clean the owner user, retire the business identity, and delete Auth after DB cleanup. Reactivation will become impossible.'
      WHEN coalesce(v_business.is_deleted, false) AND v_admin_disabled THEN
        'This business is already soft-deleted and admin-disabled. Permanent deletion will detach ownership, retire the account identity, and delete the Auth user. Acknowledge the disabled state before executing.'
      WHEN coalesce(v_business.is_deleted, false) THEN
        'This business is already soft-deleted. Permanent deletion will finalize it: detach ownership, clean the owner user, retire the account identity, and delete the Auth user. Reactivation will become impossible.'
      WHEN v_admin_disabled THEN
        'Eligible for permanent admin business-account deletion. Admin-disabled status requires explicit acknowledgment before execution.'
      ELSE
        'Eligible for permanent admin business-account deletion. This is irreversible: the account identity is retired and the Auth user is deleted.'
    END
  );
END;
$$;



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


COMMENT ON FUNCTION public.admin_delete_business_account_eligibility(uuid) IS
  'Admin read-only preview for PERMANENT business account deletion. service_role only. Soft tombstones with soft jobs at db_committed/storage_pending are promotable (soft_job_promotable). is_archived uses admin_status/admin_archived_at only.';

COMMENT ON FUNCTION public.admin_delete_business_account(uuid, text, text, text, boolean) IS
  'Admin permanent business-account deletion orchestrator. Soft Phase-2 tombstones may promote an in-progress soft job in place. DB-first; Auth/storage via Edge after identity retirement. service_role only.';

REVOKE ALL ON FUNCTION public.admin_delete_business_account_eligibility(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_delete_business_account_eligibility(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.admin_delete_business_account_eligibility(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_business_account_eligibility(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.admin_delete_business_account(uuid, text, text, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_delete_business_account(uuid, text, text, text, boolean) FROM anon;
REVOKE ALL ON FUNCTION public.admin_delete_business_account(uuid, text, text, text, boolean) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_business_account(uuid, text, text, text, boolean) TO service_role;

DO $integrity$
DECLARE
  v_elig text;
  v_orch text;
BEGIN
  IF to_regprocedure('public.admin_delete_business_account_eligibility(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: admin_delete_business_account_eligibility missing';
  END IF;
  IF to_regprocedure('public.admin_delete_business_account(uuid, text, text, text, boolean)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: admin_delete_business_account missing';
  END IF;

  SELECT pg_get_functiondef('public.admin_delete_business_account_eligibility(uuid)'::regprocedure)
    INTO v_elig;
  SELECT pg_get_functiondef('public.admin_delete_business_account(uuid, text, text, text, boolean)'::regprocedure)
    INTO v_orch;

  IF position('soft_job_promotable' IN v_elig) = 0 THEN
    RAISE EXCEPTION 'FAIL: eligibility missing soft_job_promotable';
  END IF;
  IF position('v_soft_promotable' IN v_elig) = 0 THEN
    RAISE EXCEPTION 'FAIL: eligibility missing soft promotable gate';
  END IF;
  IF position('active_soft_deletion_job' IN v_elig) = 0 THEN
    RAISE EXCEPTION 'FAIL: eligibility must still refuse non-promotable soft jobs';
  END IF;
  IF position('soft_tombstone_permanent_promotion' IN v_orch) = 0 THEN
    RAISE EXCEPTION 'FAIL: orchestrator missing soft tombstone promotion status bump';
  END IF;
  IF position('IF v_job.status IN (''auth_delete_pending'', ''db_committed'', ''storage_pending'')' IN v_orch) > 0 THEN
    RAISE EXCEPTION 'FAIL: permanent Stage 4 must not finalize from db_committed';
  END IF;
  IF has_function_privilege('anon', 'public.admin_delete_business_account_eligibility(uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.admin_delete_business_account_eligibility(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: eligibility must not be executable by anon/authenticated';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.admin_delete_business_account_eligibility(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: eligibility must be executable by service_role';
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

