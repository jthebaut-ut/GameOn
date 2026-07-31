-- Admin PERMANENT business account deletion (FanGeo).
--
-- Supersedes the soft-only admin path from 20260896 (now a stub).
--
-- DEPENDENCY: apply 20260897_0001_fix_account_deletion_pickup_request_cleanup.sql
-- FIRST. The permanent path runs the fan-side deletion core for the business
-- owner user, which fails with pickup_request_cancel_forbidden without 20260897.
--
-- What "permanent" means here (resumable, staged, never auto-reactivatable):
--   1. business DB cleanup   — existing Phase 2 soft tombstone (venues, events,
--                              claims, placements, business row anonymization)
--   2. ownership detach      — businesses.owner_user_id -> NULL,
--                              businesses.permanently_deleted_at -> now(),
--                              business-origin venues lose owner references
--   3. user DB cleanup       — fan-side account_deletion_jobs + soft-delete core
--                              for the former business owner user
--   4. identity retirement   — DELETE FROM public.account_identities for the owner
--   5. Auth delete + storage — queued to the finalize Edge Function
--                              (job status auth_delete_pending)
--
-- The DB NEVER claims Auth deletion. auth_users_deleted stays false until the
-- Edge finalizer confirms it through advance_business_account_deletion_job.
--
-- Self-service soft deletion (delete_business_account_cascade /
-- start_business_account_deletion_job / execute_business_account_deletion_db)
-- keeps identical behavior for deletion_mode = 'soft'.
--
-- Forward-only. Do not edit prior migrations. PREPARED ONLY — manual apply.

-- ---------------------------------------------------------------------------
-- 1. Schema: permanent marker + job lifecycle extensions
-- ---------------------------------------------------------------------------

ALTER TABLE public.businesses
  ADD COLUMN IF NOT EXISTS permanently_deleted_at timestamptz NULL;

COMMENT ON COLUMN public.businesses.permanently_deleted_at IS
  'Set only by Admin permanent business account deletion (20260898). Non-null means owner ownership was detached and the account identity retired: the business must never be reactivated.';

CREATE INDEX IF NOT EXISTS idx_businesses_permanently_deleted_at
  ON public.businesses (permanently_deleted_at)
  WHERE permanently_deleted_at IS NOT NULL;

ALTER TABLE public.business_account_deletion_jobs
  ADD COLUMN IF NOT EXISTS user_deletion_job_id uuid NULL,
  ADD COLUMN IF NOT EXISTS permanent_finalize_ready boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.business_account_deletion_jobs.user_deletion_job_id IS
  'Fan-side public.account_deletion_jobs.id used by the permanent path to clean the former business owner user rows.';

COMMENT ON COLUMN public.business_account_deletion_jobs.permanent_finalize_ready IS
  'true once the permanent path committed every DB stage and only Auth delete + storage cleanup remain for the Edge finalizer.';

-- The original status / deletion_mode CHECKs were inline (auto-named) in
-- 20260847; drop whichever names exist before recreating them.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT c.conname, pg_get_constraintdef(c.oid) AS def
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'public'
      AND t.relname = 'business_account_deletion_jobs'
      AND c.contype = 'c'
  LOOP
    IF r.def ILIKE '%deletion_mode%' OR r.def ILIKE '%status%' THEN
      EXECUTE format(
        'ALTER TABLE public.business_account_deletion_jobs DROP CONSTRAINT %I',
        r.conname
      );
      RAISE NOTICE 'Dropped business_account_deletion_jobs constraint %: %', r.conname, r.def;
    END IF;
  END LOOP;
END;
$$;

ALTER TABLE public.business_account_deletion_jobs
  ADD CONSTRAINT business_account_deletion_jobs_deletion_mode_check
  CHECK (deletion_mode IN ('soft', 'hard', 'permanent'));

ALTER TABLE public.business_account_deletion_jobs
  ADD CONSTRAINT business_account_deletion_jobs_status_check
  CHECK (status IN (
    'queued',
    'previewed',
    'running',
    'business_db_committed',
    'user_db_committed',
    'identity_retired',
    'auth_delete_pending',
    'db_committed',
    'storage_pending',
    'completed',
    'failed',
    'cancelled'
  ));

COMMENT ON COLUMN public.business_account_deletion_jobs.status IS
  'Lifecycle. Soft path: queued/previewed/running/db_committed/storage_pending/completed. Permanent path adds business_db_committed, user_db_committed, identity_retired, auth_delete_pending.';

