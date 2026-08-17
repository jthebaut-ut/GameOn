-- =============================================================================
-- 20261000_0001 — Discoverable Fan Teams on Play → Places
-- =============================================================================
-- Adds Team discovery visibility (independent of membership privacy) plus a
-- single canonical discovery location on fan_teams. Does NOT:
--   * broaden fan_teams table RLS
--   * reuse fan_team_locations (those remain schedule places)
--   * auto-publish existing Teams (is_discoverable defaults FALSE)
--   * create a second Team identity
--   * own or reconstruct the global assert_rpc_rate_limit implementation
--
-- Rate limiting: read the complete live assert_rpc_rate_limit definition via
-- pg_get_functiondef. If the allowlist needs update_fan_team_discovery (union
-- live + repository contract), substitute ONLY the v_allowed_buckets ARRAY
-- contents. Never drop live buckets. Never emit a static limiter body.
-- update_fan_team_discovery still calls assert_rpc_rate_limit.
--
-- Public map/search uses SECURITY DEFINER RPCs that return only safe fields.
-- Discoverable Teams MUST have a valid public-safe location (server enforced).
--
-- Transaction: PRE-FLIGHT (read-only) → BEGIN → writes → POSTFLIGHT → COMMIT.
-- Every correctness/security assertion runs before COMMIT. A failed postflight
-- rolls back columns, RPCs, grants, and the rate-limit ARRAY patch.
--
-- PREPARE ONLY — do not auto-apply. No Edge deploy.
-- =============================================================================

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.fan_teams') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_teams'];
  END IF;
  IF to_regclass('public.fan_team_members') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_team_members'];
  END IF;
  IF to_regprocedure('public.fan_team_viewer_has_permission(uuid, text)') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_team_viewer_has_permission(uuid,text)'];
  END IF;
  IF to_regprocedure('public.fan_team_active_player_count(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_team_active_player_count(uuid)'];
  END IF;
  IF to_regprocedure('public.assert_rpc_rate_limit(text,int,int)') IS NULL THEN
    v_missing := v_missing || ARRAY['assert_rpc_rate_limit(text,int,int)'];
  END IF;
  IF to_regclass('public.rpc_rate_limits') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.rpc_rate_limits'];
  END IF;
  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION '20261000_0001 prerequisite missing: %',
      array_to_string(v_missing, ', ');
  END IF;
END $$;

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Columns on fan_teams (existing rows stay private / non-discoverable)
-- -----------------------------------------------------------------------------
ALTER TABLE public.fan_teams
  ADD COLUMN IF NOT EXISTS is_discoverable boolean NOT NULL DEFAULT false;

ALTER TABLE public.fan_teams
  ADD COLUMN IF NOT EXISTS looking_for_players boolean NOT NULL DEFAULT false;

ALTER TABLE public.fan_teams
  ADD COLUMN IF NOT EXISTS sport_subtype text;

ALTER TABLE public.fan_teams
  ADD COLUMN IF NOT EXISTS discovery_location_precision text NOT NULL DEFAULT 'specific';

ALTER TABLE public.fan_teams
  ADD COLUMN IF NOT EXISTS discovery_place_name text;

ALTER TABLE public.fan_teams
  ADD COLUMN IF NOT EXISTS discovery_address text;

ALTER TABLE public.fan_teams
  ADD COLUMN IF NOT EXISTS discovery_city text;

ALTER TABLE public.fan_teams
  ADD COLUMN IF NOT EXISTS discovery_region text;

ALTER TABLE public.fan_teams
  ADD COLUMN IF NOT EXISTS discovery_postal_code text;

ALTER TABLE public.fan_teams
  ADD COLUMN IF NOT EXISTS discovery_country_code text;

ALTER TABLE public.fan_teams
  ADD COLUMN IF NOT EXISTS discovery_latitude double precision;

ALTER TABLE public.fan_teams
  ADD COLUMN IF NOT EXISTS discovery_longitude double precision;

ALTER TABLE public.fan_teams
  DROP CONSTRAINT IF EXISTS fan_teams_sport_subtype_len;

ALTER TABLE public.fan_teams
  ADD CONSTRAINT fan_teams_sport_subtype_len
  CHECK (
    sport_subtype IS NULL
    OR (
      char_length(btrim(sport_subtype)) BETWEEN 1 AND 40
      AND sport_subtype = btrim(sport_subtype)
    )
  );

ALTER TABLE public.fan_teams
  DROP CONSTRAINT IF EXISTS fan_teams_discovery_precision_ck;

ALTER TABLE public.fan_teams
  ADD CONSTRAINT fan_teams_discovery_precision_ck
  CHECK (discovery_location_precision IN ('specific', 'general_area'));

ALTER TABLE public.fan_teams
  DROP CONSTRAINT IF EXISTS fan_teams_discovery_country_code_ck;

ALTER TABLE public.fan_teams
  ADD CONSTRAINT fan_teams_discovery_country_code_ck
  CHECK (
    discovery_country_code IS NULL
    OR (
      char_length(btrim(discovery_country_code)) = 2
      AND discovery_country_code = upper(btrim(discovery_country_code))
    )
  );

ALTER TABLE public.fan_teams
  DROP CONSTRAINT IF EXISTS fan_teams_discoverable_requires_location_ck;

