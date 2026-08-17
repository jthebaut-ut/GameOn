-- Staging checks for Action Center dismissals (20260977).
-- Manual / staging only. Do NOT run against production from the agent.

DO $$
BEGIN
  IF to_regclass('public.action_center_dismissals') IS NULL THEN
    RAISE EXCEPTION 'action_center_dismissals missing — apply 20260977_0001';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'action_center_dismissals_pkey'
      AND conrelid = 'public.action_center_dismissals'::regclass
  ) THEN
    RAISE EXCEPTION 'action_center_dismissals primary key missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'action_center_dismissals_user_dismissed_at_idx'
  ) THEN
    RAISE EXCEPTION 'action_center_dismissals_user_dismissed_at_idx missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'action_center_dismissals'
      AND c.relrowsecurity
  ) THEN
    RAISE EXCEPTION 'action_center_dismissals RLS is not enabled';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.role_table_grants
    WHERE table_schema = 'public'
      AND table_name = 'action_center_dismissals'
      AND grantee IN ('anon', 'PUBLIC')
  ) THEN
    RAISE EXCEPTION 'action_center_dismissals must not be granted to anon/PUBLIC';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'action_center_dismissals'
      AND policyname = 'action_center_dismissals_select_own'
  ) THEN
    RAISE EXCEPTION 'select-own RLS policy missing';
  END IF;
END $$;
