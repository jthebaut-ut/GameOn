import Foundation

/// Presentation-only Chat inbox conversation-type filter.
/// Classification uses existing inbox metadata only
/// (`inboxKind` + `pickupGameId` + `fanTeamId` + `unreadCount`).
enum ChatInboxTypeFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case unread
    case fans
    case teams
    case businesses
    case groups
    case pickup

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .all: return "globe"
        case .unread: return "envelope.badge"
        case .fans: return "person.fill"
        case .teams: return "shield.fill"
        case .businesses: return "building.2.fill"
        case .groups: return "person.3.fill"
        case .pickup: return "figure.run"
        }
    }

    func title(languageCode: String) -> String {
        switch self {
        case .all:
            return L10n.t("chat_inbox_filter_all", languageCode: languageCode)
        case .unread:
            return L10n.t("chat_inbox_filter_unread", languageCode: languageCode)
        case .fans:
            return L10n.t("chat_inbox_filter_fans", languageCode: languageCode)
        case .teams:
            return L10n.t("chat_inbox_filter_teams", languageCode: languageCode)
        case .businesses:
            return L10n.t("chat_inbox_filter_businesses", languageCode: languageCode)
        case .groups:
            return L10n.t("chat_inbox_filter_groups", languageCode: languageCode)
        case .pickup:
            return L10n.t("chat_inbox_filter_pickup", languageCode: languageCode)
        }
    }

    func emptyTitle(languageCode: String) -> String {
        switch self {
        case .all:
            return L10n.t("chat_empty_title", languageCode: languageCode)
        case .unread:
            return L10n.t("chat_inbox_filter_empty_unread", languageCode: languageCode)
        case .fans:
            return L10n.t("chat_inbox_filter_empty_fans", languageCode: languageCode)
        case .teams:
            return L10n.t("chat_inbox_filter_empty_teams", languageCode: languageCode)
        case .businesses:
            return L10n.t("chat_inbox_filter_empty_businesses", languageCode: languageCode)
        case .groups:
            return L10n.t("chat_inbox_filter_empty_groups", languageCode: languageCode)
        case .pickup:
            return L10n.t("chat_inbox_filter_empty_pickup", languageCode: languageCode)
        }
    }

    func matches(_ conversation: ChatViewModel.FriendDisplay) -> Bool {
        switch self {
        case .all:
            return true
        case .unread:
            // Authoritative per-conversation unread from inbox summaries / read state.
            return conversation.unreadCount > 0
        case .fans:
            return conversation.inboxKind == .direct && !conversation.isPickupGameChat
        case .teams:
            return conversation.isFanTeamChat
        case .businesses:
            return conversation.inboxKind == .business
        case .groups:
            return conversation.inboxKind == .group
                && !conversation.isPickupGameChat
                && !conversation.isFanTeamChat
        case .pickup:
            return conversation.isPickupGameChat
        }
    }

    static func filtered(
        _ conversations: [ChatViewModel.FriendDisplay],
        by filter: ChatInboxTypeFilter
    ) -> [ChatViewModel.FriendDisplay] {
        guard filter != .all else { return conversations }
        return conversations.filter { filter.matches($0) }
    }

    /// Live category totals from the already-loaded inbox (independent of the selected chip).
    /// `unread` counts conversations with `unreadCount > 0` (not summed message totals).
    static func counts(
        from conversations: [ChatViewModel.FriendDisplay]
    ) -> [ChatInboxTypeFilter: Int] {
        var counts: [ChatInboxTypeFilter: Int] = [
            .all: conversations.count,
            .unread: 0,
            .fans: 0,
            .teams: 0,
            .businesses: 0,
            .groups: 0,
            .pickup: 0
        ]
        for conversation in conversations {
            if conversation.unreadCount > 0 {
                counts[.unread, default: 0] += 1
            }
            if conversation.isPickupGameChat {
                counts[.pickup, default: 0] += 1
            } else if conversation.isFanTeamChat {
                counts[.teams, default: 0] += 1
            } else {
                switch conversation.inboxKind {
                case .direct:
                    counts[.fans, default: 0] += 1
                case .business:
                    counts[.businesses, default: 0] += 1
                case .group:
                    counts[.groups, default: 0] += 1
                }
            }
        }
        return counts
    }
}
