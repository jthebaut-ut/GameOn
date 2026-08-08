import Foundation

/// Localized "N member(s)" for group chat surfaces (inbox rows, invitations, share pickers).
func groupChatLocalizedMemberCount(_ count: Int, languageCode: String) -> String {
    let key = count == 1
        ? "group_chat_member_count_one_format"
        : "group_chat_member_count_other_format"
    return String(
        format: L10n.t(key, languageCode: languageCode),
        locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
        Int64(count)
    )
}

enum ChatInboxConversationKind: String, Hashable, Sendable {
    case direct
    case business
    case group
}

/// Categories for reporting an entire group conversation (stored as plain strings).
enum GroupConversationReportCategory: String, CaseIterable, Identifiable, Sendable {
    case harassment = "harassment"
    case hate = "hate"
    case spam = "spam"
    case inappropriate = "inappropriate"
    case violence = "violence"
    case fakeAccount = "fake_account"
    case other = "other"

    var id: String { rawValue }

    func localizedTitle(languageCode: String) -> String {
        switch self {
        case .harassment:
            return L10n.t("group_chat_report_group_category_harassment", languageCode: languageCode)
        case .hate:
            return L10n.t("group_chat_report_group_category_hate", languageCode: languageCode)
        case .spam:
            return L10n.t("group_chat_report_group_category_spam", languageCode: languageCode)
        case .inappropriate:
            return L10n.t("group_chat_report_group_category_inappropriate", languageCode: languageCode)
        case .violence:
            return L10n.t("group_chat_report_group_category_violence", languageCode: languageCode)
        case .fakeAccount:
            return L10n.t("group_chat_report_group_category_impersonation", languageCode: languageCode)
        case .other:
            return L10n.t("group_chat_report_group_category_other", languageCode: languageCode)
        }
    }
}

enum GroupChatConversationReportError: LocalizedError, Equatable {
    case duplicateOpenReport
    case notActiveMember

    var errorDescription: String? {
        switch self {
        case .duplicateOpenReport:
            return L10n.t("group_chat_report_group_already_reported")
        case .notActiveMember:
            return L10n.t("group_chat_report_group_not_member")
        }
    }
}

struct GroupInboxSummaryRow: Decodable, Equatable, Sendable {
    let conversation_id: UUID
    let title: String
    let member_count: Int
    let last_message_body: String?
    let last_message_sender_id: UUID?
    let last_message_created_at: String?
    /// `text` or `system` (newer servers). Older rows may omit → treat as text.
    let last_message_type: String?
    let last_system_event: String?
    let last_system_payload: GroupSystemEventPayload?
    let unread_count: Int?
    let is_muted: Bool?
    /// Set when this inbox row is the private chat for a pickup game (migration 20260893+).
    let pickup_game_id: UUID?

    var isPickupGameChat: Bool { pickup_game_id != nil }
}

/// Pending group invitation for the current user (consent required before membership).
struct GroupPendingInvitationRow: Decodable, Equatable, Identifiable, Sendable {
    let invitation_id: UUID
    let conversation_id: UUID
    let group_title: String
    let inviter_user_id: UUID
    let created_at: String
    let member_count: Int?

    var id: UUID { invitation_id }
}

/// Admin-visible pending invite for Group Info.
struct GroupConversationPendingInviteRow: Decodable, Equatable, Identifiable, Sendable {
    let invitation_id: UUID
    let invitee_user_id: UUID
    let inviter_user_id: UUID
    let created_at: String

    var id: UUID { invitation_id }
}

/// Active membership row used to hydrate Chat Inbox avatar clusters (no RPC change).
struct GroupActiveMemberRow: Decodable, Equatable, Sendable {
    let conversation_id: UUID
    let user_id: UUID
    let joined_at: String
}

