-- =============================================================================
-- 20260883 — Pickup games: introduce archive-only expiry (no hard DELETE)
-- =============================================================================
--
-- Stage 2 (prepare only): introduce an idempotent archival stamp for pickups
-- that have crossed remove_after_at, without physically deleting parent rows.
--
-- Production baseline (srizbpfkigidsjxvpnkt, read-only equivalence review):
--   - Production may not currently contain purge_expired_pickup_games();
--     this migration introduces the archive-only implementation.
--   - No production cron currently references a pickup purge function.
--   - pickup_games.archived_at does not exist before apply.
--   - This migration CREATES purge_expired_pickup_games() (archive-only).
--     It does NOT replace a live hard-delete function on this baseline.
--
-- Chosen model:
--   - Add public.pickup_games.archived_at timestamptz (nullable)
--   - At remove_after_at, stamp archived_at = now() (once)
--   - Do NOT change status / is_visible / remove_after_at
--   - Do NOT DELETE parent rows (no CASCADE to requests / invites / ratings)
--
-- Why not status = 'expired' or 'removed':
--   - 'removed' means organizer soft-cancel (rating / request cancel semantics)
--   - 'expired' is already conflated with soft-delete on iOS
--     (mergePickupInsertedLocally → mergePickupGameAfterOrganizerSoftDelete)
--   - Public exclusion already uses remove_after_at + status='active' + is_visible
--   - Participant/creator SELECT already allows post-expiry reads via
--     creator_user_id OR can_read_pickup_game_for_requester(id)
--
-- Rating safety (required because canceled rows will now survive archival):
--   - Organizer cancel uses status = 'removed' (not 'cancelled')
--   - Live submit_pickup_creator_rating rejects cancelled/canceled only
--   - Extend rejection to include 'removed' so archival does not newly enable
--     rating on organizer-canceled games
--
-- Backfill (idempotent; no hardcoded counts in executable SQL):
--   - Stamps archived_at only where remove_after_at <= now() AND archived_at IS NULL
--   - Audit-time production expectation: approximately 37 expired rows may receive
--     archived_at; this does not restore public visibility; existing public-eligible
--     rows (~5 at audit) remain governed by their current predicates
--
-- Final physical hard-delete retention: FUTURE WORK (not defined here).
--
-- Do NOT apply from the agent against the linked (production) project.
-- Do NOT edit prior migrations.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Preflight
-- ---------------------------------------------------------------------------
-- Production may not currently contain purge_expired_pickup_games(); this
-- migration introduces the archive-only implementation. Missing purge is OK.
DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
  v_status_check text;
  v_purge_absent boolean;
BEGIN
  IF to_regclass('public.pickup_games') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.pickup_games'];
  END IF;
  IF to_regclass('public.pickup_game_requests') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.pickup_game_requests'];
  END IF;
  IF to_regclass('public.pickup_game_invites') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.pickup_game_invites'];
  END IF;
  IF to_regclass('public.pickup_game_creator_ratings') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.pickup_game_creator_ratings'];
  END IF;
  -- Do NOT require purge_expired_pickup_games(); absent is the production path.
  IF to_regprocedure('public.submit_pickup_creator_rating(uuid,integer,text)') IS NULL THEN
    v_missing := v_missing || ARRAY['function public.submit_pickup_creator_rating(uuid,integer,text)'];
  END IF;

  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION '20260883 preflight failed; missing: %', array_to_string(v_missing, ', ');
  END IF;

  v_purge_absent := to_regprocedure('public.purge_expired_pickup_games()') IS NULL;
  RAISE NOTICE '20260883 preflight: purge_expired_pickup_games absent=% (OK; will CREATE archive-only)', v_purge_absent;

  -- status vocabulary must still include active/removed/expired (no new status required).
  SELECT pg_get_constraintdef(c.oid)
  INTO v_status_check
  FROM pg_constraint c
  JOIN pg_class t ON t.oid = c.conrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  WHERE n.nspname = 'public'
    AND t.relname = 'pickup_games'
    AND c.contype = 'c'
    AND pg_get_constraintdef(c.oid) ILIKE '%status%'
  ORDER BY c.conname
  LIMIT 1;

  IF v_status_check IS NULL
     OR v_status_check NOT ILIKE '%active%'
     OR v_status_check NOT ILIKE '%removed%' THEN
    RAISE EXCEPTION '20260883 preflight failed: pickup_games status check missing active/removed';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'pickup_games'
      AND column_name = 'remove_after_at'
  ) THEN
    RAISE EXCEPTION '20260883 preflight failed: pickup_games.remove_after_at missing';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'pickup_games'
      AND column_name = 'archived_at'
  ) THEN
    RAISE NOTICE '20260883 preflight: archived_at already present (idempotent ADD COLUMN IF NOT EXISTS)';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2) Minimal schema: archival stamp (does not redefine cancel/expiry status)
