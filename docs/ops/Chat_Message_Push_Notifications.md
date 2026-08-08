# Unified Chat Message Push Notifications

Trusted server-side APNs for FanGeo social chat after a successful message RPC.

Covers:

- Direct messages (`direct_messages`)
- Venue/business DMs (same table; `chat_type=venue`)
- Social group chats (`group_messages`)
- Pickup game chats (`group_messages` + `pickup_game_id`)

Does **not** cover support admin replies, sports alerts, or friend requests (separate workers).

## Deploy order

1. Apply SQL migration (manual — do not auto-apply):

   `supabase/migrations/20260922_0001_unified_chat_message_push_notifications.sql`

   Requires prior DM push migration `20260920_0001` (queue hook on `send_direct_message`).

2. Deploy Edge Functions:

```bash
supabase functions deploy notify-chat-message --no-verify-jwt
supabase functions deploy notify-direct-message --no-verify-jwt
```

`notify-direct-message` remains a compatibility adapter into the unified handler.

3. Confirm APNs secrets (same as other notify workers):

- `APNS_KEY_ID`
- `APNS_TEAM_ID`
- `APNS_BUNDLE_ID`
- `APNS_PRIVATE_KEY`
- `APNS_ENVIRONMENT` (optional)

4. Confirm Vault secrets for `pg_net` queue:

- `fangeo_supabase_url` or `SUPABASE_URL`
- `fangeo_service_role_key` or `SUPABASE_SERVICE_ROLE_KEY`

5. Optional cron secret (either name accepted):

- `CHAT_MESSAGE_PUSH_CRON_SECRET` (preferred)
- `DIRECT_MESSAGE_PUSH_CRON_SECRET` (legacy fallback)

## Queue path

| Message path | Trigger | Queue | Worker |
|---|---|---|---|
| `send_direct_message` | existing hook | `queue_direct_message_push_notification` → unified queue | `notify-chat-message` (or legacy adapter URL) |
| `send_group_message` | new hook | `queue_chat_message_push_notification(..., 'group', group\|pickup)` | `notify-chat-message` |

## Payload

### Group / pickup (`source=chat_message`)

- `source` / `type` = `chat_message`
- `chat_type` = `group` | `pickup`
- `conversation_id`, `message_id`, `sender_id`
- `sender_display_name`, `sender_username`, `sender_handle`, optional `sender_avatar_url`
- `conversation_title`
- optional `pickup_game_id`

### Direct / venue (released-app compatible)

- `source` / `type` = `direct_message` (legacy deep-link)
- `chat_type` = `direct` | `venue`
- `conversation_id`, `message_id`, `sender_id`
- `sender_display_name`, `sender_username`, `sender_handle`, optional `sender_avatar_url`
- optional `business_id` / `venue_id` / `conversation_title`

## Alert rules

| chat_type | title | body |
|---|---|---|
| direct | sender display name | `@handle · Sent you a message: <preview>` |
| venue | business/venue name | `Sender (@handle) sent a message: <preview>` |
| group | group title | `Sender (@handle) sent a message: <preview>` |
| pickup | pickup game title | `Sender (@handle) sent a message: <preview>` |

Structured: `… shared a location` / `… sent a poll` / etc.  
Avatar: payload metadata only (no Notification Service Extension yet — system icon remains).

## Dedupe / prefs

- Ledger: `public.chat_message_push_deliveries` PK `(message_source, message_id, recipient_user_id)`
- Prefs (default ON): `direct_message_notifications_enabled`, `group_chat_notifications_enabled`, `pickup_chat_notifications_enabled`
- Preview mode reuses `direct_message_preview_mode` (`always` / `when_unlocked` / `never`)

## iOS routing

- Legacy DM → `DirectMessageNotificationDeepLinkBridge` → Chat → exact DM
- Unified group/pickup → `ChatMessageNotificationDeepLinkBridge` → Chat → `pendingGroupOpenConversationId`
- Foreground: system banner suppressed; realtime + in-app banner remain
