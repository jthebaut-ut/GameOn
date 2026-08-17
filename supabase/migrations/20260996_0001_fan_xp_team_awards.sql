-- =============================================================================
-- 20260996_0001 — Fan XP: Team participation awards
-- =============================================================================
-- Extends the existing Fan XP ledger (user_xp / xp_events / claim_fan_xp /
-- fan_xp_amount_for_source / fan_xp_validate_and_resolve / unique
-- uq_xp_events_user_source_dedup). Does NOT create a second XP system.
--
-- Existing amounts UNCHANGED:
--   favorite_venue 2 | venue_event_interest 5 | pickup_create 20
--   pickup_join_approved 10 | pickup_complete 15 | friend_connected 5
--
-- New sources (server-authoritative; clients cannot choose amounts):
--   team_created                  +20  source_id = team_id
--   team_join_player              +10  source_id = team_id  (account is_player only)
--   team_event_created            +5   source_id = pickup_game_id
--   team_event_completed_player   +10  source_id = pickup_game_id
--   team_event_completed_organizer +15 source_id = pickup_game_id
--
-- Player-seat rules:
--   ACCOUNT ACCESS ≠ MYSELF PLAYER SEAT ≠ MANAGED PLAYER SEAT
--   Join XP: user_id = auth account, managed_player_id IS NULL, is_player = true.
--   Guardian does not earn join/player-complete XP for Emma.
--   No separate child XP account (none exists).
--
-- Team events live on pickup_games + fan_team_game_links.
-- Announcement is NOT a real event (no create / complete XP).
-- Camp is not a persisted game_format; ignored.
--
-- Awards are trigger-driven (not Swift-only) and idempotent via
-- (user_id, source, source_id). Failures never roll back Team writes.
-- pickup_create / pickup_complete are rejected for team-linked rows so
-- Team events cannot also collect Pickup host/complete XP.
--
-- Anti-farming (XP only; Team creation itself is unchanged):
--   team_created: first 5 awards per account lifetime. create_fan_team is
--     already 20/hour, but new UUIDs would otherwise be an XP faucet.
--     Creating more Teams is allowed; they simply stop earning +20.
--   team_event_created: 8 awards per account per UTC day. Meaningful
--     schedule planning is rewarded; disposable Practice spam is not.
--
-- Existing members: NO backfill. Join XP is transition-aware only
--   (INSERT of an eligible account player seat, or UPDATE into that
--   state). Already-active players are not awarded on unrelated UPDATEs.
--   claim_fan_xp cannot backfill historical seats.
--
-- Completion-before-link: link_pickup_game_to_fan_team requires status
--   active, so the normal workflow cannot complete then link. The link
--   trigger still evaluates completion as defense in depth.
--
-- PREPARE ONLY — do not auto-apply. No Edge deploy.
-- =============================================================================

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.user_xp') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.user_xp'];
  END IF;
  IF to_regclass('public.xp_events') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.xp_events'];
  END IF;
  IF to_regclass('public.fan_teams') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_teams'];
  END IF;
  IF to_regclass('public.fan_team_members') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_team_members'];
  END IF;
  IF to_regclass('public.fan_team_game_links') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_team_game_links'];
  END IF;
  IF to_regclass('public.pickup_games') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.pickup_games'];
  END IF;
  IF to_regprocedure('public.fan_xp_amount_for_source(text)') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_xp_amount_for_source(text)'];
  END IF;
  IF to_regprocedure('public.fan_xp_apply_award_internal(uuid, integer, text, uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_xp_apply_award_internal'];
  END IF;
  IF to_regprocedure('public.fan_xp_validate_and_resolve(text, uuid, uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_xp_validate_and_resolve'];
  END IF;
  IF to_regprocedure('public.claim_fan_xp(text, uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['claim_fan_xp(text, uuid)'];
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'fan_team_members' AND column_name = 'is_player'
  ) THEN
    v_missing := v_missing || ARRAY['column fan_team_members.is_player'];
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public' AND indexname = 'uq_xp_events_user_source_dedup'
  ) THEN
    v_missing := v_missing || ARRAY['index uq_xp_events_user_source_dedup'];
  END IF;
  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION
      '20260996_0001 prerequisite missing: %',
      array_to_string(v_missing, ', ');
  END IF;
