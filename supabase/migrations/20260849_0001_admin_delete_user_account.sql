-- Pre-launch admin-only fan account deletion via Phase 2 lifecycle.
-- Does not weaken self-service deletion RPCs or bypass business-owner blockers.

CREATE OR REPLACE FUNCTION public.admin_delete_user_account_eligibility(
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_profile public.user_profiles%ROWTYPE;
  v_preview jsonb;
  v_job public.account_deletion_jobs;
  v_job_block text;
  v_block_reason text;
  v_admin_disabled boolean := false;
  v_can_delete boolean := false;
  v_idempotent boolean := false;
BEGIN
  PERFORM public.gameon_reactivation_assert_service_role();

  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object(
      'eligible', false,
      'can_delete', false,
      'block_reason', 'invalid_user_id',
      'message', 'A valid subject user id is required.'
    );
  END IF;

  SELECT * INTO v_profile
  FROM public.user_profiles up
  WHERE up.id = p_user_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'eligible', false,
      'can_delete', false,
      'block_reason', 'profile_not_found',
      'message', 'User profile not found.'
    );
  END IF;

  v_preview := public.preview_delete_user_account(p_user_id);
  v_job := public.gameon_reactivation_latest_deletion_job(p_user_id);
  v_job_block := public.gameon_reactivation_latest_job_block_reason(v_job);

  v_admin_disabled :=
    lower(btrim(coalesce(v_profile.admin_status, ''))) = 'disabled'
    OR v_profile.admin_disabled_at IS NOT NULL;

  IF public.gameon_reactivation_is_moderation_disabled(v_profile) THEN
    RETURN jsonb_build_object(
      'eligible', false,
      'can_delete', false,
      'block_reason', 'moderation_disable_requires_resolution',
      'message', 'This account was disabled for moderation and must be resolved through the moderation workflow before deletion.',
      'preview', v_preview,
      'deletion_job_id', v_job.id,
      'deletion_job_status', v_job.status,
      'admin_disabled', v_admin_disabled,
      'active_moderation_ban', public.gameon_reactivation_has_active_user_ban(p_user_id),
      'access_state', 'disabled'
    );
  END IF;

  IF coalesce(v_preview ->> 'block_reason', '') = 'already_deleted' THEN
    v_idempotent := v_job.id IS NOT NULL AND v_job.status = 'completed';
    RETURN jsonb_build_object(
      'eligible', false,
      'can_delete', false,
      'idempotent', v_idempotent,
      'block_reason', 'already_deleted',
      'message', CASE
        WHEN v_idempotent THEN 'This account is already deleted. No duplicate deletion will be started.'
        ELSE 'This account is already deleted.'
      END,
      'preview', v_preview,
      'deletion_job_id', v_job.id,
      'deletion_job_status', v_job.status,
      'admin_disabled', v_admin_disabled,
      'active_moderation_ban', public.gameon_reactivation_has_active_user_ban(p_user_id)
    );
  END IF;

  IF coalesce(v_preview ->> 'blocked', 'false') = 'true' THEN
    v_block_reason := v_preview ->> 'block_reason';
    RETURN jsonb_build_object(
      'eligible', false,
      'can_delete', false,
      'block_reason', v_block_reason,
      'message', 'This account cannot be deleted through the fan deletion workflow.',
      'preview', v_preview,
      'deletion_job_id', v_job.id,
      'deletion_job_status', v_job.status,
      'admin_disabled', v_admin_disabled,
      'active_moderation_ban', public.gameon_reactivation_has_active_user_ban(p_user_id)
    );
  END IF;

  IF v_job_block IS NOT NULL THEN
    RETURN jsonb_build_object(
      'eligible', false,
      'can_delete', false,
      'block_reason', v_job_block,
      'message', 'An active or incomplete deletion job already exists for this user.',
      'preview', v_preview,
      'deletion_job_id', v_job.id,
      'deletion_job_status', v_job.status,
      'admin_disabled', v_admin_disabled,
      'active_moderation_ban', public.gameon_reactivation_has_active_user_ban(p_user_id)
    );
  END IF;

  v_can_delete := true;

  RETURN jsonb_build_object(
    'eligible', true,
    'can_delete', true,
    'block_reason', NULL,
    'message', CASE
      WHEN v_admin_disabled THEN 'Eligible for admin deletion. Admin-disabled status requires explicit acknowledgment before execution.'
      ELSE 'Eligible for admin deletion through the Phase 2 workflow.'
    END,
    'preview', v_preview,
    'deletion_job_id', v_job.id,
    'deletion_job_status', v_job.status,
    'admin_disabled', v_admin_disabled,
    'requires_admin_disabled_acknowledgment', v_admin_disabled,
    'active_moderation_ban', public.gameon_reactivation_has_active_user_ban(p_user_id),
    'display_name', v_profile.display_name,
    'email', v_profile.email,
    'handle', coalesce(v_profile.handle, v_profile.username)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_user_account(
  p_user_id uuid,
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
  v_profile public.user_profiles%ROWTYPE;
  v_eligibility jsonb;
  v_start jsonb;
  v_execute jsonb;
  v_finalize jsonb := '{}'::jsonb;
  v_job_id uuid;
  v_job public.account_deletion_jobs%ROWTYPE;
  v_finalize_queued boolean := false;
BEGIN
  PERFORM public.gameon_reactivation_assert_service_role();

  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_user_id', 'message', 'A valid subject user id is required.');
  END IF;

  IF char_length(v_reason) < 3 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_reason', 'message', 'An audit reason of at least 3 characters is required.');
  END IF;

  SELECT * INTO v_profile
  FROM public.user_profiles up
  WHERE up.id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'profile_not_found', 'message', 'User profile not found.');
  END IF;

  IF public.gameon_account_deletion_profile_is_anonymized(p_user_id) THEN
    v_job := public.gameon_reactivation_latest_deletion_job(p_user_id);
    RETURN jsonb_build_object(
      'ok', true,
      'idempotent', true,
      'result', 'already_deleted',
      'message', 'This account is already deleted.',
      'subject_user_id', p_user_id,
      'deletion_job_id', v_job.id,
      'deletion_job_status', v_job.status,
      'deletion_job_stage', v_job.stage
    );
  END IF;

  v_eligibility := public.admin_delete_user_account_eligibility(p_user_id);

  IF coalesce(v_eligibility ->> 'block_reason', '') = 'moderation_disable_requires_resolution' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'moderation_disable_requires_resolution',
      'message', coalesce(v_eligibility ->> 'message', 'Moderation disable must be resolved before deletion.'),
      'eligibility', v_eligibility
    );
  END IF;

  IF coalesce(v_eligibility ->> 'can_delete', 'false') <> 'true' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', coalesce(v_eligibility ->> 'block_reason', 'not_eligible'),
      'message', coalesce(v_eligibility ->> 'message', 'This account is not eligible for admin deletion.'),
      'eligibility', v_eligibility
    );
  END IF;

  IF coalesce(v_eligibility ->> 'requires_admin_disabled_acknowledgment', 'false') = 'true'
     AND NOT coalesce(p_acknowledge_admin_disabled, false) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'admin_disabled_requires_acknowledgment',
      'message', 'This account is admin-disabled. Acknowledge the disabled state before permanent deletion.',
      'eligibility', v_eligibility
    );
  END IF;

  v_key := coalesce(nullif(btrim(p_idempotency_key), ''), 'admin:' || p_user_id::text);

  v_start := public.start_account_deletion_job(v_key, p_user_id);
  v_job_id := (v_start ->> 'job_id')::uuid;

  IF v_job_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'job_start_failed',
      'message', 'Could not start the account deletion job.',
      'start', v_start
    );
  END IF;

  v_execute := public.execute_delete_user_account_db(v_job_id);

  IF coalesce(v_execute ->> 'ok', 'false') <> 'true' THEN
    RETURN v_execute
      || jsonb_build_object(
        'ok', false,
        'error', coalesce(v_execute ->> 'error_code', 'db_execute_failed'),
        'message', coalesce(v_execute ->> 'error_detail', 'Database deletion step failed.'),
        'subject_user_id', p_user_id,
        'admin_email', v_admin_email,
        'reason', v_reason
      );
  END IF;

  v_finalize := public.queue_account_deletion_finalize(v_job_id);
  v_finalize_queued := coalesce((v_finalize ->> 'queued')::boolean, false);

  IF v_finalize_queued THEN
    UPDATE public.account_deletion_jobs
    SET status = 'storage_pending',
        stage = 'storage_finalize_queued'
    WHERE id = v_job_id
      AND status = 'db_committed';
  END IF;

  SELECT * INTO v_job
  FROM public.account_deletion_jobs
  WHERE id = v_job_id;

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
    'admin_delete_user_account',
    'user',
    p_user_id::text,
    jsonb_build_object(
      'profile', to_jsonb(v_profile),
      'eligibility', v_eligibility
    ),
    jsonb_build_object(
      'deletion_job_id', v_job_id,
      'deletion_job_status', v_job.status,
      'deletion_job_stage', v_job.stage,
      'execute', v_execute,
      'finalize_queue', v_finalize,
      'finalize_queued', v_finalize_queued,
      'admin_disabled_acknowledged', coalesce(p_acknowledge_admin_disabled, false),
      'source', 'admin_dashboard'
    ),
    v_reason
  );

  RETURN v_execute
    || jsonb_build_object(
      'ok', true,
      'idempotent', coalesce((v_execute ->> 'idempotent_replay')::boolean, false),
      'result', CASE
        WHEN v_job.status IN ('db_committed', 'storage_pending') THEN 'deletion_in_progress'
        WHEN v_job.status = 'failed' THEN 'failed'
        WHEN v_job.status = 'completed' THEN 'completed'
        ELSE 'deletion_in_progress'
      END,
      'message', CASE
        WHEN v_job.status IN ('db_committed', 'storage_pending') THEN
          CASE
            WHEN v_job.status = 'storage_pending' THEN 'Database deletion committed. Avatar storage cleanup is pending.'
            WHEN v_finalize_queued THEN 'Database deletion committed. Storage cleanup has been queued.'
            ELSE 'Database deletion committed. Storage finalization was not queued.'
          END
        WHEN v_job.status = 'failed' THEN 'Account deletion failed during database cleanup.'
        WHEN v_job.status = 'completed' THEN 'Account deletion completed.'
        ELSE 'Account deletion is in progress.'
      END,
      'subject_user_id', p_user_id,
      'deletion_job_id', v_job_id,
      'deletion_job_status', v_job.status,
      'deletion_job_stage', v_job.stage,
      'finalize_queued', v_finalize_queued,
      'admin_email', v_admin_email,
      'reason', v_reason,
      'eligibility', v_eligibility,
      'source', 'admin_dashboard'
    );
