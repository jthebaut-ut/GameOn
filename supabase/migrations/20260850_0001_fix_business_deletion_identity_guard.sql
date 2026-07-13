-- Fix Phase 2 business self-deletion tombstone conflict with enforce_business_account_identity_guard.
--
-- Root cause: gameon_business_deletion_soft_delete_core rewrites owner_email to the
-- deterministic @deleted.fangeo.local tombstone, which trg_businesses_account_identity_guard
-- blocks because it requires owner_email = auth.users.email.
--
-- Pattern mirrors fan deletion (gameon.account_deletion_anonymize): a transaction-local GUC
-- set only inside the trusted SECURITY DEFINER deletion core, bound to the business id.

CREATE OR REPLACE FUNCTION public.enforce_business_account_identity_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_auth_email text;
  v_owner_email text := lower(btrim(coalesce(NEW.owner_email, '')));
  v_deletion_bypass text := nullif(btrim(current_setting('gameon.business_account_deletion_anonymize', true)), '');
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.owner_user_id IS NOT NULL AND NEW.owner_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Business owner auth user mismatch.' USING ERRCODE = '42501';
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
  'BEFORE INSERT/UPDATE guard for businesses.owner_user_id and owner_email. Allows Phase 2 deletion tombstone rewrite only when gameon_business_deletion_soft_delete_core sets transaction-local gameon.business_account_deletion_anonymize to the business id.';

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
-- Privilege hardening (Supabase default ACLs grant EXECUTE to authenticated/anon)
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.gameon_business_deletion_soft_delete_core(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_business_deletion_soft_delete_core(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.gameon_business_deletion_soft_delete_core(uuid, uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.gameon_business_deletion_soft_delete_core(uuid, uuid) FROM service_role;
GRANT EXECUTE ON FUNCTION public.gameon_business_deletion_soft_delete_core(uuid, uuid) TO service_role;

REVOKE ALL ON FUNCTION public.gameon_business_deletion_assert_owner(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_business_deletion_assert_owner(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.gameon_business_deletion_assert_owner(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.gameon_business_deletion_assert_owner(uuid) FROM service_role;
GRANT EXECUTE ON FUNCTION public.gameon_business_deletion_assert_owner(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.advance_business_account_deletion_job(uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.advance_business_account_deletion_job(uuid, text, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.advance_business_account_deletion_job(uuid, text, text, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.advance_business_account_deletion_job(uuid, text, text, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.advance_business_account_deletion_job(uuid, text, text, text) TO service_role;

REVOKE ALL ON FUNCTION public.queue_business_account_deletion_finalize(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.queue_business_account_deletion_finalize(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.queue_business_account_deletion_finalize(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.queue_business_account_deletion_finalize(uuid) FROM service_role;
GRANT EXECUTE ON FUNCTION public.queue_business_account_deletion_finalize(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- Post-apply integrity checks
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_guard_body text;
  v_core_body text;
BEGIN
  IF to_regprocedure('public.enforce_business_account_identity_guard()') IS NULL THEN
    RAISE EXCEPTION 'Integrity fail: enforce_business_account_identity_guard missing';
  END IF;

  IF to_regprocedure('public.gameon_business_deletion_soft_delete_core(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'Integrity fail: gameon_business_deletion_soft_delete_core missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'businesses'
      AND t.tgname = 'trg_businesses_account_identity_guard'
      AND NOT t.tgisinternal
  ) THEN
    RAISE EXCEPTION 'Integrity fail: trg_businesses_account_identity_guard missing on public.businesses';
  END IF;

  SELECT pg_get_functiondef('public.enforce_business_account_identity_guard()'::regprocedure)
    INTO v_guard_body;

  IF v_guard_body NOT ILIKE '%gameon.business_account_deletion_anonymize%' THEN
    RAISE EXCEPTION 'Integrity fail: guard must read gameon.business_account_deletion_anonymize';
  END IF;

  IF v_guard_body NOT ILIKE '%gameon_business_deletion_tombstone_email%' THEN
    RAISE EXCEPTION 'Integrity fail: guard must require canonical tombstone email';
  END IF;

  IF v_guard_body NOT ILIKE '%coalesce(NEW.is_deleted, false)%' THEN
    RAISE EXCEPTION 'Integrity fail: guard bypass must require is_deleted';
  END IF;

  IF v_guard_body NOT ILIKE '%Business owner email must match the authenticated user email.%' THEN
    RAISE EXCEPTION 'Integrity fail: normal owner email equality check removed';
  END IF;

  SELECT pg_get_functiondef('public.gameon_business_deletion_soft_delete_core(uuid,uuid)'::regprocedure)
    INTO v_core_body;

  IF v_core_body NOT ILIKE '%set_config(''gameon.business_account_deletion_anonymize''%' THEN
    RAISE EXCEPTION 'Integrity fail: soft delete core must set gameon.business_account_deletion_anonymize';
  END IF;

  IF has_function_privilege('authenticated', 'public.gameon_business_deletion_soft_delete_core(uuid,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Integrity fail: authenticated must not EXECUTE gameon_business_deletion_soft_delete_core';
  END IF;

  RAISE NOTICE 'PASS: business deletion identity guard fix present';
END;
$$;
