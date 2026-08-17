import Foundation

/// Testable FanGeo Inbox chrome. Visual only — no new tabs, filters, or compose.
enum FanGeoInboxChrome {
    static let envelopeSymbol = "envelope.fill"
    static let notificationsSymbol = "bell.fill"
    static let actionNeededSymbol = "checklist"
    /// Legacy overflow symbol. Clear All is a visible header control, not this menu.
    static let cardMenuSymbol = "ellipsis"
    static let usesVisibleHeaderClearAll = true
    static let usesOverflowClearAllMenu = false
    /// Existing Clear All clears currently visible Notifications and Action Needed.
    static let clearAllClearsNotificationsOnly = false
    static let clearAllClearsActionNeeded = true
    /// Per-card one-tap dismiss. No menu, no confirmation.
    static let cardDismissSymbol = "xmark"
    static let composeSymbol = "square.and.pencil"
    static let usesPerCardDismissMenu = false
    static let requiresSingleItemDismissConfirmation = false
    static let clearAllRequiresConfirmation = true
    static let cardDismissConsumesTap = true
    static let cardDismissAccessibilityKey = "action_center_dismiss_item_a11y"

    static let envelopeTileSize: CGFloat = 52
    static let teamEventLeadingSize: CGFloat = 52
    static let compactLeadingSize: CGFloat = 40
    static let standardLeadingSize: CGFloat = 44
    static let unreadDotSize: CGFloat = 8
    static let cardCornerRadius: CGFloat = 20
    static let playerRowAvatarSize: CGFloat = 22

    /// Visual tab order from the Inbox redesign. Does not change `CaseIterable` / default selection.
    static let tabOrder: [FanGeoActionCenterListSection] = [.notifications, .actionNeeded]

    static let forbiddenToolbarTitles = ["Filter", "Unread", "Search", "Newest"]
    static let showsFilterToolbar = false
    static let showsUnreadFilter = false
    static let showsSearch = false
    static let showsNewestSort = false
    static let showsComposeButton = false
    static let showsMockupBottomTabBar = false

    static func notificationsTabCount(unreadCount: Int) -> Int {
        max(0, unreadCount)
    }

    static func actionNeededTabCount(items: [FanGeoActionItem]) -> Int {
        items.reduce(0) { $0 + $1.count }
    }

    /// Envelope badge = Notifications tab + Action Needed tab. Not a third independent count.
    static func envelopeBadgeCount(notificationsCount: Int, actionNeededCount: Int) -> Int {
        max(0, notificationsCount) + max(0, actionNeededCount)
    }

    static func showsEnvelopeBadge(totalCount: Int) -> Bool {
        totalCount > 0
    }

    static func showsEnvelopeUnreadBadge(unreadCount: Int) -> Bool {
        showsEnvelopeBadge(totalCount: unreadCount)
    }

    static func showsClearAllControl(
        notificationItemCount: Int,
        actionNeededItemCount: Int = 0,
        canClear: Bool = true
    ) -> Bool {
        canClear
            && usesVisibleHeaderClearAll
            && (notificationItemCount > 0 || actionNeededItemCount > 0)
    }

    static func tabSystemImage(for section: FanGeoActionCenterListSection) -> String {
        switch section {
        case .notifications: return notificationsSymbol
        case .actionNeeded: return actionNeededSymbol
        }
    }

    static let usesLazyNotificationList = true
    static let notificationListDisablesAnimations = true

    static func playerAvatarRefreshToken(for item: FanGeoActionItem) -> UUID {
        UserAvatarView.stableRefreshToken(
            userId: item.context.managedPlayerId
                ?? item.context.requesterUserId
                ?? UserAvatarView.placeholderRefreshToken,
            thumbnailURL: item.context.personAvatarThumbnailURL,
            avatarURL: item.context.personAvatarURL
        )
    }

    static func leadingArtworkSize(hasTeamEventNotice: Bool, isCompactInformational: Bool) -> CGFloat {
        if hasTeamEventNotice { return teamEventLeadingSize }
        if isCompactInformational { return compactLeadingSize }
        return standardLeadingSize
    }

    static func headerAccessibilityLabel(
        inboxCount: Int,
        languageCode: String
    ) -> String {
        var parts = [
            L10n.t("action_center_title", languageCode: languageCode),
            L10n.t("action_center_subtitle", languageCode: languageCode)
        ]
        if inboxCount > 0 {
            parts.append(
                String(
                    format: L10n.t(
                        "action_center_inbox_total_count_a11y_format",
                        languageCode: languageCode
                    ),
                    locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
                    Int64(inboxCount)
                )
            )
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ". ")
    }

    static func cardAccessibilityLabel(
        for item: FanGeoActionItem,
        isUnread: Bool,
        languageCode: String
    ) -> String {
        var parts = [item.accessibilitySummary(languageCode: languageCode)]
        if isUnread {
            parts.append(L10n.t("action_center_unread_a11y", languageCode: languageCode))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ". ")
    }
}
