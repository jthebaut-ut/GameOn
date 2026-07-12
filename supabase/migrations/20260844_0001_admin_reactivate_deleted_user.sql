-- Pre-launch admin-only recovery: reactivate a completed Phase 2 (or verified legacy)
-- soft-deleted fan profile as a fresh shell. Does not restore private deleted data,
-- does not delete auth.users, and does not alter account_deletion_jobs history.

-- ---------------------------------------------------------------------------
-- Immutable reactivation history (optional audit companion)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.account_reactivation_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  deletion_job_id uuid NULL REFERENCES public.account_deletion_jobs(id) ON DELETE SET NULL,
  admin_email text NOT NULL,
  reason text NOT NULL,
  original_email text NOT NULL,
  display_name text NOT NULL,
  handle text NULL,
  prior_profile_state jsonb NOT NULL DEFAULT '{}'::jsonb,
  data_not_restored jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_account_reactivation_events_subject_created
  ON public.account_reactivation_events (subject_user_id, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS account_reactivation_events_one_per_job
  ON public.account_reactivation_events (subject_user_id, deletion_job_id)
  WHERE deletion_job_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS account_reactivation_events_one_legacy_per_subject
  ON public.account_reactivation_events (subject_user_id)
  WHERE deletion_job_id IS NULL;

ALTER TABLE public.account_reactivation_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS account_reactivation_events_service_role ON public.account_reactivation_events;
CREATE POLICY account_reactivation_events_service_role
  ON public.account_reactivation_events
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- ---------------------------------------------------------------------------
-- Shared constants / helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gameon_reactivation_data_not_restored()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT jsonb_build_array(
    'favorites_and_saved_games',
    'predictions_and_xp',
    'avatar_and_profile_media',
    'notification_preferences_and_push_tokens',
    'friendships_and_social_interactions',
    'pickup_activity_and_invites',
    'location_and_national_team_identity',
    'fan_preferences_and_settings',
    'direct_messages',
    'reports_and_moderation_records',
    'support_history'
  );
$$;

CREATE OR REPLACE FUNCTION public.gameon_reactivation_preserved_shared_records()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT jsonb_build_array(
    'direct_messages',
    'reports',
    'support_history',
    'user_bans',
    'admin_audit_logs',
    'account_deletion_jobs_history'
  );
$$;

CREATE OR REPLACE FUNCTION public.gameon_reactivation_is_tombstone_email(p_email text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT lower(btrim(coalesce(p_email, ''))) LIKE '%@deleted.fangeo.local';
$$;

CREATE OR REPLACE FUNCTION public.gameon_reactivation_resolve_original_email(
  p_user_id uuid,
  p_job_row public.account_deletion_jobs DEFAULT NULL
)
RETURNS TABLE(original_email text, source text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_preview_email text;
  v_original_column text;
  v_auth_email text;
  v_identity_email text;
BEGIN
  IF p_job_row.id IS NOT NULL AND p_job_row.preview_snapshot IS NOT NULL THEN
    v_preview_email := lower(btrim(coalesce(p_job_row.preview_snapshot ->> 'normalized_email', '')));
    IF v_preview_email <> '' AND NOT public.gameon_reactivation_is_tombstone_email(v_preview_email) THEN
      original_email := v_preview_email;
      source := 'preview_snapshot';
      RETURN NEXT;
      RETURN;
    END IF;
  END IF;

  IF p_job_row.id IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM information_schema.columns
       WHERE table_schema = 'public'
         AND table_name = 'account_deletion_jobs'
         AND column_name = 'original_email'
     ) THEN
    SELECT lower(btrim(coalesce(j.original_email, '')))
      INTO v_original_column
    FROM public.account_deletion_jobs j
    WHERE j.id = p_job_row.id;

    IF v_original_column IS NOT NULL
       AND v_original_column <> ''
       AND NOT public.gameon_reactivation_is_tombstone_email(v_original_column) THEN
      original_email := v_original_column;
      source := 'original_email';
      RETURN NEXT;
      RETURN;
    END IF;
  END IF;

  SELECT lower(btrim(coalesce(ai.email, '')))
    INTO v_identity_email
  FROM public.account_identities ai
  WHERE ai.account_id = p_user_id
  LIMIT 1;

  SELECT lower(btrim(coalesce(u.email, '')))
    INTO v_auth_email
  FROM auth.users u
  WHERE u.id = p_user_id;

  IF v_auth_email <> ''
     AND NOT public.gameon_reactivation_is_tombstone_email(v_auth_email)
     AND v_identity_email <> ''
     AND v_auth_email = v_identity_email THEN
    original_email := v_auth_email;
    source := 'auth_users';
    RETURN NEXT;
    RETURN;
  END IF;

  original_email := NULL;
  source := 'unavailable';
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.gameon_reactivation_latest_deletion_job(
  p_user_id uuid
)
RETURNS public.account_deletion_jobs
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT j.*
  FROM public.account_deletion_jobs j
  WHERE j.subject_user_id = p_user_id
  ORDER BY j.created_at DESC NULLS LAST, j.id DESC
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.gameon_reactivation_assert_service_role()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.gameon_account_deletion_is_service_caller() THEN
    RAISE EXCEPTION 'Reactivation RPC restricted to service_role'
      USING ERRCODE = '42501';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.gameon_reactivation_has_active_user_ban(
  p_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_bans ub
    WHERE ub.user_id = p_user_id
      AND public.is_user_ban_active(ub.expires_at, ub.lifted_at)
  );
$$;

CREATE OR REPLACE FUNCTION public.gameon_reactivation_is_deletion_caused_disable(
  p_profile public.user_profiles
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT coalesce(p_profile.admin_disabled_reason, '') ILIKE '%delet%';
$$;

CREATE OR REPLACE FUNCTION public.gameon_reactivation_is_moderation_disabled(
  p_profile public.user_profiles
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT
    CASE
      WHEN public.gameon_reactivation_is_deletion_caused_disable(p_profile) THEN false
      WHEN lower(btrim(coalesce(p_profile.admin_status, ''))) = 'disabled' THEN true
      WHEN p_profile.admin_disabled_at IS NOT NULL THEN true
      ELSE false
    END;
$$;

CREATE OR REPLACE FUNCTION public.gameon_reactivation_latest_job_block_reason(
  p_job public.account_deletion_jobs
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
BEGIN
  IF p_job.id IS NULL THEN
    RETURN NULL;
  END IF;

  IF p_job.status IN (
    'queued',
    'previewed',
    'running',
    'db_committed',
    'storage_pending',
    'auth_pending'
  ) THEN
    RETURN 'active_deletion_job';
  END IF;

  IF p_job.status = 'failed' THEN
    RETURN 'deletion_job_not_completed';
  END IF;

  IF p_job.status = 'cancelled' THEN
    RETURN NULL;
  END IF;

  IF p_job.status = 'completed' THEN
    RETURN NULL;
  END IF;

  RETURN 'deletion_job_not_completed';
END;
$$;

CREATE OR REPLACE FUNCTION public.gameon_reactivation_auth_deletion_ban_proven(
  p_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT coalesce(
    (
      SELECT
        coalesce(u.raw_app_meta_data ->> 'ban_reason', '') = 'account_deletion'
        OR coalesce(u.raw_app_meta_data ->> 'banned_for_account_deletion', 'false') = 'true'
      FROM auth.users u
      WHERE u.id = p_user_id
    ),
    false
  );
$$;

CREATE OR REPLACE FUNCTION public.gameon_reactivation_find_prior_event(
  p_user_id uuid,
  p_deletion_job_id uuid
)
RETURNS public.account_reactivation_events
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT e.*
  FROM public.account_reactivation_events e
  WHERE e.subject_user_id = p_user_id
    AND (
      (p_deletion_job_id IS NULL AND e.deletion_job_id IS NULL)
      OR e.deletion_job_id = p_deletion_job_id
    )
  ORDER BY e.created_at DESC NULLS LAST, e.id DESC
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.gameon_reactivation_handle_is_available(
  p_user_id uuid,
  p_normalized_handle text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT NOT EXISTS (
    SELECT 1
    FROM public.user_profiles up
    WHERE up.id <> p_user_id
      AND COALESCE(up.is_deleted, false) = false
      AND COALESCE(lower(trim(up.admin_status)), 'active') = 'active'
      AND COALESCE(up.is_business_account, false) = false
      AND public.fangeo_normalize_handle(coalesce(up.handle, up.username)) = p_normalized_handle
  );
$$;

CREATE OR REPLACE FUNCTION public.gameon_reactivation_access_state(
  p_profile public.user_profiles
)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT CASE
    WHEN public.gameon_reactivation_is_moderation_disabled(p_profile)
      OR lower(btrim(coalesce(p_profile.admin_status, ''))) = 'disabled' THEN 'disabled'
    ELSE 'active'
  END;
$$;

CREATE OR REPLACE FUNCTION public.gameon_reactivation_business_conflict_reason(
  p_user_id uuid,
  p_email text
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email text := lower(btrim(coalesce(p_email, '')));
BEGIN
  IF to_regclass('public.account_identities') IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.account_identities ai
       WHERE ai.account_id = p_user_id
         AND ai.account_type = 'business'
     ) THEN
    RETURN 'business_account_type';
  END IF;

  IF to_regclass('public.businesses') IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.businesses b
       WHERE b.owner_user_id = p_user_id
     ) THEN
    RETURN 'business_ownership';
  END IF;

  IF v_email <> ''
     AND to_regclass('public.businesses') IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.businesses b
       WHERE lower(btrim(coalesce(b.owner_email, ''))) = v_email
         AND b.owner_user_id IS NULL
     ) THEN
    RETURN 'business_email_ownership';
  END IF;

  IF to_regclass('public.venues') IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.venues v
       WHERE v.owner_user_id = p_user_id
     ) THEN
    RETURN 'venue_ownership';
  END IF;

  IF to_regclass('public.venue_claims') IS NOT NULL THEN
    IF to_regprocedure('public.gameon_venue_claim_is_open_pending(text)') IS NOT NULL THEN
      IF EXISTS (
        SELECT 1
        FROM public.venue_claims vc
        WHERE public.gameon_venue_claim_is_open_pending(vc.approval_status)
          AND (
            (v_email <> '' AND lower(btrim(coalesce(vc.owner_email, ''))) = v_email)
            OR EXISTS (
              SELECT 1
              FROM public.businesses b
              WHERE b.owner_user_id = p_user_id
                AND b.id::text = vc.business_id::text
            )
          )
      ) THEN
        RETURN 'pending_venue_claim';
      END IF;
    ELSIF EXISTS (
      SELECT 1
      FROM public.venue_claims vc
      WHERE coalesce(lower(btrim(vc.approval_status)), '') NOT IN (
        'approved', 'released', 'business_deleted', 'cancelled', 'withdrawn', 'rejected'
      )
      AND (
        (v_email <> '' AND lower(btrim(coalesce(vc.owner_email, ''))) = v_email)
        OR EXISTS (
          SELECT 1
          FROM public.businesses b
          WHERE b.owner_user_id = p_user_id
            AND b.id::text = vc.business_id::text
        )
      )
    ) THEN
      RETURN 'pending_venue_claim';
    END IF;
  END IF;

  -- Fan reactivation only: block active (non-deleted) business-profile flags.
  -- Deleted profiles may retain legacy is_business_account=true without blocking fan recovery;
  -- business identity ownership is enforced separately via account_identities.account_type.
  IF to_regclass('public.user_profiles') IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.user_profiles up
       WHERE up.id = p_user_id
         AND COALESCE(up.is_business_account, false) = true
         AND COALESCE(up.is_deleted, false) = false
     ) THEN
    RETURN 'business_profile_flag';
  END IF;

  RETURN NULL;
END;
$$;

-- ---------------------------------------------------------------------------
-- Shared eligibility evaluation
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gameon_reactivation_evaluate_eligibility(
  p_user_id uuid,
  p_profile public.user_profiles,
  p_identity public.account_identities,
  p_job public.account_deletion_jobs
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
  v_original_source text;
  v_block_reason text;
  v_legacy boolean := false;
  v_job_block text;
  v_identity_belongs boolean := false;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object(
      'eligible', false,
      'block_reason', 'invalid_user_id',
      'message', 'A valid subject user id is required.'
    );
  END IF;

  IF p_profile.id IS NULL THEN
    RETURN jsonb_build_object(
      'eligible', false,
      'block_reason', 'profile_not_found',
      'message', 'User profile not found.'
    );
  END IF;

  IF NOT (
    COALESCE(p_profile.is_deleted, false) = true
    OR p_profile.deleted_at IS NOT NULL
    OR p_profile.anonymized_at IS NOT NULL
    OR public.gameon_reactivation_is_tombstone_email(p_profile.email)
  ) THEN
    RETURN jsonb_build_object(
      'eligible', false,
      'block_reason', 'profile_not_deleted',
      'message', 'This profile is not in a deleted state.',
      'idempotent', COALESCE(p_profile.is_deleted, false) = false
        AND NOT public.gameon_reactivation_is_tombstone_email(p_profile.email)
    );
  END IF;

  IF public.gameon_reactivation_is_moderation_disabled(p_profile) THEN
    RETURN jsonb_build_object(
      'eligible', false,
      'block_reason', 'moderation_disable_requires_resolution',
      'message', 'This account was disabled for moderation and must be resolved through the existing moderation workflow before reactivation.',
      'access_state', 'disabled'
    );
  END IF;

  IF public.gameon_reactivation_has_active_user_ban(p_user_id) THEN
    RETURN jsonb_build_object(
      'eligible', false,
      'block_reason', 'active_moderation_ban',
      'message', 'This account has an active moderation ban and must be resolved before reactivation.',
      'access_state', 'banned'
    );
  END IF;

  SELECT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user_id)
    INTO v_auth_exists;

  IF NOT v_auth_exists THEN
    RETURN jsonb_build_object(
      'eligible', false,
      'block_reason', 'auth_user_missing',
      'message', 'auth.users row is missing for this subject user.',
      'auth_user_exists', false
    );
  END IF;

  IF p_identity.account_id IS NULL THEN
    RETURN jsonb_build_object(
      'eligible', false,
      'block_reason', 'identity_missing',
      'message', 'account_identities row is missing for this subject user.',
      'auth_user_exists', true
    );
  END IF;

  IF p_identity.account_type IS DISTINCT FROM 'fan' THEN
    RETURN jsonb_build_object(
      'eligible', false,
      'block_reason', 'identity_not_fan',
      'message', 'This account identity is not a fan account.',
      'auth_user_exists', true
    );
  END IF;

  v_identity_belongs := p_identity.account_id = p_user_id;
  v_legacy := p_job.id IS NULL;
  v_job_block := public.gameon_reactivation_latest_job_block_reason(p_job);

  IF v_job_block IS NOT NULL THEN
    RETURN jsonb_build_object(
      'eligible', false,
      'block_reason', v_job_block,
      'message', CASE
        WHEN v_job_block = 'active_deletion_job'
          THEN 'An active or incomplete deletion job still exists for this user.'
        ELSE 'The latest deletion job is not completed.'
      END,
      'deletion_job_id', p_job.id,
      'deletion_job_status', p_job.status,
      'legacy', v_legacy,
      'auth_user_exists', true
    );
  END IF;

  IF p_job.id IS NOT NULL AND p_job.status = 'cancelled' THEN
    v_legacy := true;
  END IF;

  SELECT r.original_email, r.source
    INTO v_original_email, v_original_source
  FROM public.gameon_reactivation_resolve_original_email(p_user_id, p_job) r
  LIMIT 1;

  IF v_original_email IS NULL OR v_original_email = '' THEN
    RETURN jsonb_build_object(
      'eligible', false,
      'block_reason', 'original_email_unavailable',
      'message', 'Reactivation unavailable — original identity cannot be verified.',
      'legacy', v_legacy,
      'auth_user_exists', true,
      'identity_email', p_identity.email,
      'identity_belongs_to_user', v_identity_belongs
    );
  END IF;

  IF lower(btrim(p_identity.email)) IS DISTINCT FROM v_original_email THEN
    RETURN jsonb_build_object(
      'eligible', false,
      'block_reason', 'original_email_not_reserved_to_user',
      'message', 'The recovered original email does not match the reserved account identity for this user.',
      'original_email', v_original_email,
      'original_email_source', v_original_source,
      'identity_email', p_identity.email,
      'identity_belongs_to_user', v_identity_belongs,
      'legacy', v_legacy,
      'auth_user_exists', true
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.account_identities ai
    WHERE lower(btrim(ai.email)) = v_original_email
      AND ai.account_id <> p_user_id
  ) THEN
    RETURN jsonb_build_object(
      'eligible', false,
      'block_reason', 'email_reserved_to_other_account',
      'message', 'The original email is reserved to a different account.',
      'original_email', v_original_email,
      'legacy', v_legacy,
      'auth_user_exists', true
    );
  END IF;

  v_block_reason := public.gameon_reactivation_business_conflict_reason(p_user_id, v_original_email);
  IF v_block_reason IS NOT NULL THEN
    RETURN jsonb_build_object(
      'eligible', false,
      'block_reason', v_block_reason,
      'message', 'Business, venue, or pending venue claim ownership conflicts with fan reactivation.',
      'original_email', v_original_email,
      'legacy', v_legacy,
      'auth_user_exists', true
    );
  END IF;

  RETURN jsonb_build_object(
    'eligible', true,
    'block_reason', NULL,
    'message', CASE
      WHEN v_legacy THEN 'Legacy deleted profile eligible for reactivation.'
      ELSE 'Completed Phase 2 deletion eligible for reactivation.'
    END,
    'legacy', v_legacy,
    'original_email', v_original_email,
    'original_email_source', v_original_source,
    'auth_user_exists', v_auth_exists,
    'identity_email', p_identity.email,
    'identity_belongs_to_user', v_identity_belongs,
    'deletion_job_id', p_job.id,
    'deletion_job_status', p_job.status,
    'deleted_at', p_profile.deleted_at,
    'anonymized_at', p_profile.anonymized_at,
    'access_state', 'active',
    'auth_ban_clear_eligible', public.gameon_reactivation_auth_deletion_ban_proven(p_user_id),
    'preserved_shared_records', public.gameon_reactivation_preserved_shared_records(),
    'data_not_restored', public.gameon_reactivation_data_not_restored()
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- Eligibility preview (read-only)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_reactivate_deleted_user_eligibility(
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
  v_identity public.account_identities%ROWTYPE;
  v_job public.account_deletion_jobs;
BEGIN
  PERFORM public.gameon_reactivation_assert_service_role();

  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object(
      'eligible', false,
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
      'block_reason', 'profile_not_found',
      'message', 'User profile not found.'
    );
  END IF;

  IF to_regclass('public.account_identities') IS NULL THEN
    RETURN jsonb_build_object(
      'eligible', false,
      'block_reason', 'identity_table_missing',
      'message', 'account_identities table is unavailable.'
    );
  END IF;

  SELECT * INTO v_identity
  FROM public.account_identities ai
  WHERE ai.account_id = p_user_id;

  IF NOT FOUND THEN
    v_identity.account_id := NULL;
  END IF;

  v_job := public.gameon_reactivation_latest_deletion_job(p_user_id);

  RETURN public.gameon_reactivation_evaluate_eligibility(
    p_user_id,
    v_profile,
    v_identity,
    v_job
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- Reactivation mutation
-- ---------------------------------------------------------------------------

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

  v_set_clauses := v_set_clauses || ARRAY[
    format('email = %L', v_original_email),
    format('display_name = %L', v_display_name)
  ];

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'display_name_normalized'
  ) THEN
    v_set_clauses := v_set_clauses || ARRAY[format('display_name_normalized = %L', lower(v_display_name))];
  END IF;

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

-- ---------------------------------------------------------------------------
-- Identity guard: transaction-local reactivation bypass (service-role RPC only)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.enforce_fan_account_identity_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_auth_email text;
  v_row_email text := lower(btrim(coalesce(NEW.email, '')));
  v_anonymize_bypass text := nullif(btrim(current_setting('gameon.account_deletion_anonymize', true)), '');
  v_reactivate_bypass text := nullif(btrim(current_setting('gameon.account_reactivation_restore', true)), '');
  v_identity_email text;
BEGIN
  IF v_anonymize_bypass IS NOT NULL AND NEW.id::text = v_anonymize_bypass THEN
    RETURN NEW;
  END IF;

  IF v_reactivate_bypass IS NOT NULL AND NEW.id::text = v_reactivate_bypass THEN
    SELECT lower(btrim(coalesce(ai.email, '')))
      INTO v_identity_email
    FROM public.account_identities ai
    WHERE ai.account_id = NEW.id
      AND ai.account_type = 'fan'
    LIMIT 1;

    IF v_identity_email IS NULL OR v_identity_email = '' THEN
      RAISE EXCEPTION 'Fan reactivation requires a reserved account identity.' USING ERRCODE = '42501';
    END IF;

    IF v_row_email IS DISTINCT FROM v_identity_email THEN
      RAISE EXCEPTION 'Fan reactivation profile email must match the reserved account identity email.' USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
  END IF;

  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Fan profile auth user mismatch.' USING ERRCODE = '42501';
  END IF;

  SELECT lower(btrim(coalesce(email, '')))
  INTO v_auth_email
  FROM auth.users
  WHERE id = auth.uid();

  IF v_row_email <> v_auth_email THEN
    RAISE EXCEPTION 'Fan profile email must match the authenticated user email.' USING ERRCODE = '42501';
  END IF;

  PERFORM public.claim_account_type('fan');
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- Grants: service_role only
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.gameon_reactivation_data_not_restored() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_reactivation_preserved_shared_records() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_reactivation_is_tombstone_email(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_reactivation_resolve_original_email(uuid, public.account_deletion_jobs) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_reactivation_latest_deletion_job(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_reactivation_assert_service_role() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_reactivation_has_active_user_ban(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_reactivation_is_deletion_caused_disable(public.user_profiles) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_reactivation_is_moderation_disabled(public.user_profiles) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_reactivation_latest_job_block_reason(public.account_deletion_jobs) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_reactivation_auth_deletion_ban_proven(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_reactivation_find_prior_event(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_reactivation_handle_is_available(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_reactivation_access_state(public.user_profiles) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_reactivation_evaluate_eligibility(uuid, public.user_profiles, public.account_identities, public.account_deletion_jobs) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_reactivation_business_conflict_reason(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_reactivate_deleted_user_eligibility(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_reactivate_deleted_user(uuid, text, text, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_reactivate_deleted_user_eligibility(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_reactivate_deleted_user(uuid, text, text, text, text) TO service_role;

COMMENT ON FUNCTION public.gameon_reactivation_business_conflict_reason(uuid, text) IS
  'Fan reactivation blockers aligned with Phase 2 deletion checks. business_profile_flag applies only to active (non-deleted) business-profile flags; deleted fan rows with legacy is_business_account=true are not blocked here because account_identities.account_type enforces fan ownership.';

COMMENT ON FUNCTION public.admin_reactivate_deleted_user_eligibility(uuid) IS
  'Pre-launch admin read-only eligibility preview for reactivating a soft-deleted fan profile shell. service_role only.';

COMMENT ON FUNCTION public.admin_reactivate_deleted_user(uuid, text, text, text, text) IS
  'Pre-launch admin recovery: restore login-capable fan profile shell without recovering deleted private data. service_role only.';

COMMENT ON TABLE public.account_reactivation_events IS
  'Immutable admin reactivation history linked to optional account_deletion_jobs rows.';
