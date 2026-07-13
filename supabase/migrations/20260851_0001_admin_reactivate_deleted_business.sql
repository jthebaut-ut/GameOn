-- Admin-only reactivation for Phase 2 tombstoned business accounts.
-- Restores a fresh business profile shell on the existing businesses row without
-- recovering deleted venues, claims, games, entitlements, media, or subscriptions.
--
-- Does NOT modify fan reactivation, business self-deletion, or prior migrations.

-- ---------------------------------------------------------------------------
-- 1. Immutable reactivation audit table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.business_reactivation_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  owner_user_id uuid NOT NULL,
  deletion_job_id uuid NULL REFERENCES public.business_account_deletion_jobs(id) ON DELETE SET NULL,
  deletion_audit_id uuid NULL REFERENCES public.business_account_deletion_audit(id) ON DELETE SET NULL,
  admin_email text NOT NULL,
  reason text NOT NULL,
  original_owner_email text NOT NULL,
  display_name text NOT NULL,
  business_handle text NULL,
  prior_business_state jsonb NOT NULL DEFAULT '{}'::jsonb,
  data_not_restored jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_business_reactivation_events_business_created
  ON public.business_reactivation_events (business_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_business_reactivation_events_owner_created
  ON public.business_reactivation_events (owner_user_id, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS business_reactivation_events_one_per_job
  ON public.business_reactivation_events (business_id, deletion_job_id)
  WHERE deletion_job_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS business_reactivation_events_one_legacy_per_business
  ON public.business_reactivation_events (business_id)
  WHERE deletion_job_id IS NULL;

ALTER TABLE public.business_reactivation_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS business_reactivation_events_service_role ON public.business_reactivation_events;
CREATE POLICY business_reactivation_events_service_role
  ON public.business_reactivation_events
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE OR REPLACE FUNCTION public.gameon_business_reactivation_events_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'business_reactivation_events is immutable'
    USING ERRCODE = '42501';
END;
$$;

DROP TRIGGER IF EXISTS business_reactivation_events_immutable_bu
  ON public.business_reactivation_events;
CREATE TRIGGER business_reactivation_events_immutable_bu
  BEFORE UPDATE OR DELETE ON public.business_reactivation_events
  FOR EACH ROW
  EXECUTE FUNCTION public.gameon_business_reactivation_events_immutable();

COMMENT ON TABLE public.business_reactivation_events IS
  'Immutable admin business reactivation history linked to optional business_account_deletion_jobs rows.';

-- ---------------------------------------------------------------------------
-- 2. Shared helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gameon_business_reactivation_assert_service_role()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.gameon_business_deletion_is_service_caller() THEN
    RAISE EXCEPTION 'Business reactivation RPC restricted to service_role'
      USING ERRCODE = '42501';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.gameon_business_reactivation_data_not_restored()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT jsonb_build_array(
    'deleted_or_archived_venues',
    'released_community_claims',
    'scheduled_or_completed_games',
    'comments_and_social_content',
    'business_pro_entitlement',
    'sponsored_placements',
    'logos_images_and_media',
    'analytics',
    'private_business_settings',
    'push_tokens',
    'subscription_state',
    'venue_ownership'
  );
$$;

CREATE OR REPLACE FUNCTION public.gameon_business_reactivation_is_tombstone_business_email(p_email text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT lower(btrim(coalesce(p_email, ''))) LIKE '%@deleted.fangeo.local';
$$;

CREATE OR REPLACE FUNCTION public.gameon_business_reactivation_latest_deletion_job(
  p_business_id uuid
)
RETURNS public.business_account_deletion_jobs
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT j.*
  FROM public.business_account_deletion_jobs j
  WHERE j.subject_business_id = p_business_id
  ORDER BY j.created_at DESC NULLS LAST, j.id DESC
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.gameon_business_reactivation_latest_soft_audit(
  p_business_id uuid
)
RETURNS public.business_account_deletion_audit
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT a.*
  FROM public.business_account_deletion_audit a
  WHERE a.business_id = p_business_id
    AND a.deletion_mode = 'soft'
  ORDER BY a.deleted_at DESC NULLS LAST, a.id DESC
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.gameon_business_reactivation_latest_job_block_reason(
  p_job public.business_account_deletion_jobs
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
    'storage_pending'
  ) THEN
    RETURN 'active_deletion_job';
  END IF;

  IF p_job.status = 'db_committed' THEN
    RETURN 'storage_finalization_pending';
  END IF;

  IF p_job.status = 'failed' THEN
    RETURN 'deletion_job_not_completed';
  END IF;

  IF p_job.status = 'completed' THEN
    RETURN NULL;
  END IF;

  IF p_job.status = 'cancelled' THEN
    RETURN 'deletion_job_not_completed';
  END IF;

  RETURN 'deletion_job_not_completed';
END;
$$;

CREATE OR REPLACE FUNCTION public.gameon_business_reactivation_resolve_original_identity(
  p_business_id uuid,
  p_audit public.business_account_deletion_audit
)
RETURNS TABLE(
  original_owner_email text,
  original_display_name text,
  source text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email text;
  v_name text;
BEGIN
  IF p_audit.id IS NOT NULL AND p_audit.business_snapshot IS NOT NULL THEN
    v_email := lower(btrim(coalesce(p_audit.business_snapshot ->> 'owner_email', '')));
    v_name := btrim(coalesce(p_audit.business_snapshot ->> 'display_name', ''));
    IF v_email <> ''
       AND NOT public.gameon_business_reactivation_is_tombstone_business_email(v_email) THEN
      original_owner_email := v_email;
      original_display_name := NULLIF(v_name, '');
      source := 'business_snapshot';
      RETURN NEXT;
      RETURN;
    END IF;
  END IF;

  SELECT lower(btrim(coalesce(b.owner_email, ''))),
         btrim(coalesce(b.display_name, ''))
    INTO v_email, v_name
  FROM public.businesses b
  WHERE b.id = p_business_id;

  IF v_email <> ''
     AND NOT public.gameon_business_reactivation_is_tombstone_business_email(v_email) THEN
    original_owner_email := v_email;
    original_display_name := NULLIF(v_name, '');
    source := 'business_row';
    RETURN NEXT;
    RETURN;
  END IF;

  original_owner_email := NULL;
  original_display_name := NULL;
  source := 'unavailable';
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.gameon_business_reactivation_has_active_business_ban(
  p_business_id uuid,
  p_owner_user_id uuid,
  p_owner_email text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.business_bans bb
    WHERE bb.lifted_at IS NULL
      AND (bb.is_permanent = true OR bb.banned_until > now())
      AND (
        bb.business_id = p_business_id
        OR (p_owner_user_id IS NOT NULL AND bb.owner_user_id = p_owner_user_id)
        OR (
          p_owner_email IS NOT NULL
          AND p_owner_email <> ''
          AND lower(btrim(coalesce(bb.owner_email, ''))) = lower(btrim(p_owner_email))
        )
      )
  );
$$;

CREATE OR REPLACE FUNCTION public.gameon_business_reactivation_has_active_user_ban(
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

CREATE OR REPLACE FUNCTION public.gameon_business_reactivation_auth_user_is_banned(
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
        coalesce(u.raw_app_meta_data ->> 'ban_reason', '') <> ''
        OR coalesce(u.raw_app_meta_data ->> 'banned_for_account_deletion', 'false') = 'true'
      FROM auth.users u
      WHERE u.id = p_user_id
    ),
    false
  );
$$;

CREATE OR REPLACE FUNCTION public.gameon_business_reactivation_is_moderation_disabled(
  p_business public.businesses
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT lower(btrim(coalesce(p_business.admin_status, ''))) = 'disabled';
$$;

CREATE OR REPLACE FUNCTION public.gameon_business_reactivation_handle_is_available(
  p_business_id uuid,
  p_normalized_handle text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN p_normalized_handle IS NULL OR p_normalized_handle = '' THEN true
    ELSE NOT public.fangeo_handle_is_taken(p_normalized_handle, p_business_id)
  END;
$$;

CREATE OR REPLACE FUNCTION public.gameon_business_reactivation_find_prior_event(
  p_business_id uuid,
  p_deletion_job_id uuid
)
RETURNS public.business_reactivation_events
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT e.*
  FROM public.business_reactivation_events e
  WHERE e.business_id = p_business_id
    AND (
      (p_deletion_job_id IS NULL AND e.deletion_job_id IS NULL)
      OR e.deletion_job_id = p_deletion_job_id
    )
  ORDER BY e.created_at DESC NULLS LAST, e.id DESC
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.gameon_business_reactivation_confirmation_matches(
  p_business_id uuid,
  p_confirmation text
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT upper(btrim(coalesce(p_confirmation, ''))) = upper(
    format('REACTIVATE BUSINESS %s', lower(p_business_id::text))
  );
$$;

-- ---------------------------------------------------------------------------
-- 3. Shared eligibility evaluation
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
BEGIN
  IF p_business_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'eligible', false,
      'block_reason', 'invalid_business_id',
      'message', 'A valid business id is required.'
    );
  END IF;

  IF p_business.id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'eligible', false,
      'block_reason', 'business_not_found',
      'message', 'Business not found.'
    );
  END IF;

  IF p_business.id IS DISTINCT FROM p_business_id THEN
    RETURN jsonb_build_object(
      'ok', true,
      'eligible', false,
      'block_reason', 'business_mismatch',
      'message', 'Business row mismatch.'
    );
  END IF;

  IF coalesce(p_business.is_deleted, false) = false
     AND NOT public.gameon_business_reactivation_is_tombstone_business_email(p_business.owner_email) THEN
    RETURN jsonb_build_object(
      'ok', true,
      'eligible', false,
      'block_reason', 'business_not_deleted',
      'message', 'This business is not in a deleted tombstone state.',
      'idempotent', true,
      'business_id', p_business_id,
      'owner_user_id', p_business.owner_user_id
    );
  END IF;

  IF public.gameon_business_reactivation_is_moderation_disabled(p_business) THEN
    RETURN jsonb_build_object(
      'ok', true,
      'eligible', false,
      'block_reason', 'moderation_disable_requires_resolution',
      'message', 'This business was admin-disabled and must be resolved through moderation before reactivation.',
      'business_id', p_business_id,
      'owner_user_id', p_business.owner_user_id
    );
  END IF;

  IF p_audit.id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'eligible', false,
      'block_reason', 'deletion_audit_missing',
      'message', 'A matching soft-deletion audit row is required for business reactivation.',
      'business_id', p_business_id,
      'owner_user_id', p_business.owner_user_id
    );
  END IF;

  v_job_block := public.gameon_business_reactivation_latest_job_block_reason(p_job);
  IF v_job_block IS NOT NULL THEN
    RETURN jsonb_build_object(
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
    );
  END IF;

  IF p_business.owner_user_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'eligible', false,
      'block_reason', 'owner_user_missing',
      'message', 'Deleted business is missing owner_user_id.',
      'business_id', p_business_id
    );
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM auth.users u
    WHERE u.id = p_business.owner_user_id
  ) INTO v_auth_exists;

  IF NOT v_auth_exists THEN
    RETURN jsonb_build_object(
      'ok', true,
      'eligible', false,
      'block_reason', 'auth_user_missing',
      'message', 'auth.users row is missing for this business owner.',
      'business_id', p_business_id,
      'owner_user_id', p_business.owner_user_id,
      'auth_user_exists', false
    );
  END IF;

  IF public.gameon_business_reactivation_auth_user_is_banned(p_business.owner_user_id) THEN
    RETURN jsonb_build_object(
      'ok', true,
      'eligible', false,
      'block_reason', 'auth_user_banned',
      'message', 'The business owner auth user is banned and must be resolved before reactivation.',
      'business_id', p_business_id,
      'owner_user_id', p_business.owner_user_id,
      'auth_user_exists', true
    );
  END IF;

  IF p_identity.account_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'eligible', false,
      'block_reason', 'identity_missing',
      'message', 'account_identities row is missing for this business owner.',
      'business_id', p_business_id,
      'owner_user_id', p_business.owner_user_id,
      'auth_user_exists', true,
      'identity_reserved', false
    );
  END IF;

  IF p_identity.account_type IS DISTINCT FROM 'business' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'eligible', false,
      'block_reason', 'identity_not_business',
      'message', 'The reserved account identity is not a business account.',
      'business_id', p_business_id,
      'owner_user_id', p_business.owner_user_id,
      'auth_user_exists', true,
      'identity_reserved', false
    );
  END IF;

  IF p_identity.account_id IS DISTINCT FROM p_business.owner_user_id THEN
    RETURN jsonb_build_object(
      'ok', true,
      'eligible', false,
      'block_reason', 'identity_owner_mismatch',
      'message', 'The reserved business identity does not belong to the business owner user.',
      'business_id', p_business_id,
      'owner_user_id', p_business.owner_user_id,
      'auth_user_exists', true,
      'identity_reserved', false
    );
  END IF;

  v_identity_reserved := true;

  SELECT r.original_owner_email, r.original_display_name, r.source
    INTO v_original_email, v_original_display_name, v_original_source
  FROM public.gameon_business_reactivation_resolve_original_identity(p_business_id, p_audit) r
  LIMIT 1;

  IF v_original_email IS NULL OR v_original_email = '' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'eligible', false,
      'block_reason', 'original_owner_email_unavailable',
      'message', 'Reactivation unavailable — original business owner email cannot be verified.',
      'business_id', p_business_id,
      'owner_user_id', p_business.owner_user_id,
      'deletion_job_id', p_job.id,
      'deletion_audit_id', p_audit.id,
      'auth_user_exists', true,
      'identity_reserved', v_identity_reserved
    );
  END IF;

  IF lower(btrim(coalesce(p_identity.email, ''))) IS DISTINCT FROM v_original_email THEN
    RETURN jsonb_build_object(
      'ok', true,
      'eligible', false,
      'block_reason', 'original_email_not_reserved_to_owner',
      'message', 'The recovered original owner email does not match the reserved business account identity.',
      'business_id', p_business_id,
      'owner_user_id', p_business.owner_user_id,
      'original_owner_email', v_original_email,
      'deletion_job_id', p_job.id,
      'deletion_audit_id', p_audit.id,
      'auth_user_exists', true,
      'identity_reserved', v_identity_reserved
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.account_identities ai
    WHERE lower(btrim(ai.email)) = v_original_email
      AND ai.account_id <> p_business.owner_user_id
  ) THEN
    RETURN jsonb_build_object(
      'ok', true,
      'eligible', false,
      'block_reason', 'owner_email_reserved_to_other_account',
      'message', 'The original owner email is reserved to a different account.',
      'business_id', p_business_id,
      'owner_user_id', p_business.owner_user_id,
      'original_owner_email', v_original_email,
      'auth_user_exists', true,
      'identity_reserved', v_identity_reserved
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.businesses b
    WHERE b.id <> p_business_id
      AND coalesce(b.is_deleted, false) = false
      AND b.owner_user_id = p_business.owner_user_id
  ) THEN
    RETURN jsonb_build_object(
      'ok', true,
      'eligible', false,
      'block_reason', 'active_business_exists_for_owner',
      'message', 'Another active business row already exists for this owner user.',
      'business_id', p_business_id,
      'owner_user_id', p_business.owner_user_id,
      'original_owner_email', v_original_email,
      'auth_user_exists', true,
      'identity_reserved', v_identity_reserved
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.businesses b
    WHERE b.id <> p_business_id
      AND coalesce(b.is_deleted, false) = false
      AND lower(btrim(coalesce(b.owner_email, ''))) = v_original_email
  ) THEN
    RETURN jsonb_build_object(
      'ok', true,
      'eligible', false,
      'block_reason', 'owner_email_conflict',
      'message', 'Another active business already uses the original owner email.',
      'business_id', p_business_id,
      'owner_user_id', p_business.owner_user_id,
      'original_owner_email', v_original_email,
      'auth_user_exists', true,
      'identity_reserved', v_identity_reserved
    );
  END IF;

  IF public.gameon_business_reactivation_has_active_business_ban(
    p_business_id,
    p_business.owner_user_id,
    v_original_email
  ) THEN
    RETURN jsonb_build_object(
      'ok', true,
      'eligible', false,
      'block_reason', 'active_business_ban',
      'message', 'This business or owner has an active business ban.',
      'business_id', p_business_id,
      'owner_user_id', p_business.owner_user_id,
      'original_owner_email', v_original_email,
      'auth_user_exists', true,
      'identity_reserved', v_identity_reserved
    );
  END IF;

  IF public.gameon_business_reactivation_has_active_user_ban(p_business.owner_user_id) THEN
    RETURN jsonb_build_object(
      'ok', true,
      'eligible', false,
      'block_reason', 'active_user_ban',
      'message', 'The business owner has an active user ban.',
      'business_id', p_business_id,
      'owner_user_id', p_business.owner_user_id,
      'original_owner_email', v_original_email,
      'auth_user_exists', true,
      'identity_reserved', v_identity_reserved
    );
  END IF;

  IF p_requested_handle IS NOT NULL AND btrim(p_requested_handle) <> '' THEN
    v_normalized_handle := public.fangeo_normalize_handle(p_requested_handle);
    IF v_normalized_handle IS NULL OR NOT public.fangeo_handle_is_valid(v_normalized_handle) THEN
      RETURN jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', 'invalid_handle',
        'message', 'Handle must be 3-20 characters and use letters, numbers, underscores, or periods.',
        'business_id', p_business_id,
        'owner_user_id', p_business.owner_user_id,
        'original_owner_email', v_original_email,
        'auth_user_exists', true,
        'identity_reserved', v_identity_reserved
      );
    END IF;

    IF NOT public.gameon_business_reactivation_handle_is_available(p_business_id, v_normalized_handle) THEN
      RETURN jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', 'handle_conflict',
        'message', 'That business handle is already in use.',
        'business_id', p_business_id,
        'owner_user_id', p_business.owner_user_id,
        'original_owner_email', v_original_email,
        'auth_user_exists', true,
        'identity_reserved', v_identity_reserved
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
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
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Eligibility preview RPC
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
    RETURN jsonb_build_object(
      'ok', true,
      'eligible', false,
      'block_reason', 'invalid_business_id',
      'message', 'A valid business id is required.'
    );
  END IF;

  SELECT * INTO v_business
  FROM public.businesses b
  WHERE b.id = p_business_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', true,
      'eligible', false,
      'block_reason', 'business_not_found',
      'message', 'Business not found.'
    );
  END IF;

  IF to_regclass('public.account_identities') IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'eligible', false,
      'block_reason', 'identity_table_missing',
      'message', 'account_identities table is unavailable.'
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
-- 5. Reactivation mutation RPC
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_reactivate_deleted_business(
  p_business_id uuid,
  p_display_name text,
  p_reason text,
  p_admin_email text,
  p_confirmation text,
  p_business_handle text DEFAULT NULL
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
  v_handle_input text := nullif(btrim(coalesce(p_business_handle, '')), '');
  v_normalized_handle text;
  v_eligibility jsonb;
  v_business public.businesses%ROWTYPE;
  v_identity public.account_identities%ROWTYPE;
  v_job public.business_account_deletion_jobs;
  v_audit public.business_account_deletion_audit;
  v_prior_event public.business_reactivation_events;
  v_before jsonb;
  v_after jsonb;
  v_original_email text;
  v_original_source text;
  v_event_id uuid;
  v_now timestamptz := now();
BEGIN
  PERFORM public.gameon_business_reactivation_assert_service_role();

  IF p_business_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_business_id', 'message', 'A valid business id is required.');
  END IF;

  IF NOT public.gameon_business_reactivation_confirmation_matches(p_business_id, p_confirmation) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'confirmation_mismatch',
      'message', format('Confirmation must be exactly: REACTIVATE BUSINESS %s', lower(p_business_id::text))
    );
  END IF;

  IF char_length(v_display_name) < 1 OR char_length(v_display_name) > 120 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_display_name', 'message', 'Display name must be between 1 and 120 characters.');
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

  SELECT * INTO v_business
  FROM public.businesses b
  WHERE b.id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'business_not_found', 'message', 'Business not found.');
  END IF;

  IF v_business.owner_user_id IS NOT NULL THEN
    SELECT * INTO v_identity
    FROM public.account_identities ai
    WHERE ai.account_id = v_business.owner_user_id
    FOR UPDATE;
  END IF;

  IF NOT FOUND THEN
    v_identity.account_id := NULL;
  END IF;

  SELECT * INTO v_audit
  FROM public.business_account_deletion_audit a
  WHERE a.business_id = p_business_id
    AND a.deletion_mode = 'soft'
  ORDER BY a.deleted_at DESC NULLS LAST, a.id DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    v_audit.id := NULL;
  END IF;

  v_job := public.gameon_business_reactivation_latest_deletion_job(p_business_id);
  v_prior_event := public.gameon_business_reactivation_find_prior_event(p_business_id, v_job.id);

  IF v_prior_event.id IS NOT NULL
     AND coalesce(v_business.is_deleted, false) = false
     AND NOT public.gameon_business_reactivation_is_tombstone_business_email(v_business.owner_email) THEN
    RETURN jsonb_build_object(
      'ok', true,
      'idempotent', true,
      'result', 'already_reactivated',
      'message', 'This deleted business was already reactivated for this deletion job.',
      'business_id', p_business_id,
      'owner_user_id', v_business.owner_user_id,
      'reactivation_event_id', v_prior_event.id,
      'restored_owner_email', v_prior_event.original_owner_email,
      'display_name', v_business.display_name,
      'business_handle', v_business.business_handle
    );
  END IF;

  v_eligibility := public.gameon_business_reactivation_evaluate_eligibility(
    p_business_id,
    v_business,
    v_identity,
    v_job,
    v_audit,
    v_normalized_handle
  );

  IF coalesce(v_eligibility ->> 'idempotent', 'false') = 'true' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'idempotent', true,
      'result', 'already_active',
      'message', 'This business is already active.',
      'business_id', p_business_id,
      'owner_user_id', v_business.owner_user_id
    );
  END IF;

  IF coalesce(v_eligibility ->> 'eligible', 'false') <> 'true' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', coalesce(v_eligibility ->> 'block_reason', 'not_eligible'),
      'message', coalesce(v_eligibility ->> 'message', 'This business is not eligible for reactivation.'),
      'eligibility', v_eligibility
    );
  END IF;

  v_original_email := lower(btrim(v_eligibility ->> 'original_owner_email'));
  v_original_source := v_eligibility ->> 'original_owner_email_source';

  IF lower(btrim(coalesce(v_identity.email, ''))) IS DISTINCT FROM v_original_email THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'email_identity_conflict',
      'message', 'The reserved business identity email changed during reactivation.'
    );
  END IF;

  v_before := to_jsonb(v_business);

  PERFORM set_config('gameon.business_account_reactivation_restore', p_business_id::text, true);

  UPDATE public.businesses b
  SET
    display_name = v_display_name,
    business_handle = v_normalized_handle,
    owner_email = v_original_email,
    is_deleted = false,
    deleted_at = NULL,
    anonymized_at = NULL,
    deletion_requested_at = NULL,
    admin_status = 'active',
    plan_type = 'free',
    plan_status = 'expired',
    pro_expires_at = NULL,
    statistics_enabled = false,
    sponsored_enabled = false,
    unlimited_venues = false,
    unlimited_hosting = false,
    venue_limit = 5,
    monthly_host_limit = 5,
    entitlement_updated_at = v_now,
    admin_pro_promo_starts_at = NULL,
    admin_pro_promo_ends_at = NULL,
    admin_pro_promo_reason = NULL,
    admin_pro_promo_batch_id = NULL,
    admin_pro_promo_updated_at = NULL,
    admin_pro_promo_updated_by = NULL,
    admin_active_venue_limit_override = NULL,
    updated_at = v_now
  WHERE b.id = p_business_id;

  SELECT * INTO v_business
  FROM public.businesses b
  WHERE b.id = p_business_id;

  v_after := to_jsonb(v_business);

  INSERT INTO public.business_reactivation_events (
    business_id,
    owner_user_id,
    deletion_job_id,
    deletion_audit_id,
    admin_email,
    reason,
    original_owner_email,
    display_name,
    business_handle,
    prior_business_state,
    data_not_restored
  ) VALUES (
    p_business_id,
    v_business.owner_user_id,
    v_job.id,
    v_audit.id,
    v_admin_email,
    v_reason,
    v_original_email,
    v_display_name,
    v_normalized_handle,
    v_before,
    public.gameon_business_reactivation_data_not_restored()
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
    'reactivate_deleted_business',
    'business',
    p_business_id::text,
    jsonb_build_object(
      'business', v_before,
      'deletion_job_id', v_job.id,
      'deletion_job_status', v_job.status,
      'deletion_audit_id', v_audit.id,
      'original_owner_email_source', v_original_source
    ),
    jsonb_build_object(
      'business', v_after,
      'reactivation_event_id', v_event_id,
      'restored_owner_email', v_original_email,
      'display_name', v_display_name,
      'business_handle', v_normalized_handle,
      'data_not_restored', public.gameon_business_reactivation_data_not_restored()
    ),
    v_reason
  );

  RETURN jsonb_build_object(
    'ok', true,
    'idempotent', false,
    'result', 'reactivated',
    'message', 'Deleted business reactivated with a fresh profile shell.',
    'business_id', p_business_id,
    'owner_user_id', v_business.owner_user_id,
    'reactivation_event_id', v_event_id,
    'restored_owner_email', v_original_email,
    'display_name', v_display_name,
    'business_handle', v_normalized_handle,
    'deletion_job_id', v_job.id,
    'deletion_audit_id', v_audit.id,
    'data_not_restored', public.gameon_business_reactivation_data_not_restored()
  );
