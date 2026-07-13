import Foundation
import Supabase

private struct SupportChatRealtimeSubscribeTimeoutError: Error {}

struct SupportMessageRow: Codable, Hashable, Identifiable {
    let id: UUID
    let conversation_id: UUID
    let sender_kind: String
    let sender_auth_user_id: UUID?
    let body: String
    let created_at: String?

    var isFromSupport: Bool {
        sender_kind == "support" || sender_kind == "system"
    }
}

struct SupportRequestSummary: Codable, Hashable, Identifiable {
    let conversation_id: UUID
    let subject: String?
    let issue_type: String?
    let status: String
    let chat_opened_at: String?
    let last_message_at: String?
    let last_support_message_at: String?
    let created_at: String?
    let updated_at: String?

    var id: UUID { conversation_id }

    var isChatAvailable: Bool {
        chat_opened_at != nil || last_support_message_at != nil
    }

    var isOpen: Bool { status == "open" }

    var isCancelled: Bool { status == "cancelled" }

    var isTerminal: Bool { status == "closed" || status == "cancelled" }

    var displayStatus: SupportRequestDisplayStatus {
        if status == "cancelled" {
            return .cancelled
        }
        if status == "closed" {
            return .closed
        }
        if isChatAvailable {
            return .chatOpen
        }
        return .awaitingSupport
    }

    var issueTypeTitle: String {
        if let raw = issue_type,
           let category = SupportRequestCategory(rawValue: raw) {
            return category.displayTitle
        }
        return issue_type ?? "Support Request"
    }

    var displaySubject: String {
        let trimmed = subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Support Request" : trimmed
    }

    var lastUpdatedRaw: String? {
        last_message_at ?? updated_at ?? created_at
    }
}

enum SupportRequestDisplayStatus: String, Hashable {
    case awaitingSupport = "Awaiting Support"
    case chatOpen = "Chat Open"
    case closed = "Closed"
    case cancelled = "Cancelled"
}

struct SupportReportItemKey: Hashable {
    let reportType: String
    let id: UUID
}

struct SupportReportItemSummary: Codable, Hashable, Identifiable {
    let id: UUID
    let report_type: String
    let category: String?
    let user_status: String
    let created_at: String?
    let updated_at: String?

    var itemKey: SupportReportItemKey {
        SupportReportItemKey(reportType: report_type, id: id)
    }

