-- Sanity checks for 20260981_0001 (run after applying the migration).
DO $$
BEGIN
  IF to_regclass('public.fan_team_announcement_user_state') IS NULL THEN
    RAISE EXCEPTION 'fan_team_announcement_user_state missing — apply 20260981_0001';
  END IF;

  IF to_regprocedure('public.list_my_cleared_fan_team_announcement_ids(uuid)') IS NULL THEN
    RAISE EXCEPTION 'list_my_cleared_fan_team_announcement_ids missing';
  END IF;

  IF to_regprocedure('public.clear_fan_team_announcement_for_viewer(uuid)') IS NULL THEN
    RAISE EXCEPTION 'clear_fan_team_announcement_for_viewer missing';
  END IF;

  IF to_regprocedure('public.mark_fan_team_announcement_read_for_viewer(uuid)') IS NULL THEN
    RAISE EXCEPTION 'mark_fan_team_announcement_read_for_viewer missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'fan_team_announcement_user_state_pkey'
      AND conrelid = 'public.fan_team_announcement_user_state'::regclass
  ) THEN
    RAISE EXCEPTION 'fan_team_announcement_user_state primary key missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'fan_team_announcement_user_state'
      AND c.relrowsecurity
  ) THEN
    RAISE EXCEPTION 'fan_team_announcement_user_state RLS is not enabled';
  END IF;

  RAISE NOTICE 'OK: fan_team_announcement_user_state checks passed';
END $$;
