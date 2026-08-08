# Chat global search

**Migration:** `supabase/migrations/20260918_0001_chat_global_search.sql` (review-ready; do not apply from the agent)

**Security review checks:** `supabase/tests/chat_global_search_security_review_checks.sql`

## RPCs

- `search_chat_conversations(p_query text, p_limit int DEFAULT 25)` — SECURITY DEFINER
- `search_chat_messages(p_query text, p_conversation_id uuid DEFAULT NULL, p_limit int DEFAULT 40)` — SECURITY DEFINER
- Aliases: `search_direct_messages`, `search_group_messages` — SECURITY INVOKER wrappers

Requires applied `20260916_0001` clear-watermark helpers and `20260915_0005a` rate-limit infrastructure.

## Authorization parity

Search does **not** invent a simplified auth model. Visibility is composed from the same helpers used by ordinary reads:

| Concern | Helper |
|---|---|
| DM participant | `is_direct_conversation_participant` |
| DM clear watermark | `direct_message_after_viewer_clear` |
| DM / group blocks | `pickup_invite_users_are_unblocked` / `group_viewer_can_see_sender_message` |
| Group membership window | `group_member_can_read_message` |
| Active group listing | `is_active_group_member` |
| Pickup chat | `is_pickup_game_chat_authorized` |
| Soft-delete / moderation | `deleted_at IS NULL` + `COALESCE(is_deleted,false)=false` |

**Own vs other messages:** users may search messages they sent **and** messages others sent inside conversations they are authorized to read. Unrelated conversations are never searchable. Sender = viewer is never excluded by block filters.

## Privacy

- Matching and returned previews use `chat_search_safe_message_preview` only (never raw body / JSON / coordinates / voter IDs).
- Unrecognized `__FG_` payloads return `Shared content` — no raw fallthrough.
- Internal helpers are **not** `EXECUTE`-able by `authenticated`.

## Abuse controls

- Query: min length 2, max 100, control-character scrub
- Result caps: conversations ≤ 50, messages ≤ 80
- Rate limits: `search_chat_conversations` 30/60s, `search_chat_messages` 40/60s
- `p_conversation_id` inaccessible → zero rows (no UUID / type oracle)
- Client cancellation is UX only; server still rate-limits

## Indexing

`pg_trgm` GIN indexes on the **safe preview expression** (not raw structured JSON bodies):

- `direct_messages_safe_preview_trgm_idx`
- `group_messages_safe_preview_trgm_idx`

Auth filters still bound the searchable set to the caller’s conversations.

## Client

- Inbox: `ChatGlobalSearchController` + `ChatInboxGlobalSearchBar` in `FriendsTabView`
- In-conversation: `ChatConversationSearchSheet` (DM overflow + group toolbar)