-- Recreate the single-active-job guard so every in-progress permanent status is
-- covered (all statuses except completed/failed/cancelled).
DO $$
DECLARE
  v_dupes integer := 0;
BEGIN
  SELECT count(*) INTO v_dupes
  FROM (
    SELECT j.subject_business_id
    FROM public.business_account_deletion_jobs j
    WHERE j.status NOT IN ('completed', 'failed', 'cancelled')
    GROUP BY j.subject_business_id
    HAVING count(*) > 1
  ) d;

  IF v_dupes > 0 THEN
    RAISE EXCEPTION 'Cannot recreate business_account_deletion_jobs_one_active_per_business: % business id(s) already have more than one in-progress job. Resolve those jobs first.', v_dupes;
  END IF;
END;
$$;

DROP INDEX IF EXISTS public.business_account_deletion_jobs_one_active_per_business;

CREATE UNIQUE INDEX business_account_deletion_jobs_one_active_per_business
  ON public.business_account_deletion_jobs (subject_business_id)
  WHERE status NOT IN ('completed', 'failed', 'cancelled');

ALTER TABLE public.business_account_deletion_audit
  DROP CONSTRAINT IF EXISTS business_account_deletion_audit_deletion_mode_check;

ALTER TABLE public.business_account_deletion_audit
  ADD CONSTRAINT business_account_deletion_audit_deletion_mode_check
  CHECK (deletion_mode IN ('soft', 'hard', 'permanent'));

-- ---------------------------------------------------------------------------
-- 2. assert_owner: service_role (Admin Dashboard) may load any business row
--    FOR UPDATE. JWT callers stay ownership-gated. (Re-applied from 20260896.)
-- ---------------------------------------------------------------------------

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
  IF public.gameon_business_deletion_is_service_caller() THEN
    SELECT *
      INTO v_business
    FROM public.businesses b
    WHERE b.id = p_business_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Business not found: %', p_business_id
        USING ERRCODE = 'P0002';
    END IF;

    RETURN v_business;
  END IF;

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

COMMENT ON FUNCTION public.gameon_business_deletion_assert_owner(uuid) IS
  'Loads a business FOR UPDATE for the deletion lifecycle. service_role (Admin) may load any business; JWT callers must own it by owner_user_id or owner_email.';

