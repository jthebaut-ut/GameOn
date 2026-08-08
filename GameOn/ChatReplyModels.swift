import Foundation

/// Availability of a referenced parent message for reply UI.
enum ChatReplyAvailability: String, Equatable, Sendable {
    case available
    case unavailable
    case unsent
}

/// Privacy-safe reply presentation resolved from authoritative loaded messages (never client-authored quote text).
struct ChatReplyReference: Equatable, Identifiable, Sendable {
    var id: UUID { originalMessageId }
    let originalMessageId: UUID
    let originalSenderId: UUID?
    let originalSenderDisplayName: String
    let previewLine: String
    let originalMessageKind: FanGeoStructuredChatKind?
    let availability: ChatReplyAvailability

    static func unavailable(originalMessageId: UUID, languageCode: String? = nil) -> ChatReplyReference {
        ChatReplyReference(
            originalMessageId: originalMessageId,
            originalSenderId: nil,
            originalSenderDisplayName: "",
            previewLine: L10n.t("chat_reply_original_unavailable", languageCode: languageCode),
            originalMessageKind: nil,
            availability: .unavailable
        )
    }

    static func unsent(originalMessageId: UUID, languageCode: String? = nil) -> ChatReplyReference {
        ChatReplyReference(
            originalMessageId: originalMessageId,
            originalSenderId: nil,
            originalSenderDisplayName: "",
            previewLine: L10n.t("chat_reply_original_unsent", languageCode: languageCode),
            originalMessageKind: nil,
            availability: .unsent
        )
    }
}

/// Conversation-scoped composer reply target. Cleared on send success, cancel, leave, or account switch.
struct ChatReplyComposerDraft: Equatable, Sendable {
    let conversationId: UUID
    let accountUserId: UUID
    let targetMessageId: UUID
    let targetSenderId: UUID
    let targetSenderDisplayName: String
    let previewLine: String

    func isValid(forConversation conversationId: UUID, accountUserId: UUID?) -> Bool {
        guard let accountUserId else { return false }
        return self.conversationId == conversationId && self.accountUserId == accountUserId
    }
}

/// Shared lookup helpers for resolving reply headers from already-loaded thread rows.
enum ChatReplyResolution {
    /// Last row wins. Never traps on duplicate message IDs.
    static func messageMap<Row: Identifiable>(
        _ rows: [Row]
    ) -> [UUID: Row] where Row.ID == UUID {
        var map: [UUID: Row] = [:]
        map.reserveCapacity(rows.count)
        var duplicateCount = 0
        for row in rows {
            if map[row.id] != nil {
                duplicateCount += 1
            }
            map[row.id] = row
        }
#if DEBUG
        if duplicateCount > 0 {
            print("[ChatReplyResolution] duplicateMessageIDs count=\(duplicateCount) rows=\(rows.count)")
        }
#endif
        return map
    }

    /// Caps how many older pages we pull when jumping to a reply target.
    static let maxOlderPagesWhenSeeking = 8

    static func resolveDirect(
        replyToMessageId: UUID?,
        messagesById: [UUID: DirectMessageRow],
        displayNameForSender: (UUID) -> String,
        languageCode: String? = nil
    ) -> ChatReplyReference? {
        guard let replyToMessageId else { return nil }
        guard let parent = messagesById[replyToMessageId] else {
            return .unavailable(originalMessageId: replyToMessageId, languageCode: languageCode)
        }
        if parent.is_deleted == true || !(parent.deleted_at ?? "").isEmpty {
            return .unsent(originalMessageId: replyToMessageId, languageCode: languageCode)
        }
        let kind = FanGeoStructuredChatKind.recognized(in: parent.body)
        let preview = ChatReplyPreviewFormatting.previewLine(
            body: parent.body,
            messageType: nil,
            languageCode: languageCode
        )
        return ChatReplyReference(
            originalMessageId: parent.id,
            originalSenderId: parent.sender_id,
            originalSenderDisplayName: displayNameForSender(parent.sender_id),
            previewLine: preview,
            originalMessageKind: kind,
            availability: .available
        )
    }

    static func resolveGroup(
        replyToMessageId: UUID?,
        messagesById: [UUID: GroupMessageRow],
        displayNameForSender: (UUID) -> String,
        languageCode: String? = nil
    ) -> ChatReplyReference? {
        guard let replyToMessageId else { return nil }
        guard let parent = messagesById[replyToMessageId] else {
            return .unavailable(originalMessageId: replyToMessageId, languageCode: languageCode)
        }
        if parent.is_deleted == true || !(parent.deleted_at ?? "").isEmpty || parent.isSystemMessage {
            return .unavailable(originalMessageId: replyToMessageId, languageCode: languageCode)
        }
        let kind = FanGeoStructuredChatKind.recognized(in: parent.body)
        let preview = ChatReplyPreviewFormatting.previewLine(
            body: parent.body,
            messageType: parent.message_type,
            languageCode: languageCode
        )
        return ChatReplyReference(
            originalMessageId: parent.id,
            originalSenderId: parent.sender_id,
            originalSenderDisplayName: displayNameForSender(parent.sender_id),
            previewLine: preview,
            originalMessageKind: kind,
            availability: .available
        )
    }
}
