-- =============================================================================
-- 20260877 — Authoritative pickup organizer rating submit (immutable)
-- =============================================================================
--
-- Completes the pickup-game organizer rating system:
--   1) SECURITY DEFINER submit_pickup_creator_rating(game_id, rating, feedback)
--      — client sends only game id + stars (+ optional feedback)
--      — derives rater, organizer, eligibility, completion from server state
--   2) Tightens INSERT RLS to require scheduled end (not merely start)
--   3) Makes ratings immutable (no UPDATE for authenticated users)
--
-- Eligibility (server time):
--   - authenticated rater
--   - game exists
--   - coalesce(end_time, game_start_at + 2 hours) <= now()
--   - rater has approved pickup_game_requests row
--   - rater is not the organizer
--   - one rating per (pickup_game_id, rater_user_id)
--
-- Do NOT apply from the agent against the linked (production) project.
-- =============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regclass('public.pickup_game_creator_ratings') IS NULL THEN
    RAISE EXCEPTION 'preflight failed: public.pickup_game_creator_ratings missing';
  END IF;
  IF to_regclass('public.pickup_games') IS NULL THEN
    RAISE EXCEPTION 'preflight failed: public.pickup_games missing';
  END IF;
  IF to_regclass('public.pickup_game_requests') IS NULL THEN
    RAISE EXCEPTION 'preflight failed: public.pickup_game_requests missing';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Immutable ratings: revoke UPDATE for authenticated (account deletion uses
-- service_role / SECURITY DEFINER paths elsewhere).
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS pickup_game_creator_ratings_update_own ON public.pickup_game_creator_ratings;

REVOKE UPDATE ON public.pickup_game_creator_ratings FROM authenticated;

-- ---------------------------------------------------------------------------
-- Tighten INSERT eligibility: completed = scheduled end reached (server now).
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS pickup_game_creator_ratings_insert_eligible ON public.pickup_game_creator_ratings;
CREATE POLICY pickup_game_creator_ratings_insert_eligible
  ON public.pickup_game_creator_ratings
  FOR INSERT
  TO authenticated
  WITH CHECK (
    rater_user_id = (SELECT auth.uid())
    AND EXISTS (
      SELECT 1
      FROM public.pickup_games g
      WHERE g.id = pickup_game_id
        AND g.creator_user_id = creator_user_id
        AND coalesce(
              g.end_time,
              g.game_start_at + interval '2 hours'
            ) <= now()
    )
    AND EXISTS (
      SELECT 1
      FROM public.pickup_game_requests r
      WHERE r.pickup_game_id = pickup_game_id
        AND r.requester_user_id = (SELECT auth.uid())
        AND lower(trim(both from r.status)) = 'approved'
    )
  );

-- ---------------------------------------------------------------------------
-- Authoritative submit RPC
-- ---------------------------------------------------------------------------
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

  IF v_status IN ('cancelled', 'canceled') THEN
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
  'Authenticated insert of one organizer rating per completed pickup game; immutable; returns organizer aggregates.';

REVOKE ALL ON FUNCTION public.submit_pickup_creator_rating(uuid, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.submit_pickup_creator_rating(uuid, integer, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.submit_pickup_creator_rating(uuid, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_pickup_creator_rating(uuid, integer, text) TO service_role;

COMMIT;

-- Post-apply (SELECT only):
-- SELECT proname, pg_get_function_identity_arguments(oid)
-- FROM pg_proc WHERE proname = 'submit_pickup_creator_rating';
-- SELECT has_function_privilege('anon','public.submit_pickup_creator_rating(uuid,integer,text)'::regprocedure,'EXECUTE');
-- -- expect false
