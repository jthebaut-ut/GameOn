import SwiftUI

/// Shared Action Center presentation values injected by ``MainTabView``.
///
/// Root headers read this via ``FanGeoActionCenterHeaderButton`` so the bell
/// participates in real layout (never a global floating overlay).
struct FanGeoActionCenterChromeValue {
    var isAvailable: Bool
    var badgeCount: Int
    var languageCode: String
    var open: () -> Void

    static let unavailable = FanGeoActionCenterChromeValue(
        isAvailable: false,
        badgeCount: 0,
        languageCode: L10n.defaultLanguageCode,
        open: {}
    )
}

private struct FanGeoActionCenterChromeKey: EnvironmentKey {
    static let defaultValue = FanGeoActionCenterChromeValue.unavailable
}

extension EnvironmentValues {
    var fanGeoActionCenterChrome: FanGeoActionCenterChromeValue {
        get { self[FanGeoActionCenterChromeKey.self] }
        set { self[FanGeoActionCenterChromeKey.self] = newValue }
    }
}

/// Trailing header action for Action Center — reserved layout slot, not an overlay.
struct FanGeoActionCenterHeaderButton: View {
    @Environment(\.fanGeoActionCenterChrome) private var chrome

    var body: some View {
        if chrome.isAvailable {
            FanGeoActionCenterBellButton(
                badgeCount: chrome.badgeCount,
                languageCode: chrome.languageCode,
                action: chrome.open
            )
        }
    }
}
