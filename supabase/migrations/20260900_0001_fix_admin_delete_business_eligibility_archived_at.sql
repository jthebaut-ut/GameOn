-- Forward fix for production 20260898 permanent Delete Business Account eligibility.
--
-- Production symptom:
--   admin_delete_business_account_eligibility raised
--   "record ""v_business"" has no field ""archived_at"""
--
-- Root cause:
--   20260898 built is_archived using v_business.archived_at, but public.businesses
--   has no archived_at column. Canonical business archive fields are:
--     admin_status IN (active|archived|disabled)
--     admin_archived_at / admin_archived_by / admin_archived_reason
--     is_deleted / permanently_deleted_at
--
-- This migration CREATE OR REPLACEs only admin_delete_business_account_eligibility
-- with the corrected is_archived expression. Permanent deletion state machine,
-- privileges, ownership detach, user cleanup, identity retirement, Auth/storage
-- finalization, and reactivation block are unchanged.
--
-- Idempotent. Forward-only. PREPARED ONLY — manual apply.
-- Do NOT re-apply 20260898 to production.

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
    'owner_email', v_business.owner_email,
    'owner_user_id', v_owner,
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

  IF v_job.id IS NOT NULL
     AND coalesce(v_job.deletion_mode, 'soft') <> 'permanent'
     AND v_job.status = ANY(v_in_progress) THEN
    RETURN v_base || jsonb_build_object(
      'eligible', false,
      'can_delete', false,
      'can_resume', false,
      'idempotent', false,
      'block_reason', 'active_soft_deletion_job',
      'message', 'A non-permanent business deletion job is still in progress for this account. Let it finish (or fail it) before starting permanent deletion.'
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
    'can_resume', v_perm.id IS NOT NULL,
    'idempotent', false,
    'block_reason', NULL,
    'message', CASE
      WHEN coalesce(v_business.is_deleted, false) AND v_admin_disabled THEN
        'This business is already soft-deleted and admin-disabled. Permanent deletion will detach ownership, retire the account identity, and delete the Auth user. Acknowledge the disabled state before executing.'
      WHEN coalesce(v_business.is_deleted, false) THEN
        'This business is already soft-deleted. Permanent deletion will finalize it: detach ownership, clean the owner user, retire the account identity, and delete the Auth user.'
      WHEN v_admin_disabled THEN
        'Eligible for permanent admin business-account deletion. Admin-disabled status requires explicit acknowledgment before execution.'
      ELSE
        'Eligible for permanent admin business-account deletion. This is irreversible: the account identity is retired and the Auth user is deleted.'
    END
  );
END;
$$;

COMMENT ON FUNCTION public.admin_delete_business_account_eligibility(uuid) IS
  'Admin read-only preview for PERMANENT business account deletion. service_role only. is_archived uses admin_status/admin_archived_at only (businesses has no archived_at).';

REVOKE ALL ON FUNCTION public.admin_delete_business_account_eligibility(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_delete_business_account_eligibility(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.admin_delete_business_account_eligibility(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_business_account_eligibility(uuid) TO service_role;

DO $integrity$
DECLARE
  v_def text;
BEGIN
  IF to_regprocedure('public.admin_delete_business_account_eligibility(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: admin_delete_business_account_eligibility missing';
  END IF;

  SELECT pg_get_functiondef('public.admin_delete_business_account_eligibility(uuid)'::regprocedure)
    INTO v_def;

  IF position('v_business.archived_at' IN v_def) > 0 THEN
    RAISE EXCEPTION 'FAIL: eligibility still references nonexistent businesses.archived_at';
  END IF;

  IF position('v_business.admin_archived_at' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: eligibility missing canonical admin_archived_at archive check';
  END IF;

  IF position('admin_status' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: eligibility missing admin_status archive check';
  END IF;

  IF position('permanently_deleted_at' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: eligibility missing permanently_deleted_at handling';
  END IF;

  IF position('can_resume' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: eligibility missing can_resume permanent-job resume contract';
  END IF;

  IF has_function_privilege('anon', 'public.admin_delete_business_account_eligibility(uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.admin_delete_business_account_eligibility(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: eligibility executable by anon/authenticated';
  END IF;

  IF NOT has_function_privilege('service_role', 'public.admin_delete_business_account_eligibility(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: service_role cannot EXECUTE eligibility';
  END IF;
END;
$integrity$;