-- ---------------------------------------------------------------------------
ALTER TABLE public.pickup_games
  ADD COLUMN IF NOT EXISTS archived_at timestamptz;

COMMENT ON COLUMN public.pickup_games.archived_at IS
  'Set once by purge_expired_pickup_games when remove_after_at <= now(). Marks public-expiry archival. Does not mean organizer cancellation (status=removed). Row and children are retained; public surfaces continue to exclude via remove_after_at / active+visible predicates. Final hard-delete is future work.';

-- Candidates still needing archival (partial; keeps purge scans cheap).
CREATE INDEX IF NOT EXISTS idx_pickup_games_archive_candidates
  ON public.pickup_games (remove_after_at)
  WHERE remove_after_at IS NOT NULL
    AND archived_at IS NULL;

-- Optional lookup of already-archived rows.
CREATE INDEX IF NOT EXISTS idx_pickup_games_archived_at
  ON public.pickup_games (archived_at DESC)
  WHERE archived_at IS NOT NULL;

-- Narrow, idempotent archive-only backfill for rows already past remove_after_at.
-- Does not mutate status, visibility, ratings, requests, or invites.
-- Does not DELETE. Does not restore public visibility (remove_after_at unchanged).
-- Audit-time expectation (not hardcoded): ~37 expired rows may receive archived_at;
-- ~5 public-eligible rows remain governed by existing active/visible/remove_after predicates.
UPDATE public.pickup_games pg
SET archived_at = coalesce(pg.archived_at, pg.remove_after_at, now())
WHERE pg.remove_after_at IS NOT NULL
  AND pg.remove_after_at <= now()
  AND pg.archived_at IS NULL;

-- ---------------------------------------------------------------------------
-- 3) CREATE archive-only purge (no prior live function on production baseline)
-- ---------------------------------------------------------------------------
-- Production may not currently contain purge_expired_pickup_games(); this
-- migration introduces the archive-only implementation (CREATE OR REPLACE is
-- create-on-absent for this baseline; it is not replacing a live hard DELETE).
CREATE OR REPLACE FUNCTION public.purge_expired_pickup_games()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  archived_count integer;
BEGIN
  -- Idempotent archival: stamp rows that have crossed the public-expiry window
  -- and have not yet been archived. Does not delete. Does not change status /
  -- is_visible / remove_after_at. Does not mutate requests, invites, or ratings.
  -- Organizer-canceled rows (status='removed') may also receive archived_at when
  -- their remove_after_at has passed; their canceled semantics remain via status.
  UPDATE public.pickup_games pg
  SET archived_at = now()
  WHERE pg.remove_after_at IS NOT NULL
    AND pg.remove_after_at <= now()
    AND pg.archived_at IS NULL;

  GET DIAGNOSTICS archived_count = ROW_COUNT;
  RETURN archived_count;
END;
$$;

