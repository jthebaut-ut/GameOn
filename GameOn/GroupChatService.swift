import Foundation
import Supabase

/// Parallel group-chat API. Does not touch ``DirectChatService`` or DM tables.
final class GroupChatService {
    private let client: SupabaseClient

    private static let groupMessageListColumns =
        "id,conversation_id,sender_id,body,message_type,system_event,system_payload,created_at,deleted_at,report_count,is_deleted"

    init(client: SupabaseClient = supabase) {
        self.client = client
    }

    func currentUserId() async throws -> UUID {
        try await client.auth.session.user.id
    }

    func fetchInboxSummaries() async throws -> [GroupInboxSummaryRow] {
        try await client
            .rpc("get_group_inbox_summaries")
            .execute()
            .value
    }

    func createGroup(title: String, memberIds: [UUID]) async throws -> UUID {
        struct Params: Encodable {
            let p_title: String
            let p_member_ids: [UUID]
        }
        let data = try await client
            .rpc("create_group_conversation", params: Params(p_title: title, p_member_ids: memberIds))
            .execute()
            .data
        return try decodeUUID(from: data)
    }

    func addMembers(conversationId: UUID, memberIds: [UUID]) async throws {
        struct Params: Encodable {
            let p_conversation_id: UUID
            let p_member_ids: [UUID]
        }
        try await client
            .rpc("add_group_members", params: Params(p_conversation_id: conversationId, p_member_ids: memberIds))
            .execute()
    }

    func removeMember(conversationId: UUID, userId: UUID) async throws {
        struct Params: Encodable {
            let p_conversation_id: UUID
            let p_user_id: UUID
        }
        try await client
            .rpc("remove_group_member", params: Params(p_conversation_id: conversationId, p_user_id: userId))
            .execute()
    }

    func leave(conversationId: UUID) async throws {
        struct Params: Encodable {
            let p_conversation_id: UUID
        }
        try await client
            .rpc("leave_group_conversation", params: Params(p_conversation_id: conversationId))
            .execute()
    }

    func markRead(conversationId: UUID) async throws {
        struct Params: Encodable {
            let p_conversation_id: UUID
        }
        try await client
            .rpc("mark_group_conversation_read", params: Params(p_conversation_id: conversationId))
            .execute()
    }

    func setMuted(conversationId: UUID, muted: Bool) async throws {
        struct Params: Encodable {
            let p_conversation_id: UUID
            let p_muted: Bool
        }
        try await client
            .rpc("set_group_conversation_muted", params: Params(p_conversation_id: conversationId, p_muted: muted))
            .execute()
    }

    func reportMessage(messageId: UUID, category: String? = nil, details: String? = nil) async throws {
        struct Params: Encodable {
            let p_message_id: UUID
            let p_category: String?
            let p_details: String?
        }
        let data = try await client
            .rpc(
                "report_group_message",
                params: Params(p_message_id: messageId, p_category: category, p_details: details)
            )
            .execute()
            .data
        let reportId = try decodeUUID(from: data)
        await notifyGroupMessageReportBestEffort(
            reportId: reportId,
            messageId: messageId,
            category: category,
            details: details
        )
    }

    /// Reports an entire group conversation (requires `report_group_conversation` RPC).
    /// - Note: Distinct from ``reportMessage`` / `group_message_reports`.
    func reportConversation(
        conversationId: UUID,
        category: String,
        details: String? = nil
    ) async throws {
        struct Params: Encodable {
            let p_group_conversation_id: UUID
            let p_category: String
            let p_details: String?
        }
        do {
            let data = try await client
                .rpc(
                    "report_group_conversation",
                    params: Params(
                        p_group_conversation_id: conversationId,
                        p_category: category,
                        p_details: details
                    )
                )
                .execute()
                .data
            let reportId = try decodeUUID(from: data)
            await notifyGroupConversationReportBestEffort(
                reportId: reportId,
                conversationId: conversationId,
                category: category,
                details: details
            )
        } catch {
            if Self.isDuplicateGroupConversationReport(error) {
                throw GroupChatConversationReportError.duplicateOpenReport
            }
            if Self.isNotActiveGroupMember(error) {
                throw GroupChatConversationReportError.notActiveMember
            }
            throw error
        }
    }

    /// Best-effort admin email. Prefer server-side pg_net queue when deployed; this remains a JWT fallback.
    /// `moderation_notified_at` prevents duplicate emails if both paths run.
    private func notifyGroupConversationReportBestEffort(
        reportId: UUID,
        conversationId: UUID,
        category: String,
        details: String?
    ) async {
        await invokeModerationReportNotify(
            reportId: reportId,
            reportType: "group_conversation",
            category: category,
            details: details,
            conversationId: conversationId,
            messageId: nil
        )
    }

    private func notifyGroupMessageReportBestEffort(
        reportId: UUID,
        messageId: UUID,
        category: String?,
        details: String?
    ) async {
        await invokeModerationReportNotify(
            reportId: reportId,
            reportType: "group_message",
            category: category ?? "other",
            details: details,
            conversationId: nil,
            messageId: messageId
        )
    }