-- ---------------------------------------------------------------------------
-- 3. soft_delete_core: latest 20260850 body plus the two service_role patches
--    (1) business_disabled raises only for non-service callers
--    (2) actor email comes from gameon.business_deletion_actor_email when set
--    Soft self-service semantics are otherwise byte-for-byte unchanged.
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

  -- Self-service only: admin deletion may proceed after explicit acknowledgment.
  IF public.gameon_business_deletion_block_reason(p_business_id) = 'business_disabled'
     AND NOT public.gameon_business_deletion_is_service_caller() THEN
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
    admin_archived_by = coalesce(
      nullif(btrim(current_setting('gameon.business_deletion_actor_email', true)), ''),
      nullif(v_email, ''),
      CASE
        WHEN public.gameon_business_deletion_is_service_caller() THEN 'admin_dashboard'
        ELSE 'business_self_service_delete'
      END
    ),
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

  UPDATE public.venues v
  SET
    admin_status = 'archived',
    admin_archived_at = v_now,
    admin_archived_by = coalesce(
      nullif(btrim(current_setting('gameon.business_deletion_actor_email', true)), ''),
      nullif(v_email, ''),
      CASE
        WHEN public.gameon_business_deletion_is_service_caller() THEN 'admin_dashboard'
        ELSE 'business_self_service_delete'
      END
    ),
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

  UPDATE public.sponsored_placements sp
  SET status = 'paused'
  WHERE sp.business_id = p_business_id
    AND sp.status = 'active';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('sponsored_placements_paused', v_count);

  v_tombstone_email := public.gameon_business_deletion_tombstone_email(p_business_id);

  -- Transaction-local bypass for enforce_business_account_identity_guard during tombstone rewrite.
  PERFORM set_config('gameon.business_account_deletion_anonymize', p_business_id::text, true);

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
      coalesce(
        nullif(btrim(current_setting('gameon.business_deletion_actor_email', true)), ''),
        NULLIF(v_email, '')
      ),
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
-- 4. Permanent ownership detach (service_role only, after the soft tombstone)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gameon_business_deletion_permanent_detach_ownership(
  p_business_id uuid,
  p_job_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_business public.businesses%ROWTYPE;
  v_owner uuid;
  v_owner_email text;
  v_count integer := 0;
  v_counts jsonb := '{}'::jsonb;
  v_now timestamptz := now();
BEGIN
  IF NOT public.gameon_business_deletion_is_service_caller() THEN
    RAISE EXCEPTION 'gameon_business_deletion_permanent_detach_ownership is restricted to service_role'
      USING ERRCODE = '42501';
  END IF;

  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'p_business_id is required'
      USING ERRCODE = '22023';
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

  IF NOT coalesce(v_business.is_deleted, false) THEN
    RAISE EXCEPTION 'permanent_detach_requires_soft_tombstone'
      USING ERRCODE = 'P0001';
  END IF;

  v_owner := v_business.owner_user_id;
  v_owner_email := lower(btrim(coalesce(v_business.owner_email, '')));

  -- Defensive transaction-local identity-guard context (service_role has no auth.uid()).
  PERFORM set_config('gameon.business_account_deletion_anonymize', p_business_id::text, true);

  UPDATE public.businesses b
  SET owner_user_id = NULL,
      permanently_deleted_at = coalesce(b.permanently_deleted_at, v_now)
  WHERE b.id = p_business_id
    AND coalesce(b.is_deleted, false);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('businesses_owner_detached', v_count);

  -- Business-origin venues stay linked to the tombstoned business row for
  -- history/audit, but must no longer reference the retiring owner identity.
  UPDATE public.venues v
  SET owner_user_id = NULL,
      owner_email = NULL
  WHERE v.business_id = p_business_id
    AND (v.owner_user_id IS NOT NULL OR v.owner_email IS NOT NULL);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('business_venues_owner_detached', v_count);

  IF v_owner IS NOT NULL THEN
    UPDATE public.venues v
    SET owner_user_id = NULL,
        owner_email = NULL
    WHERE v.owner_user_id = v_owner
      AND lower(btrim(coalesce(v.admin_archived_reason, ''))) = 'business_account_deleted';
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('archived_owner_venues_detached', v_count);
  ELSE
    v_counts := v_counts || jsonb_build_object('archived_owner_venues_detached', 0);
  END IF;

  IF p_job_id IS NOT NULL THEN
    UPDATE public.business_account_deletion_jobs j
    SET affected_counts = coalesce(j.affected_counts, '{}'::jsonb)
          || jsonb_build_object('permanent_detach', v_counts)
    WHERE j.id = p_job_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'business_id', p_business_id,
    'detached_owner_user_id', v_owner,
    'detached_owner_email', nullif(v_owner_email, ''),
    'permanently_deleted_at', coalesce(v_business.permanently_deleted_at, v_now),
    'counts', v_counts
  );
END;
$$;

COMMENT ON FUNCTION public.gameon_business_deletion_permanent_detach_ownership(uuid, uuid) IS
  'Permanent deletion stage 2 (service_role only): clears businesses.owner_user_id, stamps permanently_deleted_at, and removes owner references from business-origin venues. Requires the soft tombstone first.';
-- ---------------------------------------------------------------------------
-- 5. gameon_account_deletion_block_reason: narrow permanent-path exception
--
--    Full 20260843 body preserved. The ONLY change is a transaction-local,
--    service_role-only, job-bound skip of the business-identity markers
--    (account_identities.account_type = 'business' and
--    user_profiles.is_business_account) so the permanent orchestrator can run
--    the fan-side cleanup for the former business owner AFTER ownership detach
--    and BEFORE identity retirement. Every ownership / venue / claim blocker
--    still applies, and the skip is impossible without:
--      * service_role, AND
--      * gameon.permanent_business_account_deletion = a business id, AND
--      * an in-progress deletion_mode='permanent' job for that business whose
--        subject_user_id is exactly this user.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gameon_account_deletion_block_reason(
  p_user_id uuid
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_email text := public.gameon_account_deletion_resolve_email(p_user_id);
  v_permanent_business text := nullif(
    btrim(current_setting('gameon.permanent_business_account_deletion', true)),
    ''
  );
  v_skip_business_identity boolean := false;
BEGIN
  IF v_permanent_business IS NOT NULL
     AND p_user_id IS NOT NULL
     AND public.gameon_account_deletion_is_service_caller()
     AND to_regclass('public.business_account_deletion_jobs') IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.business_account_deletion_jobs j
       WHERE j.subject_business_id::text = v_permanent_business
         AND j.subject_user_id = p_user_id
         AND j.deletion_mode = 'permanent'
         AND j.status IN (
           'running',
           'business_db_committed',
           'user_db_committed',
           'identity_retired',
           'auth_delete_pending',
           'db_committed',
           'storage_pending'
         )
     ) THEN
    v_skip_business_identity := true;
  END IF;

  IF public.gameon_account_deletion_profile_is_anonymized(p_user_id) THEN
    RETURN 'already_deleted';
  END IF;

  IF NOT v_skip_business_identity
     AND to_regclass('public.account_identities') IS NOT NULL
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
            (
              v_email <> ''
              AND lower(btrim(coalesce(vc.owner_email, ''))) = v_email
            )
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
        (
          v_email <> ''
          AND lower(btrim(coalesce(vc.owner_email, ''))) = v_email
        )
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

  IF NOT v_skip_business_identity
     AND to_regclass('public.user_profiles') IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.user_profiles up
       WHERE up.id = p_user_id
         AND coalesce(up.is_business_account, false) = true
         AND coalesce(up.is_deleted, false) = false
     ) THEN
    RETURN 'business_profile_flag';
  END IF;

  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION public.gameon_account_deletion_block_reason(uuid) IS
  'Fan account deletion blockers. Business-identity markers (account_identities.account_type = business, user_profiles.is_business_account) are skipped only for service_role inside an in-progress permanent business deletion job bound to gameon.permanent_business_account_deletion and this exact subject user (20260898). All ownership, venue, and claim blockers always apply.';

