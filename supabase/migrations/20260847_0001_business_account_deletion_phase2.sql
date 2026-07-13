-- Business account self-service deletion Phase 2.
-- Replaces hard-delete cascade semantics with tombstoned business lifecycle, archived venues,
-- preserved completed event history, job tracking, and immutable audit.
--
-- Does NOT modify fan account_deletion_jobs / fan reactivation.
-- Supersedes runtime behavior of delete_business_account_cascade (20260731_0035) without
-- editing that migration file.

-- ---------------------------------------------------------------------------
-- 1. Business tombstone columns (Model A)
-- ---------------------------------------------------------------------------

ALTER TABLE public.businesses
  ADD COLUMN IF NOT EXISTS is_deleted boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS anonymized_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS deletion_requested_at timestamptz NULL;

COMMENT ON COLUMN public.businesses.is_deleted IS
  'Self-service deletion tombstone. Distinct from admin_status archived/disabled.';
COMMENT ON COLUMN public.businesses.deleted_at IS
  'When the business row was tombstoned by self-service deletion.';
COMMENT ON COLUMN public.businesses.anonymized_at IS
  'When public business identity fields were scrubbed during self-service deletion.';
COMMENT ON COLUMN public.businesses.deletion_requested_at IS
  'First self-service deletion request timestamp (job start or cascade entry).';

CREATE INDEX IF NOT EXISTS idx_businesses_is_deleted
  ON public.businesses (is_deleted)
  WHERE is_deleted = true;

CREATE INDEX IF NOT EXISTS idx_businesses_owner_user_id_not_deleted
  ON public.businesses (owner_user_id)
  WHERE coalesce(is_deleted, false) = false
    AND owner_user_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. Deletion audit extensions
-- ---------------------------------------------------------------------------

ALTER TABLE public.business_account_deletion_audit
  ADD COLUMN IF NOT EXISTS deletion_job_id uuid NULL,
  ADD COLUMN IF NOT EXISTS archived_venue_ids uuid[] NOT NULL DEFAULT ARRAY[]::uuid[];

-- deletion_mode: nullable add -> backfill legacy hard -> default soft -> NOT NULL.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'business_account_deletion_audit'
      AND column_name = 'deletion_mode'
  ) THEN
    ALTER TABLE public.business_account_deletion_audit
      ADD COLUMN deletion_mode text NULL;
  END IF;
END;
$$;

UPDATE public.business_account_deletion_audit
SET deletion_mode = 'hard'
WHERE deletion_mode IS NULL;

ALTER TABLE public.business_account_deletion_audit
  ALTER COLUMN deletion_mode SET DEFAULT 'soft';

ALTER TABLE public.business_account_deletion_audit
  ALTER COLUMN deletion_mode SET NOT NULL;

ALTER TABLE public.business_account_deletion_audit
  DROP CONSTRAINT IF EXISTS business_account_deletion_audit_deletion_mode_check;

ALTER TABLE public.business_account_deletion_audit
  ADD CONSTRAINT business_account_deletion_audit_deletion_mode_check
  CHECK (deletion_mode IN ('soft', 'hard'));

COMMENT ON COLUMN public.business_account_deletion_audit.deletion_mode IS
  'hard = legacy self-service cascade (row removed); soft = Phase 2 tombstone lifecycle.';

CREATE INDEX IF NOT EXISTS idx_business_account_deletion_audit_job_id
  ON public.business_account_deletion_audit (deletion_job_id)
  WHERE deletion_job_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 3. Business deletion jobs (separate from fan account_deletion_jobs)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.business_account_deletion_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_business_id uuid NOT NULL,
  subject_user_id uuid NOT NULL,
  requested_by_user_id uuid NULL,
  request_source text NOT NULL DEFAULT 'self_service'
    CHECK (request_source IN ('self_service', 'admin', 'system')),
  deletion_mode text NOT NULL DEFAULT 'soft'
    CHECK (deletion_mode IN ('soft', 'hard')),
  status text NOT NULL DEFAULT 'queued'
    CHECK (status IN (
      'queued', 'previewed', 'running', 'db_committed',
      'storage_pending', 'completed', 'failed', 'cancelled'
    )),
  stage text NOT NULL DEFAULT 'init',
  idempotency_key text NOT NULL,
  preview_snapshot jsonb NULL,
  affected_counts jsonb NOT NULL DEFAULT '{}'::jsonb,
  storage_paths text[] NOT NULL DEFAULT ARRAY[]::text[],
  block_reason text NULL,
  error_code text NULL,
  error_detail text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz NULL,
  CONSTRAINT business_account_deletion_jobs_idempotency_unique UNIQUE (idempotency_key),
  CONSTRAINT business_account_deletion_jobs_subject_business_check
    CHECK (subject_business_id IS NOT NULL)
);

CREATE UNIQUE INDEX IF NOT EXISTS business_account_deletion_jobs_one_active_per_business
  ON public.business_account_deletion_jobs (subject_business_id)
  WHERE status IN (
    'queued', 'previewed', 'running', 'db_committed', 'storage_pending'
  );

