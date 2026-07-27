import SwiftUI

/// Timing for the static launch/loading screen visibility (isolated from bootstrap logic).
enum FanGeoSplashAnimation {
    static let minimumVisibleDuration: TimeInterval = 1.2
    static let statusCrossfadeDuration: TimeInterval = 0.28
}

/// User-facing splash copy mapped to existing critical bootstrap stages.
enum FanGeoSplashBootstrapStage: String, Equatable {
    case preparing = "Preparing FanGeo..."
    case signingYouIn = "Signing you in…"
    case loadingFavorites = "Loading your favorites..."
    case loadingProfile = "Loading your profile…"
    case findingNearbyVenues = "Finding nearby venues..."
    case checkingLiveGames = "Checking live games..."
    case checkingAgeEligibility = "Checking age eligibility…"
    case gettingFanGeoReady = "Getting FanGeo ready…"
    case almostReady = "Almost ready..."

    var message: String { rawValue }
}

/// Debounces splash status so sub-perceptual phases do not flash.
@MainActor
enum FanGeoSplashStatusPresentation {
    /// Minimum time a status line should remain visible before replacement (ms).
    static let minimumVisibleMs: Int = 280
    /// Delay before showing the age-eligibility status when resolution is still in flight (ms).
    static let ageStatusRevealDelayMs: Int = 180
}