COMMENT ON FUNCTION public.purge_expired_pickup_games() IS
  'Archives pickup_games past remove_after_at by setting archived_at (idempotent). Does NOT hard-delete. Returns newly archived row count. Children (requests/invites/ratings) are retained. Public surfaces exclude via existing remove_after_at predicates. Introduced by 20260883 on baselines that lacked this function. Final hard-delete retention is future work. Run on a schedule with service_role.';

REVOKE ALL ON FUNCTION public.purge_expired_pickup_games() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.purge_expired_pickup_games() FROM anon;
REVOKE ALL ON FUNCTION public.purge_expired_pickup_games() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.purge_expired_pickup_games() TO service_role;

-- ---------------------------------------------------------------------------
-- 4) Rating eligibility: treat organizer soft-cancel (status=removed) as not rateable
-- ---------------------------------------------------------------------------
-- Required once canceled rows survive archival. Ordinary archived active/completed
-- games remain rateable. Preserves live production predicates + hardening from
-- 20260877/20260880, with intentional addition of 'removed'.

CREATE OR REPLACE FUNCTION public.submit_pickup_creator_rating(
  p_pickup_game_id uuid,
  p_rating integer,
  p_feedback text DEFAULT NULL
)
RETURNS TABLE (
  outcome text,
  already_rated boolean,
  rating integer,
  organizer_avg_rating numeric,
  organizer_rating_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_creator uuid;
  v_end timestamptz;
  v_status text;
  v_feedback text;
  v_existing integer;
  v_avg numeric;
  v_count bigint;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  IF p_pickup_game_id IS NULL THEN
    RAISE EXCEPTION 'missing_pickup_game_id' USING ERRCODE = '22023';
  END IF;

  IF p_rating IS NULL OR p_rating < 1 OR p_rating > 5 THEN
    RAISE EXCEPTION 'rating_out_of_range' USING ERRCODE = '22023';
  END IF;

  v_feedback := nullif(trim(both from coalesce(p_feedback, '')), '');
  IF v_feedback IS NOT NULL AND char_length(v_feedback) > 1000 THEN
    RAISE EXCEPTION 'feedback_too_long' USING ERRCODE = '22023';
  END IF;

  SELECT
    g.creator_user_id,
    coalesce(g.end_time, g.game_start_at + interval '2 hours'),
    lower(trim(both from coalesce(g.status, '')))
  INTO v_creator, v_end, v_status
  FROM public.pickup_games g
  WHERE g.id = p_pickup_game_id;

  IF v_creator IS NULL THEN
    RAISE EXCEPTION 'pickup_game_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF me = v_creator THEN
    RAISE EXCEPTION 'cannot_rate_own_game' USING ERRCODE = '42501';
  END IF;

  -- Organizer cancel uses status='removed'. Also reject cancelled/canceled aliases.
  IF v_status IN ('cancelled', 'canceled', 'removed') THEN
    RAISE EXCEPTION 'game_canceled' USING ERRCODE = '42501';
  END IF;

  IF v_end IS NULL OR v_end > now() THEN
    RAISE EXCEPTION 'game_not_completed' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.pickup_game_requests r
    WHERE r.pickup_game_id = p_pickup_game_id
      AND r.requester_user_id = me
      AND lower(trim(both from r.status)) = 'approved'
  ) THEN
    RAISE EXCEPTION 'not_eligible_participant' USING ERRCODE = '42501';
  END IF;

  SELECT r.rating
  INTO v_existing
  FROM public.pickup_game_creator_ratings r
  WHERE r.pickup_game_id = p_pickup_game_id
    AND r.rater_user_id = me
  LIMIT 1;

  IF v_existing IS NOT NULL THEN
    SELECT
      CASE WHEN count(*) = 0 THEN NULL::numeric ELSE round(avg(r.rating)::numeric, 2) END,
      count(*)::bigint
    INTO v_avg, v_count
    FROM public.pickup_game_creator_ratings r
    WHERE r.creator_user_id = v_creator;

    outcome := 'already_rated';
    already_rated := true;
    rating := v_existing;
    organizer_avg_rating := v_avg;
    organizer_rating_count := v_count;
    RETURN NEXT;
    RETURN;
  END IF;

  INSERT INTO public.pickup_game_creator_ratings (
    pickup_game_id,
    creator_user_id,
    rater_user_id,
    rating,
    feedback
  ) VALUES (
    p_pickup_game_id,
    v_creator,
    me,
    p_rating,
    v_feedback
  );

  SELECT
    CASE WHEN count(*) = 0 THEN NULL::numeric ELSE round(avg(r.rating)::numeric, 2) END,
    count(*)::bigint
  INTO v_avg, v_count
  FROM public.pickup_game_creator_ratings r
  WHERE r.creator_user_id = v_creator;

  outcome := 'accepted';
  already_rated := false;
  rating := p_rating;
  organizer_avg_rating := v_avg;
  organizer_rating_count := v_count;
  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION public.submit_pickup_creator_rating(uuid, integer, text) IS
  'Authenticated insert of one organizer rating per completed pickup game; immutable; rejects cancelled/canceled/removed; returns organizer aggregates. Archived (archived_at set, status still active) ordinary games remain eligible.';