    var reportTypeTitle: String {
        switch report_type {
        case "user": return "User"
        case "venue": return "Venue"
        case "conversation": return "Conversation"
        case "comment": return "Comment"
        default:
            return report_type
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    var rowHeadline: String {
        switch report_type {
        case "user": return "👤 Reported User"
        case "conversation": return "💬 Reported Conversation"
        case "venue": return "🏟 Reported Venue"
        case "comment": return "💭 Reported Comment"
        default: return "Reported Item"
        }
    }

    var detailNavigationTitle: String {
        switch report_type {
        case "user": return "Reported User"
        case "conversation": return "Reported Conversation"
        case "venue": return "Reported Venue"
        case "comment": return "Reported Comment"
        default: return "Report Status"
        }
    }

    var categoryTitle: String {
        let raw = category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return "Report" }
        if let moderation = ModerationReportCategory(rawValue: raw) {
            return moderation.displayTitle
        }
        return raw
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    var displayStatus: SupportReportDisplayStatus {
        SupportReportDisplayStatus(rawValue: user_status) ?? .submitted
    }

    var isActiveReport: Bool {
        displayStatus == .submitted || displayStatus == .underReview
    }

    var canWithdraw: Bool {
        displayStatus == .submitted
    }

    var lastUpdatedRaw: String? {
        updated_at ?? created_at
    }

    var reportedAtRaw: String? {
        created_at
    }

    var outcomeTitle: String {
        switch displayStatus {
        case .withdrawn:
            return "Withdrawn by You"
        case .closed:
            return "Resolved"
        case .submitted, .underReview:
            return displayStatus.title
        }
    }
}

enum SupportReportDisplayStatus: String, Hashable {
    case submitted
    case underReview = "under_review"
    case closed
    case withdrawn

    var title: String {
        switch self {
        case .submitted: return "Submitted"
        case .underReview: return "Under Review"
        case .closed: return "Closed"
        case .withdrawn: return "Withdrawn by You"
        }
    }
}

struct SupportTicketStatus: Codable, Equatable {
    let conversation_id: UUID?
    let status: String
    let subject: String?
    let issue_type: String?
    let chat_opened_at: String?
    let last_support_message_at: String?
    let chat_available: Bool
    let pending_review: Bool

    var showsContactForm: Bool {
        status == "none" || status == "closed"
    }
}

struct SupportTicketStatusRow: Codable, Equatable {
    let conversation_id: UUID?
    let status: String
    let subject: String?
    let issue_type: String?
    let chat_opened_at: String?
    let last_support_message_at: String?
    let chat_available: Bool
    let pending_review: Bool

    func asSupportTicketStatus() -> SupportTicketStatus {
        SupportTicketStatus(
            conversation_id: conversation_id,
            status: status,
            subject: subject,
            issue_type: issue_type,
            chat_opened_at: chat_opened_at,
            last_support_message_at: last_support_message_at,
            chat_available: chat_available,
            pending_review: pending_review
        )
    }
}

/// PostgREST + RPC for FanGeo Support chat. Separate from ``DirectChatService``.
final class SupportChatService {

    private let client: SupabaseClient

    private static let messageColumns =
        "id,conversation_id,sender_kind,sender_auth_user_id,body,created_at"

    init(client: SupabaseClient = supabase) {
        self.client = client
    }

    func fetchSupportRequests(limit: Int = 50) async throws -> [SupportRequestSummary] {
        struct Params: Encodable {
            let p_limit: Int
        }

        let rows: [SupportRequestSummary] = try await client
            .rpc("get_my_support_requests", params: Params(p_limit: limit))
            .execute()
            .value
        return rows
    }

    func fetchSupportReportItems(limit: Int = 50) async throws -> [SupportReportItemSummary] {
        struct Params: Encodable {
            let p_limit: Int
        }

        let rows: [SupportReportItemSummary] = try await client
            .rpc("get_my_support_report_items", params: Params(p_limit: limit))
            .execute()
            .value
        return rows
    }

    func cancelTicket(conversationId: UUID) async throws {
        struct Params: Encodable {
            let p_conversation_id: UUID
        }

        try await client
            .rpc("cancel_my_support_ticket", params: Params(p_conversation_id: conversationId))
            .execute()
    }

    func withdrawReportItem(reportType: String, reportId: UUID) async throws {
        struct Params: Encodable {
            let p_report_type: String
            let p_report_id: UUID
        }

        try await client
            .rpc(
                "withdraw_my_support_report_item",
                params: Params(p_report_type: reportType, p_report_id: reportId)
            )
            .execute()
    }

    func fetchTicketStatus() async throws -> SupportTicketStatus {
        let rows: [SupportTicketStatusRow] = try await client
            .rpc("get_my_support_ticket_status")
            .execute()
            .value
        return (rows.first ?? SupportTicketStatusRow(
            conversation_id: nil,
            status: "none",
            subject: nil,
            issue_type: nil,
            chat_opened_at: nil,
            last_support_message_at: nil,
            chat_available: false,
            pending_review: false
        )).asSupportTicketStatus()
    }

    func submitTicket(subject: String, issueType: String, body: String) async throws -> UUID {
        struct Params: Encodable {
            let p_subject: String
            let p_issue_type: String
            let p_body: String
        }

        let data = try await client
            .rpc(
                "submit_my_support_ticket",
                params: Params(p_subject: subject, p_issue_type: issueType, p_body: body)
            )
            .execute()
            .data
        return try Self.decodeUUIDFromRPCData(data)
    }

    func getOrCreateConversationId() async throws -> UUID {
        let data = try await client
            .rpc("get_or_create_my_support_conversation")
            .execute()
            .data
        return try Self.decodeUUIDFromRPCData(data)
    }

    func fetchMessages(conversationId: UUID, limit: Int = 100) async throws -> [SupportMessageRow] {
        struct Params: Encodable {
            let p_conversation_id: UUID
            let p_limit: Int
        }

        do {
            let rows: [SupportMessageRow] = try await client
                .rpc(
                    "fetch_my_support_messages_for_conversation",
                    params: Params(p_conversation_id: conversationId, p_limit: limit)
                )
                .execute()
                .value
            return rows
        } catch {
            let rows: [SupportMessageRow] = try await client
                .from("support_messages")
                .select(Self.messageColumns)
                .eq("conversation_id", value: conversationId.uuidString.lowercased())
                .order("created_at", ascending: true)
                .order("id", ascending: true)
                .limit(limit)
                .execute()
                .value
            return rows
        }
    }

    func sendMessage(body: String) async throws -> UUID {
        struct Params: Encodable {
            let p_body: String
        }

        let data = try await client
            .rpc("send_my_support_message", params: Params(p_body: body))
            .execute()
            .data
        return try Self.decodeUUIDFromRPCData(data)
    }

    func sendMessage(conversationId: UUID, body: String) async throws -> UUID {
        struct Params: Encodable {
            let p_conversation_id: UUID
            let p_body: String
        }

        let data = try await client
            .rpc(
                "send_my_support_message_for_conversation",
                params: Params(p_conversation_id: conversationId, p_body: body)
            )
            .execute()
            .data
        return try Self.decodeUUIDFromRPCData(data)
    }

    static func supportMessagesThreadRealtimeFilterDescription(conversationId: UUID) -> String {
        "conversation_id=eq.\(conversationId.uuidString.lowercased())"
    }

    func supportMessagesInsertChannel(conversationId: UUID) -> (RealtimeChannelV2, AsyncStream<InsertAction>) {
        let cidLower = conversationId.uuidString.lowercased()
        let channel = client.channel("support-thread-\(cidLower)")
        let filter = RealtimePostgresFilter.eq("conversation_id", value: cidLower)
        let stream = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "support_messages",
            filter: filter
        )
        return (channel, stream)
    }

    func subscribeSupportMessagesChannelWithTimeout(
        _ channel: RealtimeChannelV2,
        timeoutNs: UInt64 = 15_000_000_000
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.detached(priority: .userInitiated) {
                    try await channel.subscribeWithError()
                }.value
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNs)
                throw SupportChatRealtimeSubscribeTimeoutError()
            }
            defer { group.cancelAll() }
            // Never force-unwrap: a cancelled/empty group returns nil and would crash ticket open.
            guard let result = try await group.next() else {
                throw SupportChatRealtimeSubscribeTimeoutError()
            }
            return result
        }
    }

    func removeRealtimeChannel(_ channel: RealtimeChannelV2) async {
        await client.removeChannel(channel)
    }

    private static func decodeUUIDFromRPCData(_ data: Data) throws -> UUID {
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
}
