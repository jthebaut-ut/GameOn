-- Fan Teams identity realtime (logo/name/sport/color propagation).
--
-- Do NOT apply from the agent. Apply manually after Team migrations through 20260933
-- (or at least after 20260926 when fan_teams exists).
--
-- Enables postgres_changes UPDATE delivery for public.fan_teams so member clients
-- can refresh shared Team identity without APNs and without a second sync system.
-- RLS on fan_teams already limits SELECT to active members of active Teams.

DO $pub$
BEGIN
  IF to_regclass('public.fan_teams') IS NULL THEN
    RAISE NOTICE '[FanTeamsRealtime] skipped: public.fan_teams does not exist';
    RETURN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    RAISE NOTICE '[FanTeamsRealtime] skipped: publication supabase_realtime missing';
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables pt
    WHERE pt.pubname = 'supabase_realtime'
      AND pt.schemaname = 'public'
      AND pt.tablename = 'fan_teams'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.fan_teams;
    RAISE NOTICE '[FanTeamsRealtime] table=public.fan_teams status=added_to_supabase_realtime';
  ELSE
    RAISE NOTICE '[FanTeamsRealtime] table=public.fan_teams status=already_in_supabase_realtime';
  END IF;
END
$pub$;