END $$;

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Canonical amounts (existing + Team)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_xp_amount_for_source(p_source text)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(trim(coalesce(p_source, '')))
    WHEN 'favorite_venue' THEN 2
    WHEN 'venue_event_interest' THEN 5
    WHEN 'pickup_create' THEN 20
    WHEN 'pickup_join_approved' THEN 10
    WHEN 'pickup_complete' THEN 15
    WHEN 'friend_connected' THEN 5
    WHEN 'team_created' THEN 20
    WHEN 'team_join_player' THEN 10
    WHEN 'team_event_created' THEN 5
    WHEN 'team_event_completed_player' THEN 10
    WHEN 'team_event_completed_organizer' THEN 15
    ELSE NULL
  END;
$$;

REVOKE ALL ON FUNCTION public.fan_xp_amount_for_source(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fan_xp_amount_for_source(text) TO authenticated;

COMMENT ON FUNCTION public.fan_xp_amount_for_source(text) IS
  'Authoritative Fan XP amounts by source. Clients cannot override. '
  '20260996 adds Team sources; existing Pickup/venue/friend amounts unchanged.';

-- ---------------------------------------------------------------------------
-- 2) Team event helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_xp_is_real_team_event_format(p_format text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT lower(btrim(coalesce(p_format, ''))) IN (
    'practice',
    'scrimmage',
    'match',
    'league_game',
    'tournament_game',
    'tryout',
    'clinic',
    'team_meeting',
    'other',
    'pickup'
  );
$$;

COMMENT ON FUNCTION public.fan_xp_is_real_team_event_format(text) IS
  'True for published Team event formats that earn create/complete XP. '
  'Announcement is excluded. Camp is not a persisted format.';

CREATE OR REPLACE FUNCTION public.fan_xp_team_event_is_completed(
  p_status text,
  p_archived_at timestamptz
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    lower(btrim(coalesce(p_status, ''))) IS DISTINCT FROM 'removed'
    AND (
      lower(btrim(coalesce(p_status, ''))) = 'expired'
      OR p_archived_at IS NOT NULL
    );
$$;

CREATE OR REPLACE FUNCTION public.fan_xp_account_participated_in_team_event(
  p_user_id uuid,
  p_pickup_game_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT p_user_id IS NOT NULL
    AND p_pickup_game_id IS NOT NULL
    AND (
      EXISTS (
        SELECT 1
        FROM public.pickup_game_requests r
        WHERE r.pickup_game_id = p_pickup_game_id
          AND r.requester_user_id = p_user_id
          AND lower(btrim(coalesce(r.status, ''))) = 'approved'
      )
      OR EXISTS (
        SELECT 1
        FROM public.fan_team_event_lineups l
        JOIN public.fan_team_event_lineup_members lm
          ON lm.lineup_id = l.id
        WHERE l.pickup_game_id = p_pickup_game_id
          AND lower(btrim(coalesce(l.status, ''))) = 'published'
          AND lm.user_id = p_user_id
      )
    );
$$;

REVOKE ALL ON FUNCTION public.fan_xp_account_participated_in_team_event(uuid, uuid) FROM PUBLIC;

-- Anti-farming constants (mirrored by FanXPTeamAwardPolicy in iOS).
CREATE OR REPLACE FUNCTION public.fan_xp_team_created_lifetime_cap()
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 5;
$$;

CREATE OR REPLACE FUNCTION public.fan_xp_team_event_created_daily_cap()
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 8;
$$;

CREATE OR REPLACE FUNCTION public.fan_xp_team_created_cap_allows(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT p_user_id IS NOT NULL
    AND (
      SELECT COUNT(*)
      FROM public.xp_events e
      WHERE e.user_id = p_user_id
        AND e.source = 'team_created'
    ) < public.fan_xp_team_created_lifetime_cap();
$$;

CREATE OR REPLACE FUNCTION public.fan_xp_team_event_created_cap_allows(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT p_user_id IS NOT NULL
    AND (
      SELECT COUNT(*)
      FROM public.xp_events e
      WHERE e.user_id = p_user_id
        AND e.source = 'team_event_created'
        AND (timezone('utc', e.created_at))::date
          = (timezone('utc', now()))::date
    ) < public.fan_xp_team_event_created_daily_cap();
$$;

CREATE OR REPLACE FUNCTION public.fan_xp_is_eligible_account_player_seat(
  p_user_id uuid,
  p_managed_player_id uuid,
  p_left_at timestamptz,
  p_is_player boolean
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT p_user_id IS NOT NULL
    AND p_managed_player_id IS NULL
    AND p_left_at IS NULL
    AND p_is_player IS TRUE;
$$;

REVOKE ALL ON FUNCTION public.fan_xp_team_created_cap_allows(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fan_xp_team_event_created_cap_allows(uuid) FROM PUBLIC;

-- Safe ledger write used by triggers. Never raises to the caller.
CREATE OR REPLACE FUNCTION public.fan_xp_try_award_internal(
  p_user_id uuid,
  p_source text,
  p_source_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_amount integer;
  v_source text := lower(btrim(coalesce(p_source, '')));
BEGIN
  IF p_user_id IS NULL OR p_source_id IS NULL THEN
    RETURN;
  END IF;
  v_amount := public.fan_xp_amount_for_source(v_source);
  IF v_amount IS NULL OR v_amount <= 0 THEN
    RETURN;
  END IF;
  IF v_source = 'team_created'
     AND NOT public.fan_xp_team_created_cap_allows(p_user_id) THEN
    RETURN;
  END IF;
  IF v_source = 'team_event_created'
     AND NOT public.fan_xp_team_event_created_cap_allows(p_user_id) THEN
    RETURN;
  END IF;
  BEGIN
    PERFORM public.fan_xp_apply_award_internal(p_user_id, v_amount, v_source, p_source_id);
  EXCEPTION
    WHEN OTHERS THEN
      RAISE NOTICE
        '[FanXP] try_award skipped source=% user=% id=% sqlstate=%',
        p_source, p_user_id, p_source_id, SQLSTATE;
  END;
END;
$$;

REVOKE ALL ON FUNCTION public.fan_xp_try_award_internal(uuid, text, uuid) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- 3) Evidence validation (existing sources preserved + Team)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_xp_validate_and_resolve(
  p_source text,
  p_source_id uuid,
  p_requested_user_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  src text := lower(trim(coalesce(p_source, '')));
  amount integer;
  my_email text := lower(btrim(coalesce(auth.jwt() ->> 'email', '')));
  v_requester uuid;
  v_creator uuid;
  v_other uuid;
  v_targets uuid[] := ARRAY[]::uuid[];
  v_format text;
  v_status text;
  v_archived timestamptz;
  v_owner uuid;
  v_created_at timestamptz;
  v_joined_at timestamptz;
BEGIN
  IF me IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  amount := public.fan_xp_amount_for_source(src);
  IF amount IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'unknown_source');
  END IF;

  IF p_source_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'source_id_required');
  END IF;

  IF src = 'favorite_venue' THEN
    IF my_email = '' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'missing_auth_email');
    END IF;
    IF NOT EXISTS (
      SELECT 1
      FROM public.favorite_venues fv
      WHERE fv.venue_id = p_source_id
        AND lower(btrim(fv.user_email)) = my_email
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'favorite_not_found');
    END IF;
    v_targets := ARRAY[me];

  ELSIF src = 'venue_event_interest' THEN
    IF my_email = '' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'missing_auth_email');
    END IF;
    IF NOT EXISTS (
      SELECT 1
      FROM public.venue_event_interests vei
      WHERE lower(btrim(vei.venue_event_id)) = lower(p_source_id::text)
        AND lower(btrim(vei.user_email)) = my_email
        AND lower(btrim(vei.interest_status)) IN ('going', 'interested')
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'interest_not_found');
    END IF;
    v_targets := ARRAY[me];

  ELSIF src = 'pickup_create' THEN
    IF EXISTS (
      SELECT 1 FROM public.fan_team_game_links l WHERE l.pickup_game_id = p_source_id
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'team_event_use_team_source');
    END IF;
    IF NOT EXISTS (
      SELECT 1
      FROM public.pickup_games pg
      WHERE pg.id = p_source_id
        AND pg.creator_user_id = me
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'pickup_create_not_eligible');
    END IF;
    v_targets := ARRAY[me];

  ELSIF src = 'pickup_join_approved' THEN
    SELECT pgr.requester_user_id, pg.creator_user_id
    INTO v_requester, v_creator
    FROM public.pickup_game_requests pgr
    JOIN public.pickup_games pg ON pg.id = pgr.pickup_game_id
    WHERE pgr.id = p_source_id
      AND lower(btrim(pgr.status)) = 'approved';

    IF v_requester IS NULL OR v_creator IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'join_request_not_approved');
    END IF;
    IF v_creator IS DISTINCT FROM me THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'not_pickup_creator');
    END IF;
    IF p_requested_user_id IS NOT NULL AND p_requested_user_id IS DISTINCT FROM v_requester THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'target_mismatch');
    END IF;
    v_targets := ARRAY[v_requester];

  ELSIF src = 'pickup_complete' THEN
    IF EXISTS (
      SELECT 1 FROM public.fan_team_game_links l WHERE l.pickup_game_id = p_source_id
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'team_event_use_team_source');
    END IF;
    IF NOT EXISTS (
      SELECT 1
      FROM public.pickup_game_creator_ratings r
      WHERE r.pickup_game_id = p_source_id
        AND r.rater_user_id = me
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'rating_not_found');
    END IF;
    v_targets := ARRAY[me];

  ELSIF src = 'friend_connected' THEN
    SELECT
      CASE
        WHEN f.requester_id = me THEN f.addressee_id
        WHEN f.addressee_id = me THEN f.requester_id
        ELSE NULL
      END
    INTO v_other
    FROM public.friendships f
    WHERE f.id = p_source_id
      AND lower(btrim(f.status)) = 'accepted'
      AND (f.requester_id = me OR f.addressee_id = me);

    IF v_other IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'friendship_not_accepted');
    END IF;

    IF p_requested_user_id IS NULL THEN
      v_targets := ARRAY[me, v_other];
    ELSIF p_requested_user_id = me OR p_requested_user_id = v_other THEN
      v_targets := ARRAY[p_requested_user_id];
    ELSE
      RETURN jsonb_build_object('ok', false, 'reason', 'friend_target_mismatch');
    END IF;

  ELSIF src = 'team_created' THEN
    SELECT t.owner_user_id, t.created_at INTO v_owner, v_created_at
    FROM public.fan_teams t
    WHERE t.id = p_source_id
      AND t.is_active IS TRUE;
    IF v_owner IS NULL OR v_owner IS DISTINCT FROM me THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'team_create_not_eligible');
    END IF;
    IF v_created_at IS NULL OR v_created_at < (now() - interval '1 hour') THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'team_create_not_recent');
    END IF;
    IF NOT public.fan_xp_team_created_cap_allows(me) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'team_created_cap');
    END IF;
    v_targets := ARRAY[me];

  ELSIF src = 'team_join_player' THEN
    SELECT m.joined_at INTO v_joined_at
    FROM public.fan_team_members m
    WHERE m.team_id = p_source_id
      AND m.user_id = me
      AND public.fan_xp_is_eligible_account_player_seat(
        m.user_id, m.managed_player_id, m.left_at, m.is_player
      );
    IF v_joined_at IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'team_join_player_not_eligible');
    END IF;
    -- No historical backfill: claim may confirm a trigger write, or cover a
    -- brand-new join. Already-active seats cannot self-claim +10.
    IF v_joined_at < (now() - interval '1 hour')
       AND NOT EXISTS (
         SELECT 1
         FROM public.xp_events e
         WHERE e.user_id = me
           AND e.source = 'team_join_player'
           AND e.source_id = p_source_id
       ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'team_join_player_not_recent');
    END IF;
    v_targets := ARRAY[me];

  ELSIF src = 'team_event_created' THEN
    SELECT pg.creator_user_id, pg.game_format, pg.status, pg.created_at
    INTO v_creator, v_format, v_status, v_created_at
    FROM public.pickup_games pg
    WHERE pg.id = p_source_id;
    IF v_creator IS NULL OR v_creator IS DISTINCT FROM me THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'team_event_create_not_eligible');
    END IF;
    IF lower(btrim(coalesce(v_status, ''))) = 'removed' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'team_event_invalid');
    END IF;
    IF NOT public.fan_xp_is_real_team_event_format(v_format) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'team_event_not_awardable_format');
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.fan_team_game_links l WHERE l.pickup_game_id = p_source_id
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'team_event_not_linked');
    END IF;
    IF v_created_at IS NULL OR v_created_at < (now() - interval '1 hour') THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'team_event_create_not_recent');
    END IF;
    IF NOT public.fan_xp_team_event_created_cap_allows(me) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'team_event_created_cap');
    END IF;
    v_targets := ARRAY[me];

  ELSIF src = 'team_event_completed_player' THEN
    SELECT pg.creator_user_id, pg.game_format, pg.status, pg.archived_at
    INTO v_creator, v_format, v_status, v_archived
    FROM public.pickup_games pg
    WHERE pg.id = p_source_id;
    IF v_format IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'team_event_not_found');
    END IF;
    IF NOT public.fan_xp_is_real_team_event_format(v_format) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'team_event_not_awardable_format');
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.fan_team_game_links l WHERE l.pickup_game_id = p_source_id
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'team_event_not_linked');
    END IF;
    IF NOT public.fan_xp_team_event_is_completed(v_status, v_archived) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'team_event_not_completed');
    END IF;
    IF NOT public.fan_xp_account_participated_in_team_event(me, p_source_id) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'team_event_player_not_participating');
    END IF;
    v_targets := ARRAY[me];

  ELSIF src = 'team_event_completed_organizer' THEN
    SELECT pg.creator_user_id, pg.game_format, pg.status, pg.archived_at
    INTO v_creator, v_format, v_status, v_archived
    FROM public.pickup_games pg
    WHERE pg.id = p_source_id;
    IF v_creator IS NULL OR v_creator IS DISTINCT FROM me THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'team_event_organizer_not_eligible');
    END IF;
    IF NOT public.fan_xp_is_real_team_event_format(v_format) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'team_event_not_awardable_format');
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.fan_team_game_links l WHERE l.pickup_game_id = p_source_id
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'team_event_not_linked');
    END IF;
    IF NOT public.fan_xp_team_event_is_completed(v_status, v_archived) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'team_event_not_completed');
    END IF;
    v_targets := ARRAY[me];

  ELSE
    RETURN jsonb_build_object('ok', false, 'reason', 'unknown_source');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'amount', amount,
    'source', src,
    'source_id', p_source_id,
    'targets', to_jsonb(v_targets)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.fan_xp_validate_and_resolve(text, uuid, uuid) FROM PUBLIC;

