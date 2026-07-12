-- Corrective fix for fan account deletion DB execute failures.
-- Do not edit 20260843 in production; apply as a follow-up migration only.
--
-- Verified production failure (account_deletion_jobs):
--   status = failed, stage = db_cleanup
--   error_code = 428C9
--   error_detail = column "display_name_normalized" can only be updated to DEFAULT
--
-- Root cause: gameon_account_deletion_soft_delete_core assigned display_name_normalized = NULL
-- inside the profile anonymization UPDATE, but user_profiles.display_name_normalized is
-- GENERATED ALWAYS AS NULLIF(lower(trim(display_name)), '').
-- PostgreSQL rejects explicit writes to generated columns (SQLSTATE 428C9).
--
-- Fix: remove the explicit display_name_normalized assignment; tombstone display_name to
-- 'Deleted User' and let PostgreSQL derive display_name_normalized as 'deleted user'.
-- No other GENERATED ALWAYS columns exist on user_profiles in the current schema.

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
  -- display_name_normalized is GENERATED ALWAYS from display_name; it recomputes when
  -- display_name is tombstoned to 'Deleted User' and must not be assigned directly.
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

COMMENT ON FUNCTION public.gameon_account_deletion_soft_delete_core(uuid, text) IS
  'Transactional fan soft-delete core. display_name_normalized is derived from tombstoned display_name; identity-guard bypass remains transaction-local.';

-- Post-apply integrity: soft-delete core must not write to generated display_name_normalized.
DO $$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef('public.gameon_account_deletion_soft_delete_core(uuid,text)'::regprocedure)
    INTO v_def;

  IF position('display_name_normalized =' IN v_def) > 0 THEN
    RAISE EXCEPTION 'FAIL: gameon_account_deletion_soft_delete_core still assigns display_name_normalized directly';
  END IF;

  IF position('gameon.account_deletion_anonymize' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: gameon_account_deletion_soft_delete_core missing identity-guard bypass GUC';
  END IF;
END;
$$;
