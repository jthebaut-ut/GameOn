import SwiftUI

/// Host-owned destinations — never built via parent `SettingsScreen` closures / `AnyView`.
/// Parent-coupled destination builders remount on every `MapViewModel` publish and auto-pop the stack.
struct ProfileSettingsDestinationView: View {
    let route: ProfileSettingsRoute
    @ObservedObject var viewModel: MapViewModel
    @ObservedObject var notificationSettingsStore: NotificationSettingsStore
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @EnvironmentObject private var navigator: ProfileSettingsNavigator
    @Binding var loginEmail: String
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @AppStorage(FanGeoAppearancePreference.appStorageKey) private var appearancePreferenceRaw =
        FanGeoAppearancePreference.system.rawValue
    @Environment(\.colorScheme) private var colorScheme
    var onRequestFanSignIn: () -> Void

    var body: some View {
        destinationBody
            .onAppear {
#if DEBUG
                SettingsNavigationDebug.log(
                    "destinationViewAppear route=\(route.debugName) pathCount=\(navigator.path.count) top=\(navigator.topRoute?.debugName ?? "nil") path=\(navigator.pathSummary()) navigatorId=\(navigator.instanceId.uuidString)"
                )
#endif
            }
            .onDisappear {
#if DEBUG
                SettingsNavigationDebug.log(
                    "destinationViewDisappear route=\(route.debugName) pathCount=\(navigator.path.count) top=\(navigator.topRoute?.debugName ?? "nil") path=\(navigator.pathSummary()) navigatorId=\(navigator.instanceId.uuidString)"
                )
#endif
                // Proven failure mode: destination UI gone while route remains path top (nested-stack teardown).
                // Debounce so legitimate push/pop transitions and transient redraws are ignored.
                let disappearedRoute = route
                let navigator = navigator
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard navigator.path.last == disappearedRoute else { return }
                    navigator.noteDestinationDisappearedWhileStillTop(
                        disappearedRoute,
                        source: "destinationDisappearWhileStillTop"
                    )
                }
            }
    }

    @ViewBuilder
    private var destinationBody: some View {
        switch route {
        case .liveActivitySharing:
            LiveActivitySharingOptionsSheet(
                isEnabled: viewModel.currentUserLiveVisibilityEnabled,
                mode: viewModel.currentUserLiveVisibilityMode,
                friends: chatViewModel.friends.filter { !$0.preview.isBusinessAccount },
                selectedFriendIDs: viewModel.currentUserSelectedLiveVisibilityFriendIDs,
                isSaving: viewModel.isUpdatingLiveVisibilitySetting,
                onChooseOff: {
                    Task {
                        await viewModel.setLiveVisibilitySettings(
                            enabled: false,
                            mode: viewModel.currentUserLiveVisibilityMode,
                            selectedFriendIDs: viewModel.currentUserSelectedLiveVisibilityFriendIDs
                        )
                    }
                },
                onChooseAllFriends: {
                    Task {
                        await viewModel.setLiveVisibilitySettings(
                            enabled: true,
                            mode: .allFriends,
                            selectedFriendIDs: viewModel.currentUserSelectedLiveVisibilityFriendIDs
                        )
                    }
                },
                onChooseSelectedFriends: {
                    Task {
                        await chatViewModel.loadIfNeeded()
                        await viewModel.setLiveVisibilitySettings(
                            enabled: true,
                            mode: .selectedFriends,
                            selectedFriendIDs: viewModel.currentUserSelectedLiveVisibilityFriendIDs
                        )
                    }
                },
                onLoadFriends: {
                    Task { await chatViewModel.loadIfNeeded() }
                },
                onToggleFriend: { friendID in
                    var selectedIDs = viewModel.currentUserSelectedLiveVisibilityFriendIDs
                    if selectedIDs.contains(friendID) {
                        selectedIDs.remove(friendID)
                    } else {
                        selectedIDs.insert(friendID)
                    }
                    guard selectedIDs != viewModel.currentUserSelectedLiveVisibilityFriendIDs else { return }
                    Task {
                        await viewModel.setLiveVisibilitySettings(
                            enabled: true,
                            mode: .selectedFriends,
                            selectedFriendIDs: selectedIDs
                        )
                    }
                },
                onClose: {},
                embedsInNavigationStack: false,
                showsCloseButton: false
            )

        case .notifications:
            ScrollView {
                SettingsGameNotificationsCard(viewModel: viewModel, notificationSettingsStore: notificationSettingsStore)
                    .padding(.horizontal, FGSpacing.lg)
                    .padding(.top, FGSpacing.lg)
            }
            .background(FGColor.screenGradient(colorScheme).ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
            }
            .navigationTitle(L10n.t("notifications", languageCode: appLanguageRaw))
            .navigationBarTitleDisplayMode(.inline)

        case .timeZone:
            FanGeoTimeZoneSettingsView(
                selection: $viewModel.selectedTimeZone,
                automaticPresentationToken: viewModel.automaticTimeZonePresentationToken
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
            }

        case .language:
            FanGeoLanguageSelectionView(selectionRaw: $appLanguageRaw)

        case .appearance:
            FanGeoAppearanceSelectionView(selectionRaw: $appearancePreferenceRaw)
                .navigationTitle(L10n.t("appearance", languageCode: appLanguageRaw))
                .navigationBarTitleDisplayMode(.inline)

        case .helpAndTutorial:
            ProfileSettingsHelpDestination(accountUserId: viewModel.currentUserAuthId)

        case .support:
            // Must NOT nest another NavigationStack — that desyncs Settings path
            // (destination disappears while pathCount stays > 0). Proven cause A.
            ContactGameOnSupportSheet(
                viewModel: viewModel,
                onRequestSignIn: onRequestFanSignIn,
                embedsInNavigationStack: false,
                showsCloseButton: false
            )

        case .communityGuidelines:
            SettingsLegalDocumentSheet(
                document: .communityGuidelines,
                embedsInNavigationStack: false,
                showsCloseButton: false
            )

        case .trustSafety:
            SettingsLegalDocumentSheet(
                document: .safetyReporting,
                embedsInNavigationStack: false,
                showsCloseButton: false
            )

        case .privacyPolicy:
            SettingsLegalDocumentSheet(
                document: .privacyPolicy,
                embedsInNavigationStack: false,
                showsCloseButton: false
            )

        case .termsOfService:
            SettingsLegalDocumentSheet(
                document: .termsOfService,
                embedsInNavigationStack: false,
                showsCloseButton: false
            )

        case .resetPassword:
            ScrollView {
                SettingsFanPasswordResetCard(viewModel: viewModel, loginEmail: $loginEmail)
                    .padding(.horizontal, FGSpacing.lg)
                    .padding(.top, FGSpacing.lg)
            }
            .background(FGColor.screenGradient(colorScheme).ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
            }
            .navigationTitle(L10n.t("settings_reset_password", languageCode: appLanguageRaw))
            .navigationBarTitleDisplayMode(.inline)

        case .venueResetPassword:
            ScrollView {
                SettingsVenuePasswordResetCard(viewModel: viewModel)
                    .padding(.horizontal, FGSpacing.lg)
                    .padding(.top, FGSpacing.lg)
            }
            .background(FGColor.screenGradient(colorScheme).ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
            }
            .navigationTitle("Reset venue password")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
