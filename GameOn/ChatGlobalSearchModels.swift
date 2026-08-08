import Foundation

enum ChatGlobalSearchConversationKind: String, Codable, Sendable {
    case direct
    case business
    case group
    case pickup

    var inboxKind: ChatInboxConversationKind {
        switch self {
        case .direct: return .direct
        case .business: return .business
        case .group, .pickup: return .group
        }
    }

    func matches(filter: ChatInboxTypeFilter) -> Bool {
        switch filter {
        case .all, .unread:
            return true
        case .fans:
            return self == .direct
        case .businesses:
            return self == .business
        case .groups:
            return self == .group
        case .pickup:
            return self == .pickup
        }
    }
}

struct ChatGlobalSearchConversationHit: Identifiable, Hashable, Sendable {
    var id: UUID { conversationId }
    let conversationId: UUID
    let kind: ChatGlobalSearchConversationKind
    let title: String
    let subtitle: String
    let peerUserId: UUID?
    let pickupGameId: UUID?
    let avatarURL: String?
    let avatarThumbnailURL: String?
    let unreadCount: Int
    let lastMessageAt: Date?
    /// When true, prefer opening the matching local FriendDisplay row for richer UI.
    let matchedInboxFriend: ChatViewModel.FriendDisplay?
}

struct ChatGlobalSearchMessageHit: Identifiable, Hashable, Sendable {
    var id: UUID { messageId }
    let messageId: UUID
    let conversationId: UUID
    let kind: ChatGlobalSearchConversationKind
    let conversationTitle: String
    let peerUserId: UUID?
    let pickupGameId: UUID?
    let senderId: UUID
    let createdAt: Date?
    let safePreview: String
}

struct ChatGlobalSearchSnapshot: Equatable, Sendable {
    var query: String = ""
    var conversations: [ChatGlobalSearchConversationHit] = []
    var messages: [ChatGlobalSearchMessageHit] = []
    var isSearching: Bool = false
    var didSearch: Bool = false

    var isEmpty: Bool { conversations.isEmpty && messages.isEmpty }
}

enum ChatGlobalSearchLocalMatcher {
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
    }

    static func conversationHits(
        from inbox: [ChatViewModel.FriendDisplay],
        query: String,
        filter: ChatInboxTypeFilter
    ) -> [ChatGlobalSearchConversationHit] {
        let q = normalize(query)
        guard q.count >= 2 else { return [] }
        let scoped = ChatInboxTypeFilter.filtered(inbox, by: filter)
        return scoped.compactMap { row in
            guard matchesConversation(row, query: q) else { return nil }
            let kind: ChatGlobalSearchConversationKind
            if row.isPickupGameChat {
                kind = .pickup
            } else {
                switch row.inboxKind {
                case .direct: kind = .direct
                case .business: kind = .business
                case .group: kind = .group
                }
            }
            let conversationId = row.conversationId ?? row.id
            return ChatGlobalSearchConversationHit(
                conversationId: conversationId,
                kind: kind,
                title: row.preview.displayName,
                subtitle: row.preview.username.map { "@\($0)" } ?? (row.subtitle ?? ""),
                peerUserId: row.isGroupConversation ? nil : row.preview.id,
                pickupGameId: row.pickupGameId,
                avatarURL: row.preview.avatarURL,
                avatarThumbnailURL: row.preview.avatarThumbnailURL,
                unreadCount: row.unreadCount,
                lastMessageAt: row.lastMessageAt,
                matchedInboxFriend: row
            )
        }
    }

    private static func matchesConversation(_ row: ChatViewModel.FriendDisplay, query: String) -> Bool {
        let name = normalize(row.preview.displayName)
        let username = normalize(row.preview.username ?? "")
        let subtitle = normalize(row.subtitle ?? "")
        return name.contains(query) || username.contains(query) || subtitle.contains(query)
    }
}
