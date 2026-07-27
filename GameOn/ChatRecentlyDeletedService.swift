import Foundation
import Supabase

/// Server row for Chat → Recently Deleted (per-user soft-delete within 30 days).
struct RecentlyDeletedChatConversationRow: Decodable, Identifiable, Equatable, Sendable {
    let conversation_kind: String
    let conversation_id: UUID
    let deleted_at: String
    let title: String?
    let subtitle: String?
    let peer_user_id: UUID?
    let peer_avatar_url: String?
    let peer_avatar_thumbnail_url: String?
    let is_business: Bool?
    let business_display_name: String?
    let venue_id: UUID?
    let member_count: Int?
    let last_message_body: String?
    let last_message_created_at: String?
    let days_remaining: Int?

    var id: String { "\(conversation_kind):\(conversation_id.uuidString.lowercased())" }

    var kind: ChatInboxConversationKind {
        switch conversation_kind {
        case "group": return .group
        default:
            if is_business == true || venue_id != nil { return .business }
            return .direct
        }
    }

    var serverKindParam: String {
        conversation_kind == "group" ? "group" : "direct"
    }
}

struct ChatInboxExclusionKey: Decodable, Hashable, Sendable {
    let conversation_kind: String
    let conversation_id: UUID

    var normalizedKind: String {
        conversation_kind == "group" ? "group" : "direct"
    }
}

/// RPC surface for per-user Chat soft-delete / Recently Deleted.
final class ChatRecentlyDeletedService {
    private let client: SupabaseClient

    init(client: SupabaseClient = supabase) {
        self.client = client
    }

    func softDelete(kind: String, conversationId: UUID) async throws {
        struct Params: Encodable {
            let p_conversation_kind: String
            let p_conversation_id: UUID
        }
        try await client
            .rpc(
                "soft_delete_chat_inbox_conversation",
                params: Params(p_conversation_kind: kind, p_conversation_id: conversationId)
            )
            .execute()
    }

    func restore(kind: String, conversationId: UUID) async throws {
        struct Params: Encodable {
            let p_conversation_kind: String
            let p_conversation_id: UUID
        }
        try await client
            .rpc(
                "restore_chat_inbox_conversation",
                params: Params(p_conversation_kind: kind, p_conversation_id: conversationId)
            )
            .execute()
    }

    func permanentlyDelete(kind: String, conversationId: UUID) async throws {
        struct Params: Encodable {
            let p_conversation_kind: String
            let p_conversation_id: UUID
        }
        try await client
            .rpc(
                "permanently_delete_chat_inbox_conversation",
                params: Params(p_conversation_kind: kind, p_conversation_id: conversationId)
            )
            .execute()
    }

    func fetchRecentlyDeleted() async throws -> [RecentlyDeletedChatConversationRow] {
        try await client
            .rpc("list_recently_deleted_chat_conversations")
            .execute()
            .value
    }

    func fetchExclusions() async throws -> [ChatInboxExclusionKey] {
        try await client
            .rpc("get_my_chat_inbox_exclusions")
            .execute()
            .value
    }
}
