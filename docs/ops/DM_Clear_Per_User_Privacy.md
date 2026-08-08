# Direct conversation clear — per-user privacy

## Bug

Clearing a DM must be private to the clearing user. Shared history must remain for the peer.
After clear + logout/login, the clearer must not regain pre-`cleared_at` messages.

## Root cause (persistence / rehydration)

1. Immediate clear worked by wiping local `messages` and soft-hiding inbox.
2. On reopen/login, `fetchHistoryClearedAt` could resolve to **nil**, so
   `fetchLatestMessages` loaded **unfiltered** history.
3. Contributing client bugs:
   - `DmConversationClearStore` used `UserDefaults.dictionary as? [String: String]`
     (often fails on read-back → empty cache after process restart)
   - Watermark PostgREST filters used lowercase UUID **strings**
   - `try?` / silent nil meant “load everything” when watermark resolution failed
   - Refresh/pagination paths did not always re-apply the watermark

SQL auto-restore only deletes `user_chat_inbox_deletion` rows — it does **not**
delete `user_direct_conversation_clear`. No SQL change required for that.

## Fix (migration `20260916_0001_clear_direct_conversation_per_user.sql`)

**Already applied in production — do not reapply.**

| Object | Role |
|---|---|
| `user_direct_conversation_clear` | `(user_id, conversation_id)` → `cleared_at` |
| `clear_direct_conversation` | Upserts **caller’s** watermark; soft-hides **caller’s** inbox; **never** mutates shared messages |
| `get_dm_inbox_summaries` / `get_dm_unread_total` | Ignore messages ≤ viewer `cleared_at` |

## Client hydration (this follow-up)

- Resolve `cleared_at` **before** publishing messages
- Query + client-side filter: `created_at > cleared_at`
- JSON UserDefaults cache keyed by auth user id
- Hydrate all clears on inbox refresh after login
- Refresh / pagination / realtime honor the watermark

## Manual tests

A–K in the persistence audit (logout/login, new inbound after clear, pagination, account switch).
