-- =============================================================================
-- 20260880 — Fix pickup_game_creator_ratings INSERT policy scoping
-- =============================================================================
--
-- 20260877 created pickup_game_creator_ratings_insert_eligible with unqualified
-- column references inside EXISTS subqueries. PostgreSQL bound those names to
-- the inner tables (pickup_games / pickup_game_requests), producing tautologies:
--   g.creator_user_id = g.creator_user_id
--   r.pickup_game_id = r.pickup_game_id
--
-- That weakened direct INSERT RLS (any approved participant of any game could
-- potentially insert for a completed game). The SECURITY DEFINER RPC
-- submit_pickup_creator_rating remains correct and is unchanged.
--
-- This forward-only migration recreates the policy with fully qualified outer
-- table references so Postgres stores unambiguous comparisons, and mirrors the
-- RPC's canceled-game rejection so direct INSERT RLS matches
-- submit_pickup_creator_rating (status lower/trim IN ('cancelled','canceled')).
--
-- Do NOT edit 20260877 (already applied on production; immutable history).
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
              NOT IN ('cancelled', 'canceled')
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

-- Preserve immutability from 20260877 (no UPDATE for authenticated).
-- Idempotent; does not broaden grants.
REVOKE UPDATE ON public.pickup_game_creator_ratings FROM authenticated;

COMMENT ON POLICY pickup_game_creator_ratings_insert_eligible
  ON public.pickup_game_creator_ratings IS
  'INSERT only when rater is auth.uid(), outer creator matches game creator, game status is not cancelled/canceled (mirrors submit_pickup_creator_rating), scheduled end reached, and rater has an approved request for the same pickup_game_id. Outer columns fully qualified to avoid subquery name binding.';

COMMIT;

-- ---------------------------------------------------------------------------
-- Post-deployment verification (SELECT only; run after apply):
--
-- 1) Stored WITH CHECK must reference outer table columns and must NOT contain
--    tautologies like g.creator_user_id = g.creator_user_id.
--
-- SELECT pg_get_expr(pol.polwithcheck, pol.polrelid) AS with_check_expr
-- FROM pg_policy pol
-- JOIN pg_class c ON c.oid = pol.polrelid
-- JOIN pg_namespace n ON n.oid = c.relnamespace
-- WHERE n.nspname = 'public'
--   AND c.relname = 'pickup_game_creator_ratings'
--   AND pol.polname = 'pickup_game_creator_ratings_insert_eligible';
--
-- Expect substrings:
--   pickup_game_creator_ratings.pickup_game_id
--   pickup_game_creator_ratings.creator_user_id
-- Expect NOT present:
--   g.creator_user_id = g.creator_user_id
--   r.pickup_game_id = r.pickup_game_id
--
-- 2) No UPDATE policy for authenticated; UPDATE privilege still revoked:
--
-- SELECT count(*) AS update_policies
-- FROM pg_policies
-- WHERE schemaname = 'public'
--   AND tablename = 'pickup_game_creator_ratings'
--   AND cmd = 'UPDATE';
-- -- expect 0
--
-- SELECT has_table_privilege(
--   'authenticated',
--   'public.pickup_game_creator_ratings',
--   'UPDATE'
-- );
-- -- expect false
--
-- 3) RPC unchanged:
--
-- SELECT pg_get_function_identity_arguments(oid)
-- FROM pg_proc
-- WHERE pronamespace = 'public'::regnamespace
--   AND proname = 'submit_pickup_creator_rating';
-- -- expect: p_pickup_game_id uuid, p_rating integer, p_feedback text
-- ---------------------------------------------------------------------------
