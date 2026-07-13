-- Fix misleading Admin reactivation eligibility diagnostics.
-- Early blocked responses (especially storage_finalization_pending) omitted
-- auth_user_exists / identity_reserved; Admin parsed missing keys as false.
-- Eligibility rules and mutation logic are unchanged.

-- ---------------------------------------------------------------------------
-- 1. Diagnostic helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gameon_business_reactivation_diagnostic_flags(
  p_owner_user_id uuid,
  p_identity public.account_identities
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_auth_exists boolean;
  v_identity_reserved boolean;
BEGIN
  IF p_owner_user_id IS NULL THEN
    RETURN jsonb_build_object(
      'auth_user_exists', NULL,
      'identity_reserved', NULL
    );
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM auth.users u
    WHERE u.id = p_owner_user_id
  )
  INTO v_auth_exists;

  v_identity_reserved := (
    p_identity.account_id IS NOT NULL
    AND p_identity.account_type = 'business'
    AND p_identity.account_id = p_owner_user_id
  );

  RETURN jsonb_build_object(
    'auth_user_exists', v_auth_exists,
    'identity_reserved', v_identity_reserved
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.gameon_business_reactivation_eligibility_envelope(
  p_payload jsonb
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'ok', true,
    'eligible', NULL,
    'block_reason', NULL,
    'message', NULL,
    'business_id', NULL,
    'owner_user_id', NULL,
    'auth_user_exists', NULL,
    'identity_reserved', NULL,
    'deletion_job_id', NULL,
    'deletion_job_status', NULL,
    'deletion_audit_id', NULL
  ) || coalesce(p_payload, '{}'::jsonb);
$$;

-- ---------------------------------------------------------------------------
-- 2. Shared eligibility evaluation (diagnostic payload only)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gameon_business_reactivation_evaluate_eligibility(
  p_business_id uuid,
  p_business public.businesses,
  p_identity public.account_identities,
  p_job public.business_account_deletion_jobs,
  p_audit public.business_account_deletion_audit,
  p_requested_handle text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_auth_exists boolean := false;
  v_original_email text;
  v_original_display_name text;
  v_original_source text;
  v_job_block text;
  v_normalized_handle text;
  v_identity_reserved boolean := false;
  v_diag jsonb := '{}'::jsonb;
BEGIN
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

  IF p_business.id IS NULL THEN
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

  IF p_business.id IS DISTINCT FROM p_business_id THEN
    RETURN public.gameon_business_reactivation_eligibility_envelope(
      jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', 'business_mismatch',
        'message', 'Business row mismatch.',
        'business_id', p_business_id
      )
    );
  END IF;

  v_diag := public.gameon_business_reactivation_diagnostic_flags(
    p_business.owner_user_id,
    p_identity
  );

  IF coalesce(p_business.is_deleted, false) = false
     AND NOT public.gameon_business_reactivation_is_tombstone_business_email(p_business.owner_email) THEN
    RETURN public.gameon_business_reactivation_eligibility_envelope(
      jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', 'business_not_deleted',
        'message', 'This business is not in a deleted tombstone state.',
        'idempotent', true,
        'business_id', p_business_id,
        'owner_user_id', p_business.owner_user_id
      ) || v_diag
    );
  END IF;

  IF public.gameon_business_reactivation_is_moderation_disabled(p_business) THEN
    RETURN public.gameon_business_reactivation_eligibility_envelope(
      jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', 'moderation_disable_requires_resolution',
        'message', 'This business was admin-disabled and must be resolved through moderation before reactivation.',
        'business_id', p_business_id,
        'owner_user_id', p_business.owner_user_id
      ) || v_diag
    );
  END IF;

  IF p_audit.id IS NULL THEN
    RETURN public.gameon_business_reactivation_eligibility_envelope(
      jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', 'deletion_audit_missing',
        'message', 'A matching soft-deletion audit row is required for business reactivation.',
        'business_id', p_business_id,
        'owner_user_id', p_business.owner_user_id
      ) || v_diag
    );
  END IF;

  v_job_block := public.gameon_business_reactivation_latest_job_block_reason(p_job);
  IF v_job_block IS NOT NULL THEN
    RETURN public.gameon_business_reactivation_eligibility_envelope(
      jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', v_job_block,
        'message', CASE
          WHEN v_job_block = 'active_deletion_job'
            THEN 'An active or incomplete business deletion job still exists for this business.'
          WHEN v_job_block = 'storage_finalization_pending'
            THEN 'Business deletion database work is committed but storage finalization is not complete. Reactivation is allowed only after the deletion job reaches completed.'
          ELSE 'The latest business deletion job is not in a reactivation-eligible state.'
        END,
        'business_id', p_business_id,
        'owner_user_id', p_business.owner_user_id,
        'deletion_job_id', p_job.id,
        'deletion_job_status', p_job.status,
        'deletion_audit_id', p_audit.id
      ) || v_diag
    );
  END IF;

  IF p_business.owner_user_id IS NULL THEN
    RETURN public.gameon_business_reactivation_eligibility_envelope(
      jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', 'owner_user_missing',
        'message', 'Deleted business is missing owner_user_id.',
        'business_id', p_business_id
      ) || v_diag
    );
  END IF;

  v_auth_exists := coalesce((v_diag ->> 'auth_user_exists')::boolean, false);

  IF NOT v_auth_exists THEN
    RETURN public.gameon_business_reactivation_eligibility_envelope(
      jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', 'auth_user_missing',
        'message', 'auth.users row is missing for this business owner.',
        'business_id', p_business_id,
        'owner_user_id', p_business.owner_user_id,
        'auth_user_exists', false,
        'identity_reserved', v_diag -> 'identity_reserved'
      )
    );
  END IF;

  IF public.gameon_business_reactivation_auth_user_is_banned(p_business.owner_user_id) THEN
    RETURN public.gameon_business_reactivation_eligibility_envelope(
      jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', 'auth_user_banned',
        'message', 'The business owner auth user is banned and must be resolved before reactivation.',
        'business_id', p_business_id,
        'owner_user_id', p_business.owner_user_id,
        'auth_user_exists', true
      ) || jsonb_build_object('identity_reserved', v_diag -> 'identity_reserved')
    );
  END IF;

  IF p_identity.account_id IS NULL THEN
    RETURN public.gameon_business_reactivation_eligibility_envelope(
      jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', 'identity_missing',
        'message', 'account_identities row is missing for this business owner.',
        'business_id', p_business_id,
        'owner_user_id', p_business.owner_user_id,
        'auth_user_exists', true,
        'identity_reserved', false
      )
    );
  END IF;

  IF p_identity.account_type IS DISTINCT FROM 'business' THEN
    RETURN public.gameon_business_reactivation_eligibility_envelope(
      jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', 'identity_not_business',
        'message', 'The reserved account identity is not a business account.',
        'business_id', p_business_id,
        'owner_user_id', p_business.owner_user_id,
        'auth_user_exists', true,
        'identity_reserved', false
      )
    );
  END IF;

  IF p_identity.account_id IS DISTINCT FROM p_business.owner_user_id THEN
    RETURN public.gameon_business_reactivation_eligibility_envelope(
      jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', 'identity_owner_mismatch',
        'message', 'The reserved business identity does not belong to the business owner user.',
        'business_id', p_business_id,
        'owner_user_id', p_business.owner_user_id,
        'auth_user_exists', true,
        'identity_reserved', false
      )
    );
  END IF;

  v_identity_reserved := true;

  SELECT r.original_owner_email, r.original_display_name, r.source
    INTO v_original_email, v_original_display_name, v_original_source
  FROM public.gameon_business_reactivation_resolve_original_identity(p_business_id, p_audit) r
  LIMIT 1;

  IF v_original_email IS NULL OR v_original_email = '' THEN
    RETURN public.gameon_business_reactivation_eligibility_envelope(
      jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', 'original_owner_email_unavailable',
        'message', 'Reactivation unavailable — original business owner email cannot be verified.',
        'business_id', p_business_id,
        'owner_user_id', p_business.owner_user_id,
        'deletion_job_id', p_job.id,
        'deletion_audit_id', p_audit.id,
        'deletion_job_status', p_job.status,
        'auth_user_exists', true,
        'identity_reserved', v_identity_reserved
      )
    );
  END IF;

  IF lower(btrim(coalesce(p_identity.email, ''))) IS DISTINCT FROM v_original_email THEN
    RETURN public.gameon_business_reactivation_eligibility_envelope(
      jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', 'original_email_not_reserved_to_owner',
        'message', 'The recovered original owner email does not match the reserved business account identity.',
        'business_id', p_business_id,
        'owner_user_id', p_business.owner_user_id,
        'original_owner_email', v_original_email,
        'deletion_job_id', p_job.id,
        'deletion_audit_id', p_audit.id,
        'deletion_job_status', p_job.status,
        'auth_user_exists', true,
        'identity_reserved', v_identity_reserved
      )
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.account_identities ai
    WHERE lower(btrim(ai.email)) = v_original_email
      AND ai.account_id <> p_business.owner_user_id
  ) THEN
    RETURN public.gameon_business_reactivation_eligibility_envelope(
      jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', 'owner_email_reserved_to_other_account',
        'message', 'The original owner email is reserved to a different account.',
        'business_id', p_business_id,
        'owner_user_id', p_business.owner_user_id,
        'original_owner_email', v_original_email,
        'deletion_job_id', p_job.id,
        'deletion_audit_id', p_audit.id,
        'deletion_job_status', p_job.status,
        'auth_user_exists', true,
        'identity_reserved', v_identity_reserved
      )
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.businesses b
    WHERE b.id <> p_business_id
      AND coalesce(b.is_deleted, false) = false
      AND b.owner_user_id = p_business.owner_user_id
  ) THEN
    RETURN public.gameon_business_reactivation_eligibility_envelope(
      jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', 'active_business_exists_for_owner',
        'message', 'Another active business row already exists for this owner user.',
        'business_id', p_business_id,
        'owner_user_id', p_business.owner_user_id,
        'original_owner_email', v_original_email,
        'deletion_job_id', p_job.id,
        'deletion_audit_id', p_audit.id,
        'deletion_job_status', p_job.status,
        'auth_user_exists', true,
        'identity_reserved', v_identity_reserved
      )
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.businesses b
    WHERE b.id <> p_business_id
      AND coalesce(b.is_deleted, false) = false
      AND lower(btrim(coalesce(b.owner_email, ''))) = v_original_email
  ) THEN
    RETURN public.gameon_business_reactivation_eligibility_envelope(
      jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', 'owner_email_conflict',
        'message', 'Another active business already uses the original owner email.',
        'business_id', p_business_id,
        'owner_user_id', p_business.owner_user_id,
        'original_owner_email', v_original_email,
        'deletion_job_id', p_job.id,
        'deletion_audit_id', p_audit.id,
        'deletion_job_status', p_job.status,
        'auth_user_exists', true,
        'identity_reserved', v_identity_reserved
      )
    );
  END IF;

  IF public.gameon_business_reactivation_has_active_business_ban(
    p_business_id,
    p_business.owner_user_id,
    v_original_email
  ) THEN
    RETURN public.gameon_business_reactivation_eligibility_envelope(
      jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', 'active_business_ban',
        'message', 'This business or owner has an active business ban.',
        'business_id', p_business_id,
        'owner_user_id', p_business.owner_user_id,
        'original_owner_email', v_original_email,
        'deletion_job_id', p_job.id,
        'deletion_audit_id', p_audit.id,
        'deletion_job_status', p_job.status,
        'auth_user_exists', true,
        'identity_reserved', v_identity_reserved
      )
    );
  END IF;

  IF public.gameon_business_reactivation_has_active_user_ban(p_business.owner_user_id) THEN
    RETURN public.gameon_business_reactivation_eligibility_envelope(
      jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', 'active_user_ban',
        'message', 'The business owner has an active user ban.',
        'business_id', p_business_id,
        'owner_user_id', p_business.owner_user_id,
        'original_owner_email', v_original_email,
        'deletion_job_id', p_job.id,
        'deletion_audit_id', p_audit.id,
        'deletion_job_status', p_job.status,
        'auth_user_exists', true,
        'identity_reserved', v_identity_reserved
      )
    );
  END IF;

  IF p_requested_handle IS NOT NULL AND btrim(p_requested_handle) <> '' THEN
    v_normalized_handle := public.fangeo_normalize_handle(p_requested_handle);
    IF v_normalized_handle IS NULL OR NOT public.fangeo_handle_is_valid(v_normalized_handle) THEN
      RETURN public.gameon_business_reactivation_eligibility_envelope(
        jsonb_build_object(
          'ok', true,
          'eligible', false,
          'block_reason', 'invalid_handle',
          'message', 'Handle must be 3-20 characters and use letters, numbers, underscores, or periods.',
          'business_id', p_business_id,
          'owner_user_id', p_business.owner_user_id,
          'original_owner_email', v_original_email,
          'deletion_job_id', p_job.id,
          'deletion_audit_id', p_audit.id,
          'deletion_job_status', p_job.status,
          'auth_user_exists', true,
          'identity_reserved', v_identity_reserved
        )
      );
    END IF;

    IF NOT public.gameon_business_reactivation_handle_is_available(p_business_id, v_normalized_handle) THEN
      RETURN public.gameon_business_reactivation_eligibility_envelope(
        jsonb_build_object(
          'ok', true,
          'eligible', false,
          'block_reason', 'handle_conflict',
          'message', 'That business handle is already in use.',
          'business_id', p_business_id,
          'owner_user_id', p_business.owner_user_id,
          'original_owner_email', v_original_email,
          'deletion_job_id', p_job.id,
          'deletion_audit_id', p_audit.id,
          'deletion_job_status', p_job.status,
          'auth_user_exists', true,
          'identity_reserved', v_identity_reserved
        )
      );
    END IF;
  END IF;

  RETURN public.gameon_business_reactivation_eligibility_envelope(
    jsonb_build_object(
      'ok', true,
      'eligible', true,
      'block_reason', NULL,
      'message', 'Deleted business eligible for reactivation.',
      'business_id', p_business_id,
      'owner_user_id', p_business.owner_user_id,
      'original_owner_email', v_original_email,
      'original_display_name', v_original_display_name,
      'original_owner_email_source', v_original_source,
      'deletion_job_id', p_job.id,
      'deletion_audit_id', p_audit.id,
      'deletion_job_status', p_job.status,
      'deletion_date', coalesce(p_business.deleted_at, p_audit.deleted_at),
      'auth_user_exists', v_auth_exists,
      'identity_reserved', v_identity_reserved,
      'data_not_restored', public.gameon_business_reactivation_data_not_restored()
    )
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Eligibility preview RPC (envelope on wrapper early returns)
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

-- ---------------------------------------------------------------------------
-- 4. Grants (service_role only)
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.gameon_business_reactivation_diagnostic_flags(uuid, public.account_identities) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_business_reactivation_diagnostic_flags(uuid, public.account_identities) FROM anon;
REVOKE ALL ON FUNCTION public.gameon_business_reactivation_diagnostic_flags(uuid, public.account_identities) FROM authenticated;
REVOKE ALL ON FUNCTION public.gameon_business_reactivation_diagnostic_flags(uuid, public.account_identities) FROM service_role;
GRANT EXECUTE ON FUNCTION public.gameon_business_reactivation_diagnostic_flags(uuid, public.account_identities) TO service_role;

REVOKE ALL ON FUNCTION public.gameon_business_reactivation_eligibility_envelope(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_business_reactivation_eligibility_envelope(jsonb) FROM anon;
REVOKE ALL ON FUNCTION public.gameon_business_reactivation_eligibility_envelope(jsonb) FROM authenticated;
REVOKE ALL ON FUNCTION public.gameon_business_reactivation_eligibility_envelope(jsonb) FROM service_role;
GRANT EXECUTE ON FUNCTION public.gameon_business_reactivation_eligibility_envelope(jsonb) TO service_role;

COMMENT ON FUNCTION public.gameon_business_reactivation_diagnostic_flags(uuid, public.account_identities) IS
  'Read-only auth/identity diagnostic flags for business reactivation eligibility payloads. service_role only.';

COMMENT ON FUNCTION public.gameon_business_reactivation_eligibility_envelope(jsonb) IS
  'Ensures admin business reactivation eligibility responses always include canonical diagnostic keys (null when unknown). service_role only.';

COMMENT ON FUNCTION public.gameon_business_reactivation_evaluate_eligibility(uuid, public.businesses, public.account_identities, public.business_account_deletion_jobs, public.business_account_deletion_audit, text) IS
  'Shared business reactivation eligibility evaluation. Always returns auth_user_exists and identity_reserved when evaluable. Eligibility rules unchanged.';

-- ---------------------------------------------------------------------------
-- 5. Post-apply integrity checks
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_eval_def text;
  v_envelope_keys text[] := ARRAY[
    'ok',
    'eligible',
    'block_reason',
    'message',
    'business_id',
    'owner_user_id',
    'auth_user_exists',
    'identity_reserved',
    'deletion_job_id',
    'deletion_job_status',
    'deletion_audit_id'
  ];
  v_key text;
  v_sample jsonb;
  v_flags jsonb;
BEGIN
  IF to_regprocedure('public.gameon_business_reactivation_diagnostic_flags(uuid,public.account_identities)') IS NULL THEN
    RAISE EXCEPTION 'Integrity fail: gameon_business_reactivation_diagnostic_flags missing';
  END IF;

  IF to_regprocedure('public.gameon_business_reactivation_eligibility_envelope(jsonb)') IS NULL THEN
    RAISE EXCEPTION 'Integrity fail: gameon_business_reactivation_eligibility_envelope missing';
  END IF;

  v_eval_def := pg_get_functiondef(
    'public.gameon_business_reactivation_evaluate_eligibility(uuid,public.businesses,public.account_identities,public.business_account_deletion_jobs,public.business_account_deletion_audit,text)'::regprocedure
  );

  IF position('gameon_business_reactivation_diagnostic_flags' IN v_eval_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: evaluator must call diagnostic_flags helper';
  END IF;

  IF position('gameon_business_reactivation_eligibility_envelope' IN v_eval_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: evaluator must wrap responses with eligibility_envelope';
  END IF;

  IF position('storage_finalization_pending' IN v_eval_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: evaluator must retain storage_finalization_pending messaging';
  END IF;

  IF position('auth_user_exists' IN v_eval_def) = 0
     OR position('identity_reserved' IN v_eval_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: evaluator must emit auth_user_exists and identity_reserved diagnostics';
  END IF;

  IF position('gameon_business_reactivation_latest_job_block_reason' IN v_eval_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: evaluator must preserve completed-only job policy delegation';
  END IF;

  v_sample := public.gameon_business_reactivation_eligibility_envelope('{}'::jsonb);
  FOREACH v_key IN ARRAY v_envelope_keys LOOP
    IF NOT v_sample ? v_key THEN
      RAISE EXCEPTION 'Integrity fail: eligibility_envelope missing key %', v_key;
    END IF;
  END LOOP;

  v_flags := public.gameon_business_reactivation_diagnostic_flags(NULL, NULL::public.account_identities);
  IF v_flags ? 'auth_user_exists' IS DISTINCT FROM true
     OR v_flags ? 'identity_reserved' IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Integrity fail: diagnostic_flags must always return auth_user_exists and identity_reserved keys';
  END IF;

  IF v_flags -> 'auth_user_exists' IS DISTINCT FROM 'null'::jsonb
     OR v_flags -> 'identity_reserved' IS DISTINCT FROM 'null'::jsonb THEN
    RAISE EXCEPTION 'Integrity fail: diagnostic_flags must return JSON null when owner_user_id is missing';
  END IF;

  IF NOT has_function_privilege('service_role', 'public.gameon_business_reactivation_diagnostic_flags(uuid,public.account_identities)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Integrity fail: service_role cannot EXECUTE diagnostic_flags';
  END IF;

  IF has_function_privilege('authenticated', 'public.gameon_business_reactivation_diagnostic_flags(uuid,public.account_identities)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Integrity fail: authenticated can EXECUTE diagnostic_flags';
  END IF;
END;
$$;
