-- Fan user account deletion Phase 2.
-- Adds job tracking, preview RPC, transactional soft-delete cleanup with complete
-- private-data inventory, server-side business blockers, and storage-finalize queue.
--
-- Phase 2 intentionally does NOT delete auth.users, account_identities, or enable
-- hard Auth deletion. Auth/email release remains Phase 3.

-- ---------------------------------------------------------------------------
-- Job table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.account_deletion_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_user_id uuid NOT NULL,
  requested_by_user_id uuid NULL,
  request_source text NOT NULL DEFAULT 'self_service'
    CHECK (request_source IN ('self_service', 'admin', 'system')),
  deletion_mode text NOT NULL DEFAULT 'soft'
    CHECK (deletion_mode IN ('soft', 'hard')),
  status text NOT NULL DEFAULT 'queued'
    CHECK (status IN (
      'queued', 'previewed', 'running', 'db_committed',
      'storage_pending', 'auth_pending', 'completed', 'failed', 'cancelled'
    )),
  stage text NOT NULL DEFAULT 'init',
  idempotency_key text NOT NULL,
  preview_snapshot jsonb NULL,
  affected_counts jsonb NOT NULL DEFAULT '{}'::jsonb,
  avatar_storage_paths text[] NOT NULL DEFAULT '{}'::text[],
  block_reason text NULL,
  error_code text NULL,
  error_detail text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz NULL,
  CONSTRAINT account_deletion_jobs_idempotency_unique UNIQUE (idempotency_key),
  CONSTRAINT account_deletion_jobs_subject_user_id_check CHECK (subject_user_id IS NOT NULL)
);

CREATE UNIQUE INDEX IF NOT EXISTS account_deletion_jobs_one_active_per_subject
  ON public.account_deletion_jobs (subject_user_id)
  WHERE status IN (
    'queued', 'previewed', 'running', 'db_committed', 'storage_pending', 'auth_pending'
  );

