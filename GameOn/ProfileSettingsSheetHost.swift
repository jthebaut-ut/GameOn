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
    @AppStorage(FanGeoAppearancePreference.appStorageKey) private var appearancePreferenceRaw =
        FanGeoAppearancePreference.system.rawValue
    @Environment(\.colorScheme) private var colorScheme

    private var appearancePreference: FanGeoAppearancePreference {
        FanGeoAppearancePreference(rawValue: appearancePreferenceRaw) ?? .system
    }

    var body: some View {
        // Overlay must live in this sheet hierarchy (not MainTabView) — Settings is a
        // separate presentation layer above the tab shell.
        ZStack {
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
                    .toolbarBackground(SettingsPremiumChrome.presentationBackground(colorScheme), for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
                    .toolbarColorScheme(colorScheme, for: .navigationBar)
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
            // Keep the already-presented Settings sheet aligned with the canonical preference.
            // WindowGroup `.preferredColorScheme` alone does not reliably update sheet UIKit chrome mid-presentation.
            .preferredColorScheme(appearancePreference.colorScheme)
            .background(SettingsPremiumChrome.presentationBackground(colorScheme).ignoresSafeArea())
            .onChange(of: appearancePreferenceRaw) { _, newRaw in
#if DEBUG
                let preference = FanGeoAppearancePreference(rawValue: newRaw) ?? .system
                print("[SettingsAppearanceDebug] preferenceChanged=\(preference.rawValue) effectiveColorScheme=\(colorScheme == .dark ? "dark" : "light") hostId=\(hostInstanceId.uuidString)")
#endif
            }
            .onAppear {
#if DEBUG
                print("[SettingsAppearanceDebug] hostAppear preference=\(appearancePreference.rawValue) colorScheme=\(colorScheme == .dark ? "dark" : "light") hostId=\(hostInstanceId.uuidString)")
                SettingsNavigationDebug.log(
                    "hostContentAppear hostId=\(hostInstanceId.uuidString) navigatorId=\(navigator.instanceId.uuidString) pathCount=\(navigator.path.count)"
                )
                SettingsNavigationDebug.log(
                    "hostAppear hostId=\(hostInstanceId.uuidString) navigatorId=\(navigator.instanceId.uuidString) pathCount=\(navigator.path.count)"
                )
#endif
                scheduleSettledRefreshIfNeeded()
#if DEBUG
                // Manual validation / UI testing only; requires the explicit
                // -FanGeoRunProfileSettingsSequentialNavValidation launch argument.
                // The coordinator rejects duplicate runs from repeated host appearances.
                ProfileSettingsSequentialNavValidation.scheduleIfExplicitlyEnabled(
                    navigator: navigator,
                    source: "hostAppear"
                )
#endif
            }
            .onDisappear {
#if DEBUG
                SettingsNavigationDebug.log(
                    "hostDisappear hostId=\(hostInstanceId.uuidString) navigatorId=\(navigator.instanceId.uuidString) pathCount=\(navigator.path.count)"
                )
                ProfileSettingsSequentialNavValidation.cancelRun(
                    navigatorId: navigator.instanceId,
                    reason: "hostDisappear"
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
#if DEBUG
                    ProfileSettingsSequentialNavValidation.cancelRun(
                        navigatorId: navigator.instanceId,
                        reason: "sheetDismissed"
                    )
#endif
                    navigator.reset(reason: "sheetDismissed")
                }
            }

            // Thin observer leaf — does not make the Host `@ObservedObject` on MapViewModel
            // (that would remount NavigationStack on every publish).
            AppleCalendarRemovalSheetOverlayHost(viewModel: viewModel)
                .zIndex(10_000)
        }
    }

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

