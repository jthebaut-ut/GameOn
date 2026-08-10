-- =============================================================================
-- 20260949_0001_list_pickup_discover_team_identities.sql
-- REVIEW ONLY — do NOT apply automatically from the agent.
--
-- Batch-hydrate Fan Team identity for Pickup Games the viewer can already SELECT.
-- Used by Discover map pins + preview cards so Team-linked games show Team logo/name
-- without N+1 queries and without exposing Teams the viewer cannot see as games.
--
-- Does NOT broaden pickup_games / fan_teams / fan_team_game_links table RLS.
-- =============================================================================

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.pickup_games') IS NULL THEN
    v_missing := v_missing || ARRAY['table pickup_games'];
  END IF;
  IF to_regclass('public.fan_team_game_links') IS NULL THEN
    v_missing := v_missing || ARRAY['table fan_team_game_links'];
  END IF;
  IF to_regclass('public.fan_teams') IS NULL THEN
    v_missing := v_missing || ARRAY['table fan_teams'];
  END IF;
  IF coalesce(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION '20260949 preflight failed: missing %', array_to_string(v_missing, ', ');
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.list_pickup_discover_team_identities(
  p_pickup_game_ids uuid[]
)
RETURNS TABLE (
  pickup_game_id uuid,
  team_id uuid,
  team_name text,
  team_sport text,
  color_hex text,
  logo_url text,
  logo_thumbnail_url text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH requested AS (
    SELECT DISTINCT x AS pickup_game_id
    FROM unnest(coalesce(p_pickup_game_ids, ARRAY[]::uuid[])) AS x
    WHERE x IS NOT NULL
    LIMIT 400
  ),
  visible_games AS (
    SELECT g.id
    FROM public.pickup_games g
    INNER JOIN requested r ON r.pickup_game_id = g.id
    WHERE
      -- Mirror authenticated SELECT branches when auth.uid() is present.
      (
        auth.uid() IS NOT NULL
        AND (
          g.creator_user_id = auth.uid()
          OR (
            lower(btrim(g.status)) = 'active'
            AND g.is_visible IS TRUE
            AND (g.remove_after_at IS NULL OR g.remove_after_at > now())
          )
          OR public.can_read_pickup_game_for_requester(g.id)
          OR public.is_pickup_game_fan_team_participant(g.id, auth.uid())
        )
      )
      OR
      -- Guest/anon: only public active Discover-safe rows (matches anon SELECT).
      (
        auth.uid() IS NULL
        AND lower(btrim(g.status)) = 'active'
        AND g.is_visible IS TRUE
        AND g.game_start_at >= (now() - interval '1 day')
        AND (g.remove_after_at IS NULL OR g.remove_after_at > now())
      )
  )
  SELECT
    l.pickup_game_id,
    t.id AS team_id,
    nullif(btrim(coalesce(t.name, '')), '') AS team_name,
    nullif(btrim(coalesce(t.sport, '')), '') AS team_sport,
    nullif(btrim(coalesce(t.color_hex, '')), '') AS color_hex,
    nullif(btrim(coalesce(t.logo_url, '')), '') AS logo_url,
    nullif(btrim(coalesce(t.logo_thumbnail_url, t.logo_url, '')), '') AS logo_thumbnail_url
  FROM public.fan_team_game_links l
  INNER JOIN visible_games vg ON vg.id = l.pickup_game_id
  INNER JOIN public.fan_teams t ON t.id = l.team_id
  WHERE coalesce(t.is_active, true) = true
  LIMIT 400;
$$;

COMMENT ON FUNCTION public.list_pickup_discover_team_identities(uuid[]) IS
  'Batch Team identity for Discover pins/cards for pickup games the caller can already SELECT.';

REVOKE ALL ON FUNCTION public.list_pickup_discover_team_identities(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_pickup_discover_team_identities(uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_pickup_discover_team_identities(uuid[]) TO anon;
