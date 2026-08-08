# Direct Message Push Notifications

Trusted server-side APNs for DMs after `public.send_direct_message`.

> **Superseded for new work by** [`Chat_Message_Push_Notifications.md`](./Chat_Message_Push_Notifications.md)
> (unified DM + group + pickup + venue). Keep this doc for the original DM migration (`20260920_0001`).

## Deploy order

1. Apply SQL migration `20260920_0001_direct_message_push_notifications.sql` in Supabase (manual).
2. For all-chat push, also apply `20260922_0001_unified_chat_message_push_notifications.sql` and deploy `notify-chat-message`.
3. Deploy Edge Function (compat adapter into unified handler after 20260922):

```bash
supabase functions deploy notify-direct-message --no-verify-jwt
supabase functions deploy notify-chat-message --no-verify-jwt
```

3. Confirm APNs secrets already used by other notify workers are present:

- `APNS_KEY_ID`
- `APNS_TEAM_ID`
- `APNS_BUNDLE_ID`
- `APNS_PRIVATE_KEY`
- `APNS_ENVIRONMENT` (optional: `sandbox` / `production`)

4. Confirm Vault secrets used by `pg_net` queue:

- `fangeo_supabase_url` or `SUPABASE_URL`
- `fangeo_service_role_key` or `SUPABASE_SERVICE_ROLE_KEY`

5. Optional dedicated cron secret (recommended parity with support-reply):

- Vault + Edge secret name: `DIRECT_MESSAGE_PUSH_CRON_SECRET`
- Queue function sends it as `x-cron-secret` when present

## Payload

Custom APNs keys (siblings of `aps`):

- `source` = `direct_message`
- `type` = `direct_message`
- `conversation_id`
- `sender_id`
- `message_id`
- optional `business_id` / `venue_id` for venue-scoped threads

Alert:

- title = sender display name
- body = sanitized message preview (or structured label / privacy fallback)

## Notes

- Authenticated clients still cannot `INSERT` into `direct_messages` (RPC-only preserved).
- Dedupe table: `direct_message_push_deliveries`.
- Preference columns (default on): `direct_message_notifications_enabled`, `direct_message_preview_mode`.
