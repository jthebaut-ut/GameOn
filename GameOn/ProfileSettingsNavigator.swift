import Combine
import SwiftUI

/// Path owner for the profile Settings sheet. Lifetime is tied to ``ProfileSettingsSheetHost`` via `@StateObject`.
@MainActor
final class ProfileSettingsNavigator: ObservableObject {
    let instanceId = UUID()
    /// Typed path only — Settings destinations are all ``ProfileSettingsRoute``.
    /// A heterogeneous `NavigationPath` previously allowed Support sub-routes to corrupt this stack.
    @Published var path: [ProfileSettingsRoute] = []

    private var lastRootOpenAt: Date?
    private var lastRootOpenRoute: ProfileSettingsRoute?
    private let rootOpenDebounceSeconds: TimeInterval = 0.45

    init() {
#if DEBUG
        SettingsNavigationDebug.log("navigatorInit instanceId=\(instanceId.uuidString) pathCount=0")
#endif
    }

    deinit {
#if DEBUG
        print("[SettingsNavigationDebug] navigatorDeinit instanceId=\(instanceId.uuidString)")
#endif
    }

    var topRoute: ProfileSettingsRoute? { path.last }

    func pathSummary() -> String {
        if path.isEmpty { return "[]" }
        return "[" + path.map(\.debugName).joined(separator: ",") + "]"
    }

    /// Help → Support (and similar deliberate multi-level pushes).
    func append(_ route: ProfileSettingsRoute, source: String) {
#if DEBUG
        SettingsNavigationDebug.log(
            "rowTapped route=\(route.debugName) source=\(source) pathCountBefore=\(path.count) top=\(topRoute?.debugName ?? "nil") path=\(pathSummary()) navigatorId=\(instanceId.uuidString)"
        )
#endif
        path.append(route)
#if DEBUG
        SettingsNavigationDebug.log(
            "routeAfterAppend route=\(route.debugName) pathCountAfter=\(path.count) path=\(pathSummary()) navigatorId=\(instanceId.uuidString)"
        )
#endif
    }

    /// Settings root rows: single-depth push from Settings home.
    /// Expects `pathCountBefore == 0` when the Settings root is visible.
    func openRootDestination(_ route: ProfileSettingsRoute, source: String) {
        let now = Date()
        if let lastRootOpenRoute,
           lastRootOpenRoute == route,
           let lastRootOpenAt,
           now.timeIntervalSince(lastRootOpenAt) < rootOpenDebounceSeconds {
#if DEBUG
            SettingsNavigationDebug.log(
                "rootRowTapIgnoredDuplicate route=\(route.debugName) source=\(source) pathCount=\(path.count)"
            )
#endif
            return
        }

#if DEBUG
        SettingsNavigationDebug.log(
            "rootRowTapped route=\(route.debugName) source=\(source) pathCountBefore=\(path.count) top=\(topRoute?.debugName ?? "nil") path=\(pathSummary()) navigatorId=\(instanceId.uuidString)"
        )
        if path.count != 0 {
            SettingsNavigationDebug.log(
                "pathDesyncDetected route=\(topRoute?.debugName ?? "nil") pathCount=\(path.count) source=rootRowWhilePathNonEmpty intended=\(route.debugName)"
            )
        }
#endif

        if !path.isEmpty {
            reconcileStaleTopRoutes(source: "rootRowTap:\(source)", keepingParentDepth: 0)
        }

        path.append(route)
        lastRootOpenAt = now
        lastRootOpenRoute = route
#if DEBUG
        SettingsNavigationDebug.log(
            "routeAfterRootOpen route=\(route.debugName) pathCountAfter=\(path.count) path=\(pathSummary()) navigatorId=\(instanceId.uuidString)"
        )
#endif
    }

    /// Removes only trailing stale routes down to `keepingParentDepth`. Never used as the primary navigation fix.
    func reconcileStaleTopRoutes(source: String, keepingParentDepth: Int) {
        guard path.count > keepingParentDepth else { return }
#if DEBUG
        SettingsNavigationDebug.log(
            "pathReconcileBegin source=\(source) pathCount=\(path.count) keepDepth=\(keepingParentDepth) path=\(pathSummary())"
        )
#endif
        while path.count > keepingParentDepth {
            let removed = path.removeLast()
#if DEBUG
            SettingsNavigationDebug.log(
                "pathReconcileRemoved route=\(removed.debugName) pathCount=\(path.count) source=\(source)"
            )
#endif
        }
#if DEBUG
        SettingsNavigationDebug.log(
            "pathReconcileEnd source=\(source) pathCount=\(path.count) path=\(pathSummary())"
        )
#endif
    }

    /// Guard: destination UI disappeared while this route remains the typed path top.
    func noteDestinationDisappearedWhileStillTop(_ route: ProfileSettingsRoute, source: String) {
#if DEBUG
        SettingsNavigationDebug.log(
            "pathDesyncDetected route=\(route.debugName) pathCount=\(path.count) source=\(source) path=\(pathSummary())"
        )
#endif
        guard path.last == route else { return }
        reconcileStaleTopRoutes(source: source, keepingParentDepth: max(path.count - 1, 0))
    }

    func reset(reason: String) {
#if DEBUG
        SettingsNavigationDebug.log(
            "routeReset reason=\(reason) priorPathCount=\(path.count) path=\(pathSummary()) navigatorId=\(instanceId.uuidString)"
        )
#endif
        path = []
    }
}

/// Settings row that pushes via the host-owned navigator (never via `SettingsScreen` path state).
struct ProfileSettingsRouteButton<Label: View>: View {
    @EnvironmentObject private var navigator: ProfileSettingsNavigator
    let route: ProfileSettingsRoute
    let source: String
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button {
            navigator.openRootDestination(route, source: source)
        } label: {
            label()
        }
        .buttonStyle(.plain)
    }
}

struct ProfileSettingsHelpDestination: View {
    @EnvironmentObject private var navigator: ProfileSettingsNavigator
    var accountUserId: UUID?

    var body: some View {
        HelpAndTutorialView(
            onContactSupport: {
                navigator.append(.support, source: "helpContactSupport")
            },
            accountUserId: accountUserId
        )
    }
}

struct ProfileSettingsPrivacyRefreshKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

extension EnvironmentValues {
    var profileSettingsPrivacyRefreshToken: Int {
        get { self[ProfileSettingsPrivacyRefreshKey.self] }
        set { self[ProfileSettingsPrivacyRefreshKey.self] = newValue }
    }
}
