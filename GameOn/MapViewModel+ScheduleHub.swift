import Foundation

extension MapViewModel {
    /// Request Schedule hub surface (Live / Watch / Play / Pro).
    /// Sets pending for ScheduleHubView consumption and mirrors calendar filters when applicable.
    @MainActor
    func requestScheduleHubSurface(_ surface: ScheduleHubSurface) {
        var resolved = surface
        let isBusiness = currentUserIsBusinessAccount
            || isVenueOwnerLoggedIn
            || hasAuthenticatedVenueOwnerSession
        if isBusiness, resolved == .play {
            resolved = .watch
        }
        scheduleHubSurface = resolved
        pendingScheduleHubSurface = resolved
        if let filter = resolved.calendarFilter {
            if isBusiness, filter == .pickupGames {
                calendarTabGameFilter = .venueGames
            } else {
                calendarTabGameFilter = filter
            }
        }
    }

    /// Route to the Going root tab (`AppTab.following`). Not a Schedule surface.
    @MainActor
    func requestGoingRootTab() {
        requestedMainTabRaw = MainTabView.AppTab.following.rawValue
    }
}
