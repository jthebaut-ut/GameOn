# Chat message replies — review-ready migration

**Migration:** `supabase/migrations/20260917_0001_chat_message_replies.sql`  
**Do not apply from the agent.** Review and apply deliberately after `20260915_0005a` (and ideally after `20260916_0001` clear-history).

## What it adds

- `direct_messages.reply_to_message_id uuid NULL`
- `group_messages.reply_to_message_id uuid NULL`
- Soft FK `ON DELETE SET NULL` (same-table)
- BEFORE INSERT reply-target validation (Phase A table-insert defense)
- Group immutability trigger (mirrors DM allowlist; freezes `reply_to_message_id`)
- Extended RPCs (single canonical signature each, `DEFAULT NULL` for old clients):

```sql
public.send_direct_message(p_conversation_id uuid, p_body text, p_reply_to_message_id uuid DEFAULT NULL) RETURNS uuid
public.send_group_message(p_conversation_id uuid, p_body text, p_reply_to_message_id uuid DEFAULT NULL) RETURNS uuid
```

## Authorization model

Reply target must:

1. Exist in the **same** conversation
2. Not be soft-deleted / moderated (`deleted_at` / `is_deleted`)
3. Be readable by the caller (DM: participant + clear watermark; group: `group_member_can_read_message`)
4. For groups: `message_type = 'text'` (system membership events are not replyable)

Guessed UUIDs from other conversations fail with generic `reply target unavailable`.

## Immutability

- DM: existing `enforce_direct_messages_immutable_columns` already freezes non-allowlisted columns after insert (including `reply_to_message_id`).
- Group: new `enforce_group_messages_immutable_columns` allowlists only `report_count` / `is_deleted` / `deleted_at`.

## Old clients

- Receive reply messages as normal body text
- Ignore unknown `reply_to_message_id` column if they never select it
- Continue calling send RPCs with only `p_conversation_id` + `p_body` (DEFAULT covers the third arg)
- **Do not** embed a duplicate quote into `body` for compatibility

## Inbox / push

Inbox and push continue to show the **new message body** only (privacy-safe structured generics unchanged). No extra push for creating a reply.

## Compatibility with 0005b

Unapplied `20260915_0005b` was updated to accept either:

- `send_direct_message(uuid, text)` or
- `send_direct_message(uuid, text, uuid)`

## Manual deployment order

1. Ensure `20260915_0005a` applied (send RPCs exist)
2. Ensure `20260916_0001` applied if you rely on clear-watermark reply checks in production
3. Apply `20260917_0001_chat_message_replies.sql`
4. Confirm `NOTIFY pgrst, 'reload schema'` ran (included)
5. Ship iOS build that selects/sends `reply_to_message_id`
6. Later: apply `0005b` when ready to revoke authenticated DM INSERT

## Verification snippets

```sql
SELECT to_regprocedure('public.send_direct_message(uuid, text, uuid)');
SELECT to_regprocedure('public.send_group_message(uuid, text, uuid)');
SELECT column_name FROM information_schema.columns
 WHERE table_schema = 'public'
   AND table_name IN ('direct_messages', 'group_messages')
   AND column_name = 'reply_to_message_id';
```