END;
$$;

-- Supabase default ACLs grant EXECUTE to anon/authenticated directly (not only via PUBLIC).
-- REVOKE FROM PUBLIC alone leaves anon/authenticated able to call RPCs at the PostgREST layer.
REVOKE ALL ON FUNCTION public.admin_delete_user_account_eligibility(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_delete_user_account_eligibility(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.admin_delete_user_account_eligibility(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.admin_delete_user_account_eligibility(uuid) FROM service_role;

REVOKE ALL ON FUNCTION public.admin_delete_user_account(uuid, text, text, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_delete_user_account(uuid, text, text, text, boolean) FROM anon;
REVOKE ALL ON FUNCTION public.admin_delete_user_account(uuid, text, text, text, boolean) FROM authenticated;
REVOKE ALL ON FUNCTION public.admin_delete_user_account(uuid, text, text, text, boolean) FROM service_role;

GRANT EXECUTE ON FUNCTION public.admin_delete_user_account_eligibility(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_delete_user_account(uuid, text, text, text, boolean) TO service_role;

COMMENT ON FUNCTION public.admin_delete_user_account_eligibility(uuid) IS
  'Pre-launch admin read-only preview for fan account deletion via Phase 2. service_role only.';

COMMENT ON FUNCTION public.admin_delete_user_account(uuid, text, text, text, boolean) IS
  'Pre-launch admin fan account deletion orchestrator: start + execute + queue finalize. service_role only.';

DO $$
DECLARE
  v_def text;
BEGIN
  IF to_regprocedure('public.admin_delete_user_account_eligibility(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Integrity fail: admin_delete_user_account_eligibility missing';
  END IF;

  IF to_regprocedure('public.admin_delete_user_account(uuid,text,text,text,boolean)') IS NULL THEN
    RAISE EXCEPTION 'Integrity fail: admin_delete_user_account missing';
  END IF;

  IF NOT has_function_privilege('service_role', 'public.admin_delete_user_account_eligibility(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Integrity fail: service_role cannot EXECUTE admin_delete_user_account_eligibility';
  END IF;

  IF NOT has_function_privilege('service_role', 'public.admin_delete_user_account(uuid,text,text,text,boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Integrity fail: service_role cannot EXECUTE admin_delete_user_account';
  END IF;

  IF has_function_privilege('anon', 'public.admin_delete_user_account_eligibility(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Integrity fail: anon can EXECUTE admin_delete_user_account_eligibility';
  END IF;

  IF has_function_privilege('anon', 'public.admin_delete_user_account(uuid,text,text,text,boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Integrity fail: anon can EXECUTE admin_delete_user_account';
  END IF;

  IF has_function_privilege('authenticated', 'public.admin_delete_user_account_eligibility(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Integrity fail: authenticated can EXECUTE admin_delete_user_account_eligibility';
  END IF;

  IF has_function_privilege('authenticated', 'public.admin_delete_user_account(uuid,text,text,text,boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Integrity fail: authenticated can EXECUTE admin_delete_user_account';
  END IF;

  v_def := pg_get_functiondef('public.admin_delete_user_account_eligibility(uuid)'::regprocedure);
  IF position('gameon_reactivation_assert_service_role' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: admin_delete_user_account_eligibility missing service_role assertion';
  END IF;

  v_def := pg_get_functiondef('public.admin_delete_user_account(uuid,text,text,text,boolean)'::regprocedure);
  IF position('gameon_reactivation_assert_service_role' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: admin_delete_user_account missing service_role assertion';
  END IF;

  IF position('start_account_deletion_job' IN v_def) = 0
     OR position('execute_delete_user_account_db' IN v_def) = 0
     OR position('queue_account_deletion_finalize' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: admin_delete_user_account missing Phase 2 orchestration calls';
  END IF;

  IF position('''deletion_job_status''' IN v_def) = 0
     OR position('''deletion_job_stage''' IN v_def) = 0
     OR position('''source'', ''admin_dashboard''' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: admin_delete_user_account missing admin_dashboard audit metadata';
  END IF;

  RAISE NOTICE 'PASS: admin delete RPC privilege matrix, orchestration, and audit metadata verified';
END;
$$;