-- ---------------------------------------------------------------------------
-- 6. Admin eligibility (service_role only, resume-friendly)
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- 7. Admin permanent deletion orchestrator (service_role only, resumable)
--
--    Stages, each committed before the next starts:
--      previewed/queued/running/db_committed/storage_pending
--                                  -> soft tombstone + ownership detach
--                                  -> status business_db_committed
--      business_db_committed        -> fan-side user cleanup
--                                  -> status user_db_committed
--      user_db_committed            -> account_identities retirement
--                                  -> status identity_retired -> auth_delete_pending
--      auth_delete_pending / db_committed / storage_pending
--                                  -> queue the Edge finalizer (Auth + storage)
--
--    Re-running the RPC resumes from whatever stage the job is in. Failures never
--    restore the business; they leave the job resumable at the last good stage.
-- ---------------------------------------------------------------------------

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

  UPDATE public.business_account_deletion_jobs j
  SET deletion_mode = 'permanent',
      request_source = 'admin',
      subject_user_id = coalesce(j.subject_user_id, v_owner)
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
  IF v_job.status IN ('auth_delete_pending', 'db_committed', 'storage_pending') THEN
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
-- ---------------------------------------------------------------------------
-- 8. Job advancement: permanent Auth-delete stage
--
--    Permanent Edge flow:
--      auth_delete_pending --(Edge deletes auth.users)--> mark_auth_deleted
--                          --> mark_storage_pending --> storage --> mark_completed
--    Soft flow is unchanged: db_committed -> mark_storage_pending -> mark_completed.
-- ---------------------------------------------------------------------------

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
      'completed_at', v_job.completed_at,
      'idempotent_replay', true
    );
  END IF;

  IF v_action = 'mark_auth_pending' THEN
    UPDATE public.business_account_deletion_jobs
    SET status = 'auth_delete_pending',
        stage = 'awaiting_auth_and_storage_finalize',
        permanent_finalize_ready = true,
        completed_at = NULL,
        error_code = NULL,
        error_detail = NULL
    WHERE id = p_job_id
      AND status IN (
        'db_committed',
        'business_db_committed',
        'user_db_committed',
        'identity_retired',
        'auth_delete_pending'
      );
    IF NOT FOUND THEN
      RAISE EXCEPTION 'mark_auth_pending requires a committed job status (got %)', v_job.status
        USING ERRCODE = 'P0001';
    END IF;
  ELSIF v_action = 'mark_auth_deleted' THEN
    -- Edge confirmed auth.users deletion. Status stays auth_delete_pending until
    -- storage cleanup starts; the stage records the confirmation.
    UPDATE public.business_account_deletion_jobs
    SET stage = 'auth_deleted',
        affected_counts = coalesce(affected_counts, '{}'::jsonb)
          || jsonb_build_object('auth_users_deleted', 1),
        error_code = NULL,
        error_detail = NULL
    WHERE id = p_job_id
      AND status IN ('auth_delete_pending', 'storage_pending');
    IF NOT FOUND THEN
      RAISE EXCEPTION 'mark_auth_deleted requires job status auth_delete_pending or storage_pending (got %)', v_job.status
        USING ERRCODE = 'P0001';
    END IF;
  ELSIF v_action = 'mark_storage_pending' THEN
    UPDATE public.business_account_deletion_jobs
    SET status = 'storage_pending',
        stage = 'storage_cleanup',
        completed_at = NULL,
        error_code = NULL,
        error_detail = NULL
    WHERE id = p_job_id
      AND status IN ('db_committed', 'auth_delete_pending', 'storage_pending');
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
  ELSIF v_action = 'mark_storage_partial' THEN
    UPDATE public.business_account_deletion_jobs
    SET status = 'storage_pending',
        stage = 'storage_cleanup_partial',
        completed_at = NULL,
        error_code = coalesce(nullif(btrim(p_error_code), ''), 'storage_cleanup_partial'),
        error_detail = p_error_detail
    WHERE id = p_job_id
      AND status = 'storage_pending';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'mark_storage_partial requires job status storage_pending (got %)', v_job.status
        USING ERRCODE = 'P0001';
    END IF;
  ELSIF v_action = 'mark_failed' THEN
    UPDATE public.business_account_deletion_jobs
    SET status = 'failed',
        stage = 'failed',
        error_code = p_error_code,
        error_detail = p_error_detail,
        completed_at = NULL
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
    'stage', v_job.stage,
    'deletion_mode', v_job.deletion_mode,
    'permanent_finalize_ready', v_job.permanent_finalize_ready,
    'completed_at', v_job.completed_at
  );
