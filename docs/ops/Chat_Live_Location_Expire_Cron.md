# Chat Live Location — Expire Cron (pg_cron)

Active live-location sessions are marked `expired` by
`public.chat_live_location_expire_stale_sessions()` (see migration
`20260912_0001_chat_live_location_sessions.sql`). That function is granted to
`service_role` only and mutates only `status` + `stopped_at`.

**Do not put `cron.schedule` in an auto-applied migration.** Schedule once per
environment from the Supabase SQL Editor (or a deliberate ops runbook) using
the copy-paste SQL below.

## Prerequisites

1. Migration `20260912_0001_chat_live_location_sessions.sql` applied.
2. Extension `pg_cron` available (Supabase projects usually have it under
   `extensions`).

Verify the function exists:

```sql
SELECT pg_get_functiondef(
  'public.chat_live_location_expire_stale_sessions()'::regprocedure
);
```

## Schedule (copy-paste)

Runs **every 5 minutes**. Safe if overlapping: each call only updates rows that
are still `status = 'active'` and `expires_at <= now()`.

```sql
-- Unschedule prior job with the same name (idempotent re-apply).
SELECT cron.unschedule('fangeo_chat_live_location_expire_every_5_min')
WHERE EXISTS (
  SELECT 1
  FROM cron.job
  WHERE jobname = 'fangeo_chat_live_location_expire_every_5_min'
);

SELECT cron.schedule(
  'fangeo_chat_live_location_expire_every_5_min',
  '*/5 * * * *',
  $$
    SELECT public.chat_live_location_expire_stale_sessions();
  $$
);
```

## Verify

```sql
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'fangeo_chat_live_location_expire_every_5_min';

-- Optional: how many active sessions are past expiry right now
SELECT count(*) AS stale_active
FROM public.chat_live_location_sessions
WHERE status = 'active'
  AND expires_at <= now();
```

## Unschedule

```sql
SELECT cron.unschedule('chat_live_location_expire_stale_sessions')
WHERE EXISTS (
  SELECT 1
  FROM cron.job
  WHERE jobname = 'chat_live_location_expire_stale_sessions'
);
```

## Notes

- Product max share window is 60 minutes (+5m skew in the CHECK). Cron every
  minute keeps UI cards from lingering long after `expires_at`.
- Clients should still call `stop_chat_live_location_session` on explicit stop;
  cron is the backstop for abandoned sessions.
- Prefer vault-backed HTTP cron only when the worker is an Edge Function. This
  path is in-database and needs no bearer secret.
