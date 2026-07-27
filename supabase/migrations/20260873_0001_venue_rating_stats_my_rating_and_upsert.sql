-- =============================================================================
-- 20260873 — Venue rating stats: include my_rating + upsert returning aggregates
-- =============================================================================
--
-- Production already has:
--   public.venue_ratings (PK venue_id, user_id) — one active rating per user
--   public.get_venue_rating_stats(uuid[]) → venue_id, average_rating, rating_count
--
-- iOS historically saved ratings only in UserDefaults and never called this RPC,
-- so community counts never appeared in the rating sheet.
--
-- This migration:
--   1) Extends get_venue_rating_stats to also return my_rating (auth.uid()).
--   2) Adds upsert_my_venue_rating(venue, stars) which upserts the caller's row
--      and returns the same aggregate shape in one round-trip (for Save refresh).
--
-- Does not rewrite existing ratings. Do NOT apply from the agent.
-- =============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regclass('public.venue_ratings') IS NULL THEN
    RAISE EXCEPTION 'preflight failed: public.venue_ratings missing';
  END IF;
  IF to_regclass('public.venues') IS NULL THEN
    RAISE EXCEPTION 'preflight failed: public.venues missing';
  END IF;
  IF to_regprocedure('public.get_venue_rating_stats(uuid[])') IS NULL THEN
    RAISE EXCEPTION 'preflight failed: public.get_venue_rating_stats(uuid[]) missing';
  END IF;
END;
$$;

-- Changing OUT columns requires drop + recreate.
DROP FUNCTION IF EXISTS public.get_venue_rating_stats(uuid[]);

CREATE OR REPLACE FUNCTION public.get_venue_rating_stats(p_venue_ids uuid[])
RETURNS TABLE (
  venue_id uuid,
  average_rating numeric,
  rating_count bigint,
  my_rating smallint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    vr.venue_id,
    round(avg(vr.rating::numeric), 2) AS average_rating,
    count(*)::bigint AS rating_count,
    (
      SELECT r.rating
      FROM public.venue_ratings r
      WHERE r.venue_id = vr.venue_id
        AND r.user_id = auth.uid()
      LIMIT 1
    ) AS my_rating
  FROM public.venue_ratings vr
  WHERE vr.venue_id = ANY (p_venue_ids)
  GROUP BY vr.venue_id;
$$;

COMMENT ON FUNCTION public.get_venue_rating_stats(uuid[]) IS
  'Aggregate venue ratings: average (2dp), distinct-user count (one row per user PK), and caller my_rating when authenticated.';

REVOKE ALL ON FUNCTION public.get_venue_rating_stats(uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_venue_rating_stats(uuid[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_venue_rating_stats(uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_venue_rating_stats(uuid[]) TO service_role;

-- Single-venue upsert + fresh aggregates for Save.
CREATE OR REPLACE FUNCTION public.upsert_my_venue_rating(
  p_venue_id uuid,
  p_rating smallint
)
RETURNS TABLE (
  venue_id uuid,
  average_rating numeric,
  rating_count bigint,
  my_rating smallint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '28000';
  END IF;
  IF p_venue_id IS NULL THEN
    RAISE EXCEPTION 'missing venue id';
  END IF;
  IF p_rating IS NULL OR p_rating < 1 OR p_rating > 5 THEN
    RAISE EXCEPTION 'rating must be between 1 and 5';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.venues v WHERE v.id = p_venue_id) THEN
    RAISE EXCEPTION 'venue not found' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO public.venue_ratings (venue_id, user_id, rating, created_at, updated_at)
  VALUES (p_venue_id, me, p_rating, now(), now())
  ON CONFLICT (venue_id, user_id) DO UPDATE
    SET rating = EXCLUDED.rating,
        updated_at = now();

  RETURN QUERY
  SELECT s.venue_id, s.average_rating, s.rating_count, s.my_rating
  FROM public.get_venue_rating_stats(ARRAY[p_venue_id]) AS s;
END;
$$;

COMMENT ON FUNCTION public.upsert_my_venue_rating(uuid, smallint) IS
  'Authenticated upsert of caller venue rating (1–5). Returns refreshed average, distinct-user count, and my_rating.';

REVOKE ALL ON FUNCTION public.upsert_my_venue_rating(uuid, smallint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.upsert_my_venue_rating(uuid, smallint) FROM anon;
GRANT EXECUTE ON FUNCTION public.upsert_my_venue_rating(uuid, smallint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_my_venue_rating(uuid, smallint) TO service_role;

COMMIT;

-- Post-apply (SELECT only):
-- SELECT pg_get_function_identity_arguments(oid), pg_get_function_result(oid)
-- FROM pg_proc WHERE proname IN ('get_venue_rating_stats','upsert_my_venue_rating');
-- SELECT has_function_privilege('anon','public.get_venue_rating_stats(uuid[])'::regprocedure,'EXECUTE');
-- -- expect false
-- SELECT has_function_privilege('authenticated','public.upsert_my_venue_rating(uuid,smallint)'::regprocedure,'EXECUTE');
-- -- expect true
