import Foundation

/// Fresh-process launch routing. SceneStorage may still hold the last tab from a
/// previous process; that value must not win over Discover → Map unless an
/// explicit deep link / notification already selected another tab.
enum FanGeoFreshLaunchRouting {
    static let discoverTabRawValue = "discover"
    static let mapPresentation = "map"

    /// Ordinary cold launch (no explicit external destination).
    static func freshLaunchTabRawValue(hasExplicitDeepLinkOverride: Bool) -> String {
        hasExplicitDeepLinkOverride ? "" : discoverTabRawValue
    }

    /// SceneStorage / scene-restore writes that do not match the last tab we
    /// committed (user tap, deep link, or startup force) are stale and must revert.
    static func shouldRevertStaleSceneRestore(
        restoredRaw: String,
        committedRaw: String
    ) -> Bool {
        restoredRaw != committedRaw
    }

    static func tabAfterTerminateAndRelaunch(
        tabAtTermination: String,
        hasExplicitDeepLinkOverride: Bool,
        deepLinkTabRaw: String? = nil
    ) -> String {
        if hasExplicitDeepLinkOverride, let deepLinkTabRaw, !deepLinkTabRaw.isEmpty {
            return deepLinkTabRaw
        }
        _ = tabAtTermination
        return discoverTabRawValue
    }

    static func preservesTabAcrossBackgroundForeground(
        selectedBefore: String,
        selectedAfterSameProcess: String
    ) -> Bool {
        selectedBefore == selectedAfterSameProcess
    }
}
