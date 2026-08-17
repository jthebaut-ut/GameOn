-- =============================================================================
-- fan_team_member_preferred_position_checks.sql
-- Manual / staging verification for 20260953 preferred_position_code.
-- Run AFTER applying 20260952 + 20260953. Do NOT apply as a migration.
-- =============================================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'fan_team_members'
      AND column_name = 'preferred_position_code'
  ) THEN
    RAISE EXCEPTION 'FAIL: preferred_position_code column missing';
  END IF;

  IF to_regprocedure('public.set_fan_team_member_preferred_position(uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: set_fan_team_member_preferred_position missing';
  END IF;

  -- list_fan_team_members OUT includes preferred_position_code
  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'list_fan_team_members'
      AND pg_get_function_result(p.oid) ILIKE '%preferred_position_code%'
  ) THEN
    RAISE EXCEPTION 'FAIL: list_fan_team_members missing preferred_position_code';
  END IF;

  -- Reuse sport validation helpers
  IF NOT public.fan_team_event_position_code_is_valid('Soccer', 'CB') THEN
    RAISE EXCEPTION 'FAIL: Soccer+CB should validate';
  END IF;
  IF public.fan_team_event_position_code_is_valid('Soccer', 'QB') THEN
    RAISE EXCEPTION 'FAIL: Soccer+QB should reject';
  END IF;

  -- Direct writes blocked
  IF has_table_privilege('authenticated', 'public.fan_team_members', 'UPDATE') THEN
    RAISE EXCEPTION 'FAIL: authenticated has UPDATE on fan_team_members';
  END IF;
  IF has_table_privilege('authenticated', 'public.fan_team_members', 'INSERT') THEN
    RAISE EXCEPTION 'FAIL: authenticated has INSERT on fan_team_members';
  END IF;

  -- update_fan_team_identity clears incompatible preferred positions
  IF position(
    'preferred_position_code = NULL',
    pg_get_functiondef('public.update_fan_team_identity(uuid,text,text,text,text,text,text,boolean)'::regprocedure)
  ) = 0 THEN
    RAISE EXCEPTION 'FAIL: update_fan_team_identity missing preferred_position clear on sport change';
  END IF;

  RAISE NOTICE 'PASS: preferred_position schema + RPC + write policy markers';
END $$;