REVOKE ALL ON FUNCTION public.submit_pickup_creator_rating(uuid, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.submit_pickup_creator_rating(uuid, integer, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.submit_pickup_creator_rating(uuid, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_pickup_creator_rating(uuid, integer, text) TO service_role;

DROP POLICY IF EXISTS pickup_game_creator_ratings_insert_eligible
  ON public.pickup_game_creator_ratings;

CREATE POLICY pickup_game_creator_ratings_insert_eligible
  ON public.pickup_game_creator_ratings
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.pickup_game_creator_ratings.rater_user_id = (SELECT auth.uid())
    AND EXISTS (
      SELECT 1
      FROM public.pickup_games AS g
      WHERE g.id = public.pickup_game_creator_ratings.pickup_game_id
        AND g.creator_user_id = public.pickup_game_creator_ratings.creator_user_id
        AND lower(trim(both from coalesce(g.status, '')))
              NOT IN ('cancelled', 'canceled', 'removed')
        AND coalesce(
              g.end_time,
              g.game_start_at + interval '2 hours'
            ) <= now()
    )
    AND EXISTS (
      SELECT 1
      FROM public.pickup_game_requests AS r
      WHERE r.pickup_game_id = public.pickup_game_creator_ratings.pickup_game_id
        AND r.requester_user_id = (SELECT auth.uid())
        AND lower(trim(both from r.status)) = 'approved'
    )
  );

COMMENT ON POLICY pickup_game_creator_ratings_insert_eligible
  ON public.pickup_game_creator_ratings IS
  'INSERT only when rater is auth.uid(), outer creator matches game creator, game status is not cancelled/canceled/removed, scheduled end reached, and rater has an approved request. Mirrors submit_pickup_creator_rating after 20260883 archival. Preserves 20260880 outer-column qualification.';

-- Preserve immutability from 20260877/20260880.
REVOKE UPDATE ON public.pickup_game_creator_ratings FROM authenticated;

COMMIT;

-- =============================================================================
-- Post-apply validation SQL (read-only; run manually after deliberate apply)
-- =============================================================================
--
-- 1) archived_at exists
-- SELECT column_name, data_type, is_nullable
-- FROM information_schema.columns
-- WHERE table_schema = 'public' AND table_name = 'pickup_games' AND column_name = 'archived_at';
-- -- expect: archived_at | timestamp with time zone | YES
--
-- 2) archive indexes exist
-- SELECT indexname FROM pg_indexes
-- WHERE schemaname = 'public' AND tablename = 'pickup_games'
--   AND indexname IN ('idx_pickup_games_archive_candidates', 'idx_pickup_games_archived_at');
-- -- expect both
--
-- 3) purge function exists
-- SELECT to_regprocedure('public.purge_expired_pickup_games()') IS NOT NULL AS purge_exists;
-- -- expect true
--
-- 4) purge body is UPDATE archive, not DELETE
-- SELECT pg_get_functiondef('public.purge_expired_pickup_games()'::regprocedure) AS def;
-- -- expect: UPDATE ... archived_at
-- -- expect NOT: DELETE FROM public.pickup_games
--
-- 5) purge EXECUTE is service-role-only
-- SELECT has_function_privilege('service_role','public.purge_expired_pickup_games()'::regprocedure,'EXECUTE'); -- true
-- SELECT has_function_privilege('authenticated','public.purge_expired_pickup_games()'::regprocedure,'EXECUTE'); -- false
-- SELECT has_function_privilege('anon','public.purge_expired_pickup_games()'::regprocedure,'EXECUTE'); -- false
--
-- 6) rating RPC rejects removed
-- SELECT prosrc LIKE '%removed%' AS rejects_removed
-- FROM pg_proc
-- WHERE pronamespace = 'public'::regnamespace
--   AND proname = 'submit_pickup_creator_rating';
-- -- expect true
--
-- 7) INSERT policy rejects removed
-- SELECT pg_get_expr(pol.polwithcheck, pol.polrelid) AS with_check_expr
-- FROM pg_policy pol
-- JOIN pg_class c ON c.oid = pol.polrelid
-- JOIN pg_namespace n ON n.oid = c.relnamespace
-- WHERE n.nspname = 'public'
--   AND c.relname = 'pickup_game_creator_ratings'
--   AND pol.polname = 'pickup_game_creator_ratings_insert_eligible';
-- -- expect contains removed; expect outer pickup_game_creator_ratings.* qualification
--
-- 8) no deletion of pickup rows / children (compare counts before/after apply)
-- SELECT
--   (SELECT count(*) FROM public.pickup_games) AS pickup_games,
--   (SELECT count(*) FROM public.pickup_game_requests) AS requests,
--   (SELECT count(*) FROM public.pickup_game_invites) AS invites,
--   (SELECT count(*) FROM public.pickup_game_creator_ratings) AS ratings;
--
-- 9) public visibility predicates unchanged (still remove_after_at / active / is_visible)
-- SELECT pol.polname, pg_get_expr(pol.polqual, pol.polrelid) AS using_expr
-- FROM pg_policy pol
-- JOIN pg_class c ON c.oid = pol.polrelid
-- JOIN pg_namespace n ON n.oid = c.relnamespace
-- WHERE n.nspname = 'public' AND c.relname = 'pickup_games'
--   AND pol.polname IN ('pickup_games_select_authenticated', 'pickup_games_select_public_guest_anon');
-- -- expect remove_after_at predicates unchanged; no archived_at requirement for public hide
--
-- 10) archived rows readable only via legitimate creator/requester paths
-- -- As unrelated authenticated user: SELECT on an archived game id should return 0 rows.
-- -- As creator or approved/pending/rejected requester: readable via existing RLS.
-- SELECT count(*) AS leaked_public_archived
-- FROM public.pickup_games
-- WHERE archived_at IS NOT NULL
--   AND status = 'active'
--   AND is_visible
--   AND (remove_after_at IS NULL OR remove_after_at > now());
-- -- expect 0
--
-- Extra: after one service-role purge call, unarchived past-window rows should be 0:
-- SELECT count(*) AS still_unarchived_past_window
-- FROM public.pickup_games
-- WHERE remove_after_at IS NOT NULL AND remove_after_at <= now() AND archived_at IS NULL;
--
-- =============================================================================
-- Rollback SQL (returns to actual pre-20260883 production baseline)
-- =============================================================================
-- Run deliberately only if this migration must be undone.
-- Does NOT delete pickup games, requests, invites, or ratings.
--
-- IMPORTANT — production baseline (srizbpfkigidsjxvpnkt):
--   purge_expired_pickup_games() did NOT exist before apply.
--   Rollback must DROP the function.
--   Do NOT recreate a hard-delete purge body — that would introduce destructive
--   CASCADE capability that was not present on this production baseline.
--   A previous hard-delete rollback draft is INVALID for this baseline and must
--   not remain in this file.
--
-- BEGIN;
--
-- -- Restore live rating RPC body (cancelled/canceled only; no 'removed').
-- CREATE OR REPLACE FUNCTION public.submit_pickup_creator_rating(
--   p_pickup_game_id uuid,
--   p_rating integer,
--   p_feedback text DEFAULT NULL
-- )
-- RETURNS TABLE (
--   outcome text,
--   already_rated boolean,
--   rating integer,
--   organizer_avg_rating numeric,
--   organizer_rating_count bigint
-- )
-- LANGUAGE plpgsql
-- SECURITY DEFINER
-- SET search_path = public
-- AS $$
-- DECLARE
--   me uuid := auth.uid();
--   v_creator uuid;
--   v_end timestamptz;
--   v_status text;
--   v_feedback text;
--   v_existing integer;
--   v_avg numeric;
--   v_count bigint;
-- BEGIN
--   IF me IS NULL THEN
--     RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
--   END IF;
--   IF p_pickup_game_id IS NULL THEN
--     RAISE EXCEPTION 'missing_pickup_game_id' USING ERRCODE = '22023';
--   END IF;
--   IF p_rating IS NULL OR p_rating < 1 OR p_rating > 5 THEN
--     RAISE EXCEPTION 'rating_out_of_range' USING ERRCODE = '22023';
--   END IF;
--   v_feedback := nullif(trim(both from coalesce(p_feedback, '')), '');
--   IF v_feedback IS NOT NULL AND char_length(v_feedback) > 1000 THEN
--     RAISE EXCEPTION 'feedback_too_long' USING ERRCODE = '22023';
--   END IF;
--   SELECT
--     g.creator_user_id,
--     coalesce(g.end_time, g.game_start_at + interval '2 hours'),
--     lower(trim(both from coalesce(g.status, '')))
--   INTO v_creator, v_end, v_status
--   FROM public.pickup_games g
--   WHERE g.id = p_pickup_game_id;
--   IF v_creator IS NULL THEN
--     RAISE EXCEPTION 'pickup_game_not_found' USING ERRCODE = 'P0002';
--   END IF;
--   IF me = v_creator THEN
--     RAISE EXCEPTION 'cannot_rate_own_game' USING ERRCODE = '42501';
--   END IF;
--   IF v_status IN ('cancelled', 'canceled') THEN
--     RAISE EXCEPTION 'game_canceled' USING ERRCODE = '42501';
--   END IF;
--   IF v_end IS NULL OR v_end > now() THEN
--     RAISE EXCEPTION 'game_not_completed' USING ERRCODE = '42501';
--   END IF;
--   IF NOT EXISTS (
--     SELECT 1 FROM public.pickup_game_requests r
--     WHERE r.pickup_game_id = p_pickup_game_id
--       AND r.requester_user_id = me
--       AND lower(trim(both from r.status)) = 'approved'
--   ) THEN
--     RAISE EXCEPTION 'not_eligible_participant' USING ERRCODE = '42501';
--   END IF;
--   SELECT r.rating INTO v_existing
--   FROM public.pickup_game_creator_ratings r
--   WHERE r.pickup_game_id = p_pickup_game_id AND r.rater_user_id = me
--   LIMIT 1;
--   IF v_existing IS NOT NULL THEN
--     SELECT
--       CASE WHEN count(*) = 0 THEN NULL::numeric ELSE round(avg(r.rating)::numeric, 2) END,
--       count(*)::bigint
--     INTO v_avg, v_count
--     FROM public.pickup_game_creator_ratings r
--     WHERE r.creator_user_id = v_creator;
--     outcome := 'already_rated'; already_rated := true; rating := v_existing;
--     organizer_avg_rating := v_avg; organizer_rating_count := v_count;
--     RETURN NEXT; RETURN;
--   END IF;
--   INSERT INTO public.pickup_game_creator_ratings (
--     pickup_game_id, creator_user_id, rater_user_id, rating, feedback
--   ) VALUES (p_pickup_game_id, v_creator, me, p_rating, v_feedback);
--   SELECT
--     CASE WHEN count(*) = 0 THEN NULL::numeric ELSE round(avg(r.rating)::numeric, 2) END,
--     count(*)::bigint
--   INTO v_avg, v_count
--   FROM public.pickup_game_creator_ratings r
--   WHERE r.creator_user_id = v_creator;
--   outcome := 'accepted'; already_rated := false; rating := p_rating;
--   organizer_avg_rating := v_avg; organizer_rating_count := v_count;
--   RETURN NEXT;
-- END;
-- $$;
--
-- COMMENT ON FUNCTION public.submit_pickup_creator_rating(uuid, integer, text) IS
--   'Authenticated insert of one organizer rating per completed pickup game; immutable; returns organizer aggregates.';
-- REVOKE ALL ON FUNCTION public.submit_pickup_creator_rating(uuid, integer, text) FROM PUBLIC;
-- REVOKE ALL ON FUNCTION public.submit_pickup_creator_rating(uuid, integer, text) FROM anon;
-- GRANT EXECUTE ON FUNCTION public.submit_pickup_creator_rating(uuid, integer, text) TO authenticated;
-- GRANT EXECUTE ON FUNCTION public.submit_pickup_creator_rating(uuid, integer, text) TO service_role;
--
-- -- Restore live INSERT policy (20260880-qualified; cancelled/canceled only).
-- DROP POLICY IF EXISTS pickup_game_creator_ratings_insert_eligible
--   ON public.pickup_game_creator_ratings;
-- CREATE POLICY pickup_game_creator_ratings_insert_eligible
--   ON public.pickup_game_creator_ratings
--   FOR INSERT
--   TO authenticated
--   WITH CHECK (
--     public.pickup_game_creator_ratings.rater_user_id = (SELECT auth.uid())
--     AND EXISTS (
--       SELECT 1
--       FROM public.pickup_games AS g
--       WHERE g.id = public.pickup_game_creator_ratings.pickup_game_id
--         AND g.creator_user_id = public.pickup_game_creator_ratings.creator_user_id
--         AND lower(trim(both from coalesce(g.status, '')))
--               NOT IN ('cancelled', 'canceled')
--         AND coalesce(g.end_time, g.game_start_at + interval '2 hours') <= now()
--     )
--     AND EXISTS (
--       SELECT 1
--       FROM public.pickup_game_requests AS r
--       WHERE r.pickup_game_id = public.pickup_game_creator_ratings.pickup_game_id
--         AND r.requester_user_id = (SELECT auth.uid())
--         AND lower(trim(both from r.status)) = 'approved'
--     )
--   );
-- REVOKE UPDATE ON public.pickup_game_creator_ratings FROM authenticated;
--
-- -- Return purge to pre-migration state: ABSENT (do not recreate hard DELETE).
-- DROP FUNCTION IF EXISTS public.purge_expired_pickup_games();
--
-- DROP INDEX IF EXISTS public.idx_pickup_games_archive_candidates;
-- DROP INDEX IF EXISTS public.idx_pickup_games_archived_at;
-- ALTER TABLE public.pickup_games DROP COLUMN IF EXISTS archived_at;
--
-- COMMIT;
--
-- NOTE: Dropping archived_at clears the stamp only. Pickup rows and children
-- retained during apply remain retained. No hard-delete purge is reintroduced.
-- =============================================================================
