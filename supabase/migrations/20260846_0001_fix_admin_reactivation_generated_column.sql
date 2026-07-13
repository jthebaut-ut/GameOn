-- Corrective fix for admin deleted-account reactivation failures.
-- Do not edit 20260844 in production; apply as a follow-up migration only.
--
-- Verified production failure (admin_reactivate_deleted_user):
--   SQLSTATE 428C9
--   column "display_name_normalized" can only be updated to DEFAULT
--
-- Root cause: admin_reactivate_deleted_user appended
--   display_name_normalized = lower(p_display_name)
-- to the dynamic profile UPDATE, but user_profiles.display_name_normalized is
-- GENERATED ALWAYS AS NULLIF(lower(trim(coalesce(display_name, ''))), '').
-- PostgreSQL rejects explicit writes to generated columns (SQLSTATE 428C9).
--
-- Fix: remove the explicit display_name_normalized assignment; set display_name only
-- and let PostgreSQL derive display_name_normalized automatically.
-- No other GENERATED ALWAYS columns exist on user_profiles in the current schema.

CREATE OR REPLACE FUNCTION public.admin_reactivate_deleted_user(
  p_user_id uuid,
  p_display_name text,
  p_reason text,
  p_handle text DEFAULT NULL,
  p_admin_email text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_admin_email text := lower(btrim(coalesce(p_admin_email, 'unknown')));
  v_display_name text := btrim(coalesce(p_display_name, ''));
  v_reason text := btrim(coalesce(p_reason, ''));
  v_handle_input text := nullif(btrim(coalesce(p_handle, '')), '');
  v_normalized_handle text;
  v_eligibility jsonb;
  v_profile public.user_profiles%ROWTYPE;
  v_identity public.account_identities%ROWTYPE;
  v_before jsonb;
  v_after jsonb;
  v_job public.account_deletion_jobs;
  v_prior_event public.account_reactivation_events;
  v_original_email text;
  v_original_source text;
  v_event_id uuid;
  v_set_clauses text[] := ARRAY[]::text[];
  v_sql text;
  v_access_state text;
  v_auth_ban_clear_eligible boolean := false;
  v_auth_ban_preserved boolean := false;
BEGIN
  PERFORM public.gameon_reactivation_assert_service_role();
  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_user_id', 'message', 'A valid subject user id is required.');
  END IF;

  IF char_length(v_display_name) < 1 OR char_length(v_display_name) > 80 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_display_name', 'message', 'Display name must be between 1 and 80 characters.');
  END IF;

  IF char_length(v_reason) < 3 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_reason', 'message', 'An audit reason of at least 3 characters is required.');
  END IF;

  IF v_handle_input IS NOT NULL THEN
    v_normalized_handle := public.fangeo_normalize_handle(v_handle_input);
    IF v_normalized_handle IS NULL OR NOT public.fangeo_handle_is_valid(v_normalized_handle) THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', 'invalid_handle',
        'message', 'Handle must be 3-20 characters and use letters, numbers, underscores, or periods.'
      );
    END IF;
  ELSE
    v_normalized_handle := NULL;
  END IF;

  SELECT * INTO v_profile
  FROM public.user_profiles up
  WHERE up.id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'profile_not_found', 'message', 'User profile not found.');
  END IF;

  SELECT * INTO v_identity
  FROM public.account_identities ai
  WHERE ai.account_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    v_identity.account_id := NULL;
  END IF;

  v_job := public.gameon_reactivation_latest_deletion_job(p_user_id);
  v_prior_event := public.gameon_reactivation_find_prior_event(p_user_id, v_job.id);

  IF v_prior_event.id IS NOT NULL
     AND COALESCE(v_profile.is_deleted, false) = false
     AND NOT public.gameon_reactivation_is_tombstone_email(v_profile.email) THEN
    RETURN jsonb_build_object(
      'ok', true,
      'idempotent', true,
      'result', 'already_reactivated',
      'message', 'This deleted account was already reactivated for this deletion job.',
      'subject_user_id', p_user_id,
      'reactivation_event_id', v_prior_event.id,
      'restored_email', v_prior_event.original_email,
      'access_state', public.gameon_reactivation_access_state(v_profile),
      'auth_ban_clear_eligible', false,
      'auth_ban_preserved', true
    );
  END IF;

  v_eligibility := public.gameon_reactivation_evaluate_eligibility(
    p_user_id,
    v_profile,
    v_identity,
    v_job
  );

  IF coalesce(v_eligibility ->> 'idempotent', 'false') = 'true' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'idempotent', true,
      'result', 'already_active',
      'message', 'This profile is already active.',
      'subject_user_id', p_user_id,
      'access_state', public.gameon_reactivation_access_state(v_profile),
      'auth_ban_clear_eligible', false,
      'auth_ban_preserved', true
    );
  END IF;

  IF coalesce(v_eligibility ->> 'eligible', 'false') <> 'true' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', coalesce(v_eligibility ->> 'block_reason', 'not_eligible'),
      'message', coalesce(v_eligibility ->> 'message', 'This account is not eligible for reactivation.'),
      'eligibility', v_eligibility
    );
  END IF;

  v_original_email := lower(btrim(v_eligibility ->> 'original_email'));
  v_original_source := v_eligibility ->> 'original_email_source';
  v_auth_ban_clear_eligible := coalesce(v_eligibility ->> 'auth_ban_clear_eligible', 'false') = 'true';
  v_auth_ban_preserved := NOT v_auth_ban_clear_eligible;

  IF v_normalized_handle IS NOT NULL
     AND NOT public.gameon_reactivation_handle_is_available(p_user_id, v_normalized_handle) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'handle_conflict',
      'message', 'That handle is already in use by another active profile.'
    );
  END IF;

  IF lower(btrim(coalesce(v_identity.email, ''))) IS DISTINCT FROM v_original_email THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'email_identity_conflict',
      'message', 'The reserved account identity email changed during reactivation.'
    );
  END IF;

  IF COALESCE(v_profile.is_deleted, false) = false
     AND NOT public.gameon_reactivation_is_tombstone_email(v_profile.email)
     AND lower(btrim(v_profile.email)) = v_original_email THEN
    RETURN jsonb_build_object(
      'ok', true,
      'idempotent', true,
      'result', 'already_reactivated',
      'message', 'This deleted account profile shell is already restored.',
      'subject_user_id', p_user_id,
      'restored_email', v_original_email,
      'access_state', public.gameon_reactivation_access_state(v_profile),
      'auth_ban_clear_eligible', v_auth_ban_clear_eligible,
      'auth_ban_preserved', v_auth_ban_preserved
    );
  END IF;

  v_before := to_jsonb(v_profile);

  PERFORM set_config('gameon.account_reactivation_restore', p_user_id::text, true);

  -- display_name_normalized is GENERATED ALWAYS from display_name; it recomputes when
  -- display_name is updated. Do not assign display_name_normalized directly.
  v_set_clauses := v_set_clauses || ARRAY[
    format('email = %L', v_original_email),
    format('display_name = %L', v_display_name)
  ];

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'username'
  ) THEN
    v_set_clauses := v_set_clauses || ARRAY[
      CASE WHEN v_normalized_handle IS NULL THEN 'username = NULL' ELSE format('username = %L', v_normalized_handle) END
    ];
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'handle'
  ) THEN
    v_set_clauses := v_set_clauses || ARRAY[
      CASE WHEN v_normalized_handle IS NULL THEN 'handle = NULL' ELSE format('handle = %L', v_normalized_handle) END
    ];
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'is_deleted'
  ) THEN
    v_set_clauses := v_set_clauses || ARRAY['is_deleted = false'];
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'deleted_at'
  ) THEN
    v_set_clauses := v_set_clauses || ARRAY['deleted_at = NULL'];
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'anonymized_at'
  ) THEN
    v_set_clauses := v_set_clauses || ARRAY['anonymized_at = NULL'];
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'deletion_requested_at'
  ) THEN
    v_set_clauses := v_set_clauses || ARRAY['deletion_requested_at = NULL'];
  END IF;

  IF public.gameon_reactivation_is_deletion_caused_disable(v_profile) THEN
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'admin_status'
    ) THEN
      v_set_clauses := v_set_clauses || ARRAY['admin_status = ''active'''];
    END IF;

    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'admin_disabled_at'
    ) THEN
      v_set_clauses := v_set_clauses || ARRAY[
        'admin_disabled_at = NULL',
        'admin_disabled_by = NULL',
        'admin_disabled_reason = NULL'
      ];
    END IF;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'avatar_url'
  ) THEN
    v_set_clauses := v_set_clauses || ARRAY['avatar_url = NULL'];
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'avatar_thumbnail_url'
  ) THEN
    v_set_clauses := v_set_clauses || ARRAY['avatar_thumbnail_url = NULL'];
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'bio'
  ) THEN
    v_set_clauses := v_set_clauses || ARRAY['bio = NULL'];
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'discoverable_by_fans'
  ) THEN
    v_set_clauses := v_set_clauses || ARRAY['discoverable_by_fans = true'];
  END IF;

  v_sql := format(
    'UPDATE public.user_profiles SET %s WHERE id = $1',
    array_to_string(v_set_clauses, ', ')
  );
  BEGIN
    EXECUTE v_sql USING p_user_id;
  EXCEPTION
    WHEN unique_violation THEN
      IF v_normalized_handle IS NOT NULL THEN
        RETURN jsonb_build_object(
          'ok', false,
          'error', 'handle_conflict',
          'message', 'That handle is already in use by another active profile.'
        );
      END IF;

      RETURN jsonb_build_object(
        'ok', false,
        'error', 'email_identity_conflict',
        'message', 'The restored email conflicts with another profile identity constraint.'
      );
  END;

  SELECT * INTO v_profile
  FROM public.user_profiles up
  WHERE up.id = p_user_id;

  v_after := to_jsonb(v_profile);
  v_access_state := public.gameon_reactivation_access_state(v_profile);

  INSERT INTO public.account_reactivation_events (
    subject_user_id,
    deletion_job_id,
    admin_email,
    reason,
    original_email,
    display_name,
    handle,
    prior_profile_state,
    data_not_restored
  ) VALUES (
    p_user_id,
    v_job.id,
    v_admin_email,
    v_reason,
    v_original_email,
    v_display_name,
    v_normalized_handle,
    v_before,
    public.gameon_reactivation_data_not_restored()
  )
  RETURNING id INTO v_event_id;

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
    'reactivate_deleted_user',
    'user',
    p_user_id::text,
    jsonb_build_object(
      'profile', v_before,
      'deletion_job_id', v_job.id,
      'deletion_job_status', v_job.status,
      'original_email_source', v_original_source
    ),
    jsonb_build_object(
      'profile', v_after,
      'reactivation_event_id', v_event_id,
      'restored_email', v_original_email,
      'display_name', v_display_name,
      'handle', v_normalized_handle,
      'access_state', v_access_state,
      'auth_ban_clear_eligible', v_auth_ban_clear_eligible,
      'auth_ban_preserved', v_auth_ban_preserved,
      'data_not_restored', public.gameon_reactivation_data_not_restored(),
      'preserved_shared_records', public.gameon_reactivation_preserved_shared_records()
    ),
    v_reason
  );

  RETURN jsonb_build_object(
    'ok', true,
    'idempotent', false,
    'result', 'reactivated',
    'message', 'Deleted account reactivated with a fresh profile shell.',
    'subject_user_id', p_user_id,
    'reactivation_event_id', v_event_id,
    'restored_email', v_original_email,
    'display_name', v_display_name,
    'handle', v_normalized_handle,
    'legacy', coalesce(v_eligibility ->> 'legacy', 'false') = 'true',
    'deletion_job_id', v_job.id,
    'access_state', v_access_state,
    'auth_ban_clear_eligible', v_auth_ban_clear_eligible,
    'auth_ban_preserved', v_auth_ban_preserved,
    'data_not_restored', public.gameon_reactivation_data_not_restored()
  );
END;
$$;

COMMENT ON FUNCTION public.admin_reactivate_deleted_user(uuid, text, text, text, text) IS
  'Pre-launch admin recovery: restore login-capable fan profile shell without recovering deleted private data. display_name_normalized is derived from display_name. service_role only.';

-- Post-apply integrity: reactivation must not write to generated display_name_normalized.
DO $$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef('public.admin_reactivate_deleted_user(uuid,text,text,text,text)'::regprocedure)
    INTO v_def;

  IF position('display_name_normalized =' IN v_def) > 0 THEN
    RAISE EXCEPTION 'FAIL: admin_reactivate_deleted_user still assigns display_name_normalized directly';
  END IF;

  IF position('gameon_reactivation_assert_service_role' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: admin_reactivate_deleted_user missing in-function service_role assertion';
  END IF;

  IF position('gameon.account_reactivation_restore' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: admin_reactivate_deleted_user missing identity-guard bypass GUC';
  END IF;
END;
$$;