CREATE INDEX IF NOT EXISTS idx_business_account_deletion_jobs_status_updated
  ON public.business_account_deletion_jobs (status, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_business_account_deletion_jobs_business_created
  ON public.business_account_deletion_jobs (subject_business_id, created_at DESC);

COMMENT ON TABLE public.business_account_deletion_jobs IS
  'Tracks business self-service soft-deletion jobs. Preserves auth.users and account_identities.';

CREATE OR REPLACE FUNCTION public.business_account_deletion_jobs_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS business_account_deletion_jobs_touch_updated_at_bu
  ON public.business_account_deletion_jobs;
CREATE TRIGGER business_account_deletion_jobs_touch_updated_at_bu
  BEFORE UPDATE ON public.business_account_deletion_jobs
  FOR EACH ROW
  EXECUTE FUNCTION public.business_account_deletion_jobs_touch_updated_at();

ALTER TABLE public.business_account_deletion_jobs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS business_account_deletion_jobs_select_own
  ON public.business_account_deletion_jobs;
CREATE POLICY business_account_deletion_jobs_select_own
  ON public.business_account_deletion_jobs
  FOR SELECT
  TO authenticated
  USING (subject_user_id = (SELECT auth.uid()));

GRANT SELECT ON public.business_account_deletion_jobs TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.business_account_deletion_jobs TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Internal helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gameon_business_deletion_is_service_caller()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    nullif(btrim(current_setting('request.jwt.claim.role', true)), ''),
    nullif(btrim(coalesce(auth.jwt() ->> 'role', '')), ''),
    ''
  ) = 'service_role';
$$;

CREATE OR REPLACE FUNCTION public.gameon_business_deletion_tombstone_email(p_business_id uuid)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT format(
    'deleted-business-%s@deleted.fangeo.local',
    replace(lower(p_business_id::text), '-', '')
  );
$$;

CREATE OR REPLACE FUNCTION public.gameon_business_deletion_event_is_completed(
  p_scheduled_start_at timestamptz,
  p_event_date date,
  p_admin_status text
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT CASE
    WHEN p_scheduled_start_at IS NOT NULL
         AND p_scheduled_start_at < (now() - interval '3 hours')
      THEN true
    WHEN p_event_date IS NOT NULL
         AND p_event_date < current_date
      THEN true
    WHEN lower(btrim(coalesce(p_admin_status, ''))) IN ('archived', 'completed')
         AND (
           p_scheduled_start_at IS NULL
           OR p_scheduled_start_at < (now() - interval '3 hours')
           OR (p_event_date IS NOT NULL AND p_event_date < current_date)
         )
      THEN true
    ELSE false
  END;
$$;

CREATE OR REPLACE FUNCTION public.gameon_business_deletion_assert_owner(p_business_id uuid)
RETURNS public.businesses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_email text := lower(btrim(coalesce(auth.jwt() ->> 'email', '')));
  v_business public.businesses%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated'
      USING ERRCODE = '28000';
  END IF;

  IF v_email = '' THEN
    SELECT lower(btrim(coalesce(u.email, '')))
      INTO v_email
    FROM auth.users u
    WHERE u.id = v_uid;
  END IF;

  SELECT *
    INTO v_business
  FROM public.businesses b
  WHERE b.id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business not found: %', p_business_id
      USING ERRCODE = 'P0002';
  END IF;

  IF NOT (
    (v_business.owner_user_id IS NOT NULL AND v_business.owner_user_id = v_uid)
    OR (
      v_email <> ''
      AND lower(btrim(coalesce(v_business.owner_email, ''))) = v_email
    )
  ) THEN
    RAISE EXCEPTION 'Not authorized for business deletion: %', p_business_id
      USING ERRCODE = '42501';
  END IF;

  RETURN v_business;
END;
$$;

CREATE OR REPLACE FUNCTION public.gameon_business_deletion_block_reason(p_business_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_business public.businesses%ROWTYPE;
BEGIN
  SELECT *
    INTO v_business
  FROM public.businesses b
  WHERE b.id = p_business_id;

  IF NOT FOUND THEN
    RETURN 'business_not_found';
  END IF;

  IF coalesce(v_business.is_deleted, false) THEN
    RETURN 'already_deleted';
  END IF;

  IF lower(btrim(coalesce(v_business.admin_status, ''))) = 'disabled' THEN
    -- Administrative disable blocks self-service deletion (distinct from moderation bans).
    RETURN 'business_disabled';
  END IF;

  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.gameon_business_deletion_collect_venue_storage_paths(
  p_venue_ids uuid[]
)
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(array_agg(DISTINCT storage.path), ARRAY[]::text[])
  FROM public.venues v
  CROSS JOIN LATERAL unnest(ARRAY[
    public.gameon_storage_path_from_public_url(v.cover_photo_url, 'venue-photos'),
    public.gameon_storage_path_from_public_url(v.menu_photo_url, 'venue-photos'),
    public.gameon_storage_path_from_public_url(v.cover_photo_thumbnail_url, 'venue-photos'),
    public.gameon_storage_path_from_public_url(v.menu_photo_thumbnail_url, 'venue-photos')
  ]) AS storage(path)
  WHERE v.id = ANY(p_venue_ids)
    AND storage.path IS NOT NULL
    AND btrim(storage.path) <> '';
$$;

CREATE OR REPLACE FUNCTION public.gameon_business_deletion_moderation_snapshot(
  p_business_id uuid,
  p_owner_user_id uuid
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'business_admin_status', (
      SELECT b.admin_status
      FROM public.businesses b
      WHERE b.id = p_business_id
    ),
    'active_business_bans', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', bb.id,
          'reason', bb.reason,
          'is_permanent', bb.is_permanent,
          'banned_until', bb.banned_until,
          'lifted_at', bb.lifted_at
        )
        ORDER BY bb.created_at DESC
      )
      FROM public.business_bans bb
      WHERE bb.business_id = p_business_id
        AND bb.lifted_at IS NULL
        AND (
          bb.is_permanent
          OR bb.banned_until IS NULL
          OR bb.banned_until > now()
        )
    ), '[]'::jsonb),
    'active_user_bans', CASE
      WHEN p_owner_user_id IS NULL THEN '[]'::jsonb
      ELSE coalesce((
        SELECT jsonb_agg(
          jsonb_build_object(
            'id', ub.id,
            'reason', ub.reason,
            'expires_at', ub.expires_at,
            'lifted_at', ub.lifted_at
          )
          ORDER BY ub.created_at DESC
        )
        FROM public.user_bans ub
        WHERE ub.user_id = p_owner_user_id
          AND ub.lifted_at IS NULL
          AND (ub.expires_at IS NULL OR ub.expires_at > now())
      ), '[]'::jsonb)
    END,
    'deletion_allowed_despite_bans', true,
    'reactivation_note', 'Active bans must be resolved before future admin reactivation.'
  );
