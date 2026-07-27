import Foundation

/// DEBUG-only searchable counterpart tracing (`===== CHAT COUNTERPART =====`).
enum ChatCounterpartDebug {
    static func log(_ message: String) {
#if DEBUG
        print("===== CHAT COUNTERPART ===== \(message)")
#endif
    }
}

/// Shared direct-message counterpart presentation rules.
/// Inbox rows and open-thread headers must use the same resolution.
enum ChatDMCounterpartResolution {
    enum SessionContext: String {
        case fan
        case business
    }

    enum CounterpartType: String {
        case fan
        case business
        case unknown
    }

    /// True when the authenticated chat session is operating as a business/venue owner.
    static func isBusinessSession(mapViewModel: MapViewModel?) -> Bool {
        guard let mapViewModel else { return false }
        return mapViewModel.currentUserIsBusinessAccount
            || mapViewModel.isVenueOwnerLoggedIn
            || mapViewModel.hasAuthenticatedVenueOwnerSession
    }

    static func sessionContext(mapViewModel: MapViewModel?) -> SessionContext {
        isBusinessSession(mapViewModel: mapViewModel) ? .business : .fan
    }

    /// Venue-scoped DM rows should present as a business/venue peer only for fan viewers.
    /// Business owners always see the fan counterpart (`friend_user_id`), never themselves.
    static func shouldPresentAsBusinessVenuePeer(
        venueId: UUID?,
        friendIsBusiness: Bool?,
        mapViewModel: MapViewModel?
    ) -> Bool {
        guard venueId != nil else { return false }
        if isBusinessSession(mapViewModel: mapViewModel) {
            return false
        }
        // Fan viewer of a venue thread: treat as business peer unless RPC explicitly says otherwise.
        return friendIsBusiness != false
    }

    static func shouldPresentAsBusinessVenuePeer(
        row: DmInboxSummaryRow,
        mapViewModel: MapViewModel?
    ) -> Bool {
        shouldPresentAsBusinessVenuePeer(
            venueId: row.venue_id,
            friendIsBusiness: row.friend_is_business,
            mapViewModel: mapViewModel
        )
    }
}
