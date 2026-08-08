# Friend Request Push Notifications

Trusted server-side APNs after `public.friendship_ensure_pending` creates/revives a pending request.

## Deploy order

1. Apply SQL migration `20260921_0001_friend_request_push_notifications.sql` in Supabase (manual).
2. Deploy Edge Function:

```bash
supabase functions deploy notify-friend-request --no-verify-jwt
```

3. Confirm APNs secrets already used by other notify workers:

- `APNS_KEY_ID`
- `APNS_TEAM_ID`
- `APNS_BUNDLE_ID`
- `APNS_PRIVATE_KEY`
- `APNS_ENVIRONMENT` (optional)

4. Confirm Vault secrets used by `pg_net` queue:

- `fangeo_supabase_url` or `SUPABASE_URL`
- `fangeo_service_role_key` or `SUPABASE_SERVICE_ROLE_KEY`

5. Optional dedicated cron secret:

- Vault + Edge: `FRIEND_REQUEST_PUSH_CRON_SECRET`

## Payload

- `source` / `type` = `friend_request`
- `request_id` / `friendship_id`
- `requester_id`
- `event_id` (dedupe / revive key)

Alert:

- title = requester display name
- body = `Sent you a friend request`

## Tap route

Chat → Requests (`pendingOpenFriendRequestsSection`)
