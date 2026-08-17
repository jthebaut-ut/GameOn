-- Structural checks for 20260966 (My Teams member avatar previews).
-- Run manually after applying the migration.

DO $$
DECLARE
  v_def text;
BEGIN
  IF to_regprocedure('public.list_my_fan_teams()') IS NULL THEN
    RAISE EXCEPTION 'FAIL: list_my_fan_teams missing';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.list_my_fan_teams()')) INTO v_def;
  IF v_def NOT ILIKE '%member_avatar_previews%' THEN
    RAISE EXCEPTION 'FAIL: list_my_fan_teams missing member_avatar_previews';
  END IF;
  IF v_def NOT ILIKE '%managed_player_id%' THEN
    RAISE EXCEPTION 'FAIL: list_my_fan_teams previews missing managed-player projection';
  END IF;
  IF v_def ILIKE '%birth_year%' THEN
    RAISE EXCEPTION 'FAIL: list_my_fan_teams must not expose birth_year';
  END IF;
  IF v_def ILIKE '%guardian_user_id%' THEN
    RAISE EXCEPTION 'FAIL: list_my_fan_teams must not expose guardian_user_id';
  END IF;

  RAISE NOTICE 'PASS: list_my_fan_teams member avatar preview checks';
END $$;
