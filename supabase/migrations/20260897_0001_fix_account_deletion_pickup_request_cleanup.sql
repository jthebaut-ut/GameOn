-- Fix fan account deletion db_cleanup failures caused by pickup_request_cancel_forbidden.
--
-- Proven production failure:
--   execute_delete_user_account_db → gameon_account_deletion_soft_delete_core
--   → bulk UPDATE public.pickup_game_requests
--   conflicts with pickup_game_requests_before_update_status (auth.uid()-gated interactive rules)
--   SQLSTATE 23514 / pickup_request_cancel_forbidden
--
-- Fix:
--   1) Status-aware, idempotent request transitions during deletion (no cancelled→withdrawn etc.)
--   2) Trusted, transaction-local deletion context via existing GUC
--      gameon.account_deletion_anonymize = subject user id
--      (same convention as identity-guard anonymize bypass; only set inside soft-delete core)
--   3) Trigger honors that context only for an allowlisted terminal transition matrix
--      scoped to the deletion subject (requester or removed-game organizer).
--
-- Normal interactive pickup authorization remains unchanged when the GUC is unset.
-- Forward-only. Do not edit prior migrations. Manual apply only.

-- ---------------------------------------------------------------------------
-- 1) Status-aware pickup request closer (deletion-only helper)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gameon_account_deletion_close_pickup_requests(
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_extra text := '';
  v_count integer := 0;
  v_total integer := 0;
  v_counts jsonb := '{}'::jsonb;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'p_user_id is required' USING ERRCODE = '22023';
  END IF;

  IF to_regclass('public.pickup_game_requests') IS NULL THEN
    RETURN v_counts;
  END IF;

  -- Trusted deletion context for the pickup status trigger (transaction-local).
  -- Soft-delete core also sets this before calling; idempotent here for safety.
  PERFORM set_config('gameon.account_deletion_anonymize', p_user_id::text, true);

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'pickup_game_requests' AND column_name = 'updated_at'
  ) THEN
    v_extra := v_extra || ', updated_at = now()';
  END IF;
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'pickup_game_requests' AND column_name = 'responded_at'
  ) THEN
    v_extra := v_extra || ', responded_at = coalesce(responded_at, now())';
  END IF;

  -- Requester: approved → withdrawn (canonical joiner back-out after approval).
  EXECUTE format(
    'UPDATE public.pickup_game_requests
        SET status = ''withdrawn''%s
      WHERE requester_user_id = $1
        AND status = ''approved''',
    v_extra
  ) USING p_user_id;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_total := v_total + v_count;
  v_counts := v_counts || jsonb_build_object('pickup_game_requests_approved_withdrawn', v_count);

  -- Requester: pending → cancelled (terminal; leave rejected/cancelled/withdrawn alone).
  EXECUTE format(
    'UPDATE public.pickup_game_requests
        SET status = ''cancelled''%s
      WHERE requester_user_id = $1
        AND status = ''pending''',
    v_extra
  ) USING p_user_id;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  v_total := v_total + v_count;
  v_counts := v_counts || jsonb_build_object('pickup_game_requests_pending_cancelled', v_count);

  -- Organizer: after owned games are status=removed, close remaining open join rows.
  -- Idempotent: only pending/approved; terminal rows unchanged.
  IF to_regclass('public.pickup_games') IS NOT NULL THEN
    EXECUTE format(
      'UPDATE public.pickup_game_requests
          SET status = ''cancelled''%s
        WHERE status IN (''pending'', ''approved'')
          AND pickup_game_id IN (
            SELECT g.id
            FROM public.pickup_games g
            WHERE g.creator_user_id = $1
              AND g.status IN (''removed'', ''expired'')
          )',
      v_extra
    ) USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_total := v_total + v_count;
    v_counts := v_counts || jsonb_build_object('pickup_game_requests_cancelled_for_created_games', v_count);
  ELSE
    v_counts := v_counts || jsonb_build_object('pickup_game_requests_cancelled_for_created_games', 0);
  END IF;

  v_counts := v_counts || jsonb_build_object('pickup_game_requests_closed_total', v_total);
  RETURN v_counts;
END;
$$;

