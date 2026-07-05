import SwiftUI
import UIKit

/// When false, ad UIKit hosts must not intercept touches (preserved off-screen tab).
private struct HostTabAdInteractionEnabledKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

extension EnvironmentValues {
    var hostTabAdInteractionEnabled: Bool {
        get { self[HostTabAdInteractionEnabledKey.self] }
        set { self[HostTabAdInteractionEnabledKey.self] = newValue }
    }
}

enum AdHitTestSafety {
    static func allowsInteraction(
        adLoaded: Bool,
        hostTabRaw: String,
        hostTabAdInteractionEnabled: Bool
    ) -> Bool {
        adLoaded
            && hostTabAdInteractionEnabled
            && !AdDebugContext.isTabOffscreenPreserved(tabRaw: hostTabRaw)
    }

    static func syncUIViewInteraction(
        _ view: UIView?,
        enabled: Bool,
        placement: String,
        logFrameWhenEnabled: Bool = true
    ) {
        guard let view else { return }
        view.isUserInteractionEnabled = enabled
        if enabled, logFrameWhenEnabled {
            let frame = view.convert(view.bounds, to: view.window)
            print("[AdHitTestDebug] visibleFrame placement=\(placement) frame=\(frame.debugDescription)")
        } else if !enabled {
            print("[AdHitTestDebug] disabled reason=hiddenOrOffscreen placement=\(placement)")
        }
    }
}