COMMENT ON FUNCTION public.fan_xp_validate_and_resolve(text, uuid, uuid) IS
  'Validates Fan XP evidence rows and resolves award targets. Internal. '
  '20260996 adds Team sources; Pickup/venue/friend evidence unchanged.';

-- ---------------------------------------------------------------------------
-- 4) Trigger bodies
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_xp_trg_team_created()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NEW.owner_user_id IS NOT NULL AND NEW.is_active IS TRUE THEN
    PERFORM public.fan_xp_try_award_internal(
      NEW.owner_user_id,
      'team_created',
      NEW.id
    );
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.fan_xp_trg_team_join_player()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_new_eligible boolean;
  v_old_eligible boolean := false;
BEGIN
  v_new_eligible := public.fan_xp_is_eligible_account_player_seat(
    NEW.user_id, NEW.managed_player_id, NEW.left_at, NEW.is_player
  );
  IF NOT v_new_eligible THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' THEN
    v_old_eligible := public.fan_xp_is_eligible_account_player_seat(
      OLD.user_id, OLD.managed_player_id, OLD.left_at, OLD.is_player
    );
    IF v_old_eligible THEN
      RETURN NEW;
    END IF;
  END IF;
  PERFORM public.fan_xp_try_award_internal(
    NEW.user_id,
    'team_join_player',
    NEW.team_id
  );
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.fan_xp_award_team_event_created(p_pickup_game_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_creator uuid;
  v_format text;
  v_status text;
BEGIN
  IF p_pickup_game_id IS NULL THEN
    RETURN;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.fan_team_game_links l WHERE l.pickup_game_id = p_pickup_game_id
  ) THEN
    RETURN;
  END IF;
  SELECT pg.creator_user_id, pg.game_format, pg.status
  INTO v_creator, v_format, v_status
  FROM public.pickup_games pg
  WHERE pg.id = p_pickup_game_id;
  IF v_creator IS NULL THEN
    RETURN;
  END IF;
  IF lower(btrim(coalesce(v_status, ''))) = 'removed' THEN
    RETURN;
  END IF;
  IF NOT public.fan_xp_is_real_team_event_format(v_format) THEN
    RETURN;
  END IF;
  PERFORM public.fan_xp_try_award_internal(
    v_creator,
    'team_event_created',
    p_pickup_game_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.fan_xp_award_team_event_completed(p_pickup_game_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_creator uuid;
  v_format text;
  v_status text;
  v_archived timestamptz;
  r record;
BEGIN
  IF p_pickup_game_id IS NULL THEN
    RETURN;
  END IF;
  SELECT pg.creator_user_id, pg.game_format, pg.status, pg.archived_at
  INTO v_creator, v_format, v_status, v_archived
  FROM public.pickup_games pg
  WHERE pg.id = p_pickup_game_id;
  IF NOT public.fan_xp_is_real_team_event_format(v_format) THEN
    RETURN;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.fan_team_game_links l WHERE l.pickup_game_id = p_pickup_game_id
  ) THEN
    RETURN;
  END IF;
  IF NOT public.fan_xp_team_event_is_completed(v_status, v_archived) THEN
    RETURN;
  END IF;

  IF v_creator IS NOT NULL THEN
    PERFORM public.fan_xp_try_award_internal(
      v_creator,
      'team_event_completed_organizer',
      p_pickup_game_id
    );
  END IF;

  FOR r IN
    SELECT DISTINCT m.user_id AS uid
    FROM public.fan_team_game_links l
    JOIN public.fan_team_members m
      ON m.team_id = l.team_id
     AND m.left_at IS NULL
     AND m.user_id IS NOT NULL
     AND m.managed_player_id IS NULL
    WHERE l.pickup_game_id = p_pickup_game_id
      AND public.fan_xp_account_participated_in_team_event(m.user_id, p_pickup_game_id)
  LOOP
    PERFORM public.fan_xp_try_award_internal(
      r.uid,
      'team_event_completed_player',
      p_pickup_game_id
    );
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.fan_xp_trg_team_event_linked()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  PERFORM public.fan_xp_award_team_event_created(NEW.pickup_game_id);
  -- Defense in depth: normal link RPC requires status=active, so completion
  -- before link is not a product path. If a row is already completed, award
  -- now. Unique (user_id, source, source_id) prevents duplicates.
  PERFORM public.fan_xp_award_team_event_completed(NEW.pickup_game_id);
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.fan_xp_trg_team_event_completed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_was boolean;
  v_now boolean;
BEGIN
  v_was := public.fan_xp_team_event_is_completed(OLD.status, OLD.archived_at);
  v_now := public.fan_xp_team_event_is_completed(NEW.status, NEW.archived_at);
  IF v_now AND NOT v_was THEN
    PERFORM public.fan_xp_award_team_event_completed(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS fan_xp_team_created_trg ON public.fan_teams;
CREATE TRIGGER fan_xp_team_created_trg
  AFTER INSERT ON public.fan_teams
  FOR EACH ROW
  EXECUTE FUNCTION public.fan_xp_trg_team_created();

DROP TRIGGER IF EXISTS fan_xp_team_join_player_trg ON public.fan_team_members;
CREATE TRIGGER fan_xp_team_join_player_trg
  AFTER INSERT OR UPDATE OF is_player, left_at, user_id, managed_player_id
  ON public.fan_team_members
  FOR EACH ROW
  EXECUTE FUNCTION public.fan_xp_trg_team_join_player();

DROP TRIGGER IF EXISTS fan_xp_team_event_linked_trg ON public.fan_team_game_links;
CREATE TRIGGER fan_xp_team_event_linked_trg
  AFTER INSERT ON public.fan_team_game_links
  FOR EACH ROW
  EXECUTE FUNCTION public.fan_xp_trg_team_event_linked();

DROP TRIGGER IF EXISTS fan_xp_team_event_completed_trg ON public.pickup_games;
CREATE TRIGGER fan_xp_team_event_completed_trg
  AFTER UPDATE OF status, archived_at
  ON public.pickup_games
  FOR EACH ROW
  EXECUTE FUNCTION public.fan_xp_trg_team_event_completed();

-- ---------------------------------------------------------------------------
-- 5) Self-checks
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_src text;
BEGIN
  IF public.fan_xp_amount_for_source('favorite_venue') IS DISTINCT FROM 2
     OR public.fan_xp_amount_for_source('venue_event_interest') IS DISTINCT FROM 5
     OR public.fan_xp_amount_for_source('pickup_create') IS DISTINCT FROM 20
     OR public.fan_xp_amount_for_source('pickup_join_approved') IS DISTINCT FROM 10
     OR public.fan_xp_amount_for_source('pickup_complete') IS DISTINCT FROM 15
     OR public.fan_xp_amount_for_source('friend_connected') IS DISTINCT FROM 5 THEN
    RAISE EXCEPTION '20260996 existing Fan XP amounts must not change';
  END IF;
  IF public.fan_xp_amount_for_source('team_created') IS DISTINCT FROM 20
     OR public.fan_xp_amount_for_source('team_join_player') IS DISTINCT FROM 10
     OR public.fan_xp_amount_for_source('team_event_created') IS DISTINCT FROM 5
     OR public.fan_xp_amount_for_source('team_event_completed_player') IS DISTINCT FROM 10
     OR public.fan_xp_amount_for_source('team_event_completed_organizer') IS DISTINCT FROM 15 THEN
    RAISE EXCEPTION '20260996 Team Fan XP amounts mismatch';
  END IF;
  IF public.fan_xp_amount_for_source('announcement') IS NOT NULL THEN
    RAISE EXCEPTION '20260996 announcement must not earn XP';
  END IF;
  IF public.fan_xp_is_real_team_event_format('announcement') THEN
    RAISE EXCEPTION '20260996 announcement is not a real Team event';
  END IF;
  IF NOT public.fan_xp_is_real_team_event_format('practice')
     OR NOT public.fan_xp_is_real_team_event_format('league_game')
     OR NOT public.fan_xp_is_real_team_event_format('team_meeting')
     OR NOT public.fan_xp_is_real_team_event_format('other') THEN
    RAISE EXCEPTION '20260996 expected Team event formats must award';
  END IF;
  IF public.fan_xp_team_created_lifetime_cap() IS DISTINCT FROM 5 THEN
    RAISE EXCEPTION '20260996 team_created lifetime cap must be 5';
  END IF;
  IF public.fan_xp_team_event_created_daily_cap() IS DISTINCT FROM 8 THEN
    RAISE EXCEPTION '20260996 team_event_created daily cap must be 8';
  END IF;
  IF public.fan_xp_is_eligible_account_player_seat(NULL, NULL, NULL, true) THEN
    RAISE EXCEPTION '20260996 managed/null user_id must not be an eligible account player seat';
  END IF;
  IF public.fan_xp_is_eligible_account_player_seat(
       '00000000-0000-0000-0000-000000000001'::uuid,
       '00000000-0000-0000-0000-000000000002'::uuid,
       NULL, true
     ) THEN
    RAISE EXCEPTION '20260996 managed-player seat must not earn account join XP';
  END IF;
  IF NOT public.fan_xp_is_eligible_account_player_seat(
       '00000000-0000-0000-0000-000000000001'::uuid,
       NULL, NULL, true
     ) THEN
    RAISE EXCEPTION '20260996 account is_player seat must be eligible';
  END IF;

  SELECT p.prosrc INTO v_src
  FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.fan_xp_trg_team_join_player()'::regprocedure;
  IF position('TG_OP' IN v_src) = 0
     OR position('v_old_eligible' IN v_src) = 0 THEN
    RAISE EXCEPTION '20260996 join trigger must be transition-aware';
  END IF;

  SELECT p.prosrc INTO v_src
  FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.fan_xp_trg_team_event_linked()'::regprocedure;
  IF position('fan_xp_award_team_event_completed' IN v_src) = 0 THEN
    RAISE EXCEPTION '20260996 link trigger must evaluate completion as defense in depth';
  END IF;

  SELECT p.prosrc INTO v_src
  FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.fan_xp_try_award_internal(uuid, text, uuid)'::regprocedure;
  IF position('fan_xp_team_created_cap_allows' IN v_src) = 0
     OR position('fan_xp_team_event_created_cap_allows' IN v_src) = 0 THEN
    RAISE EXCEPTION '20260996 try_award must enforce Team XP caps';
  END IF;

  SELECT p.prosrc INTO v_src
  FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.fan_xp_validate_and_resolve(text, uuid, uuid)'::regprocedure;
  IF position('team_join_player' IN v_src) = 0
     OR position('fan_xp_is_eligible_account_player_seat' IN v_src) = 0
     OR position('team_join_player_not_recent' IN v_src) = 0 THEN
    RAISE EXCEPTION '20260996 validate must require eligible account player seat without backfill';
  END IF;
  IF position('team_created_cap' IN v_src) = 0
     OR position('team_event_created_cap' IN v_src) = 0 THEN
    RAISE EXCEPTION '20260996 validate must enforce Team XP caps';
  END IF;
  IF position('team_event_use_team_source' IN v_src) = 0 THEN
    RAISE EXCEPTION '20260996 pickup_create/complete must reject team-linked rows';
  END IF;
END $$;

COMMIT;
