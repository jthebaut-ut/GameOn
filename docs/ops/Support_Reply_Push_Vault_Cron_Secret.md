# Support Reply Push — Dedicated Cron Secret

Support reply push uses a **dedicated** secret, separate from pro-game sports notifications:

- **`SUPPORT_REPLY_PUSH_CRON_SECRET`** — support reply only
- **`PRO_SCORE_PUSH_WORKER_CRON_SECRET`** — pro-game score/card worker only (do not reuse)

`notify-support-reply` accepts `x-cron-secret` / `x-fangeo-cron-secret` when they match the Edge secret `SUPPORT_REPLY_PUSH_CRON_SECRET`. Postgres `pg_net` cannot read Edge secrets; the **same value** must also exist in **Supabase Vault** under the same name so `queue_support_reply_push_notification()` can attach the headers.

Bearer `Authorization` may still be sent (Vault `fangeo_service_role_key`) but auth succeeds via the cron header when Vault and Edge values match.

## One-time setup

### 1. Generate a new random secret (session only)

Use a password manager or terminal **on your machine** (do not commit output):

```bash
openssl rand -hex 24
```

Copy the result into a private scratch buffer. This value is **only** for support-reply push — not for `PRO_SCORE_PUSH_WORKER_CRON_SECRET` or any sports worker.

### 2. Edge Function secret

**Supabase Dashboard** → **Edge Functions** → **Secrets**, or CLI:

```bash
supabase secrets set SUPPORT_REPLY_PUSH_CRON_SECRET='<paste-generated-secret-here>'
```

Redeploy is not required for secret-only changes, but after first setup deploy `notify-support-reply` once so the function revision picks up the new env.

### 3. Vault secret (SQL Editor)

Open **SQL Editor** → **New query**. Replace `<PASTE_SUPPORT_REPLY_CRON_SECRET_HERE>` with the **same** value from step 1:

```sql
-- Create (first time only). Never commit the real value to git.
SELECT vault.create_secret(
  '<PASTE_SUPPORT_REPLY_CRON_SECRET_HERE>',
  'SUPPORT_REPLY_PUSH_CRON_SECRET',
  'pg_net cron auth for notify-support-reply'
);
```

If the name already exists, rotate by id:

```sql
SELECT id, name, created_at
FROM vault.secrets
WHERE name = 'SUPPORT_REPLY_PUSH_CRON_SECRET';

SELECT vault.update_secret(
  '<SECRET_UUID>'::uuid,
  '<PASTE_SUPPORT_REPLY_CRON_SECRET_HERE>',
  'SUPPORT_REPLY_PUSH_CRON_SECRET',
  'pg_net cron auth for notify-support-reply'
);
```

### 4. Verify (safe — lengths only, no values)

```sql
SELECT * FROM public.support_reply_push_vault_auth_status();
```

Expect `cron_secret_present = true` and `cron_secret_length` matching the generated secret length.

### 5. Test pg_net invoke

```sql
SELECT public.queue_support_reply_push_notification(
  '<conversation_uuid>'::uuid,
  '<support_message_uuid>'::uuid
);

-- After a few seconds:
SELECT id, status_code, left(content::text, 200) AS content_preview, created
FROM net._http_response
ORDER BY id DESC
LIMIT 1;
```

Expect `status_code = 200` and body like `{"ok":true,...}` (or `{"ok":true,"skipped":true,...}` if no device tokens).

Edge logs should show `authMatchedSource=cron_secret`.

## Rotation (support reply only)

1. Generate a new random secret (step 1 above).
2. `supabase secrets set SUPPORT_REPLY_PUSH_CRON_SECRET='<new-value>'`
3. `vault.update_secret(...)` with the same new value (SQL Editor, session only).
4. Re-run verification and test SQL.

Do **not** change `PRO_SCORE_PUSH_WORKER_CRON_SECRET` when rotating support-reply auth.

## Related

- `docs/ops/Supabase_Cron_Secrets.md` — general Vault + cron patterns (sports workers)
- Migration `20260832_0001_support_reply_dedicated_cron_secret.sql` — dedicated Vault name + queue function