REVOKE ALL ON FUNCTION public.gameon_account_deletion_close_pickup_requests(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_account_deletion_close_pickup_requests(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.gameon_account_deletion_close_pickup_requests(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.gameon_account_deletion_close_pickup_requests(uuid) TO service_role;

COMMENT ON FUNCTION public.gameon_account_deletion_close_pickup_requests(uuid) IS
  'Deletion-only status-aware pickup_game_requests closer. Invoked from soft-delete core; not client-callable. Uses transaction-local gameon.account_deletion_anonymize.';

-- ---------------------------------------------------------------------------
-- 2) Trigger: keep interactive rules; allow deletion-only allowlist under GUC
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.pickup_game_requests_before_update_status()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  is_creator boolean;
  need int;
  cur int;
  game_removed boolean;
  v_deletion_subject_text text := nullif(btrim(current_setting('gameon.account_deletion_anonymize', true)), '');
  v_deletion_subject uuid;
BEGIN
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- Trusted account-deletion context (set only inside soft-delete SECURITY DEFINER path).
  -- Fail closed: only allowlisted terminal transitions for the deletion subject.
  IF v_deletion_subject_text IS NOT NULL THEN
    BEGIN
      v_deletion_subject := v_deletion_subject_text::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      v_deletion_subject := NULL;
    END;

    IF v_deletion_subject IS NOT NULL THEN
      IF NEW.status = 'withdrawn'
         AND OLD.status = 'approved'
         AND NEW.requester_user_id = v_deletion_subject THEN
        RETURN NEW;
      END IF;

      IF NEW.status = 'cancelled'
         AND OLD.status IN ('pending', 'approved', 'rejected')
         AND NEW.requester_user_id = v_deletion_subject THEN
        RETURN NEW;
      END IF;

      IF NEW.status = 'cancelled'
         AND OLD.status IN ('pending', 'approved')
         AND EXISTS (
           SELECT 1
           FROM public.pickup_games g
           WHERE g.id = NEW.pickup_game_id
             AND g.creator_user_id = v_deletion_subject
             AND g.status IN ('removed', 'expired')
         ) THEN
        RETURN NEW;
      END IF;
      -- Non-allowlisted transition under deletion GUC: fall through to interactive rules.
    END IF;
  END IF;

  SELECT (g.creator_user_id = (SELECT auth.uid())) INTO is_creator
  FROM public.pickup_games g
  WHERE g.id = NEW.pickup_game_id;

  SELECT EXISTS (
    SELECT 1 FROM public.pickup_games g
    WHERE g.id = NEW.pickup_game_id
      AND g.status = 'removed'
  ) INTO game_removed;

  IF NEW.status = 'cancelled' THEN
    IF NEW.requester_user_id = (SELECT auth.uid())
       AND OLD.status IN ('pending', 'approved', 'rejected') THEN
      RETURN NEW;
    ELSIF is_creator
          AND game_removed
          AND OLD.status IN ('pending', 'approved') THEN
      RETURN NEW;
    ELSE
      RAISE EXCEPTION 'pickup_request_cancel_forbidden' USING ERRCODE = 'check_violation';
    END IF;
  ELSIF NEW.status = 'withdrawn' THEN
    IF NEW.requester_user_id IS DISTINCT FROM (SELECT auth.uid()) THEN
      RAISE EXCEPTION 'pickup_request_cancel_forbidden' USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status <> 'approved' THEN
      RAISE EXCEPTION 'pickup_request_cancel_forbidden' USING ERRCODE = 'check_violation';
    END IF;
  ELSIF NEW.status IN ('approved', 'rejected') THEN
    IF NOT is_creator OR OLD.status <> 'pending' THEN
      RAISE EXCEPTION 'pickup_request_decision_forbidden' USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status = 'approved' THEN
      PERFORM 1 FROM public.pickup_games WHERE id = NEW.pickup_game_id FOR UPDATE;
      SELECT players_needed INTO need FROM public.pickup_games WHERE id = NEW.pickup_game_id;
      SELECT count(*)::int INTO cur
      FROM public.pickup_game_requests r
      WHERE r.pickup_game_id = NEW.pickup_game_id
        AND r.status = 'approved'
        AND r.id IS DISTINCT FROM NEW.id;
      IF cur >= need THEN
        RAISE EXCEPTION 'pickup_game_full' USING ERRCODE = 'check_violation';
      END IF;
    END IF;
  ELSE
    RAISE EXCEPTION 'pickup_request_status_forbidden' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.pickup_game_requests_before_update_status() IS
  'Interactive pickup request status guard. Also allows deletion-only terminal transitions when transaction-local gameon.account_deletion_anonymize matches the subject user.';

-- ---------------------------------------------------------------------------
-- 3) Soft-delete core: set deletion GUC early; close requests status-aware
--     (Full REPLACE preserves 20260845 body; only pickup cleanup path changes.)
-- ---------------------------------------------------------------------------

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
  v_notification_where_clauses text[] := ARRAY[]::text[];
  v_sql text;
  v_count integer := 0;
  v_counts jsonb := '{}'::jsonb;
  v_pickup_request_counts jsonb := '{}'::jsonb;
BEGIN
  IF to_regclass('public.user_profiles') IS NULL THEN
    RAISE EXCEPTION 'user_profiles table is required for account deletion'
      USING ERRCODE = 'P0002';
  END IF;

  v_avatar_storage_paths := public.gameon_account_deletion_collect_avatar_paths(p_user_id);

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

  IF to_regclass('public.analytics_events') IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = 'analytics_events' AND column_name = 'user_id'
     ) THEN
    EXECUTE 'UPDATE public.analytics_events SET user_id = NULL WHERE user_id = $1' USING p_user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('analytics_events_anonymized', v_count);
  END IF;

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

  -- Trusted deletion context before pickup mutations (also used by profile anonymize below).
  PERFORM set_config('gameon.account_deletion_anonymize', p_user_id::text, true);

  IF to_regclass('public.pickup_games') IS NOT NULL THEN
    v_pickup_game_set_clauses := ARRAY[]::text[];
    -- Canonical soft-delete status is 'removed' (CHECK: active|removed|expired).
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'pickup_games' AND column_name = 'status') THEN
      v_pickup_game_set_clauses := v_pickup_game_set_clauses || ARRAY['status = ''removed'''];
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
        v_sql := replace(v_sql, 'status = ''removed''', 'status = ''expired''');
        BEGIN
          EXECUTE v_sql USING p_user_id;
          GET DIAGNOSTICS v_count = ROW_COUNT;
        EXCEPTION WHEN check_violation THEN
          v_count := 0;
        END;
      END;
      v_counts := v_counts || jsonb_build_object('pickup_games_cancelled_hidden', v_count);
    END IF;
  END IF;

  IF to_regclass('public.pickup_game_requests') IS NOT NULL THEN
    v_pickup_request_counts := public.gameon_account_deletion_close_pickup_requests(p_user_id);
    v_counts := v_counts || v_pickup_request_counts;
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