$$;

CREATE OR REPLACE FUNCTION public.gameon_business_deletion_resolve_scope(
  p_business_id uuid,
  p_owner_user_id uuid,
  p_owner_email text
)
RETURNS TABLE (
  target_venue_ids uuid[],
  business_venue_ids uuid[],
  community_venue_ids uuid[],
  claim_scope_ids uuid[],
  pending_claim_ids uuid[]
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner_email text := lower(btrim(coalesce(p_owner_email, '')));
  v_owner_user_id_text text := coalesce(p_owner_user_id::text, '');
  v_claim_scope_ids uuid[] := ARRAY[]::uuid[];
  v_claim_scope_id_texts text[] := ARRAY[]::text[];
  v_target_venue_ids uuid[] := ARRAY[]::uuid[];
  v_business_venue_ids uuid[] := ARRAY[]::uuid[];
  v_community_venue_ids uuid[] := ARRAY[]::uuid[];
  v_pending_claim_ids uuid[] := ARRAY[]::uuid[];
BEGIN
  SELECT coalesce(array_agg(DISTINCT vc.id), ARRAY[]::uuid[])
    INTO v_claim_scope_ids
  FROM public.venue_claims vc
  WHERE vc.business_id = p_business_id
     OR (v_owner_email <> '' AND lower(btrim(coalesce(vc.owner_email, ''))) = v_owner_email)
     OR (
       v_owner_user_id_text <> ''
       AND EXISTS (
         SELECT 1
         FROM public.venues v
         WHERE v.id = vc.venue_id
           AND v.owner_user_id::text = v_owner_user_id_text
       )
     );
  v_claim_scope_id_texts := ARRAY(SELECT unnest(v_claim_scope_ids)::text);

  SELECT coalesce(array_agg(DISTINCT vc.id), ARRAY[]::uuid[])
    INTO v_pending_claim_ids
  FROM public.venue_claims vc
  WHERE vc.id::text = ANY(v_claim_scope_id_texts)
    AND public.gameon_venue_claim_is_open_pending(vc.approval_status);

  SELECT coalesce(array_agg(DISTINCT target_id), ARRAY[]::uuid[])
    INTO v_target_venue_ids
  FROM (
    SELECT v.id AS target_id
    FROM public.venues v
    WHERE v.business_id = p_business_id
       OR (
         v.business_id IS NULL
         AND p_owner_user_id IS NOT NULL
         AND v.owner_user_id = p_owner_user_id
       )
       OR (
         v.business_id IS NULL
         AND v_owner_email <> ''
         AND lower(btrim(coalesce(v.owner_email, ''))) = v_owner_email
       )
       OR EXISTS (
         SELECT 1
         FROM public.venue_claims vc
         WHERE vc.venue_id = v.id
           AND vc.id::text = ANY(v_claim_scope_id_texts)
           AND lower(btrim(coalesce(vc.approval_status, ''))) = 'approved'
       )
       OR v.id IN (
         SELECT vc.venue_id
         FROM public.venue_claims vc
         WHERE vc.id = ANY(v_pending_claim_ids)
           AND vc.venue_id IS NOT NULL
       )
  ) scoped;

  SELECT coalesce(array_agg(id), ARRAY[]::uuid[])
    INTO v_business_venue_ids
  FROM public.venues v
  WHERE v.id = ANY(v_target_venue_ids)
    AND lower(btrim(coalesce(v.origin_type, 'business'))) <> 'community';

  SELECT coalesce(array_agg(id), ARRAY[]::uuid[])
    INTO v_community_venue_ids
  FROM public.venues v
  WHERE v.id = ANY(v_target_venue_ids)
    AND lower(btrim(coalesce(v.origin_type, 'business'))) = 'community';

  target_venue_ids := v_target_venue_ids;
  business_venue_ids := v_business_venue_ids;
  community_venue_ids := v_community_venue_ids;
  claim_scope_ids := v_claim_scope_ids;
  pending_claim_ids := v_pending_claim_ids;
  RETURN NEXT;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. Core soft-delete (transactional)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gameon_business_deletion_soft_delete_core(
  p_business_id uuid,
  p_job_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_email text := lower(btrim(coalesce(auth.jwt() ->> 'email', '')));
  v_business public.businesses%ROWTYPE;
  v_scope record;
  v_counts jsonb := '{}'::jsonb;
  v_count integer := 0;
  v_storage_paths text[] := ARRAY[]::text[];
  v_archived_event_ids uuid[] := ARRAY[]::uuid[];
  v_archived_event_id_texts text[] := ARRAY[]::text[];
  v_tombstone_email text;
  v_snapshot jsonb;
  v_moderation jsonb;
  v_now timestamptz := now();
BEGIN
  v_business := public.gameon_business_deletion_assert_owner(p_business_id);

  IF coalesce(v_business.is_deleted, false) THEN
    RETURN jsonb_build_object(
      'ok', true,
      'idempotent_replay', true,
      'business_id', p_business_id,
      'deletion_mode', 'soft',
      'archived_venue_ids', ARRAY[]::uuid[],
      'released_venue_ids', ARRAY[]::uuid[],
      'hard_deleted_venue_ids', ARRAY[]::uuid[],
      'archived_event_ids', ARRAY[]::uuid[],
      'deleted_event_ids', ARRAY[]::uuid[],
      'deleted_storage_paths', ARRAY[]::text[],
      'deleted_counts', '{}'::jsonb,
      'storage_finalization_pending', CASE
        WHEN p_job_id IS NOT NULL THEN (
          SELECT j.status IN ('db_committed', 'storage_pending')
          FROM public.business_account_deletion_jobs j
          WHERE j.id = p_job_id
        )
        ELSE false
      END
    );
  END IF;

  -- Administrative disable blocks self-service deletion (distinct from moderation bans).
  IF public.gameon_business_deletion_block_reason(p_business_id) = 'business_disabled' THEN
    RAISE EXCEPTION 'business_disabled'
      USING ERRCODE = 'P0001';
  END IF;

  SELECT *
    INTO v_scope
  FROM public.gameon_business_deletion_resolve_scope(
    p_business_id,
    v_business.owner_user_id,
    v_business.owner_email
  );

  -- Ownership conflict guard (no cross-business venue mutation).
  IF EXISTS (
    SELECT 1
    FROM public.venues v
    WHERE v.id = ANY(v_scope.target_venue_ids)
      AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active'
      AND (
        (v.business_id IS NOT NULL AND v.business_id <> p_business_id)
        OR (
          v.business_id IS NULL
          AND btrim(coalesce(v.owner_email, '')) <> ''
          AND lower(btrim(v.owner_email)) <> lower(btrim(coalesce(v_business.owner_email, '')))
        )
      )
  ) THEN
    RAISE EXCEPTION 'duplicate_venue_other_business'
      USING ERRCODE = 'P0001';
  END IF;

  v_snapshot := to_jsonb(v_business);
  v_moderation := public.gameon_business_deletion_moderation_snapshot(
    p_business_id,
    v_business.owner_user_id
  );
  v_snapshot := v_snapshot || jsonb_build_object('moderation_snapshot', v_moderation);

  v_storage_paths := public.gameon_business_deletion_collect_venue_storage_paths(
    v_scope.business_venue_ids || v_scope.community_venue_ids
  );

  -- Future/live events: archive (completed events preserved read-only).
  WITH future_events AS (
    SELECT ve.id
    FROM public.venue_events ve
    WHERE ve.venue_id = ANY(v_scope.target_venue_ids)
      AND NOT public.gameon_business_deletion_event_is_completed(
        ve.scheduled_start_at,
        ve.event_date,
        ve.admin_status
      )
  )
  UPDATE public.venue_events ve
  SET
    admin_status = 'archived',
    admin_archived_at = v_now,
    admin_archived_by = coalesce(v_email, 'business_self_service_delete'),
    admin_archived_reason = 'business_account_deleted'
  FROM future_events fe
  WHERE ve.id = fe.id
    AND lower(btrim(coalesce(ve.admin_status, 'active'))) IN ('active', 'plan_locked');
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('future_events_archived', v_count);

  SELECT coalesce(array_agg(ve.id), ARRAY[]::uuid[])
    INTO v_archived_event_ids
  FROM public.venue_events ve
  WHERE ve.venue_id = ANY(v_scope.target_venue_ids)
    AND ve.admin_archived_reason = 'business_account_deleted'
    AND ve.admin_archived_at = v_now;
  v_archived_event_id_texts := ARRAY(SELECT unnest(v_archived_event_ids)::text);

  SELECT count(*)::integer
    INTO v_count
  FROM public.venue_events ve
  WHERE ve.venue_id = ANY(v_scope.target_venue_ids)
    AND public.gameon_business_deletion_event_is_completed(
      ve.scheduled_start_at,
      ve.event_date,
      ve.admin_status
    );
  v_counts := v_counts || jsonb_build_object('completed_events_preserved', v_count);

  -- Business-created venues: archive + scrub private media/contact (row retained).
  UPDATE public.venues v
  SET
    admin_status = 'archived',
    admin_archived_at = v_now,
    admin_archived_by = coalesce(v_email, 'business_self_service_delete'),
    admin_archived_reason = 'business_account_deleted',
    phone = '',
    website = '',
    description = '',
    features = '',
    screen_count = NULL,
    serves_food = NULL,
    has_wifi = NULL,
    has_garden = NULL,
    has_projector = NULL,
    pet_friendly = NULL,
    supporter_country = NULL,
    cover_photo_url = '',
    menu_photo_url = '',
    cover_photo_thumbnail_url = NULL,
    menu_photo_thumbnail_url = NULL
  WHERE v.id = ANY(v_scope.business_venue_ids);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('business_venues_archived', v_count);

  -- Community venues: release to unclaimed/community ownership.
  UPDATE public.venues v
  SET
    business_id = NULL,
    owner_user_id = NULL,
    owner_email = NULL,
    phone = '',
    website = '',
    description = '',
    features = '',
    screen_count = NULL,
    serves_food = NULL,
    has_wifi = NULL,
    has_garden = NULL,
    has_projector = NULL,
    pet_friendly = NULL,
    supporter_country = NULL,
    cover_photo_url = '',
    menu_photo_url = '',
    cover_photo_thumbnail_url = NULL,
    menu_photo_thumbnail_url = NULL,
    admin_status = 'active',
    origin_type = 'community'
  WHERE v.id = ANY(v_scope.community_venue_ids);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('community_venues_released', v_count);

  -- Claims lifecycle (history preserved).
  UPDATE public.venue_claims vc
  SET
    approval_status = 'cancelled',
    business_id = NULL,
    owner_email = NULL
  WHERE vc.id = ANY(v_scope.pending_claim_ids)
    AND vc.venue_id = ANY(v_scope.community_venue_ids);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('pending_community_claims_cancelled', v_count);

  UPDATE public.venue_claims vc
  SET
    approval_status = 'released',
    business_id = NULL,
    owner_email = NULL
  WHERE vc.venue_id = ANY(v_scope.community_venue_ids)
    AND lower(btrim(coalesce(vc.approval_status, ''))) = 'approved';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('community_claims_released', v_count);

  UPDATE public.venue_claims vc
  SET
    venue_id = CASE
      WHEN lower(btrim(coalesce(vc.approval_status, ''))) IN ('approved', 'released')
        AND vc.venue_id = ANY(v_scope.community_venue_ids)
        THEN vc.venue_id
      ELSE NULL
    END,
    business_id = NULL,
    owner_email = NULL,
    approval_status = CASE
      WHEN lower(btrim(coalesce(vc.approval_status, ''))) = 'approved' THEN 'released'
      WHEN lower(btrim(coalesce(vc.approval_status, ''))) IN ('released', 'cancelled', 'business_deleted')
        THEN lower(btrim(vc.approval_status))
      ELSE 'business_deleted'
    END
  WHERE vc.id = ANY(v_scope.claim_scope_ids)
     OR vc.business_id = p_business_id;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('claims_cleared', v_count);

  UPDATE public.user_profiles up
  SET home_crowd_venue_id = NULL,
      home_crowd_set_at = NULL
  WHERE up.home_crowd_venue_id = ANY(v_scope.business_venue_ids);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('home_crowd_profiles_unlinked', v_count);

  DELETE FROM public.favorite_venues fv
  WHERE fv.venue_id = ANY(v_scope.business_venue_ids);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('favorite_venues_removed', v_count);

  -- Entitlements + sponsored placements (no automatic restoration on reactivation).
  UPDATE public.sponsored_placements sp
  SET status = 'paused'
  WHERE sp.business_id = p_business_id
    AND sp.status = 'active';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('sponsored_placements_paused', v_count);

  v_tombstone_email := public.gameon_business_deletion_tombstone_email(p_business_id);

  UPDATE public.businesses b
  SET
    is_deleted = true,
    deleted_at = v_now,
    anonymized_at = v_now,
    deletion_requested_at = coalesce(b.deletion_requested_at, v_now),
    display_name = 'Deleted Business',
    business_handle = NULL,
    owner_email = v_tombstone_email,
    plan_type = 'free',
    plan_status = 'expired',
    pro_expires_at = NULL,
    sponsored_enabled = false,
    statistics_enabled = false,
    unlimited_venues = false,
    unlimited_hosting = false,
    entitlement_updated_at = v_now
  WHERE b.id = p_business_id;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('businesses_tombstoned', v_count);

  v_counts := v_counts || jsonb_build_object(
    'auth_users_deleted', 0,
    'account_identities_deleted', 0,
    'moderation_snapshot', v_moderation,
    'business_game_history_preserved', (
      SELECT count(*)::integer
      FROM public.business_game_history bgh
      WHERE bgh.business_id = p_business_id
    )
  );

  IF NOT EXISTS (
    SELECT 1
    FROM public.business_account_deletion_audit a
    WHERE a.business_id = p_business_id
      AND a.deletion_mode = 'soft'
  ) THEN
    INSERT INTO public.business_account_deletion_audit (
      business_id,
      deleted_by,
      deleted_by_email,
      business_snapshot,
      released_venue_ids,
      hard_deleted_venue_ids,
      archived_venue_ids,
      deleted_event_ids,
      deleted_storage_paths,
      deleted_counts,
      deletion_job_id,
      deletion_mode
    )
    VALUES (
      p_business_id,
      v_uid,
      NULLIF(v_email, ''),
      v_snapshot,
      v_scope.community_venue_ids,
      ARRAY[]::uuid[],
      v_scope.business_venue_ids,
      v_archived_event_ids,
      v_storage_paths,
      v_counts,
      p_job_id,
      'soft'
    );
  END IF;

  IF p_job_id IS NOT NULL THEN
    UPDATE public.business_account_deletion_jobs j
    SET
      status = 'db_committed',
      stage = 'awaiting_storage_finalize',
      affected_counts = v_counts,
      storage_paths = v_storage_paths,
      completed_at = NULL
    WHERE j.id = p_job_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'idempotent_replay', false,
    'business_id', p_business_id,
    'business_name', v_snapshot ->> 'display_name',
    'deletion_mode', 'soft',
    'released_venue_ids', v_scope.community_venue_ids,
    'archived_venue_ids', v_scope.business_venue_ids,
    'hard_deleted_venue_ids', ARRAY[]::uuid[],
    'archived_event_ids', v_archived_event_ids,
    'deleted_event_ids', v_archived_event_ids,
    'deleted_storage_paths', v_storage_paths,
    'deleted_counts', v_counts,
    'business_venue_count', cardinality(v_scope.business_venue_ids),
    'community_venue_count', cardinality(v_scope.community_venue_ids),
    'event_count', cardinality(v_archived_event_ids),
    'photo_count', cardinality(v_storage_paths),
    'pending_claim_count', cardinality(v_scope.pending_claim_ids),
    'storage_finalization_pending', true,
    'status', 'db_committed',
    'stage', 'awaiting_storage_finalize'
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. Job RPCs
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.preview_delete_business_account(p_business_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_business public.businesses%ROWTYPE;
  v_scope record;
  v_block text;
  v_future_events integer := 0;
  v_completed_events integer := 0;
BEGIN
  v_business := public.gameon_business_deletion_assert_owner(p_business_id);
  v_block := public.gameon_business_deletion_block_reason(p_business_id);

  IF v_block IS NOT NULL AND v_block <> 'already_deleted' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'blocked', true,
      'block_reason', v_block,
      'business_id', p_business_id
    );
  END IF;

  SELECT *
    INTO v_scope
  FROM public.gameon_business_deletion_resolve_scope(
    p_business_id,
    v_business.owner_user_id,
    v_business.owner_email
  );

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
  WHERE ve.venue_id = ANY(v_scope.target_venue_ids);

  RETURN jsonb_build_object(
    'ok', true,
    'blocked', coalesce(v_business.is_deleted, false),
    'block_reason', CASE WHEN coalesce(v_business.is_deleted, false) THEN 'already_deleted' ELSE NULL END,
    'business_id', p_business_id,
    'business_name', v_business.display_name,
    'deletion_mode', 'soft',
    'business_venues_to_archive', v_scope.business_venue_ids,
    'community_venues_to_release', v_scope.community_venue_ids,
    'pending_claim_ids', v_scope.pending_claim_ids,
    'future_events_to_archive', v_future_events,
    'completed_events_preserved', v_completed_events,
    'auth_users_deleted', false,
    'account_identities_deleted', false,
    'moderation_snapshot', public.gameon_business_deletion_moderation_snapshot(
      p_business_id,
      v_business.owner_user_id
    ),
    'preserved_domains', jsonb_build_array(
      'business_game_history', 'venue_reports', 'comment_reports',
      'support_requests', 'support_conversations', 'business_bans', 'user_bans',
      'admin_audit_logs', 'venue_claims_history', 'completed_venue_events'
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.start_business_account_deletion_job(
  p_idempotency_key text DEFAULT NULL,
  p_business_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_business public.businesses%ROWTYPE;
  v_key text;
  v_existing public.business_account_deletion_jobs%ROWTYPE;
  v_preview jsonb;
  v_block text;
  v_job_id uuid;
BEGIN
  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'p_business_id is required'
      USING ERRCODE = '22023';
  END IF;

  v_business := public.gameon_business_deletion_assert_owner(p_business_id);
  v_block := public.gameon_business_deletion_block_reason(p_business_id);

  IF v_block IS NOT NULL AND v_block NOT IN ('already_deleted') THEN
    RETURN jsonb_build_object(
      'ok', false,
      'blocked', true,
      'block_reason', v_block
    );
  END IF;

  v_key := coalesce(nullif(btrim(p_idempotency_key), ''), 'self:' || p_business_id::text);

  SELECT *
    INTO v_existing
  FROM public.business_account_deletion_jobs j
  WHERE j.idempotency_key = v_key
  LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'ok', true,
      'job_id', v_existing.id,
      'status', v_existing.status,
      'stage', v_existing.stage,
      'reused', true
    );
  END IF;

  SELECT *
    INTO v_existing
  FROM public.business_account_deletion_jobs j
  WHERE j.subject_business_id = p_business_id
    AND j.status IN ('queued', 'previewed', 'running', 'db_committed', 'storage_pending')
  ORDER BY j.created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'ok', true,
      'job_id', v_existing.id,
      'status', v_existing.status,
      'stage', v_existing.stage,
      'reused', true
    );
  END IF;

  v_preview := public.preview_delete_business_account(p_business_id);

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
    v_uid,
    v_uid,
    'self_service',
    'soft',
    'previewed',
    'previewed',
    v_key,
    v_preview
  )
  RETURNING id INTO v_job_id;

  RETURN jsonb_build_object(
    'ok', true,
    'job_id', v_job_id,
    'status', 'previewed',
    'stage', 'previewed',
    'reused', false,
    'preview', v_preview
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.execute_delete_business_account_db(p_job_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_job public.business_account_deletion_jobs%ROWTYPE;
  v_result jsonb;
  v_business_deleted boolean := false;
BEGIN
  SELECT *
    INTO v_job
  FROM public.business_account_deletion_jobs j
  WHERE j.id = p_job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business deletion job not found: %', p_job_id
      USING ERRCODE = 'P0002';
  END IF;

  IF v_job.subject_user_id IS DISTINCT FROM auth.uid()
     AND NOT public.gameon_business_deletion_is_service_caller() THEN
    RAISE EXCEPTION 'Not authorized for business deletion job: %', p_job_id
      USING ERRCODE = '42501';
  END IF;

  SELECT coalesce(b.is_deleted, false)
    INTO v_business_deleted
  FROM public.businesses b
  WHERE b.id = v_job.subject_business_id;

  IF v_job.status = 'completed' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'job_id', v_job.id,
      'status', v_job.status,
      'stage', v_job.stage,
      'idempotent_replay', true,
      'storage_finalization_pending', false
    );
  END IF;

  IF v_job.status IN ('failed', 'cancelled') THEN
    RETURN jsonb_build_object(
      'ok', false,
      'job_id', v_job.id,
      'status', v_job.status,
      'stage', v_job.stage,
      'idempotent_replay', true,
      'error_code', v_job.error_code,
      'error_detail', v_job.error_detail
    );
  END IF;

  -- DB already committed: never rerun profile/venue mutation (storage retry only).
  IF v_job.status IN ('db_committed', 'storage_pending') OR v_business_deleted THEN
    RETURN jsonb_build_object(
      'ok', true,
      'job_id', v_job.id,
      'business_id', v_job.subject_business_id,
      'status', v_job.status,
      'stage', v_job.stage,
      'idempotent_replay', true,
      'storage_finalization_pending', v_job.status IN ('db_committed', 'storage_pending'),
      'deleted_storage_paths', coalesce(v_job.storage_paths, ARRAY[]::text[]),
      'deletion_mode', 'soft'
    );
  END IF;

  UPDATE public.business_account_deletion_jobs
  SET status = 'running',
      stage = 'running'
  WHERE id = p_job_id;

  BEGIN
    v_result := public.gameon_business_deletion_soft_delete_core(v_job.subject_business_id, p_job_id);
  EXCEPTION
    WHEN OTHERS THEN
      UPDATE public.business_account_deletion_jobs
      SET status = 'failed',
          stage = 'failed',
          error_code = SQLSTATE,
          error_detail = SQLERRM,
          completed_at = NULL
      WHERE id = p_job_id;
      RAISE;
  END;

  SELECT *
    INTO v_job
  FROM public.business_account_deletion_jobs j
  WHERE j.id = p_job_id;

  RETURN coalesce(v_result, '{}'::jsonb)
    || jsonb_build_object(
      'job_id', p_job_id,
      'status', v_job.status,
      'stage', v_job.stage,
      'storage_finalization_pending', true
    );
END;
$$;

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
      'idempotent_replay', true
    );
  END IF;

  IF v_action = 'mark_storage_pending' THEN
    UPDATE public.business_account_deletion_jobs
    SET status = 'storage_pending',
        stage = 'storage_cleanup',
        completed_at = NULL
    WHERE id = p_job_id
      AND status IN ('db_committed', 'storage_pending');
  ELSIF v_action = 'mark_completed' THEN
    -- Completion requires confirmed storage finalization (storage_pending only).
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
  ELSIF v_action = 'mark_failed' THEN
    UPDATE public.business_account_deletion_jobs
    SET status = 'failed',
        stage = 'failed',
        error_code = p_error_code,
        error_detail = p_error_detail
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
    'stage', v_job.stage
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.queue_business_account_deletion_finalize(p_job_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_job public.business_account_deletion_jobs%ROWTYPE;
BEGIN
  IF NOT public.gameon_business_deletion_is_service_caller() THEN
    RAISE EXCEPTION 'queue_business_account_deletion_finalize is restricted to service_role'
      USING ERRCODE = '42501';
  END IF;

  IF p_job_id IS NULL THEN
    RETURN jsonb_build_object(
      'queued', false,
      'result', 'failed',
      'detail', 'job_id is required',
      'edge_function_deployed', false,
      'job_mutated', false
    );
  END IF;

  SELECT *
    INTO v_job
  FROM public.business_account_deletion_jobs
  WHERE id = p_job_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'queued', false,
      'result', 'job_not_found',
      'job_id', p_job_id,
      'edge_function_deployed', false,
      'job_mutated', false
    );
  END IF;

  -- Stub only: does not mutate job status/stage/completed_at.
  -- Future finalize-business-account-deletion Edge Function (service_role) must:
  -- 1) read job.storage_paths and delete objects from storage buckets
  -- 2) advance_business_account_deletion_job(job_id, 'mark_storage_pending')
  -- 3) on confirmed cleanup: advance_business_account_deletion_job(job_id, 'mark_completed')
  RETURN jsonb_build_object(
    'queued', false,
    'result', 'edge_function_not_deployed',
    'detail', 'Deploy finalize-business-account-deletion Edge Function; it must call advance_business_account_deletion_job(mark_storage_pending|mark_completed) after storage cleanup.',
    'edge_function_deployed', false,
    'job_mutated', false,
    'job_id', p_job_id,
    'job_status', v_job.status,
    'job_stage', v_job.stage,
    'completed_at', v_job.completed_at,
    'storage_finalization_pending', v_job.status IN ('db_committed', 'storage_pending')
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 7. Backward-compatible RPC replacements
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.business_account_deletion_preview(p_business_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_preview jsonb;
  v_scope record;
  v_business public.businesses%ROWTYPE;
BEGIN
  v_preview := public.preview_delete_business_account(p_business_id);

  IF coalesce((v_preview ->> 'blocked')::boolean, false) THEN
    RETURN v_preview;
  END IF;

  v_business := public.gameon_business_deletion_assert_owner(p_business_id);

  SELECT *
    INTO v_scope
  FROM public.gameon_business_deletion_resolve_scope(
    p_business_id,
    v_business.owner_user_id,
    v_business.owner_email
  );

  RETURN jsonb_build_object(
    'ok', true,
    'business_id', p_business_id,
    'business_name', v_business.display_name,
    'deletion_mode', 'soft',
    'business_venues_to_delete', (
      SELECT coalesce(jsonb_agg(
        jsonb_build_object(
          'id', v.id,
          'venue_name', v.venue_name,
          'origin_type', coalesce(nullif(btrim(v.origin_type), ''), 'business'),
          'label', 'Will be archived and hidden'
        )
        ORDER BY lower(coalesce(v.venue_name, ''))
      ), '[]'::jsonb)
      FROM public.venues v
      WHERE v.id = ANY(v_scope.business_venue_ids)
    ),
    'community_venues_to_release', (
      SELECT coalesce(jsonb_agg(
        jsonb_build_object(
          'id', v.id,
          'venue_name', v.venue_name,
          'origin_type', 'community',
          'label', 'Will be returned to FanGeo community'
        )
        ORDER BY lower(coalesce(v.venue_name, ''))
      ), '[]'::jsonb)
      FROM public.venues v
      WHERE v.id = ANY(v_scope.community_venue_ids)
    ),
    'pending_business_venues_to_delete', '[]'::jsonb,
    'pending_community_claims_to_cancel', (
      SELECT coalesce(jsonb_agg(
        jsonb_build_object(
          'id', vc.id,
          'venue_id', vc.venue_id,
          'venue_name', coalesce(v.venue_name, vc.venue_name, 'Community venue claim'),
          'origin_type', 'community',
          'approval_status', vc.approval_status,
          'label', 'Pending community claim to cancel'
        )
      ), '[]'::jsonb)
      FROM public.venue_claims vc
      LEFT JOIN public.venues v ON v.id = vc.venue_id
      WHERE vc.id = ANY(v_scope.pending_claim_ids)
    ),
    'games_events_to_remove', (
      SELECT coalesce(jsonb_agg(
        jsonb_build_object(
          'id', ve.id,
          'venue_name', v.venue_name,
          'event_title', ve.event_title,
          'sport', ve.sport,
          'league', ve.external_league,
          'event_date', ve.event_date,
          'event_time', ve.event_time,
          'scheduled_start_at', ve.scheduled_start_at,
          'status', ve.admin_status,
          'label', CASE
            WHEN public.gameon_business_deletion_event_is_completed(
              ve.scheduled_start_at, ve.event_date, ve.admin_status
            ) THEN 'Will be preserved (completed)'
            ELSE 'Will be archived'
          END
        )
      ), '[]'::jsonb)
      FROM public.venue_events ve
      LEFT JOIN public.venues v ON v.id = ve.venue_id
      WHERE ve.venue_id = ANY(v_scope.target_venue_ids)
    ),
    'business_venue_count', cardinality(v_scope.business_venue_ids),
    'community_venue_count', cardinality(v_scope.community_venue_ids),
    'event_count', (
      SELECT count(*)::integer
      FROM public.venue_events ve
      WHERE ve.venue_id = ANY(v_scope.target_venue_ids)
        AND NOT public.gameon_business_deletion_event_is_completed(
          ve.scheduled_start_at, ve.event_date, ve.admin_status
        )
    ),
    'photo_count', cardinality(
      public.gameon_business_deletion_collect_venue_storage_paths(
        v_scope.business_venue_ids || v_scope.community_venue_ids
      )
    ),
    'pending_claim_count', cardinality(v_scope.pending_claim_ids),
    'completed_events_preserved', (v_preview ->> 'completed_events_preserved')
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_business_account_cascade(p_business_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_start jsonb;
  v_job_id uuid;
  v_execute jsonb;
BEGIN
  IF public.gameon_business_deletion_block_reason(p_business_id) = 'already_deleted' THEN
    RETURN public.gameon_business_deletion_soft_delete_core(p_business_id, NULL);
  END IF;

  v_start := public.start_business_account_deletion_job(
    'self:' || p_business_id::text,
    p_business_id
  );

  IF coalesce((v_start ->> 'ok')::boolean, false) = false THEN
    RAISE EXCEPTION 'Business deletion blocked: %', coalesce(v_start ->> 'block_reason', 'unknown')
      USING ERRCODE = 'P0001';
  END IF;

  v_job_id := (v_start ->> 'job_id')::uuid;

  IF v_job_id IS NULL THEN
    RAISE EXCEPTION 'Unable to start business deletion job for %', p_business_id
      USING ERRCODE = 'P0001';
  END IF;

  v_execute := public.execute_delete_business_account_db(v_job_id);

  RETURN v_execute;
END;
$$;

-- ---------------------------------------------------------------------------
-- 8. RLS: hide tombstoned businesses from client discovery
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS businesses_select_active_authenticated_add_friend ON public.businesses;
CREATE POLICY businesses_select_active_authenticated_add_friend
  ON public.businesses
  FOR SELECT
  TO authenticated
  USING (
    coalesce(is_deleted, false) = false
    AND lower(trim(coalesce(admin_status, ''))) = 'active'
  );

-- ---------------------------------------------------------------------------
-- 9. Grants
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.gameon_business_deletion_soft_delete_core(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_business_deletion_assert_owner(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.advance_business_account_deletion_job(uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.queue_business_account_deletion_finalize(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.preview_delete_business_account(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.start_business_account_deletion_job(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.execute_delete_business_account_db(uuid) TO authenticated;

GRANT EXECUTE ON FUNCTION public.business_account_deletion_preview(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_business_account_cascade(uuid) TO authenticated;

GRANT EXECUTE ON FUNCTION public.preview_delete_business_account(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.start_business_account_deletion_job(text, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.execute_delete_business_account_db(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.advance_business_account_deletion_job(uuid, text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.queue_business_account_deletion_finalize(uuid) TO service_role;

COMMENT ON FUNCTION public.delete_business_account_cascade(uuid) IS
  'Phase 2 compatibility entry: start+execute business soft-delete job synchronously.';

COMMENT ON FUNCTION public.gameon_business_deletion_soft_delete_core(uuid, uuid) IS
  'Transactional business tombstone cleanup. Does not delete auth.users, account_identities, or completed event history.';

-- ---------------------------------------------------------------------------
-- 10. Post-apply integrity checks
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_body text;
BEGIN
  IF to_regclass('public.business_account_deletion_jobs') IS NULL THEN
    RAISE EXCEPTION 'Integrity fail: business_account_deletion_jobs missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'businesses'
      AND column_name = 'is_deleted'
  ) THEN
    RAISE EXCEPTION 'Integrity fail: businesses.is_deleted missing';
  END IF;

  SELECT pg_get_functiondef('public.gameon_business_deletion_soft_delete_core(uuid,uuid)'::regprocedure)
    INTO v_body;

  IF v_body ILIKE '%display_name_normalized%' THEN
    RAISE EXCEPTION 'Integrity fail: soft delete core must not assign display_name_normalized';
  END IF;

  IF to_regprocedure('public.delete_business_account_cascade(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Integrity fail: delete_business_account_cascade missing after replace';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'business_account_deletion_audit'
      AND column_name = 'deletion_mode'
      AND is_nullable = 'YES'
  ) THEN
    RAISE EXCEPTION 'Integrity fail: business_account_deletion_audit.deletion_mode must be NOT NULL';
  END IF;

  IF (
    SELECT column_default
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'business_account_deletion_audit'
      AND column_name = 'deletion_mode'
  ) IS DISTINCT FROM '''soft''::text' THEN
    RAISE NOTICE 'WARN: deletion_mode default is % (expected soft)',
      (SELECT column_default FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = 'business_account_deletion_audit'
         AND column_name = 'deletion_mode');
  END IF;

  SELECT pg_get_functiondef('public.advance_business_account_deletion_job(uuid,text,text,text)'::regprocedure)
    INTO v_body;
  IF v_body NOT ILIKE '%status = ''storage_pending''%' THEN
    RAISE EXCEPTION 'Integrity fail: mark_completed must require storage_pending';
  END IF;

  RAISE NOTICE 'PASS: business account deletion phase 2 objects present';
END;
$$;