/// Pure ordering helper; callable off the MainActor by Chat inbox snapshot preparation.
nonisolated enum GroupInboxAvatarMembership {
    /// Stable display order: other members by `joined_at` then UUID; current user only if alone.
    static func orderedAvatarMemberIds(
        members: [(userId: UUID, joinedAt: String)],
        currentUserId: UUID?
    ) -> [UUID] {
        let sorted = members.sorted { lhs, rhs in
            if lhs.joinedAt != rhs.joinedAt {
                return lhs.joinedAt < rhs.joinedAt
            }
            return lhs.userId.uuidString.lowercased() < rhs.userId.uuidString.lowercased()
        }
        let others: [UUID]
        if let currentUserId {
            others = sorted.map(\.userId).filter { $0 != currentUserId }
        } else {
            others = sorted.map(\.userId)
        }
        if !others.isEmpty {
            return others
        }
        if let currentUserId, sorted.contains(where: { $0.userId == currentUserId }) {
            return [currentUserId]
        }
        return sorted.map(\.userId)
    }
}

/// Structured metadata for `group_messages.system_payload` (membership + pickup edit activity).
struct GroupSystemEventPayload: Codable, Equatable, Sendable {
    let event: String?
    let affected_user_id: UUID?
    let affected_display_name: String?
    let actor_user_id: UUID?
    /// Pickup edit system messages (migration 20260911+).
    let pickup_game_id: UUID?
    let update_event_id: UUID?
    let change_kinds: [String]?
    let summary_lines: [String]?
    let title: String?
    let before_start: String?
    let after_start: String?
    let before_location: String?
    let after_location: String?
    let before_players_needed: Int?
    let after_players_needed: Int?
    let before_status: String?
    let after_status: String?

    var trimmedDisplayName: String? {
        let name = affected_display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }
}

enum GroupSystemEventKind: String, Sendable {
    case groupCreated = "group_created"
    case memberLeft = "member_left"
    case memberJoined = "member_joined"
    case memberRemoved = "member_removed"
    case groupRenamed = "group_renamed"
    case pickupGameUpdated = "pickup_game_updated"

    static func parse(_ raw: String?) -> GroupSystemEventKind? {
        guard let raw, let kind = GroupSystemEventKind(rawValue: raw) else { return nil }
        return kind
    }
}

