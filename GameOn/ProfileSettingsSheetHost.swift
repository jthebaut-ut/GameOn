import SwiftUI


/// Owns Settings sheet navigation path + destination factory.
/// Destinations are built here (not via parent closures) so Account-tab / `MapViewModel`
/// publishes cannot remount pushed screens and auto-pop back to Settings.

struct ProfileSettingsSheetHost<Root: View>: View {
    @StateObject private var navigator = ProfileSettingsNavigator()
    @State private var privacyRefreshToken = 0
#if DEBUG
    @State private var hostInstanceId = UUID()
#endif
    /// Intentionally NOT `@ObservedObject` — Host must not rebuild NavigationStack on every MapViewModel publish.
    /// Child root / destination views observe `viewModel` themselves.
    var viewModel: MapViewModel
    var notificationSettingsStore: NotificationSettingsStore
    @Binding var isPresented: Bool
    @Binding var loginEmail: String
    var isCloseDisabled: Bool
    var navigationTitle: String
    var closeTitle: String
    var onRequestFanSignIn: () -> Void
    /// Soft parent refresh only while stack is at root (never while a destination is pushed).
    var onSettledRootRefresh: () -> Void
    @ViewBuilder var root: () -> Root

    var body: some View {
        NavigationStack(path: $navigator.path) {
            root()
                .environmentObject(navigator)
                .environment(\.profileSettingsPrivacyRefreshToken, privacyRefreshToken)
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.large)
                .navigationDestination(for: ProfileSettingsRoute.self) { route in
                    ProfileSettingsDestinationView(
                        route: route,
                        viewModel: viewModel,
                        notificationSettingsStore: notificationSettingsStore,
                        loginEmail: $loginEmail,
                        onRequestFanSignIn: onRequestFanSignIn
                    )
                    .environmentObject(navigator)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(closeTitle) {
#if DEBUG
                            SettingsNavigationDebug.log(
                                "dismissSource=settingsCloseButton pathCount=\(navigator.path.count) path=\(navigator.pathSummary()) hostId=\(hostInstanceId.uuidString)"
                            )
#endif
                            isPresented = false
                        }
                        .disabled(isCloseDisabled)
                    }
                }
                .onAppear {
#if DEBUG
                    SettingsNavigationDebug.log(
                        "settingsRootAppear pathCount=\(navigator.path.count) path=\(navigator.pathSummary()) hostId=\(hostInstanceId.uuidString)"
                    )
                    if !navigator.path.isEmpty {
                        SettingsNavigationDebug.log(
                            "pathDesyncDetected route=\(navigator.topRoute?.debugName ?? "nil") pathCount=\(navigator.path.count) source=settingsRootAppearWhilePathNonEmpty path=\(navigator.pathSummary())"
                        )
                    }
#endif
                }
        }
        .tint(FGColor.accentGreen)
        .background {
#if DEBUG
            Color.clear
                .onAppear {
                    SettingsNavigationDebug.log(
                        "hostContentAppear hostId=\(hostInstanceId.uuidString) navigatorId=\(navigator.instanceId.uuidString) pathCount=\(navigator.path.count)"
                    )
                }
#endif
        }
        .onAppear {
#if DEBUG
            SettingsNavigationDebug.log(
                "hostAppear hostId=\(hostInstanceId.uuidString) navigatorId=\(navigator.instanceId.uuidString) pathCount=\(navigator.path.count)"
            )
#endif
            scheduleSettledRefreshIfNeeded()
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-SettingsNavSequentialValidation") {
                scheduleSequentialPathValidation()
            }
#endif
        }
        .onDisappear {
#if DEBUG
            SettingsNavigationDebug.log(
                "hostDisappear hostId=\(hostInstanceId.uuidString) navigatorId=\(navigator.instanceId.uuidString) pathCount=\(navigator.path.count)"
            )
#endif
        }
        .onChange(of: navigator.path.count) { oldCount, newCount in
#if DEBUG
            SettingsNavigationDebug.log(
                "pathCount \(oldCount)->\(newCount) path=\(navigator.pathSummary()) top=\(navigator.topRoute?.debugName ?? "nil") hostId=\(hostInstanceId.uuidString) navigatorId=\(navigator.instanceId.uuidString)"
            )
#endif
        }
        .onChange(of: isPresented) { _, presented in
#if DEBUG
            SettingsNavigationDebug.log(
                "hostIsPresented=\(presented) hostId=\(hostInstanceId.uuidString) navigatorId=\(navigator.instanceId.uuidString) pathCount=\(navigator.path.count)"
            )
#endif
            if !presented {
                navigator.reset(reason: "sheetDismissed")
            }
        }
    }

#if DEBUG
    private func scheduleSequentialPathValidation() {
        Task { @MainActor in
            // Wait for sheet settle / privacy token.
            try? await Task.sleep(nanoseconds: 600_000_000)
            await ProfileSettingsSequentialNavValidation.run(navigator: navigator)
        }
    }
#endif

    private func scheduleSettledRefreshIfNeeded() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard isPresented else { return }
            // Local token only — do not bump parent SettingsScreen state (that remounts the stack).
            privacyRefreshToken += 1
#if DEBUG
            SettingsNavigationDebug.log(
                "hostPrivacyRefreshToken=\(privacyRefreshToken) pathCount=\(navigator.path.count) hostId=\(hostInstanceId.uuidString)"
            )
#endif
            guard navigator.path.isEmpty else {
#if DEBUG
                SettingsNavigationDebug.log(
                    "skipSettledRootRefresh reason=pathNonEmpty pathCount=\(navigator.path.count)"
                )
#endif
                return
            }
            onSettledRootRefresh()
        }
    }
}