CREATE INDEX IF NOT EXISTS idx_account_deletion_jobs_status_updated
  ON public.account_deletion_jobs (status, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_account_deletion_jobs_subject_created
  ON public.account_deletion_jobs (subject_user_id, created_at DESC);

COMMENT ON TABLE public.account_deletion_jobs IS
  'Tracks fan account soft-deletion jobs. Phase 2: soft mode only; auth.users is never deleted here.';

CREATE OR REPLACE FUNCTION public.account_deletion_jobs_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS account_deletion_jobs_touch_updated_at_bu
  ON public.account_deletion_jobs;
CREATE TRIGGER account_deletion_jobs_touch_updated_at_bu
  BEFORE UPDATE ON public.account_deletion_jobs
  FOR EACH ROW
  EXECUTE FUNCTION public.account_deletion_jobs_touch_updated_at();

ALTER TABLE public.account_deletion_jobs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS account_deletion_jobs_select_own ON public.account_deletion_jobs;
CREATE POLICY account_deletion_jobs_select_own
  ON public.account_deletion_jobs
  FOR SELECT
  TO authenticated
  USING (subject_user_id = (SELECT auth.uid()));

GRANT SELECT ON public.account_deletion_jobs TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.account_deletion_jobs TO service_role;

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gameon_account_deletion_is_service_caller()
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

CREATE OR REPLACE FUNCTION public.gameon_account_deletion_resolve_target_user_id(
  p_target_user_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_target uuid := p_target_user_id;
BEGIN
  IF v_target IS NULL THEN
    v_target := v_actor;
  END IF;

  IF v_target IS NULL THEN
    RAISE EXCEPTION 'Not authenticated'
      USING ERRCODE = '28000';
  END IF;

  IF v_target IS DISTINCT FROM v_actor
     AND NOT public.gameon_account_deletion_is_service_caller() THEN
    RAISE EXCEPTION 'Not authorized to act on another user account'
      USING ERRCODE = '42501';
  END IF;

  RETURN v_target;
END;
$$;

CREATE OR REPLACE FUNCTION public.gameon_account_deletion_resolve_email(
  p_user_id uuid
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_email text := lower(btrim(coalesce(auth.jwt() ->> 'email', '')));
BEGIN
  IF v_email <> '' AND auth.uid() = p_user_id THEN
    RETURN v_email;
  END IF;

  SELECT lower(btrim(coalesce(up.email, '')))
    INTO v_email
  FROM public.user_profiles up
  WHERE up.id = p_user_id;

  IF v_email IS NULL OR v_email = '' OR v_email LIKE '%@deleted.fangeo.local' THEN
    SELECT lower(btrim(coalesce(u.email, '')))
      INTO v_email
    FROM auth.users u
    WHERE u.id = p_user_id;
  END IF;

  RETURN coalesce(v_email, '');
END;
$$;

CREATE OR REPLACE FUNCTION public.gameon_account_deletion_profile_is_anonymized(
  p_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (
      SELECT up.is_deleted
      FROM public.user_profiles up
      WHERE up.id = p_user_id
    ),
    false
  );
$$;

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
BEGIN
  IF public.gameon_account_deletion_profile_is_anonymized(p_user_id) THEN
    RETURN 'already_deleted';
  END IF;

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

  IF to_regclass('public.user_profiles') IS NOT NULL
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

CREATE OR REPLACE FUNCTION public.gameon_account_deletion_assert_deletable(
  p_user_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason text := public.gameon_account_deletion_block_reason(p_user_id);
BEGIN
  IF v_reason IS NOT NULL THEN
    RAISE EXCEPTION 'Account deletion blocked: %', v_reason
      USING ERRCODE = 'P0001',
            DETAIL = v_reason;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.gameon_account_deletion_collect_avatar_paths(
  p_user_id uuid
)
RETURNS text[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_avatar_exprs text[] := ARRAY[]::text[];
  v_avatar_storage_paths text[] := ARRAY[]::text[];
  v_sql text;
BEGIN
  BEGIN
    IF to_regprocedure('public.gameon_storage_path_from_public_url(text,text)') IS NOT NULL THEN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'avatar_url'
      ) THEN
        v_avatar_exprs := v_avatar_exprs || ARRAY['public.gameon_storage_path_from_public_url(NULLIF(btrim(up.avatar_url), ''''), ''user-avatars'')'];
      END IF;

      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'avatar_thumbnail_url'
      ) THEN
        v_avatar_exprs := v_avatar_exprs || ARRAY['public.gameon_storage_path_from_public_url(NULLIF(btrim(up.avatar_thumbnail_url), ''''), ''user-avatars'')'];
      END IF;

      IF array_length(v_avatar_exprs, 1) IS NOT NULL THEN
        v_sql := format(
          'SELECT coalesce(array_agg(DISTINCT storage.path), ARRAY[]::text[])
             FROM public.user_profiles up
             CROSS JOIN LATERAL unnest(ARRAY[%s]::text[]) AS storage(path)
            WHERE up.id = $1
              AND storage.path IS NOT NULL
              AND btrim(storage.path) <> ''''',
          array_to_string(v_avatar_exprs, ', ')
        );
        EXECUTE v_sql INTO v_avatar_storage_paths USING p_user_id;
      END IF;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'gameon_account_deletion_collect_avatar_paths: skipped for user %: %', p_user_id, SQLERRM;
    v_avatar_storage_paths := ARRAY[]::text[];
  END;

  RETURN coalesce(v_avatar_storage_paths, ARRAY[]::text[]);
END;
$$;

CREATE OR REPLACE FUNCTION public.gameon_account_deletion_count_if_exists(
  p_table regclass,
  p_where_sql text,
  p_uid uuid,
  p_email text DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count integer := 0;
  v_sql text;
BEGIN
  IF p_table IS NULL THEN
    RETURN 0;
  END IF;

  IF position('$2' IN p_where_sql) > 0 THEN
    v_sql := format('SELECT count(*)::integer FROM %s WHERE %s', p_table, p_where_sql);
    EXECUTE v_sql INTO v_count USING p_uid, p_email;
  ELSE
    v_sql := format('SELECT count(*)::integer FROM %s WHERE %s', p_table, p_where_sql);
    EXECUTE v_sql INTO v_count USING p_uid;
  END IF;

  RETURN coalesce(v_count, 0);
EXCEPTION WHEN OTHERS THEN
  RETURN 0;
END;
$$;

CREATE OR REPLACE FUNCTION public.gameon_account_deletion_estimate_counts(
  p_user_id uuid,
  p_email text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_counts jsonb := '{}'::jsonb;
BEGIN
  v_counts := v_counts || jsonb_build_object(
    'user_push_tokens', public.gameon_account_deletion_count_if_exists('public.user_push_tokens'::regclass, 'user_id = $1', p_user_id),
    'user_notification_preferences', public.gameon_account_deletion_count_if_exists('public.user_notification_preferences'::regclass, 'user_id = $1', p_user_id),
    'saved_pro_games', public.gameon_account_deletion_count_if_exists('public.saved_pro_games'::regclass, 'user_id = $1', p_user_id),
    'pro_game_predictions', public.gameon_account_deletion_count_if_exists('public.pro_game_predictions'::regclass, 'user_id = $1', p_user_id),
    'pro_game_alert_subscriptions', public.gameon_account_deletion_count_if_exists('public.pro_game_alert_subscriptions'::regclass, 'user_id = $1', p_user_id),
    'pro_game_score_notification_deliveries', public.gameon_account_deletion_count_if_exists('public.pro_game_score_notification_deliveries'::regclass, 'user_id = $1', p_user_id),
    'user_xp', public.gameon_account_deletion_count_if_exists('public.user_xp'::regclass, 'user_id = $1', p_user_id),
    'xp_events', public.gameon_account_deletion_count_if_exists('public.xp_events'::regclass, 'user_id = $1', p_user_id),
    'profile_likes', public.gameon_account_deletion_count_if_exists('public.profile_likes'::regclass, 'liker_user_id = $1 OR liked_user_id = $1', p_user_id),
    'profile_pokes', public.gameon_account_deletion_count_if_exists('public.profile_pokes'::regclass, 'poker_user_id = $1 OR poked_user_id = $1', p_user_id),
    'profile_props_recipient_clear', public.gameon_account_deletion_count_if_exists('public.profile_props_recipient_clear'::regclass, 'user_id = $1', p_user_id),
    'profile_pokes_recipient_clear', public.gameon_account_deletion_count_if_exists('public.profile_pokes_recipient_clear'::regclass, 'user_id = $1', p_user_id),
    'suggested_fan_dismissals', public.gameon_account_deletion_count_if_exists('public.suggested_fan_dismissals'::regclass, 'user_id = $1 OR dismissed_user_id = $1', p_user_id),
    'blocked_users', public.gameon_account_deletion_count_if_exists('public.blocked_users'::regclass, 'blocker_user_id = $1 OR blocked_user_id = $1', p_user_id),
    'pickup_game_invites', public.gameon_account_deletion_count_if_exists('public.pickup_game_invites'::regclass, 'inviter_user_id = $1 OR invitee_user_id = $1', p_user_id),
    'pickup_game_creator_ratings', public.gameon_account_deletion_count_if_exists('public.pickup_game_creator_ratings'::regclass, 'creator_user_id = $1 OR rater_user_id = $1', p_user_id),
    'fangeo_plus_award_push_events', public.gameon_account_deletion_count_if_exists('public.fangeo_plus_award_push_events'::regclass, 'user_id = $1', p_user_id),
    'venue_event_predictions', public.gameon_account_deletion_count_if_exists('public.venue_event_predictions'::regclass, 'user_id = $1', p_user_id),
    'user_favorite_teams', public.gameon_account_deletion_count_if_exists('public.user_favorite_teams'::regclass, 'user_id = $1', p_user_id),
    'conversation_read_state', public.gameon_account_deletion_count_if_exists('public.conversation_read_state'::regclass, 'user_id = $1', p_user_id),
    'venue_event_comment_likes', public.gameon_account_deletion_count_if_exists('public.venue_event_comment_likes'::regclass, 'user_id = $1', p_user_id),
    'venue_event_comment_reactions', public.gameon_account_deletion_count_if_exists('public.venue_event_comment_reactions'::regclass, 'user_id = $1', p_user_id),
    'pickup_games_owned', public.gameon_account_deletion_count_if_exists('public.pickup_games'::regclass, 'creator_user_id = $1', p_user_id),
    'pickup_game_requests_as_requester', public.gameon_account_deletion_count_if_exists('public.pickup_game_requests'::regclass, 'requester_user_id = $1', p_user_id),
    'direct_messages_preserved', public.gameon_account_deletion_count_if_exists('public.direct_messages'::regclass, 'sender_id = $1', p_user_id),
    'user_reports_preserved', public.gameon_account_deletion_count_if_exists('public.user_reports'::regclass, 'reporter_user_id = $1 OR reported_user_id = $1', p_user_id),
    'support_conversations_preserved', public.gameon_account_deletion_count_if_exists('public.support_conversations'::regclass, 'user_id = $1', p_user_id),
    'support_requests_preserved', public.gameon_account_deletion_count_if_exists('public.support_requests'::regclass, 'user_id = $1', p_user_id)
  );

  IF p_email <> '' THEN
    v_counts := v_counts || jsonb_build_object(
      'favorite_venues', public.gameon_account_deletion_count_if_exists('public.favorite_venues'::regclass, 'lower(btrim(user_email)) = $2', p_user_id, p_email),
      'venue_event_interests', public.gameon_account_deletion_count_if_exists('public.venue_event_interests'::regclass, 'lower(btrim(user_email)) = $2', p_user_id, p_email),
      'venue_event_vibes', public.gameon_account_deletion_count_if_exists('public.venue_event_vibes'::regclass, 'lower(btrim(user_email)) = $2', p_user_id, p_email),
      'venue_event_comments_anonymize', public.gameon_account_deletion_count_if_exists('public.venue_event_comments'::regclass, 'lower(btrim(user_email)) = $2', p_user_id, p_email)
    );
  END IF;

  RETURN v_counts;
END;
$$;

-- Core transactional soft-delete body (Phase 1 superset + private inventory).
CREATE OR REPLACE FUNCTION public.gameon_account_deletion_soft_delete_core(
  p_user_id uuid,
  p_email text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted_email text := 'deleted-user-' || replace(p_user_id::text, '-', '') || '@deleted.fangeo.local';
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_avatar_storage_paths text[] := ARRAY[]::text[];
  v_profile_set_clauses text[] := ARRAY[]::text[];
  v_friendship_set_clauses text[] := ARRAY[]::text[];
  v_pickup_game_set_clauses text[] := ARRAY[]::text[];
  v_pickup_request_set_clauses text[] := ARRAY[]::text[];
  v_notification_where_clauses text[] := ARRAY[]::text[];
  v_sql text;
  v_count integer := 0;
  v_counts jsonb := '{}'::jsonb;
BEGIN
  IF to_regclass('public.user_profiles') IS NULL THEN
    RAISE EXCEPTION 'user_profiles table is required for account deletion'
      USING ERRCODE = 'P0002';
  END IF;

  v_avatar_storage_paths := public.gameon_account_deletion_collect_avatar_paths(p_user_id);

  -- Private push / notification state
  IF to_regclass('public.user_push_tokens') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.user_push_tokens WHERE user_id = $1' USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('user_push_tokens_deleted', v_count);
  END IF;

  IF to_regclass('public.user_notification_preferences') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.user_notification_preferences WHERE user_id = $1' USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('user_notification_preferences_deleted', v_count);
  END IF;

  -- Pro game private data
  IF to_regclass('public.saved_pro_games') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.saved_pro_games WHERE user_id = $1' USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('saved_pro_games_deleted', v_count);
  END IF;

  IF to_regclass('public.pro_game_predictions') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.pro_game_predictions WHERE user_id = $1' USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('pro_game_predictions_deleted', v_count);
  END IF;

  IF to_regclass('public.pro_game_alert_subscriptions') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.pro_game_alert_subscriptions WHERE user_id = $1' USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('pro_game_alert_subscriptions_deleted', v_count);
  END IF;

  IF to_regclass('public.pro_game_score_notification_deliveries') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.pro_game_score_notification_deliveries WHERE user_id = $1' USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('pro_game_score_notification_deliveries_deleted', v_count);
  END IF;

  -- XP
  IF to_regclass('public.xp_events') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.xp_events WHERE user_id = $1' USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('xp_events_deleted', v_count);
  END IF;

  IF to_regclass('public.user_xp') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.user_xp WHERE user_id = $1' USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('user_xp_deleted', v_count);
  END IF;

  -- Profile interactions
  IF to_regclass('public.profile_likes') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.profile_likes WHERE liker_user_id = $1 OR liked_user_id = $1' USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('profile_likes_deleted', v_count);
  END IF;

  IF to_regclass('public.profile_pokes') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.profile_pokes WHERE poker_user_id = $1 OR poked_user_id = $1' USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('profile_pokes_deleted', v_count);
  END IF;

  IF to_regclass('public.profile_props_recipient_clear') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.profile_props_recipient_clear WHERE user_id = $1' USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('profile_props_recipient_clear_deleted', v_count);
  END IF;

  IF to_regclass('public.profile_pokes_recipient_clear') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.profile_pokes_recipient_clear WHERE user_id = $1' USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('profile_pokes_recipient_clear_deleted', v_count);
  END IF;

  IF to_regclass('public.suggested_fan_dismissals') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.suggested_fan_dismissals WHERE user_id = $1 OR dismissed_user_id = $1' USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('suggested_fan_dismissals_deleted', v_count);
  END IF;

  IF to_regclass('public.blocked_users') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.blocked_users WHERE blocker_user_id = $1 OR blocked_user_id = $1' USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('blocked_users_deleted', v_count);
  END IF;

  IF to_regclass('public.pickup_game_invites') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.pickup_game_invites WHERE inviter_user_id = $1 OR invitee_user_id = $1' USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('pickup_game_invites_deleted', v_count);
  END IF;

  IF to_regclass('public.pickup_game_creator_ratings') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.pickup_game_creator_ratings WHERE creator_user_id = $1 OR rater_user_id = $1' USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('pickup_game_creator_ratings_deleted', v_count);
  END IF;

  IF to_regclass('public.fangeo_plus_award_push_events') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.fangeo_plus_award_push_events WHERE user_id = $1' USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('fangeo_plus_award_push_events_deleted', v_count);
  END IF;

  IF to_regclass('public.venue_event_predictions') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.venue_event_predictions WHERE user_id = $1' USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('venue_event_predictions_deleted', v_count);
  END IF;

  -- Telemetry anonymize (do not delete aggregate rows)
  IF to_regclass('public.analytics_events') IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = 'analytics_events' AND column_name = 'user_id'
     ) THEN
    EXECUTE 'UPDATE public.analytics_events SET user_id = NULL WHERE user_id = $1' USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('analytics_events_anonymized', v_count);
  END IF;

  -- Phase 1 preference / activity cleanup
  IF to_regclass('public.user_favorite_teams') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.user_favorite_teams WHERE user_id = $1' USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('user_favorite_teams_deleted', v_count);
  END IF;

  IF v_email <> '' AND to_regclass('public.favorite_venues') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.favorite_venues WHERE lower(btrim(user_email)) = $1' USING v_email;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('favorite_venues_deleted', v_count);
  END IF;

  IF v_email <> '' AND to_regclass('public.venue_event_interests') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.venue_event_interests WHERE lower(btrim(user_email)) = $1' USING v_email;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('venue_event_interests_deleted', v_count);
  END IF;

  IF v_email <> '' AND to_regclass('public.venue_event_vibes') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.venue_event_vibes WHERE lower(btrim(user_email)) = $1' USING v_email;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('venue_event_vibes_deleted', v_count);
  END IF;

  IF to_regclass('public.venue_event_comment_likes') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.venue_event_comment_likes WHERE user_id = $1' USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('venue_event_comment_likes_deleted', v_count);
  END IF;

  IF to_regclass('public.venue_event_comment_reactions') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.venue_event_comment_reactions WHERE user_id = $1' USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('venue_event_comment_reactions_deleted', v_count);
  END IF;

  IF to_regclass('public.conversation_read_state') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.conversation_read_state WHERE user_id = $1' USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('conversation_read_state_deleted', v_count);
  END IF;

  IF v_email <> '' AND to_regclass('public.venue_event_comments') IS NOT NULL THEN
    EXECUTE
      'UPDATE public.venue_event_comments SET user_email = $1 WHERE lower(btrim(user_email)) = $2'
      USING v_deleted_email, v_email;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('venue_event_comments_anonymized', v_count);
  END IF;

  IF to_regclass('public.friendships') IS NOT NULL THEN
    v_friendship_set_clauses := ARRAY['status = ''archived'''];
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'friendships' AND column_name = 'requester_cleared_at') THEN
      v_friendship_set_clauses := v_friendship_set_clauses || ARRAY['requester_cleared_at = now()'];
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'friendships' AND column_name = 'addressee_cleared_at') THEN
      v_friendship_set_clauses := v_friendship_set_clauses || ARRAY['addressee_cleared_at = now()'];
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'friendships' AND column_name = 'responded_at') THEN
      v_friendship_set_clauses := v_friendship_set_clauses || ARRAY['responded_at = coalesce(responded_at, now())'];
    END IF;

    v_sql := format(
      'UPDATE public.friendships SET %s
        WHERE (
          requester_id = $1
          %s
        ) OR (
          addressee_id = $1
          %s
        )',
      array_to_string(v_friendship_set_clauses, ', '),
      CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'friendships' AND column_name = 'requester_entity_type')
        THEN 'AND coalesce(requester_entity_type, ''user'') = ''user''' ELSE '' END,
      CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'friendships' AND column_name = 'addressee_entity_type')
        THEN 'AND coalesce(addressee_entity_type, ''user'') = ''user''' ELSE '' END
    );

    BEGIN
      EXECUTE v_sql USING p_user_id;
      GET DIAGNOSTICS v_count = ROW_COUNT;
    EXCEPTION WHEN check_violation THEN
      v_sql := replace(v_sql, 'status = ''archived''', 'status = ''declined''');
      EXECUTE v_sql USING p_user_id;
      GET DIAGNOSTICS v_count = ROW_COUNT;
    END;
    v_counts := v_counts || jsonb_build_object('friendships_archived', v_count);
  END IF;

  IF to_regclass('public.pickup_games') IS NOT NULL THEN
    v_pickup_game_set_clauses := ARRAY[]::text[];
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pickup_games' AND column_name = 'status') THEN
      v_pickup_game_set_clauses := v_pickup_game_set_clauses || ARRAY['status = ''cancelled'''];
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pickup_games' AND column_name = 'is_visible') THEN
      v_pickup_game_set_clauses := v_pickup_game_set_clauses || ARRAY['is_visible = false'];
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pickup_games' AND column_name = 'remove_after_at') THEN
      v_pickup_game_set_clauses := v_pickup_game_set_clauses || ARRAY['remove_after_at = coalesce(remove_after_at, now())'];
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pickup_games' AND column_name = 'updated_at') THEN
      v_pickup_game_set_clauses := v_pickup_game_set_clauses || ARRAY['updated_at = now()'];
    END IF;

    IF array_length(v_pickup_game_set_clauses, 1) IS NOT NULL THEN
      v_sql := format('UPDATE public.pickup_games SET %s WHERE creator_user_id = $1', array_to_string(v_pickup_game_set_clauses, ', '));
      BEGIN
        EXECUTE v_sql USING p_user_id;
        GET DIAGNOSTICS v_count = ROW_COUNT;
      EXCEPTION WHEN check_violation THEN
        v_sql := replace(v_sql, 'status = ''cancelled''', 'status = ''removed''');
        BEGIN
          EXECUTE v_sql USING p_user_id;
          GET DIAGNOSTICS v_count = ROW_COUNT;
        EXCEPTION WHEN check_violation THEN
          v_sql := replace(v_sql, 'status = ''removed''', 'status = ''expired''');
          BEGIN
            EXECUTE v_sql USING p_user_id;
            GET DIAGNOSTICS v_count = ROW_COUNT;
          EXCEPTION WHEN check_violation THEN
            v_count := 0;
          END;
        END;
      END;
      v_counts := v_counts || jsonb_build_object('pickup_games_cancelled_hidden', v_count);
    END IF;
  END IF;

  IF to_regclass('public.pickup_game_requests') IS NOT NULL THEN
    v_pickup_request_set_clauses := ARRAY[]::text[];
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pickup_game_requests' AND column_name = 'updated_at') THEN
      v_pickup_request_set_clauses := v_pickup_request_set_clauses || ARRAY['updated_at = now()'];
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pickup_game_requests' AND column_name = 'responded_at') THEN
      v_pickup_request_set_clauses := v_pickup_request_set_clauses || ARRAY['responded_at = coalesce(responded_at, now())'];
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pickup_game_requests' AND column_name = 'requester_user_id') THEN
      BEGIN
        v_sql := format(
          'UPDATE public.pickup_game_requests SET status = ''withdrawn''%s WHERE requester_user_id = $1',
          CASE WHEN array_length(v_pickup_request_set_clauses, 1) IS NULL THEN '' ELSE ', ' || array_to_string(v_pickup_request_set_clauses, ', ') END
        );
        EXECUTE v_sql USING p_user_id;
        GET DIAGNOSTICS v_count = ROW_COUNT;
      EXCEPTION WHEN check_violation THEN
        v_sql := format(
          'UPDATE public.pickup_game_requests SET status = ''cancelled''%s WHERE requester_user_id = $1',
          CASE WHEN array_length(v_pickup_request_set_clauses, 1) IS NULL THEN '' ELSE ', ' || array_to_string(v_pickup_request_set_clauses, ', ') END
        );
        EXECUTE v_sql USING p_user_id;
        GET DIAGNOSTICS v_count = ROW_COUNT;
      END;
      v_counts := v_counts || jsonb_build_object('pickup_game_requests_withdrawn', v_count);
    END IF;

    IF to_regclass('public.pickup_games') IS NOT NULL
       AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pickup_game_requests' AND column_name = 'pickup_game_id') THEN
      v_sql := format(
        'UPDATE public.pickup_game_requests SET status = ''cancelled''%s
          WHERE pickup_game_id IN (SELECT id FROM public.pickup_games WHERE creator_user_id = $1)',
        CASE WHEN array_length(v_pickup_request_set_clauses, 1) IS NULL THEN '' ELSE ', ' || array_to_string(v_pickup_request_set_clauses, ', ') END
      );
      EXECUTE v_sql USING p_user_id;
      GET DIAGNOSTICS v_count = ROW_COUNT;
      v_counts := v_counts || jsonb_build_object('pickup_game_requests_cancelled_for_created_games', v_count);
    END IF;
  END IF;

  IF to_regclass('public.notifications') IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'notifications' AND column_name = 'user_id') THEN
      v_notification_where_clauses := v_notification_where_clauses || ARRAY['user_id = $1'];
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'notifications' AND column_name = 'recipient_user_id') THEN
      v_notification_where_clauses := v_notification_where_clauses || ARRAY['recipient_user_id = $1'];
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'notifications' AND column_name = 'target_user_id') THEN
      v_notification_where_clauses := v_notification_where_clauses || ARRAY['target_user_id = $1'];
    END IF;

    IF array_length(v_notification_where_clauses, 1) IS NOT NULL THEN
      v_sql := format('DELETE FROM public.notifications WHERE %s', array_to_string(v_notification_where_clauses, ' OR '));
      EXECUTE v_sql USING p_user_id;
      GET DIAGNOSTICS v_count = ROW_COUNT;
      v_counts := v_counts || jsonb_build_object('notifications_deleted', v_count);
    END IF;
  END IF;

  -- Profile anonymization (row preserved for FK/thread integrity)
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'is_deleted') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['is_deleted = true'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'deleted_at') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['deleted_at = now()'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'anonymized_at') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['anonymized_at = now()'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'deletion_requested_at') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['deletion_requested_at = coalesce(deletion_requested_at, now())'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'display_name') THEN
    v_profile_set_clauses := array_append(v_profile_set_clauses, format('display_name = %L', 'Deleted User'));
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'display_name_normalized') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['display_name_normalized = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'email') THEN
    v_profile_set_clauses := array_append(v_profile_set_clauses, format('email = %L', v_deleted_email));
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'username') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['username = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'handle') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['handle = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'bio') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['bio = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'avatar_url') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['avatar_url = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'avatar_thumbnail_url') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['avatar_thumbnail_url = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'discoverable_by_fans') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['discoverable_by_fans = false'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'live_visibility_enabled') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['live_visibility_enabled = false'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'selected_live_visibility_friend_ids') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['selected_live_visibility_friend_ids = ARRAY[]::uuid[]'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'fan_identity_preferences') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['fan_identity_preferences = ''{}''::jsonb'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'home_crowd_venue_id') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['home_crowd_venue_id = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'home_crowd_set_at') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['home_crowd_set_at = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'active_session_id') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['active_session_id = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'active_session_updated_at') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['active_session_updated_at = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'last_seen_at') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['last_seen_at = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'ad_free_enabled') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['ad_free_enabled = false'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'ad_free_expires_at') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['ad_free_expires_at = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'home_city') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['home_city = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'home_region') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['home_region = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'home_country') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['home_country = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'show_home_city') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['show_home_city = false'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'national_team_country_code') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['national_team_country_code = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'national_team_country_name') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['national_team_country_name = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'national_team_flag') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['national_team_flag = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'national_team_supporter_label') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['national_team_supporter_label = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'national_team_updated_at') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['national_team_updated_at = NULL'];
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'last_active_at') THEN
    v_profile_set_clauses := v_profile_set_clauses || ARRAY['last_active_at = NULL'];
  END IF;

  IF array_length(v_profile_set_clauses, 1) IS NOT NULL THEN
    -- Transaction-local bypass for enforce_fan_account_identity_guard while anonymizing
    -- to deleted-local email. Only reachable from this SECURITY DEFINER helper, which
    -- is not granted to authenticated clients.
    PERFORM set_config('gameon.account_deletion_anonymize', p_user_id::text, true);
    v_sql := format('UPDATE public.user_profiles SET %s WHERE id = $1', array_to_string(v_profile_set_clauses, ', '));
    EXECUTE v_sql USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('user_profiles_anonymized', v_count);
  END IF;

  v_counts := v_counts || jsonb_build_object(
    'direct_messages_preserved', coalesce(public.gameon_account_deletion_count_if_exists('public.direct_messages'::regclass, 'sender_id = $1', p_user_id), 0),
    'user_reports_preserved', coalesce(public.gameon_account_deletion_count_if_exists('public.user_reports'::regclass, 'reporter_user_id = $1 OR reported_user_id = $1', p_user_id), 0),
    'support_conversations_preserved', coalesce(public.gameon_account_deletion_count_if_exists('public.support_conversations'::regclass, 'user_id = $1', p_user_id), 0),
    'support_requests_preserved', coalesce(public.gameon_account_deletion_count_if_exists('public.support_requests'::regclass, 'user_id = $1', p_user_id), 0)
  );

  RETURN jsonb_build_object(
    'affected_counts', v_counts,
    'avatar_storage_paths', to_jsonb(coalesce(v_avatar_storage_paths, ARRAY[]::text[])),
    'deleted_email', v_deleted_email,
    'normalized_email', v_email
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- Public RPCs
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.preview_delete_user_account(
  p_target_user_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_target uuid := public.gameon_account_deletion_resolve_target_user_id(p_target_user_id);
  v_email text := public.gameon_account_deletion_resolve_email(v_target);
  v_block text := public.gameon_account_deletion_block_reason(v_target);
  v_avatar_paths text[] := public.gameon_account_deletion_collect_avatar_paths(v_target);
  v_estimates jsonb := public.gameon_account_deletion_estimate_counts(v_target, v_email);
BEGIN
  RETURN jsonb_build_object(
    'ok', true,
    'blocked', v_block IS NOT NULL,
    'block_reason', v_block,
    'target_user_id', v_target,
    'normalized_email', v_email,
    'deletion_mode', 'soft',
    'auth_users_deleted', false,
    'account_identities_deleted', false,
    'email_released', false,
    'estimated_counts', v_estimates,
    'avatar_storage_paths', to_jsonb(coalesce(v_avatar_paths, ARRAY[]::text[])),
    'preserved_domains', jsonb_build_array(
      'direct_messages', 'direct_conversations', 'user_reports', 'message_reports',
      'conversation_reports', 'venue_reports', 'comment_reports',
      'support_requests', 'support_conversations', 'support_messages',
      'user_bans', 'admin_audit'
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.start_account_deletion_job(
  p_idempotency_key text DEFAULT NULL,
  p_target_user_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_target uuid := public.gameon_account_deletion_resolve_target_user_id(p_target_user_id);
  v_key text := coalesce(nullif(btrim(p_idempotency_key), ''), 'self:' || v_target::text);
  v_existing public.account_deletion_jobs%ROWTYPE;
  v_preview jsonb;
  v_block text;
  v_job_id uuid;
BEGIN
  PERFORM public.gameon_account_deletion_assert_deletable(v_target);

  SELECT *
    INTO v_existing
  FROM public.account_deletion_jobs j
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
  FROM public.account_deletion_jobs j
  WHERE j.subject_user_id = v_target
    AND j.status IN ('queued', 'previewed', 'running', 'db_committed', 'storage_pending', 'auth_pending')
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

  v_preview := public.preview_delete_user_account(v_target);
  v_block := v_preview ->> 'block_reason';

  INSERT INTO public.account_deletion_jobs (
    subject_user_id,
    requested_by_user_id,
    request_source,
    deletion_mode,
    status,
    stage,
    idempotency_key,
    preview_snapshot,
    block_reason
  )
  VALUES (
    v_target,
    v_actor,
    CASE WHEN public.gameon_account_deletion_is_service_caller() AND v_target IS DISTINCT FROM v_actor
      THEN 'admin' ELSE 'self_service' END,
    'soft',
    'queued',
    'previewed',
    v_key,
    v_preview,
    v_block
  )
  RETURNING id INTO v_job_id;

  RETURN jsonb_build_object(
    'ok', true,
    'job_id', v_job_id,
    'status', 'queued',
    'stage', 'previewed',
    'reused', false,
    'preview', v_preview
  );
EXCEPTION
  WHEN unique_violation THEN
    SELECT j.id, j.status, j.stage
      INTO v_job_id, v_existing.status, v_existing.stage
    FROM public.account_deletion_jobs j
    WHERE j.idempotency_key = v_key
       OR (
         j.subject_user_id = v_target
         AND j.status IN ('queued', 'previewed', 'running', 'db_committed', 'storage_pending', 'auth_pending')
       )
    ORDER BY j.created_at DESC
    LIMIT 1;

    RETURN jsonb_build_object(
      'ok', true,
      'job_id', v_job_id,
      'status', v_existing.status,
      'stage', v_existing.stage,
      'reused', true
    );
END;
$$;

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

-- Remove legacy overload from earlier drafts before defining the canonical signature.
DROP FUNCTION IF EXISTS public.advance_account_deletion_job(uuid, text, text, text, text, boolean);

CREATE OR REPLACE FUNCTION public.advance_account_deletion_job(
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
  v_job public.account_deletion_jobs%ROWTYPE;
  v_action text := lower(btrim(coalesce(p_action, '')));
BEGIN
  IF NOT public.gameon_account_deletion_is_service_caller() THEN
    RAISE EXCEPTION 'advance_account_deletion_job is restricted to service_role'
      USING ERRCODE = '42501';
  END IF;

  IF p_job_id IS NULL THEN
    RAISE EXCEPTION 'job_id is required' USING ERRCODE = '22023';
  END IF;

  IF v_action NOT IN ('mark_storage_pending', 'mark_completed', 'mark_storage_partial') THEN
    RAISE EXCEPTION 'Invalid account deletion job action: %', p_action
      USING ERRCODE = '22023';
  END IF;

  SELECT *
    INTO v_job
  FROM public.account_deletion_jobs
  WHERE id = p_job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Account deletion job not found: %', p_job_id USING ERRCODE = 'P0002';
  END IF;

  IF v_job.status = 'completed' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'job_id', v_job.id,
      'status', v_job.status,
      'stage', v_job.stage,
      'completed_at', v_job.completed_at,
      'idempotent_replay', true
    );
  END IF;

  IF v_action = 'mark_storage_pending' THEN
    IF v_job.status NOT IN ('db_committed', 'storage_pending') THEN
      RAISE EXCEPTION 'Cannot mark storage pending from status %', v_job.status
        USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.account_deletion_jobs
    SET status = 'storage_pending',
        stage = 'storage_cleanup',
        error_code = NULL,
        error_detail = NULL
    WHERE id = p_job_id
    RETURNING * INTO v_job;
  ELSIF v_action = 'mark_completed' THEN
    IF v_job.status <> 'storage_pending' THEN
      RAISE EXCEPTION 'Cannot mark completed from status %', v_job.status
        USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.account_deletion_jobs
    SET status = 'completed',
        stage = 'completed',
        error_code = NULL,
        error_detail = NULL,
        completed_at = coalesce(completed_at, now())
    WHERE id = p_job_id
    RETURNING * INTO v_job;
  ELSIF v_action = 'mark_storage_partial' THEN
    IF v_job.status <> 'storage_pending' THEN
      RAISE EXCEPTION 'Cannot mark storage partial failure from status %', v_job.status
        USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.account_deletion_jobs
    SET status = 'storage_pending',
        stage = 'storage_cleanup_partial',
        error_code = coalesce(nullif(btrim(p_error_code), ''), 'storage_cleanup_partial'),
        error_detail = p_error_detail
    WHERE id = p_job_id
    RETURNING * INTO v_job;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'job_id', v_job.id,
    'status', v_job.status,
    'stage', v_job.stage,
    'completed_at', v_job.completed_at,
    'idempotent_replay', false
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.queue_account_deletion_finalize(
  p_job_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_url text;
  v_service_role_key text;
BEGIN
  IF NOT public.gameon_account_deletion_is_service_caller() THEN
    RAISE EXCEPTION 'queue_account_deletion_finalize is restricted to service_role'
      USING ERRCODE = '42501';
  END IF;

  IF p_job_id IS NULL THEN
    RETURN jsonb_build_object(
      'queued', false,
      'result', 'failed',
      'detail', 'job_id is required'
    );
  END IF;

  IF to_regnamespace('net') IS NULL OR to_regclass('vault.decrypted_secrets') IS NULL THEN
    RETURN jsonb_build_object(
      'queued', false,
      'result', 'skipped_pg_net_unavailable'
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
      'result', 'skipped_missing_secrets'
    );
  END IF;

  PERFORM net.http_post(
    url := v_url || '/functions/v1/finalize-account-deletion',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_service_role_key
    ),
    body := jsonb_build_object('job_id', p_job_id),
    timeout_milliseconds := 30000
  );

  RETURN jsonb_build_object(
    'queued', true,
    'result', 'queued'
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'queued', false,
      'result', 'failed',
      'detail', SQLERRM
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.request_delete_my_account()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_target uuid := auth.uid();
  v_start jsonb;
  v_execute jsonb;
  v_finalize jsonb := '{}'::jsonb;
  v_job_id uuid;
  v_job public.account_deletion_jobs%ROWTYPE;
  v_finalize_queued boolean := false;
BEGIN
  IF v_target IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
  END IF;

  v_start := public.start_account_deletion_job(NULL, v_target);
  v_job_id := (v_start ->> 'job_id')::uuid;

  v_execute := public.execute_delete_user_account_db(v_job_id);

  IF coalesce((v_execute ->> 'ok')::boolean, false) THEN
    IF public.gameon_account_deletion_is_service_caller() THEN
      v_finalize := public.queue_account_deletion_finalize(v_job_id);
      v_finalize_queued := coalesce((v_finalize ->> 'queued')::boolean, false);

      IF v_finalize_queued THEN
        UPDATE public.account_deletion_jobs
        SET status = 'storage_pending',
            stage = 'storage_finalize_queued'
        WHERE id = v_job_id
          AND status = 'db_committed';
      END IF;
    ELSE
      v_finalize := jsonb_build_object(
        'queued', false,
        'result', 'skipped_client_finalize'
      );
    END IF;
  END IF;

  SELECT *
    INTO v_job
  FROM public.account_deletion_jobs
  WHERE id = v_job_id;

  RETURN v_execute
    || jsonb_build_object(
      'job_id', v_job_id,
      'status', v_job.status,
      'stage', v_job.stage,
      'finalize_queue', v_finalize,
      'finalize_queued', v_finalize_queued
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- Identity guard: scoped anonymization bypass
-- ---------------------------------------------------------------------------
-- During soft-delete, user_profiles.email is rewritten to a deleted-local
-- address while account_identities retains the original email (Phase 2).
-- The fan identity guard normally requires profile email = auth.users email.
-- gameon_account_deletion_soft_delete_core sets a transaction-local GUC that
-- only matches the subject user id; the helper is not granted to clients.

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
BEGIN
  IF v_anonymize_bypass IS NOT NULL AND NEW.id::text = v_anonymize_bypass THEN
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
-- Grants
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.gameon_account_deletion_is_service_caller() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_account_deletion_resolve_target_user_id(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_account_deletion_resolve_email(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_account_deletion_profile_is_anonymized(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_account_deletion_block_reason(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_account_deletion_assert_deletable(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_account_deletion_collect_avatar_paths(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_account_deletion_count_if_exists(regclass, text, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_account_deletion_estimate_counts(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_account_deletion_soft_delete_core(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.queue_account_deletion_finalize(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.advance_account_deletion_job(uuid, text, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.preview_delete_user_account(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.preview_delete_user_account(uuid) TO service_role;

GRANT EXECUTE ON FUNCTION public.start_account_deletion_job(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.start_account_deletion_job(text, uuid) TO service_role;

GRANT EXECUTE ON FUNCTION public.execute_delete_user_account_db(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.execute_delete_user_account_db(uuid) TO service_role;

GRANT EXECUTE ON FUNCTION public.request_delete_my_account() TO authenticated;

GRANT EXECUTE ON FUNCTION public.advance_account_deletion_job(uuid, text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.queue_account_deletion_finalize(uuid) TO service_role;

COMMENT ON FUNCTION public.preview_delete_user_account(uuid) IS
  'Preview fan account soft deletion impact. Self-service uses auth.uid(); service_role may pass explicit target for future admin preview.';

COMMENT ON FUNCTION public.start_account_deletion_job(text, uuid) IS
  'Creates or reuses an active account_deletion_jobs row after server-side block checks. Phase 2 soft mode only.';

COMMENT ON FUNCTION public.execute_delete_user_account_db(uuid) IS
  'Transactional fan soft-delete cleanup for a job. Does not delete auth.users or account_identities.';

COMMENT ON FUNCTION public.advance_account_deletion_job(uuid, text, text, text) IS
  'Service-role only. Whitelisted job transitions: mark_storage_pending, mark_completed, mark_storage_partial. completed is terminal.';

COMMENT ON FUNCTION public.queue_account_deletion_finalize(uuid) IS
  'Service-role only. Enqueues finalize-account-deletion Edge Function via pg_net. Returns structured queue result.';

COMMENT ON FUNCTION public.request_delete_my_account() IS
  'Fan self-service orchestrator: start job, execute DB soft-delete, optionally queue storage finalize when called as service_role. Authenticated clients finalize storage via Edge Function directly. Auth deletion disabled in Phase 2.';