ALTER TABLE public.fan_teams
  ADD CONSTRAINT fan_teams_discoverable_requires_location_ck
  CHECK (
    is_discoverable IS FALSE
    OR (
      discovery_latitude IS NOT NULL
      AND discovery_longitude IS NOT NULL
      AND abs(discovery_latitude) <= 90
      AND abs(discovery_longitude) <= 180
      AND NOT (discovery_latitude = 0 AND discovery_longitude = 0)
      AND discovery_country_code IS NOT NULL
      AND char_length(btrim(discovery_country_code)) = 2
      AND (
        coalesce(btrim(discovery_city), '') <> ''
        OR coalesce(btrim(discovery_place_name), '') <> ''
      )
    )
  );

CREATE INDEX IF NOT EXISTS idx_fan_teams_discoverable_geo
  ON public.fan_teams (discovery_latitude, discovery_longitude)
  WHERE is_discoverable IS TRUE
    AND is_active IS TRUE
    AND discovery_latitude IS NOT NULL
    AND discovery_longitude IS NOT NULL;

COMMENT ON COLUMN public.fan_teams.is_discoverable IS
  'Owner-controlled Discover visibility. FALSE (default) never appears on Play → Places.';
COMMENT ON COLUMN public.fan_teams.looking_for_players IS
  'Recruiting badge. Independent of is_discoverable; never publishes a hidden Team.';
COMMENT ON COLUMN public.fan_teams.discovery_location_precision IS
  'specific = place/address may be shown; general_area = locality/country only.';

-- -----------------------------------------------------------------------------
-- 2) Rate-limit allowlist — patch ONLY the live ARRAY initializer
-- -----------------------------------------------------------------------------
-- Read the complete live definition with pg_get_functiondef.
-- Locate exactly one executable v_allowed_buckets text[] := ARRAY[...];
-- Canonical ARRAY initializer parser (do not fork). Same v_init_pattern /
-- v_capture_pattern strings are used for live parse, post-merge verification,
-- and the final transaction postflight. Optional ::text[] cast is accepted.
-- Exactly one initializer is required. Bucket tokens are quoted identifiers
-- inside the ARRAY region only — comments are not matched as buckets.
-- Union live buckets with the repository contract (includes
-- update_fan_team_discovery). If the merged set already matches live, do not
-- replace the function. Otherwise substitute only the ARRAY contents inside
-- the live definition text and EXECUTE that patched definition.
-- Fail closed on missing function, NULL definition, ambiguous parse, dropped
-- live buckets, missing repo buckets, lost SECURITY DEFINER, or wrong
-- privileges. Never emit a static limiter body from this migration.
-- -----------------------------------------------------------------------------
DO $rl$
DECLARE
  v_def text;
  -- CANONICAL_RL_ARRAY_INIT_PATTERN (do not fork)
  v_init_pattern text :=
    'v_allowed_buckets[[:space:]]+text[[:space:]]*\[\][[:space:]]*:=[[:space:]]*ARRAY\[(?:.|\n)*?\][[:space:]]*(::[[:space:]]*text\[\])?[[:space:]]*;';
  -- CANONICAL_RL_ARRAY_CAPTURE_PATTERN (do not fork)
  v_capture_pattern text :=
    '(v_allowed_buckets[[:space:]]+text[[:space:]]*\[\][[:space:]]*:=[[:space:]]*ARRAY\[)((?:.|\n)*?)(\][[:space:]]*(::[[:space:]]*text\[\])?[[:space:]]*;)';
  v_init_count int;
  v_matches text[];
  v_head text;
  v_inner text;
  v_tail text;
  v_old_full text;
  v_new_inner text;
  v_new_full text;
  v_new_def text;
  v_pos int;
  v_stripped_old text;
  v_stripped_new text;
  v_live text[] := ARRAY[]::text[];
  v_repo text[] := ARRAY[
    'accept_fan_team_invitation',
    'accept_fan_team_invitation_as_managed_player',
    'accept_fan_team_invitation_for_participants',
    'add_managed_player_to_fan_team',
    'create_fan_team',
    'create_managed_player',
    'decline_fan_team_invitation',
    'delete_fan_team',
    'friendship_ensure_pending',
    'invite_fan_team_members',
    'leave_fan_team',
    'poke_profile',
    'report_fan_team',
    'report_group_message',
    'resend_fan_team_invitation',
    'search_chat_conversations',
    'search_chat_messages',
    'send_direct_message',
    'send_group_message',
    'set_fan_team_member_permissions',
    'set_fan_team_membership_role',
    'set_my_fan_team_is_player',
    'set_my_teams_profile_visibility',
    'update_fan_team_discovery',
    'update_managed_player'
  ];
  v_extra text[];
  v_merged text[];
  v_merged_ordered text[];
  v_missing_repo text[];
  v_dropped_live text[];
  v_list text;
  v_patched text[];
  v_final_def text;
  v_final_matches text[];
  v_final_inner text;
  v_final text[];
  v_prosecdef boolean;
