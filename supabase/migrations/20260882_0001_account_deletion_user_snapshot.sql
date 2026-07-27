-- =============================================================================
-- 20260882 — Capture immutable user snapshot before fan account anonymization
-- =============================================================================
--
-- Purpose:
--   Persist deletion-time identity/engagement fields on account_deletion_jobs so
--   the Admin Dashboard Deleted Accounts page can audit who was deleted after
--   user_profiles / user_xp are anonymized or cleared.
--
-- Captured once, immediately before gameon_account_deletion_soft_delete_core:
--   display_name_snapshot
--   handle_snapshot
--   total_xp_snapshot
--   fangeo_plus_snapshot
--   fangeo_plus_expires_at_snapshot
--   account_type_snapshot
--
-- Does NOT rewrite existing deletion history rows (legacy stays NULL).
-- Does NOT change anonymization behavior beyond capturing the snapshot first.
-- Do NOT apply from the agent; review and apply deliberately.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Preflight
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.account_deletion_jobs') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.account_deletion_jobs'];
  END IF;
  IF to_regclass('public.user_profiles') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.user_profiles'];
  END IF;
  IF to_regprocedure('public.execute_delete_user_account_db(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.execute_delete_user_account_db(uuid)'];
  END IF;
  IF to_regprocedure('public.gameon_account_deletion_soft_delete_core(uuid,text)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.gameon_account_deletion_soft_delete_core(uuid,text)'];
  END IF;

  IF to_regclass('public.user_profiles') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'display_name'
    ) THEN
      v_missing := v_missing || ARRAY['column public.user_profiles.display_name'];
    END IF;
  END IF;

  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION
      '20260882 preflight failed (no schema changes applied): %',
      array_to_string(v_missing, ', ')
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Snapshot columns on account_deletion_jobs
-- ---------------------------------------------------------------------------
ALTER TABLE public.account_deletion_jobs
  ADD COLUMN IF NOT EXISTS display_name_snapshot text NULL,
  ADD COLUMN IF NOT EXISTS handle_snapshot text NULL,
  ADD COLUMN IF NOT EXISTS total_xp_snapshot integer NULL,
  ADD COLUMN IF NOT EXISTS fangeo_plus_snapshot boolean NULL,
  ADD COLUMN IF NOT EXISTS fangeo_plus_expires_at_snapshot timestamptz NULL,
  ADD COLUMN IF NOT EXISTS account_type_snapshot text NULL;

COMMENT ON COLUMN public.account_deletion_jobs.display_name_snapshot IS
  'Immutable display_name captured immediately before anonymization.';
COMMENT ON COLUMN public.account_deletion_jobs.handle_snapshot IS
  'Immutable handle captured immediately before anonymization.';
COMMENT ON COLUMN public.account_deletion_jobs.total_xp_snapshot IS
  'Immutable user_xp.total_xp captured immediately before XP rows are deleted.';
COMMENT ON COLUMN public.account_deletion_jobs.fangeo_plus_snapshot IS
  'Immutable FanGeo+ (ad_free_enabled) flag captured before anonymization.';
COMMENT ON COLUMN public.account_deletion_jobs.fangeo_plus_expires_at_snapshot IS
  'Immutable FanGeo+ expiration captured before anonymization.';
COMMENT ON COLUMN public.account_deletion_jobs.account_type_snapshot IS
  'Immutable account type (fan/business/etc.) captured before anonymization.';

