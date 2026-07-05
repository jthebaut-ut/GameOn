# FanGeo Announcement Push — Dedicated Cron Secret

FanGeo announcement push uses a **dedicated** secret, separate from support reply and sports workers:

- **`FANGEO_ANNOUNCEMENT_PUSH_CRON_SECRET`** — announcement push only
- **`SUPPORT_REPLY_PUSH_CRON_SECRET`** — support reply only (do not reuse)
- **`PRO_SCORE_PUSH_WORKER_CRON_SECRET`** — pro-game score/card worker only (do not reuse)

`notify-fangeo-announcement` accepts `x-cron-secret` / `x-fangeo-cron-secret` when they match the Edge secret `FANGEO_ANNOUNCEMENT_PUSH_CRON_SECRET`. Postgres `pg_net` cannot read Edge secrets; the **same value** must also exist in **Supabase Vault** under the same name so `queue_fangeo_announcement_push_notification()` can attach the headers.

Bearer `Authorization` may still be sent (Vault `SUPABASE_SERVICE_ROLE_KEY`) but auth succeeds via the cron header when Vault and Edge values match.

## One-time setup

### 1. Generate a new random secret (session only)

Use a password manager or terminal **on your machine** (do not commit output):

```bash
openssl rand -hex 24
```

Copy the result into a private scratch buffer. This value is **only** for announcement push.

### 2. Edge Function secret

**Supabase Dashboard** → **Edge Functions** → **Secrets**, or CLI:

```bash
supabase secrets set FANGEO_ANNOUNCEMENT_PUSH_CRON_SECRET='<paste-generated-secret-here>'
```

Redeploy is not required for secret-only changes, but after first setup deploy `notify-fangeo-announcement` once so the function revision picks up the new env.

### 3. Vault secret (SQL Editor)

Open **SQL Editor** → **New query**. Replace `<PASTE_ANNOUNCEMENT_CRON_SECRET_HERE>` with the **same** value from step 1:

```sql
-- Create (first time only). Never commit the real value to git.
SELECT vault.create_secret(
  '<PASTE_ANNOUNCEMENT_CRON_SECRET_HERE>',
  'FANGEO_ANNOUNCEMENT_PUSH_CRON_SECRET',
  'pg_net cron auth for notify-fangeo-announcement'
);
```

If the name already exists, rotate by id:

```sql
SELECT id, name, created_at
FROM vault.secrets
WHERE name = 'FANGEO_ANNOUNCEMENT_PUSH_CRON_SECRET';

SELECT vault.update_secret(
  '<SECRET_UUID>'::uuid,
  '<PASTE_ANNOUNCEMENT_CRON_SECRET_HERE>',
  'FANGEO_ANNOUNCEMENT_PUSH_CRON_SECRET',
  'pg_net cron auth for notify-fangeo-announcement'
);
```

### 4. Verify (safe — lengths only, no values)

```sql
SELECT * FROM public.fangeo_announcement_push_vault_auth_status();
```

Expect `cron_secret_present = true` and `cron_secret_length` matching the generated secret length.

### 5. Test pg_net invoke

```sql
SELECT public.admin_send_fangeo_announcement_push(
  '<announcement_uuid>'::uuid,
  '<admin@email>'
);

-- After a few seconds:
SELECT id, status_code, left(content::text, 200) AS content_preview, created
FROM net._http_response
ORDER BY created DESC
LIMIT 5;
```

Expect `status_code = 200` and body like `{"ok":true,...}` (or `{"ok":true,"skipped":true,...}` if ineligible).

Edge logs should show `authMatchedSource=cron_secret`.

## Rotation (announcement push only)

1. Generate a new random secret (step 1 above).
2. `supabase secrets set FANGEO_ANNOUNCEMENT_PUSH_CRON_SECRET='<new-value>'`
3. `vault.update_secret(...)` with the same new value (SQL Editor, session only).
4. Re-run verification and test SQL.

Do **not** change `SUPPORT_REPLY_PUSH_CRON_SECRET` or `PRO_SCORE_PUSH_WORKER_CRON_SECRET` when rotating announcement auth.

## Related

- `docs/ops/Support_Reply_Push_Vault_Cron_Secret.md` — support reply pattern (same architecture)
- Migration `20260834_0001_fangeo_announcement_push_vault_cron_secret.sql` — queue function + vault status helper
