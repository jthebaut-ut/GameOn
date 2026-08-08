import Foundation

/// Central privacy-safe reply preview formatting for DM + group/pickup chats.
///
/// Never returns raw JSON, coordinates, addresses, UUIDs, poll voter identity, or moderation snapshots.
enum ChatReplyPreviewFormatting {
    /// One-line preview for composer banner and quoted reply headers.
    static func previewLine(
        body: String,
        messageType: String? = nil,
        languageCode: String? = nil
    ) -> String {
        if GroupSystemEventFormatting.isSystemMessage(messageType: messageType) {
            return L10n.t("chat_reply_original_unavailable", languageCode: languageCode)
        }

        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return L10n.t("chat_reply_original_unavailable", languageCode: languageCode)
        }

        if let kind = FanGeoStructuredChatKind.recognized(in: trimmed) {
            return structuredPreview(kind: kind, body: trimmed, languageCode: languageCode)
        }

        return collapseToSingleLine(trimmed, maxChars: 120)
    }

    static func structuredPreview(
        kind: FanGeoStructuredChatKind,
        body: String,
        languageCode: String? = nil
    ) -> String {
        switch kind {
        case .locationShare:
            return L10n.t("chat_reply_preview_shared_location", languageCode: languageCode)
        case .liveLocation:
            return L10n.t("chat_reply_preview_live_location", languageCode: languageCode)
        case .onMyWay:
            if let payload = ChatOnMyWayMessage.decode(from: body), payload.isArrived {
                return L10n.t("chat_reply_preview_arrived", languageCode: languageCode)
            }
            return L10n.t("chat_reply_preview_on_my_way", languageCode: languageCode)
        case .poll:
            return L10n.t("chat_reply_preview_poll", languageCode: languageCode)
        case .profileShare:
            return L10n.t("chat_reply_preview_profile", languageCode: languageCode)
        case .pickupShare:
            return L10n.t("chat_reply_preview_pickup", languageCode: languageCode)
        case .proShare:
            return L10n.t("chat_reply_preview_pro_game", languageCode: languageCode)
        case .venueShare:
            return L10n.t("chat_reply_preview_venue", languageCode: languageCode)
        }
    }

    static func collapseToSingleLine(_ text: String, maxChars: Int) -> String {
        let flattened = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let compacted = flattened
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard compacted.count > maxChars else { return compacted }
        let end = compacted.index(compacted.startIndex, offsetBy: max(0, maxChars - 1))
        return String(compacted[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// Whether Reply should appear in the message context menu.
    static func isReplyEligible(
        body: String,
        messageType: String?,
        isDeleted: Bool?,
        deletedAt: String?
    ) -> Bool {
        if isDeleted == true { return false }
        if let deletedAt, !deletedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if GroupSystemEventFormatting.isSystemMessage(messageType: messageType) {
            return false
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }
}