END;
$$;

COMMENT ON FUNCTION public.advance_business_account_deletion_job(uuid, text, text, text) IS
  'Service-role only. Advances business_account_deletion_jobs through Auth delete (permanent mode), storage cleanup, and completion. Actions: mark_auth_pending, mark_auth_deleted, mark_storage_pending, mark_storage_partial, mark_completed, mark_failed.';

-- ---------------------------------------------------------------------------
-- 9. Finalize queue: allow the permanent auth_delete_pending status
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.queue_business_account_deletion_finalize(p_job_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_job public.business_account_deletion_jobs%ROWTYPE;
  v_url text;
  v_service_role_key text;
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
      'edge_function_deployed', true,
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
      'edge_function_deployed', true,
      'job_mutated', false
    );
  END IF;

  IF v_job.status = 'completed' THEN
    RETURN jsonb_build_object(
      'queued', false,
      'result', 'already_completed',
      'job_id', p_job_id,
      'job_status', v_job.status,
      'job_stage', v_job.stage,
      'completed_at', v_job.completed_at,
      'edge_function_deployed', true,
      'job_mutated', false,
      'storage_finalization_pending', false
    );
  END IF;

  IF v_job.status NOT IN ('db_committed', 'auth_delete_pending', 'storage_pending') THEN
    RETURN jsonb_build_object(
      'queued', false,
      'result', 'job_not_ready_for_finalize',
      'job_id', p_job_id,
      'job_status', v_job.status,
      'job_stage', v_job.stage,
      'edge_function_deployed', true,
      'job_mutated', false,
      'storage_finalization_pending', false
    );
  END IF;

  IF to_regnamespace('net') IS NULL OR to_regclass('vault.decrypted_secrets') IS NULL THEN
    RETURN jsonb_build_object(
      'queued', false,
      'result', 'skipped_pg_net_unavailable',
      'job_id', p_job_id,
      'job_status', v_job.status,
      'job_stage', v_job.stage,
      'edge_function_deployed', true,
      'job_mutated', false,
      'storage_finalization_pending', true
    );
  END IF;

  SELECT rtrim(decrypted_secret, '/')
    INTO v_url
  FROM vault.decrypted_secrets
  WHERE name IN ('fangeo_supabase_url', 'SUPABASE_URL')
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY CASE name WHEN 'fangeo_supabase_url' THEN 0 ELSE 1 END
  LIMIT 1;

  SELECT decrypted_secret
    INTO v_service_role_key
  FROM vault.decrypted_secrets
  WHERE name IN ('fangeo_service_role_key', 'SUPABASE_SERVICE_ROLE_KEY')
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY CASE name WHEN 'fangeo_service_role_key' THEN 0 ELSE 1 END
  LIMIT 1;

  IF v_url IS NULL OR v_service_role_key IS NULL THEN
    RETURN jsonb_build_object(
      'queued', false,
      'result', 'skipped_missing_secrets',
      'job_id', p_job_id,
      'job_status', v_job.status,
      'job_stage', v_job.stage,
      'edge_function_deployed', true,
      'job_mutated', false,
      'storage_finalization_pending', true
    );
  END IF;

  PERFORM net.http_post(
    url := v_url || '/functions/v1/finalize-business-account-deletion',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_service_role_key
    ),
    body := jsonb_build_object(
      'job_id', p_job_id,
      'deletion_mode', v_job.deletion_mode,
      'permanent', v_job.deletion_mode = 'permanent',
      'auth_delete_pending', v_job.status = 'auth_delete_pending',
      'subject_user_id', v_job.subject_user_id,
      'user_deletion_job_id', v_job.user_deletion_job_id
    ),
    timeout_milliseconds := 60000
  );

  RETURN jsonb_build_object(
    'queued', true,
    'result', 'queued',
    'job_id', p_job_id,
    'job_status', v_job.status,
    'job_stage', v_job.stage,
    'deletion_mode', v_job.deletion_mode,
    'auth_delete_pending', v_job.status = 'auth_delete_pending',
    'edge_function_deployed', true,
    'job_mutated', false,
    'storage_finalization_pending', true
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'queued', false,
      'result', 'failed',
      'detail', SQLERRM,
      'job_id', p_job_id,
      'edge_function_deployed', true,
      'job_mutated', false
    );
