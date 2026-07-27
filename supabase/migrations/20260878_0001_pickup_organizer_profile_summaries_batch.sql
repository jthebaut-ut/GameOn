-- =============================================================================
-- 20260878 — Batch pickup organizer profile summaries for Discover map cards
-- =============================================================================
--
-- Reuses public.pickup_organizer_profile_summary (hosted + avg + count + last
-- created) for many organizers in one round-trip. Avoids N+1 per map card.
--
-- Does not expose rating authors or private participant data.
-- Do NOT apply from the agent against the linked (production) project.
-- =============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.pickup_organizer_profile_summary(uuid)') IS NULL THEN
    RAISE EXCEPTION 'preflight failed: public.pickup_organizer_profile_summary(uuid) missing';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.pickup_organizer_profile_summaries(p_user_ids uuid[])
RETURNS TABLE (
  user_id uuid,
  pickup_games_hosted_count integer,
  pickup_organizer_average_rating numeric,
  pickup_organizer_rating_count bigint,
  last_pickup_game_created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    u.uid AS user_id,
    s.pickup_games_hosted_count,
    s.pickup_organizer_average_rating,
    s.pickup_organizer_rating_count,
    s.last_pickup_game_created_at
  FROM (
    SELECT DISTINCT x AS uid
    FROM unnest(coalesce(p_user_ids, ARRAY[]::uuid[])) AS x
    WHERE x IS NOT NULL
  ) AS u
  CROSS JOIN LATERAL public.pickup_organizer_profile_summary(u.uid) AS s;
$$;

COMMENT ON FUNCTION public.pickup_organizer_profile_summaries(uuid[]) IS
  'Batched organizer hosted/rating aggregates for Discover map cards; same definitions as pickup_organizer_profile_summary.';

REVOKE ALL ON FUNCTION public.pickup_organizer_profile_summaries(uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pickup_organizer_profile_summaries(uuid[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.pickup_organizer_profile_summaries(uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pickup_organizer_profile_summaries(uuid[]) TO service_role;

COMMIT;

-- Post-apply (SELECT only):
-- SELECT proname, pg_get_function_identity_arguments(oid)
-- FROM pg_proc WHERE proname = 'pickup_organizer_profile_summaries';
-- SELECT has_function_privilege('anon','public.pickup_organizer_profile_summaries(uuid[])'::regprocedure,'EXECUTE');
-- -- expect false