BEGIN
  IF to_regprocedure('public.assert_rpc_rate_limit(text,integer,integer)') IS NULL THEN
    RAISE EXCEPTION '20261000 assert_rpc_rate_limit(text,integer,integer) does not exist';
  END IF;

  SELECT p.prosecdef
    INTO v_prosecdef
  FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.assert_rpc_rate_limit(text,integer,integer)'::regprocedure;

  IF v_prosecdef IS NOT TRUE THEN
    RAISE EXCEPTION '20261000 assert_rpc_rate_limit must be SECURITY DEFINER before merge';
  END IF;

  v_def := pg_get_functiondef(
    'public.assert_rpc_rate_limit(text,integer,integer)'::regprocedure
  );
  IF v_def IS NULL OR btrim(v_def) = '' THEN
    RAISE EXCEPTION '20261000 pg_get_functiondef returned NULL';
  END IF;
  IF position('SECURITY DEFINER' IN upper(v_def)) = 0 THEN
    RAISE EXCEPTION '20261000 live pg_get_functiondef text is missing SECURITY DEFINER';
  END IF;

  SELECT count(*)::int
    INTO v_init_count
  FROM regexp_matches(v_def, v_init_pattern, 'g');

  IF v_init_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION
      '20261000 expected exactly one v_allowed_buckets initializer, found %',
      coalesce(v_init_count, 0);
  END IF;

  v_matches := regexp_match(v_def, v_capture_pattern);
  IF v_matches IS NULL
     OR v_matches[1] IS NULL
     OR v_matches[2] IS NULL
     OR v_matches[3] IS NULL THEN
    RAISE EXCEPTION
      '20261000 cannot parse live assert_rpc_rate_limit ARRAY allowlist';
  END IF;

  v_head := v_matches[1];
  v_inner := v_matches[2];
  v_tail := v_matches[3];
  IF btrim(v_inner) = '' THEN
    RAISE EXCEPTION
      '20261000 cannot parse live assert_rpc_rate_limit ARRAY allowlist';
  END IF;

  v_old_full := v_head || v_inner || v_tail;

  SELECT coalesce(
    (SELECT array_agg(bucket ORDER BY ord)
     FROM (
       SELECT raw.m[1] AS bucket, min(raw.ord) AS ord
       FROM (
         SELECT m, ordinality AS ord
         FROM regexp_matches(v_inner, '''([a-z][a-z0-9_]*)''', 'g')
              WITH ORDINALITY AS t(m, ordinality)
       ) raw
       GROUP BY raw.m[1]
     ) parsed),
    ARRAY[]::text[]
  )
    INTO v_live;

  IF v_live IS NULL OR cardinality(v_live) = 0 THEN
    RAISE EXCEPTION
      '20261000 live assert_rpc_rate_limit ARRAY parsed zero buckets; refusing to patch';
  END IF;

  SELECT array_agg(b ORDER BY b)
    INTO v_merged
  FROM (SELECT DISTINCT b FROM unnest(v_live || v_repo) AS b) s;

  IF v_merged IS NULL OR cardinality(v_merged) < cardinality(v_live) THEN
    RAISE EXCEPTION '20261000 merged allowlist smaller than live ARRAY';
  END IF;

  IF NOT ('update_fan_team_discovery' = ANY (v_merged)) THEN
    RAISE EXCEPTION '20261000 merged allowlist missing update_fan_team_discovery';
  END IF;

  SELECT coalesce(array_agg(b ORDER BY b), ARRAY[]::text[])
    INTO v_missing_repo
  FROM unnest(v_repo) AS b
  WHERE NOT (b = ANY (v_merged));
  IF cardinality(v_missing_repo) > 0 THEN
    RAISE EXCEPTION '20261000 merged allowlist missing repo buckets: %',
      array_to_string(v_missing_repo, ', ');
  END IF;

  SELECT coalesce(array_agg(b ORDER BY b), ARRAY[]::text[])
    INTO v_dropped_live
  FROM unnest(v_live) AS b
  WHERE NOT (b = ANY (v_merged));
  IF cardinality(v_dropped_live) > 0 THEN
    RAISE EXCEPTION '20261000 merged allowlist dropped live buckets: %',
      array_to_string(v_dropped_live, ', ');
  END IF;

  -- Already complete (re-apply): do not replace the function.
  IF v_live @> v_merged AND v_merged @> v_live THEN
    RAISE NOTICE '20261000 assert_rpc_rate_limit already contains merged allowlist; skip rewrite';
  ELSE
    SELECT coalesce(array_agg(b ORDER BY b), ARRAY[]::text[])
      INTO v_extra
    FROM unnest(v_repo) AS b
    WHERE NOT (b = ANY (v_live));

    v_merged_ordered := v_live || coalesce(v_extra, ARRAY[]::text[]);

    SELECT string_agg(quote_literal(b), E',\n    ')
      INTO v_list
    FROM unnest(v_merged_ordered) AS b;

    IF v_list IS NULL OR btrim(v_list) = '' THEN
      RAISE EXCEPTION '20261000 cannot format merged ARRAY contents';
    END IF;

    v_new_inner := E'\n    ' || v_list || E'\n  ';
    v_new_full := v_head || v_new_inner || v_tail;

    SELECT coalesce(
      (SELECT array_agg(bucket ORDER BY bucket)
       FROM (
         SELECT DISTINCT m[1] AS bucket
         FROM regexp_matches(v_new_inner, '''([a-z][a-z0-9_]*)''', 'g') AS m
       ) parsed),
      ARRAY[]::text[]
    )
      INTO v_patched;

    IF v_patched IS NULL
       OR NOT (v_patched @> v_merged AND v_merged @> v_patched) THEN
      RAISE EXCEPTION '20261000 patched ARRAY contents do not match the merged allowlist';
    END IF;

    v_pos := strpos(v_def, v_old_full);
    IF v_pos = 0 THEN
      RAISE EXCEPTION '20261000 live ARRAY initializer not found in pg_get_functiondef text';
    END IF;
    IF strpos(
         overlay(v_def placing '' from v_pos for length(v_old_full)),
         v_old_full
       ) > 0 THEN
      RAISE EXCEPTION
        '20261000 expected exactly one v_allowed_buckets initializer, found more than one identical region';
    END IF;

    v_new_def := overlay(
      v_def
      placing v_new_full
      from v_pos
      for length(v_old_full)
    );

    IF v_new_def IS NULL OR v_new_def = v_def THEN
      RAISE EXCEPTION '20261000 ARRAY replacement did not change the intended ARRAY region';
    END IF;

    v_stripped_old := left(v_def, v_pos - 1)
      || substr(v_def, v_pos + length(v_old_full));
    v_stripped_new := left(v_new_def, v_pos - 1)
      || substr(v_new_def, v_pos + length(v_new_full));
    IF v_stripped_old IS DISTINCT FROM v_stripped_new THEN
      RAISE EXCEPTION '20261000 replacement changed more than the ARRAY initializer';
    END IF;

    SELECT count(*)::int
      INTO v_init_count
    FROM regexp_matches(v_new_def, v_init_pattern, 'g');
    IF v_init_count IS DISTINCT FROM 1 THEN
      RAISE EXCEPTION
        '20261000 patched definition does not contain exactly one v_allowed_buckets initializer, found %',
        coalesce(v_init_count, 0);
    END IF;

    IF position('SECURITY DEFINER' IN upper(v_new_def)) = 0 THEN
      RAISE EXCEPTION '20261000 patched live definition lost SECURITY DEFINER';
    END IF;

    EXECUTE v_new_def;
  END IF;

  SELECT p.prosecdef
    INTO v_prosecdef
  FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.assert_rpc_rate_limit(text,integer,integer)'::regprocedure;

  IF v_prosecdef IS NOT TRUE THEN
    RAISE EXCEPTION '20261000 assert_rpc_rate_limit lost SECURITY DEFINER';
  END IF;

  v_final_def := pg_get_functiondef(
    'public.assert_rpc_rate_limit(text,integer,integer)'::regprocedure
  );
  IF v_final_def IS NULL OR btrim(v_final_def) = '' THEN
    RAISE EXCEPTION '20261000 postflight pg_get_functiondef returned NULL';
  END IF;

  SELECT count(*)::int
    INTO v_init_count
  FROM regexp_matches(v_final_def, v_init_pattern, 'g');
  IF v_init_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION
      '20261000 postflight expected exactly one v_allowed_buckets initializer, found %',
      coalesce(v_init_count, 0);
  END IF;

  v_final_matches := regexp_match(v_final_def, v_capture_pattern);
  v_final_inner := v_final_matches[2];
  IF v_final_inner IS NULL OR btrim(v_final_inner) = '' THEN
    RAISE EXCEPTION '20261000 postflight cannot parse rewritten ARRAY allowlist';
  END IF;

  SELECT coalesce(
    (SELECT array_agg(bucket ORDER BY bucket)
     FROM (
       SELECT DISTINCT m[1] AS bucket
       FROM regexp_matches(v_final_inner, '''([a-z][a-z0-9_]*)''', 'g') AS m
     ) parsed),
    ARRAY[]::text[]
  )
    INTO v_final;

  IF NOT ('update_fan_team_discovery' = ANY (v_final)) THEN
    RAISE EXCEPTION '20261000 postflight ARRAY missing update_fan_team_discovery';
  END IF;

  SELECT coalesce(array_agg(b ORDER BY b), ARRAY[]::text[])
    INTO v_missing_repo
  FROM unnest(v_repo) AS b
  WHERE NOT (b = ANY (v_final));
  IF cardinality(v_missing_repo) > 0 THEN
    RAISE EXCEPTION '20261000 postflight ARRAY missing repo buckets: %',
      array_to_string(v_missing_repo, ', ');
  END IF;

  SELECT coalesce(array_agg(b ORDER BY b), ARRAY[]::text[])
    INTO v_dropped_live
  FROM unnest(v_live) AS b
  WHERE NOT (b = ANY (v_final));
  IF cardinality(v_dropped_live) > 0 THEN
    RAISE EXCEPTION '20261000 postflight dropped live buckets: %',
      array_to_string(v_dropped_live, ', ');
  END IF;

  IF has_function_privilege('anon', 'public.assert_rpc_rate_limit(text,integer,integer)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.assert_rpc_rate_limit(text,integer,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION '20261000 assert_rpc_rate_limit must not be executable by anon/authenticated';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.assert_rpc_rate_limit(text,integer,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION '20261000 service_role must EXECUTE assert_rpc_rate_limit';
  END IF;
END;
$rl$;

-- -----------------------------------------------------------------------------
-- 3) Helpers
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_team_discovery_location_is_valid(
  p_latitude double precision,
  p_longitude double precision,
  p_country_code text,
  p_city text,
  p_place_name text
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    p_latitude IS NOT NULL
    AND p_longitude IS NOT NULL
    AND abs(p_latitude) <= 90
    AND abs(p_longitude) <= 180
    AND NOT (p_latitude = 0 AND p_longitude = 0)
    AND char_length(btrim(coalesce(p_country_code, ''))) = 2
    AND (
      coalesce(btrim(p_city), '') <> ''
      OR coalesce(btrim(p_place_name), '') <> ''
    );
$$;

CREATE OR REPLACE FUNCTION public.fan_team_discovery_sport_matches(
  p_team_sport text,
  p_team_subtype text,
  p_query text
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    p_query IS NULL
    OR btrim(p_query) = ''
    OR lower(btrim(p_query)) IN ('all', '*')
    OR strpos(lower(btrim(coalesce(p_team_sport, ''))), lower(btrim(p_query))) > 0
    OR strpos(lower(btrim(p_query)), lower(btrim(coalesce(p_team_sport, '')))) > 0
    OR (
      coalesce(btrim(p_team_subtype), '') <> ''
      AND (
        strpos(lower(btrim(p_team_subtype)), lower(btrim(p_query))) > 0
        OR strpos(lower(btrim(p_query)), lower(btrim(p_team_subtype))) > 0
      )
    );
$$;

-- -----------------------------------------------------------------------------
-- 4) Public-safe viewport listing (anon + authenticated)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_discoverable_fan_teams_in_bounds(
  p_min_lat double precision,
  p_max_lat double precision,
  p_min_lon double precision,
  p_max_lon double precision,
  p_sport text DEFAULT NULL
)
RETURNS TABLE (
  team_id uuid,
  name text,
  sport text,
  sport_subtype text,
  logo_url text,
  logo_thumbnail_url text,
  color_hex text,
  looking_for_players boolean,
  member_count integer,
  location_precision text,
  place_name text,
  city text,
  region text,
  postal_code text,
  country_code text,
  latitude double precision,
  longitude double precision
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_min_lat double precision := p_min_lat;
  v_max_lat double precision := p_max_lat;
  v_min_lon double precision := p_min_lon;
  v_max_lon double precision := p_max_lon;
  v_sport text := nullif(btrim(coalesce(p_sport, '')), '');
BEGIN
  IF v_min_lat IS NULL OR v_max_lat IS NULL OR v_min_lon IS NULL OR v_max_lon IS NULL THEN
    RETURN;
  END IF;
  IF v_min_lat > v_max_lat OR v_min_lon > v_max_lon THEN
    RETURN;
  END IF;
  -- Fail closed on worldwide/continental spans (nearby map only).
  IF (v_max_lat - v_min_lat) > 8 OR (v_max_lon - v_min_lon) > 8 THEN
    RETURN;
  END IF;

  v_min_lat := greatest(-90, v_min_lat);
  v_max_lat := least(90, v_max_lat);
  v_min_lon := greatest(-180, v_min_lon);
  v_max_lon := least(180, v_max_lon);

  RETURN QUERY
  SELECT
    t.id,
    t.name,
    t.sport,
    t.sport_subtype,
    t.logo_url,
    t.logo_thumbnail_url,
    t.color_hex,
    t.looking_for_players,
    public.fan_team_active_player_count(t.id),
    t.discovery_location_precision,
    CASE
      WHEN t.discovery_location_precision = 'general_area' THEN NULL
      ELSE t.discovery_place_name
    END,
    t.discovery_city,
    t.discovery_region,
    CASE
      WHEN t.discovery_location_precision = 'general_area' THEN NULL
      ELSE t.discovery_postal_code
    END,
    t.discovery_country_code,
    t.discovery_latitude,
    t.discovery_longitude
  FROM public.fan_teams t
  WHERE t.is_active IS TRUE
    AND t.is_discoverable IS TRUE
    AND t.discovery_latitude IS NOT NULL
    AND t.discovery_longitude IS NOT NULL
    AND t.discovery_latitude BETWEEN v_min_lat AND v_max_lat
    AND t.discovery_longitude BETWEEN v_min_lon AND v_max_lon
    AND public.fan_team_discovery_sport_matches(t.sport, t.sport_subtype, v_sport)
  ORDER BY t.name
  LIMIT 200;
END;
$$;

REVOKE ALL ON FUNCTION public.list_discoverable_fan_teams_in_bounds(double precision, double precision, double precision, double precision, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_discoverable_fan_teams_in_bounds(double precision, double precision, double precision, double precision, text) TO anon;
GRANT EXECUTE ON FUNCTION public.list_discoverable_fan_teams_in_bounds(double precision, double precision, double precision, double precision, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_discoverable_fan_teams_in_bounds(double precision, double precision, double precision, double precision, text) TO service_role;

COMMENT ON FUNCTION public.list_discoverable_fan_teams_in_bounds(double precision, double precision, double precision, double precision, text) IS
  'Public-safe Discover Play → Places Team overlay. Viewport only. Never dumps fan_teams.';

-- -----------------------------------------------------------------------------
-- 5) Public summary (discoverable Teams only)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_public_fan_team_summary(p_team_id uuid)
RETURNS TABLE (
  team_id uuid,
  name text,
  sport text,
  sport_subtype text,
  logo_url text,
  logo_thumbnail_url text,
  color_hex text,
  looking_for_players boolean,
  member_count integer,
  location_precision text,
  place_name text,
  city text,
  region text,
  postal_code text,
  country_code text,
  latitude double precision,
  longitude double precision
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF p_team_id IS NULL THEN
    RAISE EXCEPTION 'Team not found' USING ERRCODE = 'P0002';
  END IF;

  RETURN QUERY
  SELECT
    t.id,
    t.name,
    t.sport,
    t.sport_subtype,
    t.logo_url,
    t.logo_thumbnail_url,
    t.color_hex,
    t.looking_for_players,
    public.fan_team_active_player_count(t.id),
    t.discovery_location_precision,
    CASE
      WHEN t.discovery_location_precision = 'general_area' THEN NULL
      ELSE t.discovery_place_name
    END,
    t.discovery_city,
    t.discovery_region,
    CASE
      WHEN t.discovery_location_precision = 'general_area' THEN NULL
      ELSE t.discovery_postal_code
    END,
    t.discovery_country_code,
    t.discovery_latitude,
    t.discovery_longitude
  FROM public.fan_teams t
  WHERE t.id = p_team_id
    AND t.is_active IS TRUE
    AND t.is_discoverable IS TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Team not found' USING ERRCODE = 'P0002';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.get_public_fan_team_summary(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_fan_team_summary(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_public_fan_team_summary(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_public_fan_team_summary(uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 6) Owner/editor read + write
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_fan_team_discovery(p_team_id uuid)
RETURNS TABLE (
  team_id uuid,
  is_discoverable boolean,
  looking_for_players boolean,
  sport_subtype text,
  location_precision text,
  place_name text,
  address text,
  city text,
  region text,
  postal_code text,
  country_code text,
  latitude double precision,
  longitude double precision
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := auth.uid();
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_team_id IS NULL THEN
    RAISE EXCEPTION 'Team not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT public.fan_team_viewer_can_access_team(p_team_id) THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    t.id,
    t.is_discoverable,
    t.looking_for_players,
    t.sport_subtype,
    t.discovery_location_precision,
    t.discovery_place_name,
    t.discovery_address,
    t.discovery_city,
    t.discovery_region,
    t.discovery_postal_code,
    t.discovery_country_code,
    t.discovery_latitude,
    t.discovery_longitude
  FROM public.fan_teams t
  WHERE t.id = p_team_id
    AND t.is_active IS TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_fan_team_discovery(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_fan_team_discovery(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_my_fan_team_discovery(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_fan_team_discovery(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.update_fan_team_discovery(
  p_team_id uuid,
  p_is_discoverable boolean,
  p_looking_for_players boolean,
  p_sport_subtype text DEFAULT NULL,
  p_location_precision text DEFAULT 'specific',
  p_place_name text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_region text DEFAULT NULL,
  p_postal_code text DEFAULT NULL,
  p_country_code text DEFAULT NULL,
  p_latitude double precision DEFAULT NULL,
  p_longitude double precision DEFAULT NULL,
  p_clear_location boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := auth.uid();
  v_discoverable boolean := coalesce(p_is_discoverable, false);
  v_looking boolean := coalesce(p_looking_for_players, false);
  v_clear boolean := coalesce(p_clear_location, false);
  v_precision text := lower(btrim(coalesce(p_location_precision, 'specific')));
  v_subtype text := nullif(btrim(coalesce(p_sport_subtype, '')), '');
  v_country text := nullif(upper(btrim(coalesce(p_country_code, ''))), '');
  v_place text := nullif(btrim(coalesce(p_place_name, '')), '');
  v_address text := nullif(btrim(coalesce(p_address, '')), '');
  v_city text := nullif(btrim(coalesce(p_city, '')), '');
  v_region text := nullif(btrim(coalesce(p_region, '')), '');
  v_postal text := nullif(btrim(coalesce(p_postal_code, '')), '');
  v_lat double precision := p_latitude;
  v_lng double precision := p_longitude;
  v_location_absent boolean;
  v_old_place text;
  v_old_address text;
  v_old_city text;
  v_old_region text;
  v_old_postal text;
  v_old_country text;
  v_old_lat double precision;
  v_old_lng double precision;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_team_id IS NULL THEN
    RAISE EXCEPTION 'Team not found' USING ERRCODE = 'P0002';
  END IF;

  PERFORM public.assert_rpc_rate_limit('update_fan_team_discovery', 60, 3600);

  IF NOT public.fan_team_viewer_has_permission(p_team_id, 'edit_team_information') THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.fan_teams t
    WHERE t.id = p_team_id AND t.is_active IS TRUE
  ) THEN
    RAISE EXCEPTION 'Team not found' USING ERRCODE = 'P0002';
  END IF;

  SELECT
    t.discovery_place_name,
    t.discovery_address,
    t.discovery_city,
    t.discovery_region,
    t.discovery_postal_code,
    t.discovery_country_code,
    t.discovery_latitude,
    t.discovery_longitude
  INTO
    v_old_place,
    v_old_address,
    v_old_city,
    v_old_region,
    v_old_postal,
    v_old_country,
    v_old_lat,
    v_old_lng
  FROM public.fan_teams t
  WHERE t.id = p_team_id AND t.is_active IS TRUE;

  IF v_precision NOT IN ('specific', 'general_area') THEN
    v_precision := 'specific';
  END IF;

  v_location_absent :=
    v_place IS NULL AND v_address IS NULL AND v_city IS NULL AND v_region IS NULL
    AND v_postal IS NULL AND v_country IS NULL
    AND v_lat IS NULL AND v_lng IS NULL;

  -- Explicit clear is the only path that erases a saved Team Location.
  IF v_clear AND v_discoverable THEN
    RAISE EXCEPTION 'Choose a Team location before showing this Team on Discover.'
      USING ERRCODE = '22023';
  END IF;

  IF v_clear AND NOT v_discoverable THEN
    UPDATE public.fan_teams t
    SET
      is_discoverable = false,
      looking_for_players = v_looking,
      sport_subtype = v_subtype,
      discovery_location_precision = v_precision,
      discovery_place_name = NULL,
      discovery_address = NULL,
      discovery_city = NULL,
      discovery_region = NULL,
      discovery_postal_code = NULL,
      discovery_country_code = NULL,
      discovery_latitude = NULL,
      discovery_longitude = NULL,
      updated_at = now()
    WHERE t.id = p_team_id;
    RETURN;
  END IF;

  -- Preserve stored discovery location unless p_clear_location is explicitly true.
  -- Omitted/null location arguments while Discover is OFF must not wipe a
  -- previously configured Team Location.
  IF v_location_absent THEN
    IF v_discoverable
       AND NOT public.fan_team_discovery_location_is_valid(
         v_old_lat, v_old_lng, v_old_country, v_old_city, v_old_place
       ) THEN
      RAISE EXCEPTION 'Choose a Team location before showing this Team on Discover.'
        USING ERRCODE = '22023';
    END IF;
    UPDATE public.fan_teams t
    SET
      is_discoverable = v_discoverable,
      looking_for_players = v_looking,
      sport_subtype = v_subtype,
      updated_at = now()
    WHERE t.id = p_team_id;
    RETURN;
  END IF;

  -- Patch unspecified location fields from the stored row (supplied ?? old).
  v_place := coalesce(v_place, v_old_place);
  v_address := coalesce(v_address, v_old_address);
  v_city := coalesce(v_city, v_old_city);
  v_region := coalesce(v_region, v_old_region);
  v_postal := coalesce(v_postal, v_old_postal);
  v_country := coalesce(v_country, v_old_country);
  v_lat := coalesce(v_lat, v_old_lat);
  v_lng := coalesce(v_lng, v_old_lng);

  -- Intentional General Area privacy transform, not an accidental NULL.
  IF v_precision = 'general_area' THEN
    v_address := NULL;
    v_postal := NULL;
  END IF;

  -- Validate the final merged location, not raw incoming arguments.
  IF v_discoverable
     AND NOT public.fan_team_discovery_location_is_valid(
       v_lat, v_lng, v_country, v_city, v_place
     ) THEN
    RAISE EXCEPTION 'Choose a Team location before showing this Team on Discover.'
      USING ERRCODE = '22023';
  END IF;

  UPDATE public.fan_teams t
  SET
    is_discoverable = v_discoverable,
    looking_for_players = v_looking,
    sport_subtype = v_subtype,
    discovery_location_precision = v_precision,
    discovery_place_name = v_place,
    discovery_address = v_address,
    discovery_city = v_city,
    discovery_region = v_region,
    discovery_postal_code = v_postal,
    discovery_country_code = v_country,
    discovery_latitude = v_lat,
    discovery_longitude = v_lng,
    updated_at = now()
  WHERE t.id = p_team_id;
END;
$$;

REVOKE ALL ON FUNCTION public.update_fan_team_discovery(
  uuid, boolean, boolean, text, text, text, text, text, text, text, text, double precision, double precision, boolean
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_fan_team_discovery(
  uuid, boolean, boolean, text, text, text, text, text, text, text, text, double precision, double precision, boolean
) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_fan_team_discovery(
  uuid, boolean, boolean, text, text, text, text, text, text, text, text, double precision, double precision, boolean
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_fan_team_discovery(
  uuid, boolean, boolean, text, text, text, text, text, text, text, text, double precision, double precision, boolean
) TO service_role;

DO $$
DECLARE
  v_src text;
  v_region text;
  v_buckets text[];
  v_rpc_src text;
  v_default text;
  -- CANONICAL_RL_ARRAY_INIT_PATTERN (do not fork)
  v_init_pattern text :=
    'v_allowed_buckets[[:space:]]+text[[:space:]]*\[\][[:space:]]*:=[[:space:]]*ARRAY\[(?:.|\n)*?\][[:space:]]*(::[[:space:]]*text\[\])?[[:space:]]*;';
  -- CANONICAL_RL_ARRAY_CAPTURE_PATTERN (do not fork)
  v_capture_pattern text :=
    '(v_allowed_buckets[[:space:]]+text[[:space:]]*\[\][[:space:]]*:=[[:space:]]*ARRAY\[)((?:.|\n)*?)(\][[:space:]]*(::[[:space:]]*text\[\])?[[:space:]]*;)';
  v_init_count int;
  v_matches text[];
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'fan_teams' AND column_name = 'is_discoverable'
  ) THEN
    RAISE EXCEPTION '20261000 is_discoverable missing';
  END IF;
  SELECT c.column_default INTO v_default
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'fan_teams'
    AND c.column_name = 'is_discoverable';
  IF v_default IS NULL OR position('false' IN lower(v_default)) = 0 THEN
    RAISE EXCEPTION '20261000 is_discoverable default is not false';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'fan_teams' AND column_name = 'looking_for_players'
  ) THEN
    RAISE EXCEPTION '20261000 looking_for_players missing';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'fan_teams' AND column_name = 'discovery_latitude'
  ) THEN
    RAISE EXCEPTION '20261000 discovery_latitude missing';
  END IF;
  IF to_regprocedure(
       'public.list_discoverable_fan_teams_in_bounds(double precision, double precision, double precision, double precision, text)'
     ) IS NULL THEN
    RAISE EXCEPTION '20261000 list_discoverable_fan_teams_in_bounds missing';
  END IF;
  IF to_regprocedure('public.get_public_fan_team_summary(uuid)') IS NULL THEN
    RAISE EXCEPTION '20261000 get_public_fan_team_summary missing';
  END IF;
  IF to_regprocedure('public.get_my_fan_team_discovery(uuid)') IS NULL THEN
    RAISE EXCEPTION '20261000 get_my_fan_team_discovery missing';
  END IF;
  IF to_regprocedure('public.update_fan_team_discovery(uuid, boolean, boolean, text, text, text, text, text, text, text, text, double precision, double precision, boolean)') IS NULL THEN
    RAISE EXCEPTION '20261000 update_fan_team_discovery missing';
  END IF;

  SELECT p.prosrc INTO v_rpc_src
  FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.update_fan_team_discovery(uuid, boolean, boolean, text, text, text, text, text, text, text, text, double precision, double precision, boolean)'::regprocedure;
  IF v_rpc_src IS NULL
     OR position('assert_rpc_rate_limit(''update_fan_team_discovery''' IN v_rpc_src) = 0 THEN
    RAISE EXCEPTION '20261000 update_fan_team_discovery must call assert_rpc_rate_limit(''update_fan_team_discovery'')';
  END IF;
  IF position('Preserve stored discovery location unless p_clear_location is explicitly true' IN v_rpc_src) = 0 THEN
    RAISE EXCEPTION '20261000 update_fan_team_discovery must preserve location unless p_clear_location is true';
  END IF;
  IF position('v_location_absent' IN v_rpc_src) = 0 THEN
    RAISE EXCEPTION '20261000 update_fan_team_discovery missing omitted-location preserve path';
  END IF;
  IF position('coalesce(v_place, v_old_place)' IN v_rpc_src) = 0
     OR position('coalesce(v_lat, v_old_lat)' IN v_rpc_src) = 0 THEN
    RAISE EXCEPTION '20261000 update_fan_team_discovery missing non-destructive location patch';
  END IF;
  IF position('final merged location' IN v_rpc_src) = 0 THEN
    RAISE EXCEPTION '20261000 update_fan_team_discovery must validate the final merged location';
  END IF;

  IF NOT has_function_privilege(
       'anon',
       'public.list_discoverable_fan_teams_in_bounds(double precision, double precision, double precision, double precision, text)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated',
       'public.list_discoverable_fan_teams_in_bounds(double precision, double precision, double precision, double precision, text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION '20261000 list_discoverable_fan_teams_in_bounds missing anon/authenticated EXECUTE';
  END IF;
  IF NOT has_function_privilege(
       'anon',
       'public.get_public_fan_team_summary(uuid)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated',
       'public.get_public_fan_team_summary(uuid)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION '20261000 get_public_fan_team_summary missing anon/authenticated EXECUTE';
  END IF;
  IF has_function_privilege(
       'anon',
       'public.get_my_fan_team_discovery(uuid)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION '20261000 get_my_fan_team_discovery must not be executable by anon';
  END IF;
  IF NOT has_function_privilege(
       'authenticated',
       'public.get_my_fan_team_discovery(uuid)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION '20261000 authenticated must EXECUTE get_my_fan_team_discovery';
  END IF;
  IF has_function_privilege(
       'anon',
       'public.update_fan_team_discovery(uuid, boolean, boolean, text, text, text, text, text, text, text, text, double precision, double precision, boolean)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION '20261000 update_fan_team_discovery must not be executable by anon';
  END IF;
  IF NOT has_function_privilege(
       'authenticated',
       'public.update_fan_team_discovery(uuid, boolean, boolean, text, text, text, text, text, text, text, text, double precision, double precision, boolean)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION '20261000 authenticated must EXECUTE update_fan_team_discovery';
  END IF;

  SELECT p.prosrc INTO v_src
  FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.assert_rpc_rate_limit(text,int,int)'::regprocedure;
  SELECT count(*)::int
    INTO v_init_count
  FROM regexp_matches(v_src, v_init_pattern, 'g');
  IF v_init_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION
      '20261000 expected exactly one v_allowed_buckets initializer, found %',
      coalesce(v_init_count, 0);
  END IF;
  v_matches := regexp_match(v_src, v_capture_pattern);
  v_region := v_matches[2];
  IF v_region IS NULL OR btrim(v_region) = '' THEN
    RAISE EXCEPTION '20261000 assert_rpc_rate_limit ARRAY allowlist unreadable after apply';
  END IF;
  SELECT coalesce(
    (SELECT array_agg(bucket ORDER BY bucket)
     FROM (
       SELECT DISTINCT m[1] AS bucket
       FROM regexp_matches(v_region, '''([a-z][a-z0-9_]*)''', 'g') AS m
     ) parsed),
    ARRAY[]::text[]
  )
    INTO v_buckets;
  IF NOT ('update_fan_team_discovery' = ANY (v_buckets)) THEN
    RAISE EXCEPTION '20261000 assert_rpc_rate_limit ARRAY missing update_fan_team_discovery';
  END IF;
END $$;

COMMIT;
