import Foundation

/// Shared inbox conversation-preview formatting for direct and business chats.
enum ChatInboxPreviewFormatting {
    /// Builds the subtitle shown under a conversation name in Recent conversations.
    /// - Parameters:
    ///   - body: Raw last-message body (may be a profile-share payload).
    ///   - isFromCurrentUser: When true, prefixes with a localized "You:" marker.
    ///   - isSystemEvent: When true, never prefixes `You:` (membership / system activity).
    static func previewLine(
        body: String?,
        isFromCurrentUser: Bool,
        languageCode: String? = nil,
        isSystemEvent: Bool = false
    ) -> String {
        let trimmed = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayBody: String
        if trimmed.isEmpty {
            displayBody = ""
        } else {
            displayBody = FanProfileShareMessage.inboxPreview(from: trimmed) ?? trimmed
        }

        let cleaned = displayBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            return L10n.t("chat_preview_empty", languageCode: languageCode)
        }
        if isSystemEvent {
            return cleaned
        }
        if isFromCurrentUser {
            let you = L10n.t("chat_preview_you_prefix", languageCode: languageCode)
            return "\(you): \(cleaned)"
        }
        return cleaned
    }

    /// Fallback when a row has no subtitle stored (edge / legacy).
    static func emptyConversationPlaceholder(languageCode: String? = nil) -> String {
        L10n.t("chat_preview_start_conversation", languageCode: languageCode)
    }
}

/// Locale-aware inbox list timestamps (not thread bubble grouping).
enum ChatInboxTimestampFormatting {
    private static let shortTime: DateFormatter = {
        let df = DateFormatter()
        df.locale = .autoupdatingCurrent
        df.timeStyle = .short
        df.dateStyle = .none
        return df
    }()

    private static let monthDay: DateFormatter = {
        let df = DateFormatter()
        df.locale = .autoupdatingCurrent
        df.setLocalizedDateFormatFromTemplate("MMM d")
        return df
    }()

    /// Today → short time; yesterday → localized "Yesterday"; else → localized month + day.
    static func label(for date: Date?, languageCode: String? = nil) -> String {
        guard let date else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return shortTime.string(from: date)
        }
        if cal.isDateInYesterday(date) {
            return L10n.t("chat_inbox_yesterday", languageCode: languageCode)
        }
        return monthDay.string(from: date)
    }
}
