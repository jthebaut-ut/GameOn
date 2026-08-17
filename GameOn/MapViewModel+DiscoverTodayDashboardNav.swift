import Foundation

/// Typed Discover Activity Panel destinations — tab switch + lightweight focus only.
enum DiscoverTodayDashboardNavIntent: Equatable {
    /// Going → Venue Games, scoped to local calendar today.
    case goingVenueGamesToday
    /// Going → Pickup Games, scoped to local calendar today.
    case goingPickupGamesToday
    /// Going → Venue Games, all upcoming plans.
    case goingVenueGamesUpcoming
    /// Going → Pickup Games, all upcoming plans.
    case goingPickupGamesUpcoming
    /// Account / Profile → Suggested Fans section.
    case accountSuggestedFans
    /// Chat → Chats subtab (Fans Live Now remains at top when eligible).
    case chatFansLiveNow
}

extension MapViewModel {
    @MainActor
    func enqueueDiscoverTodayDashboardNav(_ intent: DiscoverTodayDashboardNavIntent) {
        // One tap → one transition; ignore duplicate rapid enqueues of the same intent.
        guard pendingDiscoverTodayDashboardNav != intent else { return }
        pendingDiscoverTodayDashboardNav = intent
        switch intent {
        case .goingVenueGamesToday, .goingPickupGamesToday,
             .goingVenueGamesUpcoming, .goingPickupGamesUpcoming:
            requestGoingRootTab()
        case .accountSuggestedFans:
            requestedMainTabRaw = MainTabView.AppTab.account.rawValue
        case .chatFansLiveNow:
            requestedMainTabRaw = MainTabView.AppTab.chat.rawValue
        }
#if DEBUG
        print("[DiscoverTodayDashboard] enqueue intent=\(intent)")
#endif
    }

    @MainActor
    func clearPendingDiscoverTodayDashboardNav() {
        pendingDiscoverTodayDashboardNav = nil
    }
}