EXCEPTION
  WHEN unique_violation THEN
    IF v_normalized_handle IS NOT NULL THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', 'handle_conflict',
        'message', 'That business handle is already in use.'
      );
    END IF;

    RETURN jsonb_build_object(
      'ok', false,
      'error', 'owner_email_conflict',
      'message', 'The restored owner email conflicts with another business identity constraint.'
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. Identity guard: transaction-local reactivation bypass
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.enforce_business_account_identity_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_auth_email text;
  v_owner_email text := lower(btrim(coalesce(NEW.owner_email, '')));
  v_identity_email text;
  v_deletion_bypass text := nullif(btrim(current_setting('gameon.business_account_deletion_anonymize', true)), '');
  v_reactivation_bypass text := nullif(btrim(current_setting('gameon.business_account_reactivation_restore', true)), '');
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.owner_user_id IS NOT NULL AND NEW.owner_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Business owner auth user mismatch.' USING ERRCODE = '42501';
  END IF;

  IF v_reactivation_bypass IS NOT NULL
     AND TG_OP = 'UPDATE'
     AND NEW.id::text = v_reactivation_bypass
     AND coalesce(OLD.is_deleted, false) = true
     AND coalesce(NEW.is_deleted, false) = false
     AND NEW.owner_user_id IS NOT DISTINCT FROM OLD.owner_user_id
  THEN
    SELECT lower(btrim(coalesce(ai.email, '')))
      INTO v_identity_email
    FROM public.account_identities ai
    WHERE ai.account_id = NEW.owner_user_id
      AND ai.account_type = 'business'
    LIMIT 1;

    IF v_identity_email IS NULL OR v_identity_email = '' THEN
      RAISE EXCEPTION 'Business reactivation requires a reserved business account identity.' USING ERRCODE = '42501';
    END IF;

    IF v_owner_email IS DISTINCT FROM v_identity_email THEN
      RAISE EXCEPTION 'Business reactivation owner email must match the reserved account identity email.' USING ERRCODE = '42501';
    END IF;

    IF public.gameon_business_reactivation_is_tombstone_business_email(v_owner_email) THEN
      RAISE EXCEPTION 'Business reactivation owner email cannot remain a tombstone email.' USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
  END IF;

  IF v_deletion_bypass IS NOT NULL
     AND NEW.id::text = v_deletion_bypass
     AND coalesce(NEW.is_deleted, false)
     AND v_owner_email = lower(btrim(public.gameon_business_deletion_tombstone_email(NEW.id)))
  THEN
    RETURN NEW;
  END IF;

  SELECT lower(btrim(coalesce(email, '')))
    INTO v_auth_email
  FROM auth.users
  WHERE id = auth.uid();

  IF v_owner_email <> '' AND v_owner_email <> v_auth_email THEN
    RAISE EXCEPTION 'Business owner email must match the authenticated user email.' USING ERRCODE = '42501';
  END IF;

  PERFORM set_config('fangeo.allow_fan_to_business_identity_upgrade', 'true', true);
  PERFORM public.claim_account_type('business');
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.enforce_business_account_identity_guard() IS
  'BEFORE INSERT/UPDATE guard for businesses.owner_user_id and owner_email. Allows Phase 2 deletion tombstone rewrite via gameon.business_account_deletion_anonymize and admin reactivation restore via gameon.business_account_reactivation_restore.';

-- ---------------------------------------------------------------------------
-- 7. Grants: hardened service_role-only pattern
-- ---------------------------------------------------------------------------

REVOKE ALL ON TABLE public.business_reactivation_events FROM PUBLIC;
REVOKE ALL ON TABLE public.business_reactivation_events FROM anon;
REVOKE ALL ON TABLE public.business_reactivation_events FROM authenticated;
REVOKE ALL ON TABLE public.business_reactivation_events FROM service_role;
GRANT SELECT, INSERT ON TABLE public.business_reactivation_events TO service_role;

DO $$
DECLARE
  v_fn regprocedure;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    'public.gameon_business_reactivation_assert_service_role()'::regprocedure,
    'public.gameon_business_reactivation_data_not_restored()'::regprocedure,
    'public.gameon_business_reactivation_is_tombstone_business_email(text)'::regprocedure,
    'public.gameon_business_reactivation_latest_deletion_job(uuid)'::regprocedure,
    'public.gameon_business_reactivation_latest_soft_audit(uuid)'::regprocedure,
    'public.gameon_business_reactivation_latest_job_block_reason(public.business_account_deletion_jobs)'::regprocedure,
    'public.gameon_business_reactivation_resolve_original_identity(uuid,public.business_account_deletion_audit)'::regprocedure,
    'public.gameon_business_reactivation_has_active_business_ban(uuid,uuid,text)'::regprocedure,
    'public.gameon_business_reactivation_has_active_user_ban(uuid)'::regprocedure,
    'public.gameon_business_reactivation_auth_user_is_banned(uuid)'::regprocedure,
    'public.gameon_business_reactivation_is_moderation_disabled(public.businesses)'::regprocedure,
    'public.gameon_business_reactivation_handle_is_available(uuid,text)'::regprocedure,
    'public.gameon_business_reactivation_find_prior_event(uuid,uuid)'::regprocedure,
    'public.gameon_business_reactivation_confirmation_matches(uuid,text)'::regprocedure,
    'public.gameon_business_reactivation_evaluate_eligibility(uuid,public.businesses,public.account_identities,public.business_account_deletion_jobs,public.business_account_deletion_audit,text)'::regprocedure,
    'public.admin_reactivate_deleted_business_eligibility(uuid)'::regprocedure,
    'public.admin_reactivate_deleted_business(uuid,text,text,text,text,text)'::regprocedure,
    'public.gameon_business_reactivation_events_immutable()'::regprocedure
  ]
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', v_fn);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', v_fn);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM authenticated', v_fn);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM service_role', v_fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', v_fn);
  END LOOP;
