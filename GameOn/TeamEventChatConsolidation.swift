import Foundation

/// Presentation rules for consolidating Team-linked event chats into the single Team Chat.
///
/// Standalone pickup games keep their own `pickup_game_id` conversation.
/// Team-linked games must never surface a second inbox row.
enum TeamEventChatConsolidation {
    /// Inbox rows with a pickup id that is known Team-linked should be hidden
    /// (defense in depth when SQL `get_group_inbox_summaries` filter is not yet applied).
    static func shouldShowInGroupInbox(
        pickupGameId: UUID?,
        teamLinkedPickupGameIds: Set<UUID>
    ) -> Bool {
        guard let pickupGameId else { return true }
        return !teamLinkedPickupGameIds.contains(pickupGameId)
    }

    /// True when open/ensure should target Team Chat instead of creating a pickup chat.
    static func shouldOpenTeamChatInsteadOfPickupChat(isTeamLinked: Bool) -> Bool {
        isTeamLinked
    }
}

#if DEBUG
enum TeamEventChatConsolidationSelfTests {
    static func run() {
        let linked = UUID()
        let standalone = UUID()
        let set: Set<UUID> = [linked]
        assert(
            TeamEventChatConsolidation.shouldShowInGroupInbox(
                pickupGameId: nil,
                teamLinkedPickupGameIds: set
            ),
            "Team Chat (no pickup id) stays visible"
        )
        assert(
            !TeamEventChatConsolidation.shouldShowInGroupInbox(
                pickupGameId: linked,
                teamLinkedPickupGameIds: set
            ),
            "Team-linked pickup chat hidden"
        )
        assert(
            TeamEventChatConsolidation.shouldShowInGroupInbox(
                pickupGameId: standalone,
                teamLinkedPickupGameIds: set
            ),
            "Standalone pickup chat remains"
        )
        assert(
            TeamEventChatConsolidation.shouldOpenTeamChatInsteadOfPickupChat(isTeamLinked: true)
        )
        assert(
            !TeamEventChatConsolidation.shouldOpenTeamChatInsteadOfPickupChat(isTeamLinked: false)
        )
    }
}
#endif