    private func invokeModerationReportNotify(
        reportId: UUID,
        reportType: String,
        category: String,
        details: String?,
        conversationId: UUID?,
        messageId: UUID?
    ) async {
        struct Payload: Encodable {
            let report_id: String
            let report_type: String
            let category: String
            let details: String?
            let created_at: String
            let conversation_id: UUID?
            let message_id: UUID?
        }
        struct Response: Decodable {
            let ok: Bool?
            let skipped: Bool?
            let error: String?
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let payload = Payload(
            report_id: reportId.uuidString.lowercased(),
            report_type: reportType,
            category: category,
            details: details,
            created_at: formatter.string(from: Date()),
            conversation_id: conversationId,
            message_id: messageId
        )
        guard let bodyData = try? JSONEncoder().encode(payload) else { return }

        do {
            let response: Response = try await client.functions.invoke(
                "notify-moderation-report",
                options: FunctionInvokeOptions(method: .post, body: bodyData)
            )
#if DEBUG
            print(
                "GroupChat: notify-moderation-report type=\(reportType) ok=\(response.ok ?? false) skipped=\(response.skipped ?? false) error=\(response.error ?? "nil")"
            )
#endif
            _ = response
        } catch {
#if DEBUG
            print("GroupChat: notify-moderation-report email notify failed:", error)
#endif
        }
    }

    private static func isDuplicateGroupConversationReport(_ error: Error) -> Bool {
        let s = String(describing: error).lowercased()
        return s.contains("23505")
            || s.contains("unique")
            || s.contains("already reported this group")
            || s.contains("group_conversation_reports_one_open_per_reporter")
    }

    private static func isNotActiveGroupMember(_ error: Error) -> Bool {
        let s = String(describing: error).lowercased()
        return s.contains("not an active member")
    }

    func fetchDetails(conversationId: UUID) async throws -> [GroupConversationDetailRow] {
        struct Params: Encodable {
            let p_conversation_id: UUID
        }
        return try await client
            .rpc("get_group_conversation_details", params: Params(p_conversation_id: conversationId))
            .execute()
            .value
    }

    /// Batched active members for inbox avatar clusters. Uses existing RLS on `group_conversation_members`.
    func fetchActiveMembers(forConversationIds conversationIds: [UUID]) async throws -> [GroupActiveMemberRow] {
        let ids = Array(Set(conversationIds))
        guard !ids.isEmpty else { return [] }
        return try await client
            .from("group_conversation_members")
            .select("conversation_id,user_id,joined_at")
            .in("conversation_id", values: ids.map { $0.uuidString.lowercased() })
            .is("left_at", value: nil)
            .order("joined_at", ascending: true)
            .execute()
            .value
    }

    func sendMessage(conversationId: UUID, body: String) async throws -> UUID {
        struct Params: Encodable {
            let p_conversation_id: UUID
            let p_body: String
        }
        let data = try await client
            .rpc("send_group_message", params: Params(p_conversation_id: conversationId, p_body: body))
            .execute()
            .data
        return try decodeUUID(from: data)
    }

    func fetchLatestMessages(conversationId: UUID, limit: Int = 50) async throws -> [GroupMessageRow] {
        let rows: [GroupMessageRow] = try await client
            .from("group_messages")
            .select(Self.groupMessageListColumns)
            .eq("conversation_id", value: conversationId)
            .is("deleted_at", value: nil)
            .or("is_deleted.is.null,is_deleted.eq.false")
            .order("created_at", ascending: false)
            .order("id", ascending: false)
            .limit(limit)
            .execute()
            .value
        return rows.reversed()
    }

    /// Older page for thread history (messages strictly older than ``beforeCreatedAt``).
    func fetchOlderMessages(
        conversationId: UUID,
        beforeCreatedAt: String,
        beforeId: UUID,
        limit: Int = 40
    ) async throws -> [GroupMessageRow] {
        _ = beforeId // Reserved for tie-break if needed; created_at cursor is sufficient for UX paging.
        let rows: [GroupMessageRow] = try await client
            .from("group_messages")
            .select(Self.groupMessageListColumns)
            .eq("conversation_id", value: conversationId)
            .is("deleted_at", value: nil)
            .or("is_deleted.is.null,is_deleted.eq.false")
            .lt("created_at", value: beforeCreatedAt)
            .order("created_at", ascending: false)
            .order("id", ascending: false)
            .limit(limit)
            .execute()
            .value
        return rows.reversed()
    }

    func groupMessagesInsertChannel(conversationId: UUID) -> (RealtimeChannelV2, AsyncStream<InsertAction>) {
        let cidLower = conversationId.uuidString.lowercased()
        let channel = client.channel("group-thread-\(cidLower)")
        let filter = RealtimePostgresFilter.eq("conversation_id", value: cidLower)
        let stream = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "group_messages",
            filter: filter
        )
        return (channel, stream)
    }

    func removeRealtimeChannel(_ channel: RealtimeChannelV2) async {
        await client.removeChannel(channel)
    }

    private func decodeUUID(from data: Data) throws -> UUID {
        if let uuid = try? JSONDecoder().decode(UUID.self, from: data) {
            return uuid
        }
        if let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
            .lowercased(),
           let uuid = UUID(uuidString: raw) {
            return uuid
        }
        throw NSError(domain: "GroupChatService", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not decode group conversation id."
        ])
    }
}