END;
$$;

COMMENT ON FUNCTION public.queue_business_account_deletion_finalize(uuid) IS
  'Service-role only. Enqueues finalize-business-account-deletion via pg_net for db_committed (soft), auth_delete_pending (permanent Auth delete + storage), and storage_pending jobs.';

-- ---------------------------------------------------------------------------
-- 10. Reactivation must never resurrect a permanently deleted business
--
--     Patched at two points:
--       a) admin_reactivate_deleted_business_eligibility — explicit early return
--       b) gameon_business_reactivation_latest_job_block_reason — shared blocker
--          used by gameon_business_reactivation_evaluate_eligibility, which both
--          the eligibility RPC and the admin_reactivate_deleted_business
--          execute path run through.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gameon_business_reactivation_latest_job_block_reason(
  p_job public.business_account_deletion_jobs
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_job.id IS NULL THEN
    RETURN NULL;
  END IF;

  -- Permanent deletion is terminal: no reactivation at any job status.
  IF p_job.deletion_mode = 'permanent'
     OR EXISTS (
       SELECT 1
       FROM public.businesses b
       WHERE b.id = p_job.subject_business_id
         AND b.permanently_deleted_at IS NOT NULL
     ) THEN
    RETURN 'permanently_deleted';
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

COMMENT ON FUNCTION public.gameon_business_reactivation_latest_job_block_reason(public.business_account_deletion_jobs) IS
  'Reactivation policy for the latest business deletion job. Returns permanently_deleted for permanent-mode jobs or businesses stamped permanently_deleted_at; otherwise unchanged (completed-only policy).';

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

  -- Permanent Admin deletion (20260898) is irreversible.
  IF v_business.permanently_deleted_at IS NOT NULL THEN
    RETURN public.gameon_business_reactivation_eligibility_envelope(
      jsonb_build_object(
        'ok', true,
        'eligible', false,
        'block_reason', 'permanently_deleted',
        'message', 'This business account was permanently deleted by an admin and can never be reactivated.',
        'business_id', p_business_id,
        'owner_user_id', v_business.owner_user_id,
        'permanently_deleted_at', v_business.permanently_deleted_at,
        'permanent_non_reactivatable', true
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

COMMENT ON FUNCTION public.admin_reactivate_deleted_business_eligibility(uuid) IS
  'Admin read-only eligibility preview for reactivating a Phase 2 tombstoned business shell. Returns block_reason permanently_deleted when businesses.permanently_deleted_at is set. service_role only.';
-- ---------------------------------------------------------------------------
-- 11. Privileges (Supabase grants EXECUTE to anon/authenticated by default)
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_fn text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    'public.admin_delete_business_account_eligibility(uuid)',
    'public.admin_delete_business_account(uuid, text, text, text, boolean)',
    'public.gameon_business_deletion_permanent_detach_ownership(uuid, uuid)',
    'public.gameon_business_deletion_assert_owner(uuid)',
    'public.gameon_business_deletion_soft_delete_core(uuid, uuid)',
    'public.advance_business_account_deletion_job(uuid, text, text, text)',
    'public.queue_business_account_deletion_finalize(uuid)',
    'public.gameon_account_deletion_block_reason(uuid)',
    'public.gameon_business_reactivation_latest_job_block_reason(public.business_account_deletion_jobs)',
    'public.admin_reactivate_deleted_business_eligibility(uuid)'
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

COMMENT ON FUNCTION public.admin_delete_business_account_eligibility(uuid) IS
  'Admin read-only preview for PERMANENT business account deletion. service_role only. Reports can_delete, can_resume/resume_status for in-flight permanent jobs, and the irreversible consequences (Auth delete + identity retirement).';

COMMENT ON FUNCTION public.admin_delete_business_account(uuid, text, text, text, boolean) IS
  'Admin PERMANENT business account deletion orchestrator (service_role only, resumable): soft tombstone -> ownership detach -> owner user cleanup -> account_identities retirement -> queue Edge finalizer for Auth delete + storage. Never reports auth_users_deleted true from the database.';

-- ---------------------------------------------------------------------------
-- 12. Post-apply integrity checks
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_def text;
  v_fn text;
BEGIN
  -- Procedures exist
  FOREACH v_fn IN ARRAY ARRAY[
    'public.admin_delete_business_account_eligibility(uuid)',
    'public.admin_delete_business_account(uuid,text,text,text,boolean)',
    'public.gameon_business_deletion_permanent_detach_ownership(uuid,uuid)',
    'public.gameon_business_deletion_assert_owner(uuid)',
    'public.gameon_business_deletion_soft_delete_core(uuid,uuid)',
    'public.gameon_account_deletion_block_reason(uuid)',
    'public.advance_business_account_deletion_job(uuid,text,text,text)',
    'public.queue_business_account_deletion_finalize(uuid)',
    'public.admin_reactivate_deleted_business_eligibility(uuid)',
    'public.gameon_business_reactivation_latest_job_block_reason(public.business_account_deletion_jobs)'
  ]
  LOOP
    IF to_regprocedure(v_fn) IS NULL THEN
      RAISE EXCEPTION 'Integrity fail: % missing', v_fn;
    END IF;

    IF NOT has_function_privilege('service_role', v_fn::regprocedure, 'EXECUTE') THEN
      RAISE EXCEPTION 'Integrity fail: service_role cannot EXECUTE %', v_fn;
    END IF;

    IF has_function_privilege('anon', v_fn::regprocedure, 'EXECUTE') THEN
      RAISE EXCEPTION 'Integrity fail: anon can EXECUTE %', v_fn;
    END IF;

    IF has_function_privilege('authenticated', v_fn::regprocedure, 'EXECUTE') THEN
      RAISE EXCEPTION 'Integrity fail: authenticated can EXECUTE %', v_fn;
    END IF;
  END LOOP;

  -- Permanent marker column
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'businesses'
      AND column_name = 'permanently_deleted_at'
  ) THEN
    RAISE EXCEPTION 'Integrity fail: businesses.permanently_deleted_at missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'business_account_deletion_jobs'
      AND column_name = 'user_deletion_job_id'
  ) THEN
    RAISE EXCEPTION 'Integrity fail: business_account_deletion_jobs.user_deletion_job_id missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'business_account_deletion_jobs'
      AND column_name = 'permanent_finalize_ready'
      AND is_nullable = 'NO'
  ) THEN
    RAISE EXCEPTION 'Integrity fail: business_account_deletion_jobs.permanent_finalize_ready missing or nullable';
  END IF;

  -- deletion_mode / status domains
  SELECT pg_get_constraintdef(c.oid)
    INTO v_def
  FROM pg_constraint c
  JOIN pg_class t ON t.oid = c.conrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  WHERE n.nspname = 'public'
    AND t.relname = 'business_account_deletion_jobs'
    AND c.conname = 'business_account_deletion_jobs_deletion_mode_check';

  IF v_def IS NULL OR position('permanent' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: jobs deletion_mode CHECK must include permanent';
  END IF;

  SELECT pg_get_constraintdef(c.oid)
    INTO v_def
  FROM pg_constraint c
  JOIN pg_class t ON t.oid = c.conrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  WHERE n.nspname = 'public'
    AND t.relname = 'business_account_deletion_jobs'
    AND c.conname = 'business_account_deletion_jobs_status_check';

  IF v_def IS NULL
     OR position('business_db_committed' IN v_def) = 0
     OR position('user_db_committed' IN v_def) = 0
     OR position('identity_retired' IN v_def) = 0
     OR position('auth_delete_pending' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: jobs status CHECK missing permanent lifecycle values';
  END IF;

  SELECT pg_get_constraintdef(c.oid)
    INTO v_def
  FROM pg_constraint c
  JOIN pg_class t ON t.oid = c.conrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  WHERE n.nspname = 'public'
    AND t.relname = 'business_account_deletion_audit'
    AND c.conname = 'business_account_deletion_audit_deletion_mode_check';

  IF v_def IS NULL OR position('permanent' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: audit deletion_mode CHECK must include permanent';
  END IF;

  -- Single active job guard covers the new in-progress statuses
  SELECT indexdef
    INTO v_def
  FROM pg_indexes
  WHERE schemaname = 'public'
    AND indexname = 'business_account_deletion_jobs_one_active_per_business';

  IF v_def IS NULL
     OR position('completed' IN v_def) = 0
     OR position('cancelled' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: one-active-job index missing or does not exclude terminal statuses';
  END IF;

  -- service_role bypass patches
  v_def := pg_get_functiondef('public.gameon_business_deletion_assert_owner(uuid)'::regprocedure);
  IF position('gameon_business_deletion_is_service_caller' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: assert_owner missing service_role bypass';
  END IF;

  v_def := pg_get_functiondef('public.gameon_business_deletion_soft_delete_core(uuid,uuid)'::regprocedure);
  IF position('NOT public.gameon_business_deletion_is_service_caller()' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: soft_delete_core missing service_role business_disabled bypass';
  END IF;

  IF position('gameon.business_deletion_actor_email' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: soft_delete_core missing admin actor email GUC';
  END IF;

  IF position('set_config(''gameon.business_account_deletion_anonymize''' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: soft_delete_core must keep the identity guard bypass';
  END IF;

  -- Narrow permanent skip in the fan blocker
  v_def := pg_get_functiondef('public.gameon_account_deletion_block_reason(uuid)'::regprocedure);
  IF position('gameon.permanent_business_account_deletion' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: block_reason missing permanent business deletion GUC';
  END IF;

  IF position('business_ownership' IN v_def) = 0
     OR position('venue_ownership' IN v_def) = 0
     OR position('pending_venue_claim' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: block_reason must keep ownership/venue/claim blockers';
  END IF;

  -- Orchestration wiring
  v_def := pg_get_functiondef('public.admin_delete_business_account(uuid,text,text,text,boolean)'::regprocedure);
  IF position('gameon_business_deletion_soft_delete_core' IN v_def) = 0
     OR position('gameon_business_deletion_permanent_detach_ownership' IN v_def) = 0
     OR position('start_account_deletion_job' IN v_def) = 0
     OR position('execute_delete_user_account_db' IN v_def) = 0
     OR position('DELETE FROM public.account_identities' IN v_def) = 0
     OR position('queue_business_account_deletion_finalize' IN v_def) = 0
     OR position('admin_permanent_delete_business_account' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: admin_delete_business_account missing permanent orchestration stages';
  END IF;

  IF position(E'''auth_users_deleted'', false' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: orchestrator must never report auth_users_deleted true from the database';
  END IF;

  -- Job advancement + finalize queue
  v_def := pg_get_functiondef('public.advance_business_account_deletion_job(uuid,text,text,text)'::regprocedure);
  IF position('mark_auth_pending' IN v_def) = 0
     OR position('mark_auth_deleted' IN v_def) = 0
     OR position('mark_storage_partial' IN v_def) = 0
     OR position('mark_completed requires job status storage_pending' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: advance_business_account_deletion_job missing permanent actions';
  END IF;

  v_def := pg_get_functiondef('public.queue_business_account_deletion_finalize(uuid)'::regprocedure);
  IF position('auth_delete_pending' IN v_def) = 0
     OR position('finalize-business-account-deletion' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: queue_business_account_deletion_finalize must accept auth_delete_pending';
  END IF;

  -- Reactivation block
  v_def := pg_get_functiondef('public.admin_reactivate_deleted_business_eligibility(uuid)'::regprocedure);
  IF position('permanently_deleted' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: reactivation eligibility missing permanently_deleted block';
  END IF;

  v_def := pg_get_functiondef(
    'public.gameon_business_reactivation_latest_job_block_reason(public.business_account_deletion_jobs)'::regprocedure
  );
  IF position('permanently_deleted' IN v_def) = 0
     OR position('storage_finalization_pending' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Integrity fail: reactivation job policy must block permanent deletions and keep completed-only policy';
  END IF;

  RAISE NOTICE 'PASS: admin permanent business account deletion schema, orchestration, privileges, and reactivation blocks verified';
  RAISE NOTICE 'REMINDER: finalize-business-account-deletion Edge Function must be updated to accept deletion_mode=permanent and auth_delete_pending (Auth delete -> mark_auth_deleted -> mark_storage_pending -> mark_completed).';
END;
$$;

