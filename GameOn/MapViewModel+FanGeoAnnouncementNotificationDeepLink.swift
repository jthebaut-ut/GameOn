import Foundation

extension MapViewModel {
    @MainActor
    func enqueueFanGeoAnnouncementNotificationDeepLink(announcementID: UUID) {
        focusedDiscoverAnnouncementId = announcementID
        focusedDiscoverAnnouncementDisplayed = false
        requestedMainTabRaw = "discover"
        applyDiscoverBannerSelectionFromCache()
#if DEBUG
        print(
            "[AnnouncementDeepLink] focused announcementId=\(announcementID.uuidString.lowercased()) " +
            "visibleCount=\(discoverBannerAnnouncements.count)"
        )
#endif
    }
}
