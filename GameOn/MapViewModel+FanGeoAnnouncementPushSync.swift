import Combine
import Foundation

extension MapViewModel {
    @MainActor
    func setFanGeoAnnouncementNotificationsEnabled(_ enabled: Bool) async {
        notificationSettingsStore.fanGeoAnnouncementNotificationsEnabled = enabled
        objectWillChange.send()
        applyDiscoverBannerSelectionFromCache()
        await syncProGameFinalScorePreferenceToBackend(reason: "announcementNotificationsToggle")
    }
}
