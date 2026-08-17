-- Static / definition checks for 20260972 list_my_fan_teams managed-player access.
-- Run against a DB after applying 20260972. Does NOT apply the migration.

DO $$
DECLARE
  v_def text;
BEGIN
  IF to_regprocedure('public.list_my_fan_teams()') IS NULL THEN
    RAISE EXCEPTION 'FAIL: list_my_fan_teams missing';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.list_my_fan_teams()')) INTO v_def;

  IF position('access_via' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: list_my_fan_teams missing access_via';
  END IF;
  IF position('via_managed_player_names' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: list_my_fan_teams missing via_managed_player_names';
  END IF;
  IF position('managed_player' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: list_my_fan_teams missing managed_player access path';
  END IF;
  IF position('fan_managed_player_guardians' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: list_my_fan_teams missing guardian join';
  END IF;
  IF position('SET search_path TO ''pg_catalog'', ''public''' IN v_def) = 0
     AND position('SET search_path = pg_catalog, public' IN v_def) = 0
     AND position('search_path=pg_catalog, public' IN lower(v_def)) = 0 THEN
    -- pg_get_functiondef may normalize quoting; accept either form containing both schemas.
    IF position('pg_catalog' IN v_def) = 0 OR position('public' IN v_def) = 0 THEN
      RAISE EXCEPTION 'FAIL: list_my_fan_teams search_path must include pg_catalog, public';
    END IF;
  END IF;
  IF position('CASCADE' IN upper(v_def)) > 0 THEN
    RAISE EXCEPTION 'FAIL: list_my_fan_teams definition unexpectedly references CASCADE';
  END IF;

  RAISE NOTICE 'PASS: list_my_fan_teams managed-player access definition checks';
END $$;
