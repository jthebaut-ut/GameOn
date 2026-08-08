# Direct messages — two-phase RPC rollout

## Problem

New iOS calls `send_direct_message(p_conversation_id, p_body)` but that RPC
lived only in a combined migration that also revoked INSERT — which would break
old production builds and had not been applied (schema-cache miss).

## Phase A — apply now for dual-client compat

**Migration:** `20260915_0005a_messaging_rate_limit_rpc_compat.sql`

- Creates `public.send_direct_message(p_conversation_id uuid, p_body text)`
- Rate limiter + other RPC throttles
- **Keeps** authenticated INSERT policy/grant
- Includes `NOTIFY pgrst, 'reload schema'`

After apply: new app works via RPC; old app still inserts.

## Phase B — later (RPC-only enforcement)

**Migration:** `20260915_0005b_direct_messages_rpc_only_enforcement.sql`

- Requires `send_direct_message` present
- Drops INSERT policies + `REVOKE INSERT` from authenticated
- Do **not** apply until RPC-only iOS is released and old INSERT clients are ended

## Signature (exact)

After `20260915_0005a` only:

```sql
public.send_direct_message(p_conversation_id uuid, p_body text) RETURNS uuid
```

After `20260917_0001` replies (replaces the two-arg form with one DEFAULT-capable signature):

```sql
public.send_direct_message(p_conversation_id uuid, p_body text, p_reply_to_message_id uuid DEFAULT NULL) RETURNS uuid
```

Swift (omit reply when nil so pre-reply servers stay compatible):

```swift
SendParams(p_conversation_id: conversationId, p_body: body, p_reply_to_message_id: replyTo)
```

See also `docs/ops/Chat_Message_Replies.md`.

## Other objects for testing the new build

| Object | Migration | Needed to test |
|---|---|---|
| `send_direct_message` | **0005a** | **Required** for DM send |
| `bump_direct_message_report_count` | 0003 | Soft — report count bump best-effort skips if missing |
| Venue-photo UID Storage policies | 0004 | Required for **new** UID photo uploads (legacy email URLs still read) |
| Admin override read gates | 0001 | Only admin screens |
| Friendships RLS FORCE | 0002 | Only if testing friendship forge / write revoke |
| Live-location expire cron | ops doc | Not required for DM send |
