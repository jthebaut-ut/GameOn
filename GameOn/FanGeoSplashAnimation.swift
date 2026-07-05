import SwiftUI

/// Timing for the static launch/loading screen visibility (isolated from bootstrap logic).
enum FanGeoSplashAnimation {
    static let minimumVisibleDuration: TimeInterval = 1.2
    static let statusCrossfadeDuration: TimeInterval = 0.28
}

/// User-facing splash copy mapped to existing critical bootstrap stages.
enum FanGeoSplashBootstrapStage: String, Equatable {
    case preparing = "Preparing FanGeo..."
    case loadingFavorites = "Loading your favorites..."
    case findingNearbyVenues = "Finding nearby venues..."
    case checkingLiveGames = "Checking live games..."
    case almostReady = "Almost ready..."

    var message: String { rawValue }
}