END;
$$;

COMMENT ON FUNCTION public.admin_reactivate_deleted_business_eligibility(uuid) IS
  'Admin read-only eligibility preview for reactivating a Phase 2 tombstoned business shell. service_role only.';

COMMENT ON FUNCTION public.admin_reactivate_deleted_business(uuid, text, text, text, text, text) IS
  'Admin recovery: restore login-capable business shell on the tombstoned businesses row without recovering deleted private data. Parameter order: (p_business_id, p_display_name, p_reason, p_admin_email, p_confirmation, p_business_handle default null). Requires deletion job status = completed. service_role only.';

-- ---------------------------------------------------------------------------
-- 8. Post-apply integrity checks
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_reactivate_def text;
  v_guard_body text;
  v_generated_count integer;
  v_fn regprocedure;
BEGIN
  IF to_regclass('public.business_reactivation_events') IS NULL THEN
    RAISE EXCEPTION 'FAIL: business_reactivation_events table missing';
  END IF;

  IF to_regprocedure('public.admin_reactivate_deleted_business(uuid,text,text,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: admin_reactivate_deleted_business missing';
  END IF;

  IF to_regprocedure('public.admin_reactivate_deleted_business_eligibility(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: admin_reactivate_deleted_business_eligibility missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'business_reactivation_events'
      AND c.relrowsecurity
  ) THEN
    RAISE EXCEPTION 'FAIL: business_reactivation_events RLS not enabled';
  END IF;

  IF has_table_privilege('anon', 'public.business_reactivation_events', 'INSERT')
     OR has_table_privilege('anon', 'public.business_reactivation_events', 'UPDATE')
     OR has_table_privilege('anon', 'public.business_reactivation_events', 'DELETE') THEN
    RAISE EXCEPTION 'FAIL: anon has write privileges on business_reactivation_events';
  END IF;

  IF has_table_privilege('authenticated', 'public.business_reactivation_events', 'INSERT')
     OR has_table_privilege('authenticated', 'public.business_reactivation_events', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.business_reactivation_events', 'DELETE') THEN
    RAISE EXCEPTION 'FAIL: authenticated has write privileges on business_reactivation_events';
  END IF;

  SELECT count(*)::integer
    INTO v_generated_count
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'businesses'
    AND is_generated = 'ALWAYS';

  IF v_generated_count > 0 THEN
    RAISE NOTICE 'INFO: public.businesses has % GENERATED ALWAYS column(s); reactivation must not assign them directly.', v_generated_count;
  END IF;

  SELECT pg_get_functiondef('public.admin_reactivate_deleted_business(uuid,text,text,text,text,text)'::regprocedure)
    INTO v_reactivate_def;

  IF position('gameon_business_reactivation_assert_service_role' IN v_reactivate_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: admin_reactivate_deleted_business missing in-function service_role assertion';
  END IF;

  IF position('gameon.business_account_reactivation_restore' IN v_reactivate_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: admin_reactivate_deleted_business missing identity-guard bypass GUC';
  END IF;

  IF position('storage_finalization_pending' IN pg_get_functiondef('public.gameon_business_reactivation_latest_job_block_reason(public.business_account_deletion_jobs)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'FAIL: deletion job policy must block db_committed before completed';
  END IF;

  FOREACH v_fn IN ARRAY ARRAY[
    'public.admin_reactivate_deleted_business(uuid,text,text,text,text,text)'::regprocedure,
    'public.admin_reactivate_deleted_business_eligibility(uuid)'::regprocedure
  ]
  LOOP
    IF has_function_privilege('authenticated', v_fn, 'EXECUTE') THEN
      RAISE EXCEPTION 'FAIL: authenticated can EXECUTE %', v_fn;
    END IF;

    IF has_function_privilege('anon', v_fn, 'EXECUTE') THEN
      RAISE EXCEPTION 'FAIL: anon can EXECUTE %', v_fn;
    END IF;

    IF NOT has_function_privilege('service_role', v_fn, 'EXECUTE') THEN
      RAISE EXCEPTION 'FAIL: service_role cannot EXECUTE %', v_fn;
    END IF;
  END LOOP;

  SELECT pg_get_functiondef('public.enforce_business_account_identity_guard()'::regprocedure)
    INTO v_guard_body;

  IF v_guard_body NOT ILIKE '%gameon.business_account_reactivation_restore%' THEN
    RAISE EXCEPTION 'FAIL: identity guard must read gameon.business_account_reactivation_restore';
  END IF;

  IF v_guard_body NOT ILIKE '%gameon.business_account_deletion_anonymize%' THEN
    RAISE EXCEPTION 'FAIL: identity guard must retain gameon.business_account_deletion_anonymize bypass';
  END IF;

  IF v_guard_body NOT ILIKE '%OLD.is_deleted%'
     OR v_guard_body NOT ILIKE '%NEW.is_deleted%' THEN
    RAISE EXCEPTION 'FAIL: identity guard reactivation bypass must require deleted to active transition';
  END IF;

  RAISE NOTICE 'PASS: admin reactivate deleted business migration integrity checks';
END;
$$;
