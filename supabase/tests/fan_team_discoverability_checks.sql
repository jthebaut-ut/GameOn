-- Local catalog checks for 20261000 Team discovery.
-- Source/catalog only. Do not execute against production from the agent.
--
-- Location contract (enforced by update_fan_team_discovery prosrc):
--   1. Hidden Team + saved location, Discover OFF save → location preserved
--   2. Discover ON + valid location → succeeds (server validates)
--   3. Discover ON + no stored/supplied location → fails
--   4. Discover OFF + p_clear_location=false → location preserved
--   4b. Partial location payload + p_clear_location=false → unspecified fields preserved
--   5. Discover OFF + p_clear_location=true → location cleared
--   6. Looking for Players ON + Discover OFF → still hidden; recruiting persists
--   7. General Area: address/postal NULL; city/region/country + lat/lng retained
--   8. Existing Teams default is_discoverable false
DO $$
DECLARE
  v_src text;
  v_region text;
  v_buckets text[];
  v_need text;
  v_upd text;
  v_default text;
  v_preserve text;
  v_clear text;
  v_init_count int;
BEGIN
  IF to_regclass('public.fan_teams') IS NULL THEN
    RAISE NOTICE 'SKIP 20261000 checks: fan_teams missing';
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'fan_teams' AND column_name = 'is_discoverable'
  ) THEN
    RAISE EXCEPTION 'FAIL: is_discoverable missing';
  END IF;

  -- 8. Existing Teams default discoverable false
  SELECT c.column_default INTO v_default
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'fan_teams'
    AND c.column_name = 'is_discoverable';
  IF v_default IS NULL OR position('false' IN lower(v_default)) = 0 THEN
    RAISE EXCEPTION 'FAIL: is_discoverable default is not false';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'fan_teams' AND column_name = 'looking_for_players'
  ) THEN
    RAISE EXCEPTION 'FAIL: looking_for_players missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'fan_teams_discoverable_requires_location_ck'
  ) THEN
    RAISE EXCEPTION 'FAIL: discoverable location CHECK missing';
  END IF;

  IF to_regprocedure(
       'public.list_discoverable_fan_teams_in_bounds(double precision, double precision, double precision, double precision, text)'
     ) IS NULL THEN
    RAISE EXCEPTION 'FAIL: list_discoverable_fan_teams_in_bounds missing';
  END IF;

  IF to_regprocedure('public.fan_team_discovery_location_is_valid(double precision, double precision, text, text, text)') IS NOT NULL THEN
    IF NOT public.fan_team_discovery_location_is_valid(40.5, -111.8, 'US', 'Lehi', NULL) THEN
      RAISE EXCEPTION 'FAIL: valid US city location rejected';
    END IF;
    IF public.fan_team_discovery_location_is_valid(NULL, -111.8, 'US', 'Lehi', NULL) THEN
      RAISE EXCEPTION 'FAIL: missing lat accepted';
    END IF;
    IF public.fan_team_discovery_location_is_valid(0, 0, 'US', 'Lehi', NULL) THEN
      RAISE EXCEPTION 'FAIL: 0,0 accepted';
    END IF;
  END IF;
  IF to_regprocedure('public.fan_team_discovery_sport_matches(text, text, text)') IS NOT NULL THEN
    IF public.fan_team_discovery_sport_matches('Cycling', 'mountain_biking', 'mountain_biking') IS NOT TRUE THEN
      RAISE EXCEPTION 'FAIL: subtype sport match';
    END IF;
    IF public.fan_team_discovery_sport_matches('Soccer', NULL, 'All') IS NOT TRUE THEN
      RAISE EXCEPTION 'FAIL: All sports should match';
    END IF;
  END IF;

  IF to_regprocedure(
       'public.update_fan_team_discovery(uuid, boolean, boolean, text, text, text, text, text, text, text, text, double precision, double precision, boolean)'
     ) IS NOT NULL THEN
    SELECT p.prosrc INTO v_upd
    FROM pg_catalog.pg_proc p
    WHERE p.oid = 'public.update_fan_team_discovery(uuid, boolean, boolean, text, text, text, text, text, text, text, text, double precision, double precision, boolean)'::regprocedure;

    -- 1 + 4. Discover OFF / omitted location preserves stored fields
    IF position('Preserve stored discovery location unless p_clear_location is explicitly true' IN v_upd) = 0
       OR position('v_location_absent' IN v_upd) = 0 THEN
      RAISE EXCEPTION 'FAIL: location preserve path missing (hidden Team + Discover OFF must keep saved location)';
    END IF;
    v_preserve := split_part(split_part(v_upd, 'IF v_location_absent THEN', 2), 'RETURN;', 1);
    IF position('discovery_place_name = NULL' IN v_preserve) > 0
       OR position('discovery_latitude = NULL' IN v_preserve) > 0 THEN
      RAISE EXCEPTION 'FAIL: omitted-location path must not NULL stored location';
    END IF;

    -- Partial payload with p_clear_location=false patches unspecified fields
    IF position('coalesce(v_place, v_old_place)' IN v_upd) = 0
       OR position('coalesce(v_city, v_old_city)' IN v_upd) = 0
       OR position('coalesce(v_lat, v_old_lat)' IN v_upd) = 0
       OR position('coalesce(v_lng, v_old_lng)' IN v_upd) = 0 THEN
      RAISE EXCEPTION 'FAIL: partial location update must COALESCE unspecified fields from stored row';
    END IF;

    -- 2 + 3. Discover ON validates the final merged location
    IF position('Choose a Team location before showing this Team on Discover.' IN v_upd) = 0 THEN
      RAISE EXCEPTION 'FAIL: Discover ON location validation missing';
    END IF;
    IF position('final merged location' IN v_upd) = 0
       OR position('fan_team_discovery_location_is_valid' IN v_upd) = 0 THEN
      RAISE EXCEPTION 'FAIL: Discover ON must validate the final merged location';
    END IF;

    -- 5. Explicit clear
    IF position('IF v_clear AND NOT v_discoverable THEN' IN v_upd) = 0 THEN
      RAISE EXCEPTION 'FAIL: p_clear_location=true clear branch missing';
    END IF;
    v_clear := split_part(split_part(v_upd, 'IF v_clear AND NOT v_discoverable THEN', 2), 'RETURN;', 1);
    IF position('discovery_place_name = NULL' IN v_clear) = 0
       OR position('discovery_latitude = NULL' IN v_clear) = 0
       OR position('discovery_longitude = NULL' IN v_clear) = 0 THEN
      RAISE EXCEPTION 'FAIL: p_clear_location=true must clear stored location';
    END IF;

    -- 6. Looking for Players independent of Discover
    IF position('looking_for_players = v_looking' IN v_upd) = 0 THEN
      RAISE EXCEPTION 'FAIL: looking_for_players not persisted independently';
    END IF;

    -- 7. General Area privacy
    IF position('v_precision = ''general_area''' IN v_upd) = 0
       OR position('v_address := NULL;' IN v_upd) = 0
       OR position('v_postal := NULL;' IN v_upd) = 0 THEN
      RAISE EXCEPTION 'FAIL: general_area address/postal NULL contract changed';
    END IF;
  END IF;

  IF to_regprocedure('public.assert_rpc_rate_limit(text,int,int)') IS NOT NULL THEN
    SELECT p.prosrc INTO v_src
    FROM pg_catalog.pg_proc p
    WHERE p.oid = 'public.assert_rpc_rate_limit(text,int,int)'::regprocedure;
    -- CANONICAL_RL_ARRAY_INIT_PATTERN (do not fork)
    -- CANONICAL_RL_ARRAY_CAPTURE_PATTERN (do not fork)
    SELECT count(*)::int
      INTO v_init_count
    FROM regexp_matches(
      v_src,
      'v_allowed_buckets[[:space:]]+text[[:space:]]*\[\][[:space:]]*:=[[:space:]]*ARRAY\[(?:.|\n)*?\][[:space:]]*(::[[:space:]]*text\[\])?[[:space:]]*;',
      'g'
    );
    IF v_init_count IS DISTINCT FROM 1 THEN
      RAISE EXCEPTION 'FAIL: expected exactly one v_allowed_buckets initializer, found %', coalesce(v_init_count, 0);
    END IF;
    v_region := (regexp_match(
      v_src,
      '(v_allowed_buckets[[:space:]]+text[[:space:]]*\[\][[:space:]]*:=[[:space:]]*ARRAY\[)((?:.|\n)*?)(\][[:space:]]*(::[[:space:]]*text\[\])?[[:space:]]*;)'
    ))[2];
    IF v_region IS NULL OR btrim(v_region) = '' THEN
      RAISE EXCEPTION 'FAIL: assert_rpc_rate_limit ARRAY allowlist unreadable';
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
    IF NOT ('update_fan_team_discovery' = ANY (coalesce(v_buckets, ARRAY[]::text[]))) THEN
      RAISE EXCEPTION 'FAIL: ARRAY missing update_fan_team_discovery';
    END IF;
    FOREACH v_need IN ARRAY ARRAY[
      'set_my_fan_team_is_player',
      'set_fan_team_member_permissions',
      'set_fan_team_membership_role',
      'create_fan_team',
      'send_direct_message'
    ]
    LOOP
      IF NOT (v_need = ANY (v_buckets)) THEN
        RAISE EXCEPTION 'FAIL: ARRAY missing required bucket %', v_need;
      END IF;
    END LOOP;
  END IF;

  RAISE NOTICE 'PASS 20261000 fan team discoverability checks';
END $$;
