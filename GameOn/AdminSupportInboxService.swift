import Foundation
import Supabase

struct AdminSupportConversationRow: Codable, Hashable, Identifiable {
    let id: UUID
    let user_id: UUID
    let status: String
    let subject: String?
    let issue_type: String?
    let chat_opened_at: String?
    let last_message_at: String?
    let last_user_message_at: String?
    let last_support_message_at: String?
    let created_at: String?
    let updated_at: String?
    let last_message_body: String?
    let last_message_sender_kind: String?

    var isChatOpen: Bool {
        chat_opened_at != nil || last_support_message_at != nil
    }

    var issueTypeTitle: String {
        guard let issue_type,
              let category = SupportRequestCategory(rawValue: issue_type) else {
            return issue_type ?? "Support Request"
        }
        return category.displayTitle
    }
}

/// Admin Support Inbox API + realtime. Separate from ``DirectChatService`` and ``SupportChatService``.
final class AdminSupportInboxService {

    private let client: SupabaseClient

    init(client: SupabaseClient = supabase) {
        self.client = client
    }

    func listConversations(adminEmail: String, limit: Int = 50) async throws -> [AdminSupportConversationRow] {
        struct Params: Encodable {
            let p_admin_email: String
            let p_limit: Int
        }

        return try await client
            .rpc(
                "admin_list_support_conversations",
                params: Params(p_admin_email: adminEmail, p_limit: limit)
            )
            .execute()
            .value
    }

    func fetchMessages(conversationId: UUID, adminEmail: String, limit: Int = 100) async throws -> [SupportMessageRow] {
        struct Params: Encodable {
            let p_conversation_id: UUID
            let p_admin_email: String
            let p_limit: Int
        }

        return try await client
            .rpc(
                "admin_fetch_support_messages",
                params: Params(
                    p_conversation_id: conversationId,
                    p_admin_email: adminEmail,
                    p_limit: limit
                )
            )
            .execute()
            .value
    }

    func openSupportChat(conversationId: UUID, adminEmail: String) async throws -> UUID {
        struct Params: Encodable {
            let p_conversation_id: UUID
            let p_admin_email: String
        }

        let data = try await client
            .rpc(
                "admin_open_support_chat",
                params: Params(
                    p_conversation_id: conversationId,
                    p_admin_email: adminEmail
                )
            )
            .execute()
            .data

        if let decoded = try? JSONDecoder().decode(UUID.self, from: data) {
            return decoded
        }
        if let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
           let uuid = UUID(uuidString: raw) {
            return uuid
        }
        throw URLError(.cannotDecodeContentData)
    }

    func sendSupportReply(conversationId: UUID, body: String, adminEmail: String) async throws -> UUID {
        struct Params: Encodable {
            let p_conversation_id: UUID
            let p_body: String
            let p_admin_email: String
        }

        let data = try await client
            .rpc(
                "admin_send_support_message",
                params: Params(
                    p_conversation_id: conversationId,
                    p_body: body,
                    p_admin_email: adminEmail
                )
            )
            .execute()
            .data

        if let decoded = try? JSONDecoder().decode(UUID.self, from: data) {
            return decoded
        }
        if let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
           let uuid = UUID(uuidString: raw) {
            return uuid
        }
        throw URLError(.cannotDecodeContentData)
    }

    /// Inbox-wide INSERT listener for new user/support messages (admin JWT must pass RLS).
    func supportInboxInsertChannel() -> (RealtimeChannelV2, AsyncStream<InsertAction>) {
        let channel = client.channel("support-inbox-admin")
        let stream = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "support_messages"
        )
        return (channel, stream)
    }

    /// Thread-scoped INSERT listener while viewing one conversation.
    func supportThreadInsertChannel(conversationId: UUID) -> (RealtimeChannelV2, AsyncStream<InsertAction>) {
        let cidLower = conversationId.uuidString.lowercased()
        let channel = client.channel("support-thread-admin-\(cidLower)")
        let filter = RealtimePostgresFilter.eq("conversation_id", value: cidLower)
        let stream = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "support_messages",
            filter: filter
        )
        return (channel, stream)
    }

    func subscribeChannelWithTimeout(_ channel: RealtimeChannelV2, timeoutNs: UInt64 = 15_000_000_000) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.detached(priority: .userInitiated) {
                    try await channel.subscribeWithError()
                }.value
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNs)
                throw AdminSupportInboxRealtimeSubscribeTimeoutError()
            }
            defer { group.cancelAll() }
            try await group.next()!
        }
    }

    func removeRealtimeChannel(_ channel: RealtimeChannelV2) async {
        await client.removeChannel(channel)
    }
}

private struct AdminSupportInboxRealtimeSubscribeTimeoutError: Error {}