REVOKE ALL ON FUNCTION public.gameon_account_deletion_soft_delete_core(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gameon_account_deletion_soft_delete_core(uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.gameon_account_deletion_soft_delete_core(uuid, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.gameon_account_deletion_soft_delete_core(uuid, text) TO service_role;

COMMENT ON FUNCTION public.gameon_account_deletion_soft_delete_core(uuid, text) IS
  'Transactional fan soft-delete core. Pickup request cleanup is status-aware and uses transaction-local gameon.account_deletion_anonymize; display_name_normalized remains generated.';

-- ---------------------------------------------------------------------------
-- 4) Post-apply integrity
--
-- NOTE on pg_get_functiondef matching:
--   The closer builds dynamic SQL with format(), so its stored source contains
--   doubled single-quotes inside the format string literals, e.g.
--     status = ''approved''
--   A check written as position('status = ''approved''' IN ...) looks for the
--   *different* text status = 'approved' and falsely fails even when the
--   implementation is correct. Use tagged dollar-quoted needles that match the
--   doubled-quote form, plus stable result-key markers.
--
-- Quoting: this DO block uses $integrity$ / $needle$ tags so nested dollar
-- quotes cannot prematurely terminate the outer DO body (untagged $$ would).
-- ---------------------------------------------------------------------------

DO $integrity$
DECLARE
  v_soft text;
  v_trigger text;
  v_helper text;
BEGIN
  IF to_regprocedure('public.gameon_account_deletion_close_pickup_requests(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: gameon_account_deletion_close_pickup_requests missing';
  END IF;

  SELECT pg_get_functiondef('public.gameon_account_deletion_soft_delete_core(uuid,text)'::regprocedure)
    INTO v_soft;
  SELECT pg_get_functiondef('public.pickup_game_requests_before_update_status()'::regprocedure)
    INTO v_trigger;
  SELECT pg_get_functiondef('public.gameon_account_deletion_close_pickup_requests(uuid)'::regprocedure)
    INTO v_helper;

  IF position('gameon_account_deletion_close_pickup_requests' IN v_soft) = 0 THEN
    RAISE EXCEPTION 'FAIL: soft-delete core missing status-aware pickup closer call';
  END IF;

  IF position($needle$SET status = 'withdrawn'$needle$ IN v_soft) > 0
     AND position('gameon_account_deletion_close_pickup_requests' IN v_soft) = 0 THEN
    RAISE EXCEPTION 'FAIL: soft-delete still uses bulk withdrawn for all requester rows';
  END IF;

  IF position('display_name_normalized =' IN v_soft) > 0 THEN
    RAISE EXCEPTION 'FAIL: soft-delete core assigns display_name_normalized';
  END IF;

  IF position('gameon.account_deletion_anonymize' IN v_soft) = 0 THEN
    RAISE EXCEPTION 'FAIL: soft-delete core missing deletion GUC';
  END IF;

  IF position('gameon.account_deletion_anonymize' IN v_trigger) = 0 THEN
    RAISE EXCEPTION 'FAIL: pickup status trigger missing deletion GUC allowlist';
  END IF;

  IF position('auth.uid()' IN v_trigger) = 0 THEN
    RAISE EXCEPTION 'FAIL: pickup status trigger lost interactive auth.uid() rules';
  END IF;

  -- Structural markers for the three intended closer transitions (stable keys).
  IF position('pickup_game_requests_approved_withdrawn' IN v_helper) = 0 THEN
    RAISE EXCEPTION 'FAIL: pickup closer missing approved→withdrawn result key';
  END IF;
  IF position('pickup_game_requests_pending_cancelled' IN v_helper) = 0 THEN
    RAISE EXCEPTION 'FAIL: pickup closer missing pending→cancelled result key';
  END IF;
  IF position('pickup_game_requests_cancelled_for_created_games' IN v_helper) = 0 THEN
    RAISE EXCEPTION 'FAIL: pickup closer missing organizer-cancel result key';
  END IF;

  -- Filters as they appear in pg_get_functiondef (doubled quotes inside format()).
  IF position($needle$AND status = ''approved''$needle$ IN v_helper) = 0 THEN
    RAISE EXCEPTION 'FAIL: pickup closer missing approved requester filter';
  END IF;
  IF position($needle$AND status = ''pending''$needle$ IN v_helper) = 0 THEN
    RAISE EXCEPTION 'FAIL: pickup closer missing pending requester filter';
  END IF;
  IF position($needle$status IN (''pending'', ''approved'')$needle$ IN v_helper) = 0 THEN
    RAISE EXCEPTION 'FAIL: pickup closer missing organizer pending/approved filter';
  END IF;
  IF position($needle$status IN (''removed'', ''expired'')$needle$ IN v_helper) = 0 THEN
    RAISE EXCEPTION 'FAIL: pickup closer missing removed/expired game gate for organizer cancels';
  END IF;
  IF position($needle$SET status = ''withdrawn''$needle$ IN v_helper) = 0 THEN
    RAISE EXCEPTION 'FAIL: pickup closer missing approved→withdrawn assignment';
  END IF;
  IF position($needle$SET status = ''cancelled''$needle$ IN v_helper) = 0 THEN
    RAISE EXCEPTION 'FAIL: pickup closer missing →cancelled assignment';
  END IF;

  -- Negative: terminal requester statuses must not be selected via AND status = ... filters.
  -- (Do not match SET status = ''cancelled'' / ''withdrawn'' assignments.)
  IF position($needle$AND status = ''cancelled''$needle$ IN v_helper) > 0 THEN
    RAISE EXCEPTION 'FAIL: pickup closer must not filter on status=cancelled (no cancelled→* rewrites)';
  END IF;
  IF position($needle$AND status = ''withdrawn''$needle$ IN v_helper) > 0 THEN
    RAISE EXCEPTION 'FAIL: pickup closer must not filter on status=withdrawn (no withdrawn→* rewrites)';
  END IF;
  IF position($needle$AND status = ''rejected''$needle$ IN v_helper) > 0 THEN
    RAISE EXCEPTION 'FAIL: pickup closer must not filter on status=rejected (rejected stays unchanged)';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.role_routine_grants g
    WHERE g.specific_schema = 'public'
      AND g.routine_name = 'gameon_account_deletion_close_pickup_requests'
      AND g.privilege_type = 'EXECUTE'
      AND g.grantee IN ('PUBLIC', 'anon', 'authenticated')
  ) OR has_function_privilege('anon', 'public.gameon_account_deletion_close_pickup_requests(uuid)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.gameon_account_deletion_close_pickup_requests(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: pickup closer executable by PUBLIC/anon/authenticated';
  END IF;

  IF NOT has_function_privilege('service_role', 'public.gameon_account_deletion_close_pickup_requests(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: service_role cannot EXECUTE pickup closer';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.role_routine_grants g
    WHERE g.specific_schema = 'public'
      AND g.routine_name = 'gameon_account_deletion_soft_delete_core'
      AND g.privilege_type = 'EXECUTE'
      AND g.grantee IN ('PUBLIC', 'anon', 'authenticated')
  ) OR has_function_privilege('anon', 'public.gameon_account_deletion_soft_delete_core(uuid,text)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.gameon_account_deletion_soft_delete_core(uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: soft-delete core executable by PUBLIC/anon/authenticated';
  END IF;

  IF NOT has_function_privilege('service_role', 'public.gameon_account_deletion_soft_delete_core(uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: service_role cannot EXECUTE soft-delete core';
  END IF;
END;
$integrity$;
