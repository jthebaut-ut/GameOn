-- =============================================================================
-- fan_team_event_lineup_position_checks.sql
-- Manual / staging verification for 20260952_0001 position + write policy.
-- Run AFTER applying 20260952_0001. Do NOT apply as a migration.
-- =============================================================================

-- A–M: pure position policy helpers (no table mutation)
DO $$
BEGIN
  -- A Soccer + GK
  IF NOT public.fan_team_event_position_code_is_valid('Soccer', 'GK') THEN
    RAISE EXCEPTION 'FAIL A: Soccer + GK should accept';
  END IF;
  -- B Soccer + CB
  IF NOT public.fan_team_event_position_code_is_valid('Soccer', 'CB') THEN
    RAISE EXCEPTION 'FAIL B: Soccer + CB should accept';
  END IF;
  -- C Soccer + QB
  IF public.fan_team_event_position_code_is_valid('Soccer', 'QB') THEN
    RAISE EXCEPTION 'FAIL C: Soccer + QB should reject';
  END IF;
  -- D Basketball + PG
  IF NOT public.fan_team_event_position_code_is_valid('NBA', 'PG') THEN
    RAISE EXCEPTION 'FAIL D: NBA/Basketball + PG should accept';
  END IF;
  IF NOT public.fan_team_event_position_code_is_valid('Basketball', 'PG') THEN
    RAISE EXCEPTION 'FAIL D: Basketball alias + PG should accept';
  END IF;
  -- E Basketball + GK
  IF public.fan_team_event_position_code_is_valid('NBA', 'GK') THEN
    RAISE EXCEPTION 'FAIL E: Basketball + GK should reject';
  END IF;
  -- F Baseball + SS
  IF NOT public.fan_team_event_position_code_is_valid('Baseball', 'SS') THEN
    RAISE EXCEPTION 'FAIL F: Baseball + SS should accept';
  END IF;
  IF NOT public.fan_team_event_position_code_is_valid('Softball', 'SS') THEN
    RAISE EXCEPTION 'FAIL F: Softball + SS should accept';
  END IF;
  -- G Hockey + G
  IF NOT public.fan_team_event_position_code_is_valid('NHL', 'G') THEN
    RAISE EXCEPTION 'FAIL G: NHL/Hockey + G should accept';
  END IF;
  -- H Volleyball + L
  IF NOT public.fan_team_event_position_code_is_valid('Volleyball', 'L') THEN
    RAISE EXCEPTION 'FAIL H: Volleyball + L should accept';
  END IF;
  -- I unsupported + NULL
  IF NOT public.fan_team_event_position_code_is_valid('Golf', NULL) THEN
    RAISE EXCEPTION 'FAIL I: unsupported + NULL should accept';
  END IF;
  IF NOT public.fan_team_event_position_code_is_valid('Tennis', '') THEN
    RAISE EXCEPTION 'FAIL I: unsupported + empty should accept';
  END IF;
  -- J unsupported + arbitrary
  IF public.fan_team_event_position_code_is_valid('Golf', 'GK') THEN
    RAISE EXCEPTION 'FAIL J: unsupported + GK should reject';
  END IF;
  IF public.fan_team_event_position_code_is_valid('Golf', 'HELLO') THEN
    RAISE EXCEPTION 'FAIL J: unsupported + HELLO should reject';
  END IF;
  -- K lowercase normalized
  IF public.fan_team_event_normalize_position_code('gk') IS DISTINCT FROM 'GK' THEN
    RAISE EXCEPTION 'FAIL K: gk → GK';
  END IF;
  IF NOT public.fan_team_event_position_code_is_valid('Soccer', 'gk') THEN
    RAISE EXCEPTION 'FAIL K: Soccer + gk should accept after normalize';
  END IF;
  -- L whitespace normalized
  IF public.fan_team_event_normalize_position_code(' cb ') IS DISTINCT FROM 'CB' THEN
    RAISE EXCEPTION 'FAIL L: '' cb '' → CB';
  END IF;
  IF NOT public.fan_team_event_position_code_is_valid('Soccer', ' cb ') THEN
    RAISE EXCEPTION 'FAIL L: Soccer + spaced cb should accept';
  END IF;
  -- M invalid code rejected
  IF public.fan_team_event_position_code_is_valid('Soccer', 'HELLO') THEN
    RAISE EXCEPTION 'FAIL M: Soccer + HELLO should reject';
  END IF;
  IF public.fan_team_event_position_code_is_valid('Soccer', 'GOALIE123') THEN
    RAISE EXCEPTION 'FAIL M: Soccer + GOALIE123 should reject';
  END IF;

  -- Formation support: soccer yes, others no
  IF NOT public.fan_team_event_sport_supports_formation('Soccer') THEN
    RAISE EXCEPTION 'FAIL formation: Soccer should support formation';
  END IF;
  IF public.fan_team_event_sport_supports_formation('NBA') THEN
    RAISE EXCEPTION 'FAIL formation: NBA should not support formation';
  END IF;

  -- Football aliases
  IF public.fan_team_event_position_family('NFL') IS DISTINCT FROM 'american_football' THEN
    RAISE EXCEPTION 'FAIL family: NFL → american_football';
  END IF;
  IF NOT public.fan_team_event_position_code_is_valid('NFL', 'QB') THEN
    RAISE EXCEPTION 'FAIL family: NFL + QB should accept';
  END IF;

  RAISE NOTICE 'PASS A–M: position / formation policy helpers';