enum GroupSystemEventFormatting {
    /// Localized timeline / inbox copy for a system row. Never prefixes `You:`.
    static func displayText(
        systemEvent: String?,
        payload: GroupSystemEventPayload?,
        fallbackBody: String,
        languageCode: String? = nil
    ) -> String {
        let kind = GroupSystemEventKind.parse(systemEvent)
            ?? GroupSystemEventKind.parse(payload?.event)
        switch kind {
        case .memberLeft:
            let name = payload?.trimmedDisplayName
                ?? L10n.t("group_chat_system_member_fallback", languageCode: languageCode)
            return String(
                format: L10n.t("group_chat_system_member_left_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode ?? L10n.defaultLanguageCode),
                name
            )
        case .groupCreated:
            let trimmed = fallbackBody.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? L10n.t("group_chat_system_group_created", languageCode: languageCode)
                : trimmed
        case .pickupGameUpdated:
            if let localized = localizedPickupGameUpdatedLines(payload: payload, languageCode: languageCode),
               !localized.isEmpty {
                return localized.joined(separator: "\n")
            }
            if let lines = payload?.summary_lines?.filter({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
               !lines.isEmpty {
                return lines.joined(separator: "\n")
            }
            let trimmed = fallbackBody.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? L10n.t("pickup_edit_chat_headline", languageCode: languageCode)
                : trimmed
        case .memberJoined, .memberRemoved, .groupRenamed, .none:
            let trimmed = fallbackBody.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? L10n.t("group_chat_system_member_fallback", languageCode: languageCode)
                : trimmed
        }
    }

    static func displayText(for message: GroupMessageRow, languageCode: String? = nil) -> String {
        displayText(
            systemEvent: message.system_event,
            payload: message.system_payload,
            fallbackBody: message.body,
            languageCode: languageCode
        )
    }

    /// Pure classification from the wire `message_type` token — safe off the MainActor.
    nonisolated static func isSystemMessage(messageType: String?) -> Bool {
        (messageType ?? "text") == "system"
    }

    /// Rebuild localized chat lines from structured change metadata when present.
    private static func localizedPickupGameUpdatedLines(
        payload: GroupSystemEventPayload?,
        languageCode: String?
    ) -> [String]? {
        guard let payload else { return nil }
        let kinds = (payload.change_kinds ?? []).compactMap {
            PickupGameMeaningfulChangeKind(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        let beforeStatus = (payload.before_status ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let afterStatus = (payload.after_status ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isCancellation = beforeStatus != "removed" && afterStatus == "removed"
        guard !kinds.isEmpty || isCancellation else { return nil }

        let changes = PickupGameMeaningfulChangeSet(
            kinds: isCancellation && !kinds.contains(.status) ? kinds + [.status] : kinds,
            beforeLocationLabel: payload.before_location ?? "",
            afterLocationLabel: payload.after_location ?? "",
            beforeStartRaw: payload.before_start ?? "",
            afterStartRaw: payload.after_start ?? "",
            beforePlayersNeeded: payload.before_players_needed ?? 0,
            afterPlayersNeeded: payload.after_players_needed ?? 0,
            title: payload.title ?? "",
            isCancellation: isCancellation
        )
        return PickupGameMeaningfulChange.chatBodyLines(for: changes, languageCode: languageCode ?? L10n.defaultLanguageCode)
    }
}

struct GroupMessageRow: Decodable, Identifiable, Equatable, Sendable {
    let id: UUID
    let conversation_id: UUID
    let sender_id: UUID
    let body: String
    let message_type: String?
    let system_event: String?
    let system_payload: GroupSystemEventPayload?
    let created_at: String
    let deleted_at: String?
    let report_count: Int?
    let is_deleted: Bool?
    /// Same-conversation parent message id (migration `20260917_0001`). Nil on older rows.
    let reply_to_message_id: UUID?

    var isSystemMessage: Bool {
        GroupSystemEventFormatting.isSystemMessage(messageType: message_type)
    }
}

struct GroupConversationDetailRow: Decodable, Equatable, Sendable {
    let conversation_id: UUID
    let title: String
    let created_by: UUID
    let created_at: String
    let member_user_id: UUID
    let member_role: String
    let member_joined_at: String
    let viewer_is_admin: Bool
    let viewer_is_muted: Bool
    /// Present when this conversation is linked to a pickup game (migration 20260893+).
    let pickup_game_id: UUID?

    var isPickupGameChat: Bool { pickup_game_id != nil }

    /// Copies membership rows with an updated viewer mute flag (same value on every peer row).
    func withViewerMuted(_ muted: Bool) -> GroupConversationDetailRow {
        GroupConversationDetailRow(
            conversation_id: conversation_id,
            title: title,
            created_by: created_by,
            created_at: created_at,
            member_user_id: member_user_id,
            member_role: member_role,
            member_joined_at: member_joined_at,
            viewer_is_admin: viewer_is_admin,
            viewer_is_muted: muted,
            pickup_game_id: pickup_game_id
        )
    }
}

struct GroupMessageInsert: Encodable {
    let conversation_id: UUID
    let sender_id: UUID
    let body: String
    let message_type: String
}

/// Presentation context when opening a group thread as a pickup-game chat (not a social group).
struct PickupGameChatContext: Equatable, Sendable {
    let pickupGameId: UUID
    let title: String
    let sportLabel: String
    let whenLabel: String
    let locationLabel: String?
    let approvedParticipantCount: Int
    /// Authoritative pickup pin when available (for On My Way prefill).
    let latitude: Double?
    let longitude: Double?

    init(
        pickupGameId: UUID,
        title: String,
        sportLabel: String,
        whenLabel: String,
        locationLabel: String?,
        approvedParticipantCount: Int,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.pickupGameId = pickupGameId
        self.title = title
        self.sportLabel = sportLabel
        self.whenLabel = whenLabel
        self.locationLabel = locationLabel
        self.approvedParticipantCount = approvedParticipantCount
        self.latitude = latitude
        self.longitude = longitude
    }

    var headerSubtitle: String {
        var parts: [String] = []
        let sport = sportLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sport.isEmpty { parts.append(sport) }
        let when = whenLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !when.isEmpty { parts.append(when) }
        if approvedParticipantCount > 0 {
            parts.append("\(approvedParticipantCount) approved")
        }
        return parts.joined(separator: " · ")
    }
}
