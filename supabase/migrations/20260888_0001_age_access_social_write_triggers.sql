-- =============================================================================
-- 20260888 — Attach 13+ age-access triggers to social write tables
-- =============================================================================
--
-- STATUS: PREPARED ONLY — DO NOT APPLY from the agent. Apply on STAGING after
-- 20260886 and 20260887. Never applied anywhere — corrected in place.
--
-- Strategy: data-layer enforcement. BEFORE INSERT OR UPDATE trigger
-- (public.enforce_age_access_social_write from 20260887) on each social table.
-- Covers direct PostgREST writes and SECURITY DEFINER RPCs (auth.uid() remains
-- the end user). DELETE is intentionally NOT gated.
--
-- DECISION — user_favorite_teams:
--   GATED. Favorite-team writes are profile personalization that feeds social
--   surfaces (public profile, Discover, Following). Reads remain unrestricted
--   by this trigger (SELECT policies unchanged). The prior comment that listed
--   user_favorite_teams as "intentionally not gated" contradicted the attach
--   array; this migration makes SQL + comments agree: GATE writes.
--
-- INTENTIONALLY NOT GATED (allowed for blocked / unresolved users):
--   support_requests / support_conversations / support_messages
--   account_deletion_jobs / business_account_deletion_jobs
--   blocked_users
--   message_reports / conversation_reports / group_message_reports /
--   group_conversation_reports / venue_reports
--   user_notification_preferences / user_push_tokens
--   user_profiles — handled by dedicated age freeze + social-field triggers
--
-- REQUIRED vs OPTIONAL:
--   Required core FanGeo social tables MUST exist; missing ones FAIL preflight.
--   Optional feature tables may be absent and are skipped with NOTICE.
-- =============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.enforce_age_access_social_write()') IS NULL THEN
    RAISE EXCEPTION '20260888 preflight failed: apply 20260887_0001_age_access_enforcement_core.sql first';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- Required tables — fail migration if absent
-- -----------------------------------------------------------------------------

DO $$
DECLARE
  v_table text;
  v_missing text[] := ARRAY[]::text[];
  v_required text[] := ARRAY[
    -- Friendship / social graph (core)
    'friendships',
    'profile_pokes',
    -- Direct messaging (core)
    'direct_conversations',
    'direct_messages',
    -- Group chat (core product surface)
    'group_conversations',
    'group_conversation_members',
    'group_conversation_invitations',
    'group_messages',
    -- Pickup games (core)
    'pickup_games',
    'pickup_game_requests',
    'pickup_game_invites',
    'pickup_game_creator_ratings',
    -- Venue / event UGC + ratings (core Going / Live social)
    'venue_event_comments',
    'venue_event_comment_likes',
    'venue_event_vibes',
    'venue_event_interests',
    'venue_ratings',
    -- Profile personalization feeding social surfaces (GATED by design)
    'user_favorite_teams',
    -- Pro-game social predictions / saves (core Going / Live)
    'pro_game_predictions',
    'saved_pro_games'
  ];
BEGIN
  FOREACH v_table IN ARRAY v_required LOOP
    IF to_regclass(format('public.%I', v_table)) IS NULL THEN
      v_missing := v_missing || ARRAY[format('public.%I', v_table)];
    END IF;
  END LOOP;

  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION
      '20260888 preflight failed; required social tables missing: %. Restore schema before applying age-access triggers.',
      array_to_string(v_missing, ', ');
  END IF;
END $$;

DO $$
DECLARE
  v_table text;
  v_required text[] := ARRAY[
    'friendships',
    'profile_pokes',
    'direct_conversations',
    'direct_messages',
    'group_conversations',
    'group_conversation_members',
    'group_conversation_invitations',
    'group_messages',
    'pickup_games',
    'pickup_game_requests',
    'pickup_game_invites',
    'pickup_game_creator_ratings',
    'venue_event_comments',
    'venue_event_comment_likes',
    'venue_event_vibes',
    'venue_event_interests',
    'venue_ratings',
    'user_favorite_teams',
    'pro_game_predictions',
    'saved_pro_games'
  ];
BEGIN
  FOREACH v_table IN ARRAY v_required LOOP
    EXECUTE format(
      'DROP TRIGGER IF EXISTS trg_age_access_social_write ON public.%I',
      v_table
    );
    EXECUTE format(
      'CREATE TRIGGER trg_age_access_social_write
         BEFORE INSERT OR UPDATE ON public.%I
         FOR EACH ROW
         EXECUTE FUNCTION public.enforce_age_access_social_write()',
      v_table
    );
    RAISE NOTICE '20260888: trg_age_access_social_write attached to REQUIRED public.%', v_table;
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- Optional feature tables — skip with NOTICE if absent
-- -----------------------------------------------------------------------------

DO $$
DECLARE
  v_table text;
  v_optional text[] := ARRAY[
    'profile_likes',
    'venue_event_comment_reactions',
    'venue_event_predictions',
    'pro_game_alert_subscriptions'
  ];
BEGIN
  FOREACH v_table IN ARRAY v_optional LOOP
    IF to_regclass(format('public.%I', v_table)) IS NULL THEN
      RAISE NOTICE '20260888: optional table public.% not present, skipping trigger attach', v_table;
      CONTINUE;
    END IF;

    EXECUTE format(
      'DROP TRIGGER IF EXISTS trg_age_access_social_write ON public.%I',
      v_table
    );
    EXECUTE format(
      'CREATE TRIGGER trg_age_access_social_write
         BEFORE INSERT OR UPDATE ON public.%I
         FOR EACH ROW
         EXECUTE FUNCTION public.enforce_age_access_social_write()',
      v_table
    );
    RAISE NOTICE '20260888: trg_age_access_social_write attached to OPTIONAL public.%', v_table;
  END LOOP;
END $$;

COMMIT;