END $$;

-- N: direct write bypass blocked for authenticated
DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.fan_team_event_lineups', 'INSERT') THEN
    RAISE EXCEPTION 'FAIL N: authenticated has INSERT on fan_team_event_lineups';
  END IF;
  IF has_table_privilege('authenticated', 'public.fan_team_event_lineups', 'UPDATE') THEN
    RAISE EXCEPTION 'FAIL N: authenticated has UPDATE on fan_team_event_lineups';
  END IF;
  IF has_table_privilege('authenticated', 'public.fan_team_event_lineups', 'DELETE') THEN
    RAISE EXCEPTION 'FAIL N: authenticated has DELETE on fan_team_event_lineups';
  END IF;
  IF has_table_privilege('authenticated', 'public.fan_team_event_lineup_members', 'INSERT') THEN
    RAISE EXCEPTION 'FAIL N: authenticated has INSERT on fan_team_event_lineup_members';
  END IF;
  IF has_table_privilege('authenticated', 'public.fan_team_event_lineup_members', 'UPDATE') THEN
    RAISE EXCEPTION 'FAIL N: authenticated has UPDATE on fan_team_event_lineup_members';
  END IF;
  IF has_table_privilege('authenticated', 'public.fan_team_event_lineup_members', 'DELETE') THEN
    RAISE EXCEPTION 'FAIL N: authenticated has DELETE on fan_team_event_lineup_members';
  END IF;
  IF NOT has_table_privilege('authenticated', 'public.fan_team_event_lineups', 'SELECT') THEN
    RAISE EXCEPTION 'FAIL N: authenticated missing SELECT on fan_team_event_lineups';
  END IF;
  IF NOT has_table_privilege('authenticated', 'public.fan_team_event_lineup_members', 'SELECT') THEN
    RAISE EXCEPTION 'FAIL N: authenticated missing SELECT on fan_team_event_lineup_members';
  END IF;
  RAISE NOTICE 'PASS N: authenticated SELECT-only; writes revoked';
END $$;

-- O/P: document published_at / published_by last-publish semantics in function source
DO $$
DECLARE
  v_src text;
BEGIN
  SELECT pg_get_functiondef('public.save_fan_team_event_lineup(uuid,uuid,text,text,jsonb)'::regprocedure)
  INTO v_src;
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'FAIL O/P: save_fan_team_event_lineup missing';
  END IF;
  -- Must refresh publish metadata (not coalesce first-publish).
  IF position('WHEN EXCLUDED.status = ''published'' THEN now()' IN v_src) = 0
     AND position('WHEN EXCLUDED.status = ''published'' THEN now()' IN replace(v_src, ' ', '')) = 0 THEN
    -- tolerate formatting; require absence of first-publish coalesce pattern
    NULL;
  END IF;
  IF position('coalesce(public.fan_team_event_lineups.published_at' IN v_src) > 0 THEN
    RAISE EXCEPTION 'FAIL O: save still coalesces first published_at';
  END IF;
  IF position('coalesce(public.fan_team_event_lineups.published_by' IN v_src) > 0 THEN
    RAISE EXCEPTION 'FAIL P: save still coalesces first published_by';
  END IF;
  IF position('Invalid position for this sport.' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL: save missing Invalid position exception';
  END IF;
  IF position('Duplicate lineup player.' IN v_src) = 0 THEN
    RAISE EXCEPTION 'FAIL Q: save missing Duplicate lineup player exception';
  END IF;
  RAISE NOTICE 'PASS O/P/Q markers: last-publish + position + duplicate guards in save RPC';
END $$;

-- Unique constraint still present
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.fan_team_event_lineup_members'::regclass
      AND conname = 'fan_team_event_lineup_members_unique'
  ) THEN
    RAISE EXCEPTION 'FAIL Q: missing unique (lineup_id, user_id)';
  END IF;
  RAISE NOTICE 'PASS Q: unique lineup member constraint present';
END $$;

-- Status CHECKs
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.fan_team_event_lineups'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%draft%published%'
  ) THEN
    RAISE EXCEPTION 'FAIL: lineup status CHECK missing';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.fan_team_event_lineup_members'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%starting%bench%'
  ) THEN
    RAISE EXCEPTION 'FAIL: member lineup_status CHECK missing';
  END IF;
  RAISE NOTICE 'PASS: draft/published and starting/bench CHECKs present';
END $$;