-- ---------------------------------------------------------------------------
-- Build snapshot jsonb from live profile + XP (read-only helper)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gameon_account_deletion_build_user_snapshot(
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_display_name text;
  v_handle text;
  v_account_type text;
  v_is_business boolean := false;
  v_fangeo_plus boolean;
  v_fangeo_expires timestamptz;
  v_total_xp integer;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN '{}'::jsonb;
  END IF;

  SELECT
    nullif(btrim(coalesce(up.display_name, '')), ''),
    nullif(btrim(coalesce(up.handle, '')), ''),
    coalesce(up.is_business_account, false),
    up.ad_free_enabled,
    up.ad_free_expires_at
  INTO
    v_display_name,
    v_handle,
    v_is_business,
    v_fangeo_plus,
    v_fangeo_expires
  FROM public.user_profiles up
  WHERE up.id = p_user_id;

  IF to_regclass('public.account_identities') IS NOT NULL THEN
    SELECT nullif(lower(btrim(coalesce(ai.account_type, ''))), '')
      INTO v_account_type
    FROM public.account_identities ai
    WHERE ai.account_id = p_user_id
    ORDER BY ai.created_at DESC NULLS LAST
    LIMIT 1;
  END IF;

  IF v_account_type IS NULL THEN
    v_account_type := CASE WHEN v_is_business THEN 'business' ELSE 'fan' END;
  END IF;

  IF to_regclass('public.user_xp') IS NOT NULL THEN
    SELECT ux.total_xp
      INTO v_total_xp
    FROM public.user_xp ux
    WHERE ux.user_id = p_user_id;
  END IF;

  RETURN jsonb_build_object(
    'display_name_snapshot', to_jsonb(v_display_name),
    'handle_snapshot', to_jsonb(v_handle),
    'total_xp_snapshot', to_jsonb(v_total_xp),
    'fangeo_plus_snapshot', to_jsonb(v_fangeo_plus),
    'fangeo_plus_expires_at_snapshot', to_jsonb(v_fangeo_expires),
    'account_type_snapshot', to_jsonb(v_account_type)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.gameon_account_deletion_build_user_snapshot(uuid) FROM PUBLIC;
-- Internal helper used by SECURITY DEFINER deletion execute path.

COMMENT ON FUNCTION public.gameon_account_deletion_build_user_snapshot(uuid) IS
  'Reads live profile/XP values for an immutable deletion-time snapshot. Not client-callable.';

-- ---------------------------------------------------------------------------
-- Hardened execute path: snapshot then anonymize
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.execute_delete_user_account_db(
  p_job_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_job public.account_deletion_jobs%ROWTYPE;
  v_email text;
  v_core jsonb;
  v_paths text[];
  v_counts jsonb;
  v_cleanup_sqlstate text;
  v_cleanup_error text;
  v_snapshot jsonb;
  v_display_name text;
  v_handle text;
  v_total_xp integer;
  v_fangeo_plus boolean;
  v_fangeo_expires timestamptz;
  v_account_type text;
BEGIN
  IF p_job_id IS NULL THEN
    RAISE EXCEPTION 'job_id is required' USING ERRCODE = '22023';
  END IF;

  SELECT *
    INTO v_job
  FROM public.account_deletion_jobs
  WHERE id = p_job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Account deletion job not found: %', p_job_id USING ERRCODE = 'P0002';
  END IF;

  PERFORM public.gameon_account_deletion_resolve_target_user_id(v_job.subject_user_id);

  IF v_job.deletion_mode <> 'soft' THEN
    RAISE EXCEPTION 'Hard deletion is not enabled in Phase 2' USING ERRCODE = 'P0001';
  END IF;

  IF v_job.status = 'completed' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'job_id', v_job.id,
      'status', v_job.status,
      'stage', v_job.stage,
      'deleted_user_id', v_job.subject_user_id,
      'affected_counts', coalesce(v_job.affected_counts, '{}'::jsonb),
      'avatar_storage_paths', to_jsonb(coalesce(v_job.avatar_storage_paths, ARRAY[]::text[])),
      'idempotent_replay', true
    );
  END IF;

  IF v_job.status IN ('db_committed', 'storage_pending', 'auth_pending') THEN
    RETURN jsonb_build_object(
      'ok', true,
      'job_id', v_job.id,
      'status', v_job.status,
      'stage', v_job.stage,
      'deleted_user_id', v_job.subject_user_id,
      'affected_counts', coalesce(v_job.affected_counts, '{}'::jsonb),
      'avatar_storage_paths', to_jsonb(coalesce(v_job.avatar_storage_paths, ARRAY[]::text[])),
      'idempotent_replay', true
    );
  END IF;

  IF v_job.status = 'failed' THEN
    IF v_job.stage = 'db_cleanup'
       AND NOT public.gameon_account_deletion_profile_is_anonymized(v_job.subject_user_id) THEN
      NULL;
    ELSE
      RAISE EXCEPTION 'Job % failed at stage % and cannot be retried from DB execute', p_job_id, v_job.stage
        USING ERRCODE = 'P0001';
    END IF;
  END IF;

  PERFORM public.gameon_account_deletion_assert_deletable(v_job.subject_user_id);

  UPDATE public.account_deletion_jobs
  SET status = 'running',
      stage = 'db_cleanup',
      error_code = NULL,
      error_detail = NULL
  WHERE id = p_job_id;

  -- Capture immutable snapshot once, immediately before anonymization.
  -- Do not overwrite a previously captured snapshot on retry.
  IF v_job.display_name_snapshot IS NULL
     AND v_job.handle_snapshot IS NULL
     AND v_job.total_xp_snapshot IS NULL
     AND v_job.fangeo_plus_snapshot IS NULL
     AND v_job.fangeo_plus_expires_at_snapshot IS NULL
     AND v_job.account_type_snapshot IS NULL THEN
    v_snapshot := public.gameon_account_deletion_build_user_snapshot(v_job.subject_user_id);

    v_display_name := nullif(btrim(coalesce(v_snapshot ->> 'display_name_snapshot', '')), '');
    v_handle := nullif(btrim(coalesce(v_snapshot ->> 'handle_snapshot', '')), '');
    v_account_type := nullif(btrim(coalesce(v_snapshot ->> 'account_type_snapshot', '')), '');

    IF (v_snapshot ->> 'total_xp_snapshot') IS NOT NULL
       AND btrim(v_snapshot ->> 'total_xp_snapshot') <> ''
       AND btrim(v_snapshot ->> 'total_xp_snapshot') <> 'null' THEN
      v_total_xp := (v_snapshot ->> 'total_xp_snapshot')::integer;
    ELSE
      v_total_xp := NULL;
    END IF;

    IF (v_snapshot ->> 'fangeo_plus_snapshot') IS NOT NULL
       AND btrim(v_snapshot ->> 'fangeo_plus_snapshot') <> ''
       AND btrim(v_snapshot ->> 'fangeo_plus_snapshot') <> 'null' THEN
      v_fangeo_plus := (v_snapshot ->> 'fangeo_plus_snapshot')::boolean;
    ELSE
      v_fangeo_plus := NULL;
    END IF;

    IF (v_snapshot ->> 'fangeo_plus_expires_at_snapshot') IS NOT NULL
       AND btrim(v_snapshot ->> 'fangeo_plus_expires_at_snapshot') <> ''
       AND btrim(v_snapshot ->> 'fangeo_plus_expires_at_snapshot') <> 'null' THEN
      v_fangeo_expires := (v_snapshot ->> 'fangeo_plus_expires_at_snapshot')::timestamptz;
    ELSE
      v_fangeo_expires := NULL;
    END IF;

    UPDATE public.account_deletion_jobs
    SET display_name_snapshot = v_display_name,
        handle_snapshot = v_handle,
        total_xp_snapshot = v_total_xp,
        fangeo_plus_snapshot = v_fangeo_plus,
        fangeo_plus_expires_at_snapshot = v_fangeo_expires,
        account_type_snapshot = v_account_type
    WHERE id = p_job_id;
  END IF;

  BEGIN
    v_email := public.gameon_account_deletion_resolve_email(v_job.subject_user_id);
    v_core := public.gameon_account_deletion_soft_delete_core(v_job.subject_user_id, v_email);
    v_counts := coalesce(v_core -> 'affected_counts', '{}'::jsonb);
    v_paths := coalesce(
      ARRAY(SELECT jsonb_array_elements_text(coalesce(v_core -> 'avatar_storage_paths', '[]'::jsonb))),
      ARRAY[]::text[]
    );
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS
        v_cleanup_sqlstate = RETURNED_SQLSTATE,
        v_cleanup_error = MESSAGE_TEXT;

      UPDATE public.account_deletion_jobs
      SET status = 'failed',
          stage = 'db_cleanup',
          error_code = v_cleanup_sqlstate,
          error_detail = v_cleanup_error
      WHERE id = p_job_id;

      RETURN jsonb_build_object(
        'ok', false,
        'job_id', p_job_id,
        'status', 'failed',
        'stage', 'db_cleanup',
        'deleted_user_id', v_job.subject_user_id,
        'error_code', v_cleanup_sqlstate,
        'error_detail', v_cleanup_error,
        'idempotent_replay', false
      );
  END;

  UPDATE public.account_deletion_jobs
  SET status = 'db_committed',
      stage = 'awaiting_storage_finalize',
      affected_counts = v_counts,
      avatar_storage_paths = v_paths,
      preview_snapshot = coalesce(preview_snapshot, public.preview_delete_user_account(v_job.subject_user_id)),
      error_code = NULL,
      error_detail = NULL
  WHERE id = p_job_id;

  RETURN jsonb_build_object(
    'ok', true,
    'job_id', p_job_id,
    'status', 'db_committed',
    'stage', 'awaiting_storage_finalize',
    'deleted_user_id', v_job.subject_user_id,
    'normalized_email', v_core ->> 'normalized_email',
    'affected_counts', v_counts,
    'avatar_storage_paths', to_jsonb(v_paths),
    'auth_users_deleted', false,
    'account_identities_deleted', false,
    'idempotent_replay', false
  );
END;
$$;

COMMENT ON FUNCTION public.execute_delete_user_account_db(uuid) IS
  'Runs fan soft-delete DB stage. Captures immutable user snapshot columns before anonymization.';

COMMIT;
