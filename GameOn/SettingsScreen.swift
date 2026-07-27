import Combine
import CoreLocation
#if canImport(MessageUI)
import MessageUI
#endif
import PhotosUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One ``Identifiable`` sheet route for ``VenueOwnerDashboardView`` so only one venue-owner dashboard
/// presentation exists at a time (avoids SwiftUI reusing or stacking multiple ``VenueOwnerDashboardView`` hierarchies
/// across the previous three independent ``.sheet(isPresented:)`` booleans).
private enum VenueOwnerDashboardSheetRoute: String, Identifiable {
    case businessDashboard
    case manageVenue
    case manageGames
    case statistics

    var id: String { rawValue }

    var entryPoint: VenueOwnerDashboardEntryPoint {
        switch self {
        case .businessDashboard:
            return .overviewDashboard
        case .manageVenue:
            return .profileEditor
        case .manageGames:
            return .gamesManager
        case .statistics:
            return .analyticsViewer
        }
    }
}

private struct BusinessProfileVenueHydrationState: Equatable {
    let isReady: Bool
    let reason: String
    let selectedVenueId: UUID?
    let managedCount: Int
}


enum SettingsAboutFanGeoMetadata {
    static let supportEmail = "support@fangeosports.com"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
    }
}


/// Account tab: end-user and venue-owner auth, profile, notifications, Apple Calendar sync, and entry to venue dashboard flows.
struct SettingsScreen: View {
    @ObservedObject var viewModel: MapViewModel
    @ObservedObject private var notificationSettingsStore: NotificationSettingsStore
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    /// Shared main-tab selection (same source of truth as Calendar / Following).
    @Binding var selectedTab: MainTabView.AppTab
    /// False while Account tab is preserved off-screen (avoids Pokes / Suggested Fans network on launch).
    var isAccountTabSelected: Bool = true

    init(
        viewModel: MapViewModel,
        selectedTab: Binding<MainTabView.AppTab>,
        isAccountTabSelected: Bool = true
    ) {
        self._selectedTab = selectedTab
        self.isAccountTabSelected = isAccountTabSelected
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._notificationSettingsStore = ObservedObject(wrappedValue: viewModel.notificationSettingsStore)
#if DEBUG
        SettingsNavigationDebug.log("settingsScreenInit")
#endif
    }

    @State private var email = ""
    @State private var password = ""
    @State private var venuePassword = ""
    @State private var showRegisterMode = false
    @State private var venueOwnerDashboardSheet: VenueOwnerDashboardSheetRoute?
    @State private var showVenueRegisterMode = false
    @State private var showProfileSettingsSheet = false
    @State private var showBusinessProSubscriptionSheet = false
    @State private var showBusinessUsageSheet = false
    @State private var showSponsorInquirySheet = false
    @State private var showBusinessActiveVenueSelectionSheet = false
    @State private var showBusinessFavoriteTeamsSheet = false
    @State private var showBusinessIdentitySheet = false
    @State private var businessDashboardQuickActionNotice: String?
    @State private var businessProfileManagedVenuesSheetToken: UInt = 0
    @State private var settingsBusinessMembershipStatus: BusinessVenueGamePostingStatus?
    @State private var settingsBusinessHostedGameCycleAudit: BusinessHostedGameCycleAudit?
    @State private var settingsBusinessHostedGameCycleAuditLoading = false
    @State private var settingsBusinessHostedGameCycleAuditUnavailable = false
#if DEBUG
    /// Stable for this SettingsScreen state lifetime; changes only if the Account tab root remounts.
    @State private var settingsScreenInstanceId = UUID()
#endif
    @State private var isFanGeoPlusEntitlementRefreshing = false
    @State private var fanGeoPlusEntitlementDisplayActive = FanGeoUserEntitlements.adFreeEnabled
    @State private var showUserAuthSheet = false
    @State private var showVenueAuthSheet = false
    @State private var showLiveSharingModeDialog = false
    @State private var showProfileDiscoveryHelpSheet = false
    @State private var showFanActivityHelpSheet = false
    @State private var profileSettingsLogoutError: String?
    @State private var showProfileOverflowLogoutConfirmation = false
    @State private var showProfileSettingsLogoutConfirmation = false
    @State private var showProfileOverflowLogoutErrorAlert = false
    @State private var showDeleteAccountSheet = false
    @State private var showDeleteVenueOwnerSheet = false
    @State private var showReportedCommentsSheet = false
    @State private var showVenueOwnerPasswordResetSheet = false
    @State private var showAddLocationSheet = false
    @State private var inlineBusinessDashboardGames: [VenueEventRow] = []
    @State private var settingsBusinessDashboardCachedData: BusinessVenueDashboardData?
    @State private var addLocationSubmitBanner: String?
    @State private var settingsBusinessProfileRefreshSequence = 0
    @State private var settingsBusinessProfileLatestRequestId = 0
    @State private var settingsBusinessProfileLastEntitlementSignature = ""
    @State private var settingsActiveVenueSelectionCTAVisible = false
    @State private var settingsActiveVenueSelectionCacheKey = ""
    @State private var settingsBusinessProfileLastPassiveRefreshAt: Date?
    @State private var settingsBusinessProfileHydrationInFlight = false
    @State private var settingsManagedVenuesManualRefreshInFlight = false
    /// Holds Add-location draft fields across ``MapViewModel`` publishes (e.g. after photo upload) so the sheet does not reset.
    @StateObject private var addLocationSheetFormState = AddLocationSheetFormState()
    /// Which pending claim row is running ``performPendingClaimRefresh(claimId:)`` (nil = idle).
    @State private var pendingRefreshingClaimId: UUID?
    @AppStorage(L10n.appLanguageKey) var appLanguageRaw = L10n.defaultLanguageCode
    @AppStorage(FanGeoAppearancePreference.appStorageKey) private var appearancePreferenceRaw = FanGeoAppearancePreference.system.rawValue
    @AppStorage(PrivateChatSecuritySettings.requireFaceIDSettingKey) private var requireFaceIDForPrivateChat = false
    @AppStorage(ProGamesFavoriteTeamAutoFollowPreference.windowDaysKey) private var proGamesFavoriteTeamWindowDays = ProGamesFavoriteTeamAutoFollowPreference.Window.next30.rawValue

    private var favoriteTeamProGameAlertsToggleBinding: Binding<Bool> {
        Binding(
            get: { notificationSettingsStore.favoriteTeamProGameAlertsEnabled },
            set: { enabled in
                Task {
                    await viewModel.setFavoriteTeamProGameAlertsEnabled(
                        enabled,
                        games: viewModel.favoriteTeamProGames,
                        reason: "settingsFavoriteTeamAutoFollowToggle"
                    )
                }
            }
        )
    }

    private var appearancePreference: FanGeoAppearancePreference {
        FanGeoAppearancePreference(rawValue: appearancePreferenceRaw) ?? .system
    }

    private var selectedAppLanguage: AppLanguage {
        L10n.language(for: appLanguageRaw)
    }

    private var privateChatFaceIDBinding: Binding<Bool> {
        Binding(
            get: { requireFaceIDForPrivateChat },
            set: { newValue in
                requireFaceIDForPrivateChat = newValue
                print("[PrivateChatSecurityDebug] settingChanged=\(newValue)")
                if isBusinessAccountProfileContext {
                    print("[BusinessPrivacySettingsDebug] faceIDToggleChanged=\(newValue)")
                }
            }
        )
    }

    private var liveVisibilityBinding: Binding<Bool> {
        Binding(
            get: { viewModel.currentUserLiveVisibilityEnabled },
            set: { newValue in
                Task { await viewModel.setLiveVisibilityEnabled(newValue) }
            }
        )
    }

    private var profileDiscoverabilityBinding: Binding<Bool> {
        Binding(
            get: { viewModel.currentUserDiscoverableByFans },
            set: { newValue in
                Task { await viewModel.setProfileDiscoverableByFans(newValue) }
            }
        )
    }

    private var activityStatusVisibilityBinding: Binding<Bool> {
        Binding(
            get: { viewModel.currentUserActivityStatusVisible },
            set: { newValue in
                Task { await viewModel.setActivityStatusVisible(newValue) }
            }
        )
    }

    private var liveSharingModeSubtitle: String {
        guard viewModel.currentUserLiveVisibilityEnabled else {
            return L10n.t("live_sharing_hidden_from_friends", languageCode: appLanguageRaw)
        }
        switch viewModel.currentUserLiveVisibilityMode {
        case .allFriends:
            return L10n.t("live_sharing_visible_to_all_friends", languageCode: appLanguageRaw)
        case .selectedFriends:
            return L10n.t("live_sharing_visible_to_selected_friends", languageCode: appLanguageRaw)
        }
    }

    private var isBusinessAccountForLiveSharing: Bool {
        viewModel.currentUserIsBusinessAccount || viewModel.isVenueOwnerLoggedIn || viewModel.hasAuthenticatedVenueOwnerSession
    }

    private var isBusinessAccountProfileContext: Bool {
        viewModel.venueOwnerMode || viewModel.isVenueOwnerLoggedIn || viewModel.currentUserIsBusinessAccount
    }

    private var settingsBusinessProfileHasCachedData: Bool {
        viewModel.hasBusinessAccountForOwner()
            && !viewModel.hasArchivedBusinessAccountForOwner()
            && !viewModel.managedVenuesForOwner().isEmpty
    }

    private var canShowLiveActivitySharing: Bool {
        viewModel.canUseFanSocialFeatures && !isBusinessAccountForLiveSharing
    }

    private var liveSharingModeDialogBinding: Binding<Bool> {
        Binding(
            get: { showLiveSharingModeDialog && canShowLiveActivitySharing },
            set: { if !$0 { showLiveSharingModeDialog = false } }
        )
    }

    @ViewBuilder
    private var liveActivitySharingOptionsSheetContent: some View {
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
                    showLiveSharingModeDialog = false
                }
            },
            onChooseAllFriends: {
                Task {
                    await viewModel.setLiveVisibilitySettings(
                        enabled: true,
                        mode: .allFriends,
                        selectedFriendIDs: viewModel.currentUserSelectedLiveVisibilityFriendIDs
                    )
                    showLiveSharingModeDialog = false
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
            onClose: { showLiveSharingModeDialog = false }
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(FGAdaptiveSurface.sheetRoot)
    }

    private var canShowPrivateChatFaceIDSetting: Bool {
        viewModel.isLoggedIn || viewModel.isVenueOwnerLoggedIn || viewModel.hasAuthenticatedVenueOwnerSession
    }

    /// Full Supabase sign-out for fan and business sessions via the shared safe-logout coordinator.
    private func performProfileSettingsLogout(openedFromOverflowMenu: Bool = false) {
        guard !viewModel.isSafeLogoutBlockingUI else { return }
        profileSettingsLogoutError = nil
        showProfileOverflowLogoutConfirmation = false
        showProfileSettingsLogoutConfirmation = false
        if openedFromOverflowMenu {
            // Overflow Log Out must never present Settings (avoids sheet flash).
            showProfileSettingsSheet = false
        } else {
            // Keep Settings sheet up under the global overlay until sign-out settles.
            showProfileSettingsSheet = false
        }
        chatViewModel.clearForSignOut()
        viewModel.beginSafeUserLogout(
            source: openedFromOverflowMenu
                ? "SettingsScreen.overflowMenu"
                : "SettingsScreen.settingsSheet"
        )
    }

    private var canShowProfileOverflowMenu: Bool {
        viewModel.isLoggedIn || viewModel.isVenueOwnerLoggedIn
    }

    private func presentProfileSettingsFromOverflowMenu() {
        guard !viewModel.isSafeLogoutBlockingUI else { return }
        showProfileOverflowLogoutConfirmation = false
        showProfileOverflowLogoutErrorAlert = false
        showProfileSettingsSheet = true
    }

    private func presentProfileLogoutConfirmationFromOverflowMenu() {
        guard !viewModel.isSafeLogoutBlockingUI else { return }
        // Mutually exclusive with Settings — never open the sheet for Log Out.
        showProfileSettingsSheet = false
        // Present after the Menu finishes dismissing so confirmation is not tied to a disappearing hierarchy.
        Task { @MainActor in
            guard !viewModel.isSafeLogoutBlockingUI else { return }
            showProfileOverflowLogoutConfirmation = true
        }
    }

    @ViewBuilder
    private var profileOverflowMenuButton: some View {
        Menu {
            if !isBusinessAccountProfileContext {
                Button {
                    viewModel.presentOwnPublicProfilePreview()
                } label: {
                    Label(
                        L10n.t("preview_public_profile", languageCode: appLanguageRaw),
                        systemImage: "eye"
                    )
                }
                .accessibilityHint(
                    L10n.t("preview_public_profile_hint", languageCode: appLanguageRaw)
                )
            }

            Button {
                presentProfileSettingsFromOverflowMenu()
            } label: {
                Label(
                    L10n.t("settings", languageCode: appLanguageRaw),
                    systemImage: "gearshape"
                )
            }

            Divider()

            Button(role: .destructive) {
                presentProfileLogoutConfirmationFromOverflowMenu()
            } label: {
                Label(
                    L10n.t("log_out", languageCode: appLanguageRaw),
                    systemImage: "rectangle.portrait.and.arrow.right"
                )
            }
            .disabled(viewModel.isSafeLogoutBlockingUI)
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(FGColor.accentGreen)
                .frame(width: 34, height: 34)
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                    Circle()
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.82))
                }
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.70), lineWidth: 0.75)
                }
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.10), radius: 10, y: 4)
        }
        .disabled(viewModel.isSafeLogoutBlockingUI)
        .accessibilityLabel(L10n.t("profile_overflow_menu_a11y", languageCode: appLanguageRaw))
    }

    @ViewBuilder
    private func profileOverflowLogoutPresentations<Content: View>(on content: Content) -> some View {
        content
            .confirmationDialog(
                L10n.t("log_out", languageCode: appLanguageRaw),
                isPresented: $showProfileOverflowLogoutConfirmation,
                titleVisibility: .visible
            ) {
                Button(L10n.t("log_out", languageCode: appLanguageRaw), role: .destructive) {
                    performProfileSettingsLogout(openedFromOverflowMenu: true)
                }
                .disabled(viewModel.isSafeLogoutBlockingUI)
                Button(L10n.t("Cancel", languageCode: appLanguageRaw), role: .cancel) {
                    showProfileOverflowLogoutConfirmation = false
                }
            }
            .alert(
                L10n.t("Could not log out", languageCode: appLanguageRaw),
                isPresented: $showProfileOverflowLogoutErrorAlert
            ) {
                Button(L10n.t("OK", languageCode: appLanguageRaw), role: .cancel) {
                    showProfileOverflowLogoutErrorAlert = false
                    profileSettingsLogoutError = nil
                }
            } message: {
                Text(profileSettingsLogoutError ?? "")
            }
            .confirmationDialog(
                L10n.t("log_out", languageCode: appLanguageRaw),
                isPresented: $showProfileSettingsLogoutConfirmation,
                titleVisibility: .visible
            ) {
                Button(L10n.t("log_out", languageCode: appLanguageRaw), role: .destructive) {
                    performProfileSettingsLogout(openedFromOverflowMenu: false)
                }
                .disabled(viewModel.isSafeLogoutBlockingUI)
                Button(L10n.t("Cancel", languageCode: appLanguageRaw), role: .cancel) {
                    showProfileSettingsLogoutConfirmation = false
                }
            }
            .onChange(of: showProfileOverflowLogoutConfirmation) { _, isPresented in
                if isPresented {
                    showProfileSettingsSheet = false
                }
            }
            .onChange(of: viewModel.safeLogoutPhase) { _, phase in
                if phase == .failed {
                    let message = viewModel.safeLogoutFailureMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    profileSettingsLogoutError = message.isEmpty
                        ? L10n.t(
                            "Could not log out. Please check your connection and try again.",
                            languageCode: appLanguageRaw
                        )
                        : message
                } else if phase == .idle {
                    venueOwnerDashboardSheet = nil
                    showVenueOwnerPasswordResetSheet = false
                    showReportedCommentsSheet = false
                    showDeleteVenueOwnerSheet = false
                    showDeleteAccountSheet = false
                    showProfileSettingsSheet = false
                    showProfileOverflowLogoutConfirmation = false
                    showProfileSettingsLogoutConfirmation = false
                }
            }
    }

    private func logSettingsBusinessVenueSectionVisibilityForFanAccount() {
        guard viewModel.isLoggedIn, !viewModel.isVenueOwnerLoggedIn else { return }
        print("[SettingsVisibility] hiding business venue section for fan account")
    }

    private func clearPendingDiscoverTodayDashboardAccountNavIfNeeded() {
        guard viewModel.pendingDiscoverTodayDashboardNav == .accountSuggestedFans else { return }
        viewModel.clearPendingDiscoverTodayDashboardNav()
#if DEBUG
        print("[DiscoverTodayDashboard] applied accountSuggestedFans (Account tab)")
#endif
    }

    @ViewBuilder
    private var accountTabRootContent: some View {
        if isAccountTabSelected {
            accountTabNavigationStack
        } else {
            accountOffTabPlaceholder
        }
    }

    /// Preserved-tab shell: skip profile lists, dashboard rows, and hero cards while off-screen.
    private var accountOffTabPlaceholder: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }

    private var accountTabNavigationStack: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 12) {
                        FanGeoPagePurposeHeader(
                            title: L10n.t("profile_tab_title", languageCode: appLanguageRaw),
                            subtitle: ""
                        )

                        Spacer(minLength: 8)

                        if canShowProfileOverflowMenu {
                            profileOverflowMenuButton
                        } else {
                            Button {
                                showProfileSettingsSheet = true
                            } label: {
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(FGColor.accentGreen)
                                    .frame(width: 34, height: 34)
                                    .background {
                                        Circle()
                                            .fill(.ultraThinMaterial)
                                        Circle()
                                            .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.82))
                                    }
                                    .overlay {
                                        Circle()
                                            .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.70), lineWidth: 0.75)
                                    }
                                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.10), radius: 10, y: 4)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.t("Open settings", languageCode: appLanguageRaw))
                        }
                    }
                    .padding(.horizontal, 16)
                    // Title sits just below the safe-area content boundary (no duplicate nav-bar row).
                    .padding(.top, 14)
                    .padding(.bottom, 0)

                    Group {
                        if isBusinessAccountProfileContext {
                            SettingsProfileHero(
                                viewModel: viewModel,
                                businessMembershipStatus: settingsBusinessMembershipStatus,
                                businessVenueSelectorOnAddLocation: { openAddLocationFromPicker() },
                                businessVenueSelectorIsHydrating: businessProfileVenueSelectorIsHydrating,
                                businessVenueSelectorHydrationReason: businessProfileVenueHydrationState.reason,
                                businessVenueSelectorOnBlockedEarlyTap: logBusinessProfileHydrationBlockedEarlyTap,
                                managedVenuesSheetPresentationToken: businessProfileManagedVenuesSheetToken,
                                venueOwnerOnNotifications: { showReportedCommentsSheet = true },
                                venueOwnerOnResetPassword: {
                                    guard viewModel.canPresentPasswordResetRequestSheet() else {
                                        showVenueOwnerPasswordResetSheet = false
                                        return
                                    }
                                    showVenueOwnerPasswordResetSheet = true
                                },
                                venueOwnerOnDismissSheetsAfterLogout: {
                                    venueOwnerDashboardSheet = nil
                                    showVenueOwnerPasswordResetSheet = false
                                    showReportedCommentsSheet = false
                                    showDeleteVenueOwnerSheet = false
                                }
                            )
                        } else if viewModel.resolvingEmailConfirmation {
                            VStack(spacing: FGSpacing.md) {
                                ProgressView()
                                Text(L10n.t(MapViewModel.finishingEmailVerificationMessage, languageCode: appLanguageRaw))
                                    .font(FGTypography.caption.weight(.semibold))
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, FGSpacing.xl)
                        } else if viewModel.isLoggedIn {
                            // Erase at the SettingsScreen boundary so Account's type graph
                            // does not embed ProfileIdentityCard's nested SwiftUI generics.
                            AnyView(
                                ProfileIdentityCard(
                                    viewModel: viewModel,
                                    isAccountTabActive: isAccountTabSelected
                                )
                            )
                        } else {
                            SettingsUnifiedAccountEntryCard(
                                viewModel: viewModel,
                                onSignIn: {
                                    showRegisterMode = false
                                    showUserAuthSheet = true
                                },
                                onCreateAccount: {
                                    showRegisterMode = true
                                    showUserAuthSheet = true
                                },
                                onWatchLiveWithFans: openDiscoverForVenuesFromProfile,
                                onJoinPickupGames: openDiscoverForPickupGamesFromProfile,
                                onVenueOwnerTools: nil,
                                statusMessage: viewModel.authErrorMessage,
                                attemptedLoginEmail: email
                            )
                        }
                    }
                    // Fan profile: adaptive outer inset (SE keeps 16; standard/Pro Max use 6).
                    .padding(
                        .horizontal,
                        isBusinessAccountProfileContext || !viewModel.isLoggedIn
                            ? 16
                            : ProfileHeroMetrics.outerInset(screenWidth: nil)
                    )
                    .padding(.top, isBusinessAccountProfileContext || !viewModel.isLoggedIn ? 16 : 0)
                    .padding(.bottom, 10)

                    if isBusinessAccountProfileContext && !viewModel.isVenueOwnerLoggedIn {
                        settingsBusinessProRow
                            .padding(.horizontal, 16)

                        settingsBusinessActiveVenueSelectionCard
                            .padding(.horizontal, 16)

                        settingsSponsorInquiryCard
                            .padding(.horizontal, 16)
                    }

                    if shouldShowInlineBusinessDashboard {
                        settingsBusinessProRow
                            .padding(.horizontal, 16)

                        settingsBusinessActiveVenueSelectionCard
                            .padding(.horizontal, 16)

                        settingsSponsorInquiryCard
                            .padding(.horizontal, 16)

                        settingsInlineBusinessDashboard
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                    }

                    if !shouldShowInlineBusinessDashboard && (viewModel.isVenueOwnerLoggedIn || !viewModel.isLoggedIn) {
                        Group {
                            if viewModel.isVenueOwnerLoggedIn {
                                settingsSectionHeader("Business & Venue")
                            } else {
                                businessOwnersLoggedOutSectionHeader()
                            }
                        }
                        .padding(.horizontal, 16)

                        Group {
                            if viewModel.isVenueOwnerLoggedIn {
                                settingsSectionCard {
                                    let hasArchivedBusinessAccount = viewModel.hasArchivedBusinessAccountForOwner()
                                    let hasActiveBusinessAccount = viewModel.hasBusinessAccountForOwner()

                                    settingsBusinessProButton()

                                settingsRowDivider()

                                if viewModel.isVenueOwnerBusinessDataLoading && !settingsBusinessProfileHasCachedData {
                                    HStack(spacing: 10) {
                                        ProgressView()
                                        Text("Loading business data…")
                                            .font(FGTypography.caption)
                                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                                    }
                                    .padding(.horizontal, FGSpacing.md)
                                    .padding(.vertical, FGSpacing.md)
                                } else if hasArchivedBusinessAccount {
                                    settingsInfoRow(
                                        title: "Business account",
                                        subtitle: settingsBusinessAccountSubtitle(),
                                        systemImage: viewModel.businessAccountStatusIconName(),
                                        tint: viewModel.businessAccountStatusTint()
                                    )

                                    settingsRowDivider()

                                    settingsInfoRow(
                                        title: "Location status",
                                        subtitle: viewModel.businessSettingsLocationStatusSubtitle(),
                                        systemImage: viewModel.businessSettingsLocationStatusSystemImage(),
                                        tint: settingsLocationStatusTint()
                                    )
                                } else if !hasActiveBusinessAccount && !hasArchivedBusinessAccount {
                                    settingsInfoRow(
                                        title: "Business account",
                                        subtitle: settingsBusinessAccountSubtitle(),
                                        systemImage: viewModel.businessAccountStatusIconName(),
                                        tint: viewModel.businessAccountStatusTint()
                                    )

                                    settingsRowDivider()

                                    settingsInlineNote(
                                        "Add a businesses record for this sign-in email before locations can be linked or approved.",
                                        systemImage: "info.circle"
                                    )

                                    settingsRowDivider()

                                    Button {
                                        openBusinessVenueToolRoute(.manageVenue)
                                    } label: {
                                        settingsRow(
                                            title: "Set up business account",
                                            subtitle: "Open the business dashboard to finish account and listing details.",
                                            systemImage: "rectangle.and.pencil.and.ellipsis"
                                        )
                                    }
                                    .buttonStyle(.plain)

                                    settingsRowDivider()

                                    settingsInfoRow(
                                        title: "Location status",
                                        subtitle: viewModel.businessSettingsLocationStatusSubtitle(),
                                        systemImage: viewModel.businessSettingsLocationStatusSystemImage(),
                                        tint: settingsLocationStatusTint()
                                    )

                                } else if viewModel.managedVenuesForOwner().isEmpty {
                                    settingsInfoRow(
                                        title: "Business account",
                                        subtitle: settingsBusinessAccountSubtitle(),
                                        systemImage: viewModel.businessAccountStatusIconName(),
                                        tint: viewModel.businessAccountStatusTint()
                                    )

                                    settingsRowDivider()

                                    settingsInfoRow(
                                        title: "Location status",
                                        subtitle: viewModel.businessSettingsLocationStatusSubtitle(),
                                        systemImage: viewModel.businessSettingsLocationStatusSystemImage(),
                                        tint: settingsLocationStatusTint()
                                    )

                                    settingsRowDivider()

                                    BusinessLocationVenuePicker(
                                        viewModel: viewModel,
                                        chrome: .settings,
                                        onRequestAddNewLocation: { openAddLocationFromPicker() },
                                        onEditApprovedVenue: openManagedVenueDetailsForEditing,
                                        isHydrating: businessProfileVenueSelectorIsHydrating,
                                        hydrationReason: businessProfileVenueHydrationState.reason,
                                        onBlockedEarlyTap: logBusinessProfileHydrationBlockedEarlyTap
                                    )

                                    if let bannerText = addLocationSubmitBannerDisplayText(), !bannerText.isEmpty {
                                        settingsRowDivider()
                                        settingsInlineNote(
                                            bannerText,
                                            tint: addLocationSubmitBannerForegroundColor(),
                                            systemImage: "info.circle"
                                        )
                                    }

                                    settingsRowDivider()

                                    settingsVenueReviewSections()
                                } else {
                                    settingsInfoRow(
                                        title: "Business account",
                                        subtitle: settingsBusinessAccountSubtitle(),
                                        systemImage: viewModel.businessAccountStatusIconName(),
                                        tint: viewModel.businessAccountStatusTint()
                                    )

                                    if let bannerText = addLocationSubmitBannerDisplayText(), !bannerText.isEmpty {
                                        settingsRowDivider()
                                        settingsInlineNote(
                                            bannerText,
                                            tint: addLocationSubmitBannerForegroundColor(),
                                            systemImage: "info.circle"
                                        )
                                    }

                                    settingsRowDivider()

                                    BusinessLocationVenuePicker(
                                        viewModel: viewModel,
                                        chrome: .settings,
                                        onRequestAddNewLocation: { openAddLocationFromPicker() },
                                        onEditApprovedVenue: openManagedVenueDetailsForEditing,
                                        isHydrating: businessProfileVenueSelectorIsHydrating,
                                        hydrationReason: businessProfileVenueHydrationState.reason,
                                        onBlockedEarlyTap: logBusinessProfileHydrationBlockedEarlyTap
                                    )

                                    settingsRowDivider()

                                    settingsVenueReviewSections()

                                    settingsRowDivider()

                                    Button { openBusinessVenueToolRoute(.manageVenue) } label: {
                                        settingsRow(
                                            title: L10n.t("venue_details", languageCode: appLanguageRaw),
                                            subtitle: "Photos, amenities, and venue profile.",
                                            systemImage: "photo.on.rectangle.angled"
                                        )
                                    }
                                    .buttonStyle(.plain)

                                    if settingsVenueClaimApprovedForStatusRow() {
                                        settingsRowDivider()

                                        Button { openBusinessVenueToolRoute(.manageGames) } label: {
                                            settingsRow(
                                                title: L10n.t("manage_games", languageCode: appLanguageRaw),
                                                subtitle: "Schedule or cancel games.",
                                                systemImage: "sportscourt"
                                            )
                                        }
                                        .buttonStyle(.plain)

                                        settingsRowDivider()

                                        Button { openBusinessVenueToolRoute(.statistics) } label: {
                                            settingsRow(
                                                title: L10n.t("statistics", languageCode: appLanguageRaw),
                                                subtitle: "Analytics and game history.",
                                                systemImage: "chart.bar"
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }

                                settingsRowDivider()

                                Button { showReportedCommentsSheet = true } label: {
                                    settingsRow(
                                        title: "Flagged Comments",
                                        subtitle: "Review reported venue activity.",
                                        systemImage: "exclamationmark.bubble"
                                    )
                                }
                                .buttonStyle(.plain)
                                }
                            } else {
                                Button {
                                    showVenueRegisterMode = false
                                    showVenueAuthSheet = true
                                } label: {
                                    loggedOutBusinessOwnerEntryCard()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .task(id: viewModel.isVenueOwnerLoggedIn) {
                            if viewModel.isVenueOwnerLoggedIn {
                                await viewModel.refreshPendingVenueClaimsForSettings()
                            }
                        }
#if DEBUG
                        .onAppear {
                            viewModel.logBusinessAccountStateDebug()
                        }
#endif
                    }
                }
                .padding(.bottom, SettingsScrollBottomLayout.accountTabScrollBottomInset)
            }
            .scrollIndicators(.hidden)
            .background(SettingsPremiumChrome.screenBackground(colorScheme).ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
#if DEBUG
                SettingsNavigationDebug.log(
                    "settingsScreenAppear settingsScreenId=\(settingsScreenInstanceId.uuidString) isAccountTabSelected=\(isAccountTabSelected)"
                )
                SettingsPerf.log("appear isAccountTabSelected=\(isAccountTabSelected) isLoggedIn=\(viewModel.isLoggedIn) businessContext=\(isBusinessAccountProfileContext)")
                // Validation mode: auto-open the Settings sheet so the host-owned
                // validator can run. The host schedules the single validation run;
                // no detached "path-only" navigator run (that duplicated the run).
                if ProfileSettingsSequentialNavValidation.isExplicitlyEnabled {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        SettingsNavigationDebug.log("sequentialValidationOpeningSettingsSheet=true")
                        showProfileSettingsSheet = true
                    }
                }
#endif
                SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] accountScreenAppeared=true isAccountTabSelected=\(isAccountTabSelected) isLoggedIn=\(viewModel.isLoggedIn) authId=\(viewModel.currentUserAuthId?.uuidString.lowercased() ?? "nil") businessContext=\(isBusinessAccountProfileContext)")
                refreshSettingsActiveVenueSelectionCTAVisibility()
                if isAccountTabSelected {
                    clearPendingDiscoverTodayDashboardAccountNavIfNeeded()
                    AppPerfDebug.screenLoadStart(tab: "account", source: "onAppear")
                    UIPerformanceDiagnostics.signpost("Profile tab open", "source=onAppear")
                    logBusinessProfilePerformance(event: "profileTabAppeared source=onAppear")
                    Task {
                        await Task.yield()
                        await refreshSettingsBusinessProfile(trigger: "accountTabAppears", refreshBusinessData: true, debounce: true)
                    }
                }
#if DEBUG
                print("[FaceIDSettingsDebug] defaultPrivateChatFaceID=false")
#endif
                logSettingsBusinessVenueSectionVisibilityForFanAccount()
                guard isAccountTabSelected else { return }
                AccountActivationPerf.log("activationStarted cachedContentShown=\(viewModel.currentUserAuthId != nil)")
                Task {
                    await Task.yield()
                    await viewModel.loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: true)
                    if viewModel.canFanUsePickupGamesUI {
                        await viewModel.loadMyPickupGamesForSettings()
                    }
                }
            }
        }
    }

    var body: some View {
        profileOverflowLogoutPresentations(on: accountTabRootContent)
        .onChange(of: isAccountTabSelected) { _, isSelected in
            SponsoredPlacementDebugLog.log("[SponsoredPlacementDebug] accountTabSelectionChanged isSelected=\(isSelected) isLoggedIn=\(viewModel.isLoggedIn) authId=\(viewModel.currentUserAuthId?.uuidString.lowercased() ?? "nil") businessContext=\(isBusinessAccountProfileContext)")
            if isSelected {
                clearPendingDiscoverTodayDashboardAccountNavIfNeeded()
                AppPerfDebug.screenLoadStart(tab: "account", source: "tabSelected")
                UIPerformanceDiagnostics.signpost("Profile tab open", "source=tabSelected")
                logBusinessProfilePerformance(event: "profileTabAppeared source=tabSelected")
                if viewModel.didCompleteTabIntentPreloadRecently("account", within: 15) {
                    AppPerfDebug.refreshSkipped(tab: "account", source: "businessProfile", reason: "tabPreloadRecent")
                    return
                }
                Task {
                    await Task.yield()
                    await refreshSettingsBusinessProfile(trigger: "accountTabAppears", refreshBusinessData: true, debounce: true)
                }
            }
        }
        .onChange(of: scenePhase) { oldPhase, phase in
            guard phase == .active, isAccountTabSelected else { return }
            if showProfileSettingsSheet, oldPhase != .active {
                // Soft refresh only — Host owns navigation; avoid parent rebuild storms while pushed.
                Task {
                    await refreshFanGeoPlusEntitlementFromSettings()
                    syncFanGeoPlusDisplayFromEntitlements()
                }
            }
            Task {
                await refreshSettingsBusinessProfile(trigger: "foreground", refreshBusinessData: true, debounce: true)
            }
        }
        .onChange(of: settingsBusinessEntitlementSignature) { _, newValue in
            guard isAccountTabSelected, isBusinessAccountProfileContext else { return }
            guard !settingsBusinessProfileLastEntitlementSignature.isEmpty else { return }
            guard newValue != settingsBusinessProfileLastEntitlementSignature else { return }
            Task {
                await refreshSettingsBusinessProfile(trigger: "businessRowEntitlementChanged", refreshBusinessData: false, debounce: true)
            }
        }
        .onChange(of: settingsActiveVenueSelectionEvaluationKey) { _, _ in
            refreshSettingsActiveVenueSelectionCTAVisibility()
        }
        .onChange(of: settingsBusinessMembershipStatus?.computedIsPro) { _, _ in
            refreshSettingsActiveVenueSelectionCTAVisibility()
        }
        .overlay(alignment: .top) {
            if let toast = viewModel.socialActionToastText, !toast.isEmpty {
                settingsSocialToastBanner(
                    text: toast,
                    isError: viewModel.socialActionToastIsError
                )
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
        }
        .onChange(of: viewModel.openVenueOwnerAuthSheetFromClaimFlow) { _, shouldPresent in
            guard shouldPresent else { return }
            showVenueAuthSheet = true
            viewModel.openVenueOwnerAuthSheetFromClaimFlow = false
        }
        .onChange(of: viewModel.presentFanUserAuthSheetFromDiscover) { _, shouldPresent in
            guard shouldPresent else { return }
            showRegisterMode = viewModel.fanUserAuthSheetOpenInRegisterMode
            showUserAuthSheet = true
            let verifiedEmail = OwnerBusinessEmail.normalized(viewModel.pendingEmailVerificationEmail)
            if OwnerBusinessEmail.isValidStrict(verifiedEmail) {
                email = verifiedEmail
            }
            viewModel.presentFanUserAuthSheetFromDiscover = false
            viewModel.fanUserAuthSheetOpenInRegisterMode = false
        }
        .onChange(of: showUserAuthSheet) { _, isPresented in
            password = ""
            if isPresented {
                venuePassword = ""
            }
        }
        .onChange(of: showVenueAuthSheet) { _, isPresented in
            venuePassword = ""
            if isPresented {
                password = ""
            }
        }
        .onChange(of: showProfileSettingsSheet) { _, isPresented in
#if DEBUG
            SettingsNavigationDebug.log(
                "settingsSheetPresented=\(isPresented) settingsScreenId=\(settingsScreenInstanceId.uuidString)"
            )
#endif
            if isPresented {
                profileSettingsLogoutError = nil
                showProfileOverflowLogoutConfirmation = false
                showProfileOverflowLogoutErrorAlert = false
                // Do NOT bump parent privacy/FanGeo+ state here — that rebuilds SettingsScreen
                // while the sheet NavigationStack is presenting and auto-pops destinations.
                // Host owns privacy refresh; settled FanGeo+ refresh runs only at root.
            }
        }
        .onChange(of: viewModel.isLoggedIn) { _, _ in
            password = ""
            logSettingsBusinessVenueSectionVisibilityForFanAccount()
        }
        .onChange(of: viewModel.isVenueOwnerLoggedIn) { _, _ in
            venuePassword = ""
            logSettingsBusinessVenueSectionVisibilityForFanAccount()
        }
        .onChange(of: viewModel.hasAuthenticatedVenueOwnerSession) { _, isBusiness in
            if !isBusiness {
                venueOwnerDashboardSheet = nil
                showVenueOwnerPasswordResetSheet = false
                showReportedCommentsSheet = false
                showAddLocationSheet = false
                showDeleteVenueOwnerSheet = false
                showBusinessFavoriteTeamsSheet = false
            }
        }
        .sheet(item: $venueOwnerDashboardSheet) { route in
            VenueOwnerDashboardView(viewModel: viewModel, entryPoint: route.entryPoint)
                .id(route.id)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
        .sheet(isPresented: $showUserAuthSheet) {
            SettingsUserAuthSheet(
                viewModel: viewModel,
                email: $email,
                password: $password,
                showRegisterMode: $showRegisterMode
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showVenueAuthSheet) {
            SettingsVenueAuthSheet(
                viewModel: viewModel,
                venuePassword: $venuePassword,
                showVenueRegisterMode: $showVenueRegisterMode,
                onRequestVenueProfileDashboard: { openBusinessVenueToolRoute(.manageVenue) }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
        .sheet(isPresented: $showAddLocationSheet) {
            AddBusinessLocationRequestSheet(
                viewModel: viewModel,
                form: addLocationSheetFormState,
                submitBanner: $addLocationSubmitBanner,
                isPresented: $showAddLocationSheet
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
            .onAppear {
                if !viewModel.hasAuthenticatedVenueOwnerSession {
                    showAddLocationSheet = false
                }
            }
        }
        .sheet(isPresented: $showProfileSettingsSheet) {
            profileSettingsSheetHost
        }
        .sheet(isPresented: $showBusinessProSubscriptionSheet) {
            BusinessProSubscriptionView(businessStatus: settingsBusinessMembershipStatus)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(FGAdaptiveSurface.sheetRoot)
                .task {
                    await refreshSettingsBusinessProfile(
                        trigger: "businessProSheet",
                        refreshBusinessData: true
                    )
                }
        }
        .sheet(isPresented: $showBusinessUsageSheet) {
            BusinessUsageCenterView(
                status: settingsBusinessMembershipStatus,
                hostedGameCycleAudit: settingsBusinessHostedGameCycleAudit,
                isHostedGameCycleLoading: settingsBusinessHostedGameCycleAuditLoading,
                hostedGameCycleAuditUnavailable: settingsBusinessHostedGameCycleAuditUnavailable
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(FGAdaptiveSurface.sheetRoot)
                .task {
                    await refreshSettingsBusinessHostedGameCycleAudit()
                }
        }
        .sheet(isPresented: $showSponsorInquirySheet) {
            BusinessSponsorInquirySheet(
                viewModel: viewModel,
                businessId: viewModel.currentBusinessIdForAddLocation(),
                businessName: settingsSponsorInquiryBusinessName,
                ownerEmail: OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail),
                selectedVenue: settingsSponsorInquirySelectedVenueLine
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
        .sheet(isPresented: $showBusinessActiveVenueSelectionSheet) {
            BusinessActiveVenueSelectionSheet(
                viewModel: viewModel,
                businessId: settingsBusinessActiveVenueSelectionBusinessId,
                venueLimit: settingsBusinessActiveVenueSelectionLimit,
                venues: settingsBusinessActiveVenueSelectionRows,
                approvedDateText: { row in settingsApprovedVenueDateInfo(for: row).displayText },
                onSaved: {
                    settingsActiveVenueSelectionCacheKey = ""
                    Task {
                        await refreshSettingsBusinessProfile(trigger: "activeVenueSelectionSaved", refreshBusinessData: true, debounce: false)
                        refreshSettingsActiveVenueSelectionCTAVisibility()
                    }
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
        .sheet(isPresented: $showBusinessFavoriteTeamsSheet) {
            BusinessFavoriteTeamsManagementSheet(
                viewModel: viewModel,
                businessId: viewModel.currentBusinessIdForAddLocation()
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
        .sheet(isPresented: $showBusinessIdentitySheet) {
            BusinessIdentityEditSheet(
                viewModel: viewModel,
                businessId: viewModel.currentBusinessIdForAddLocation(),
                initialDisplayName: settingsBusinessIdentityInitialDisplayName,
                initialBusinessHandle: settingsBusinessIdentityInitialHandle,
                suggestedHandlePlaceholder: settingsBusinessIdentitySuggestedHandlePlaceholder
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
        .sheet(isPresented: liveSharingModeDialogBinding) {
            liveActivitySharingOptionsSheetContent
        }
        .sheet(isPresented: $showVenueOwnerPasswordResetSheet) {
            SettingsVenueOwnerPasswordResetSheet(
                viewModel: viewModel,
                isPresented: $showVenueOwnerPasswordResetSheet
            )
        }
        .sheet(isPresented: $showDeleteAccountSheet) {
            SettingsAccountDeletionSheet(
                viewModel: viewModel,
                onCloseAfterSuccess: {
                    showProfileSettingsSheet = false
                    showDeleteAccountSheet = false
                }
            )
        }
        .sheet(isPresented: $showDeleteVenueOwnerSheet) {
            SettingsVenueOwnerDeletionSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showReportedCommentsSheet) {
            NavigationStack {
                ScrollView {
                    SettingsReportedCommentsAdminCard(viewModel: viewModel)
                        .padding()
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
                }
                .navigationTitle("Flagged Comments")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showReportedCommentsSheet = false }
                    }
                }
            }
            .onAppear {
                if !viewModel.hasAuthenticatedVenueOwnerSession {
                    showReportedCommentsSheet = false
                }
            }
        }
    }

    private var profileSettingsSheetHost: some View {
        ProfileSettingsSheetHost(
            viewModel: viewModel,
            notificationSettingsStore: notificationSettingsStore,
            isPresented: $showProfileSettingsSheet,
            loginEmail: $email,
            isCloseDisabled: viewModel.isSafeLogoutBlockingUI,
            navigationTitle: L10n.t("settings", languageCode: appLanguageRaw),
            closeTitle: L10n.t("close", languageCode: appLanguageRaw),
            onRequestFanSignIn: {
                showProfileSettingsSheet = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    showUserAuthSheet = true
                }
            },
            onSettledRootRefresh: {
                syncFanGeoPlusDisplayFromEntitlements()
                Task { await refreshFanGeoPlusEntitlementFromSettings() }
            },
            root: { profileSettingsSheetRoot }
        )
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(SettingsPremiumChrome.presentationBackground(colorScheme))
        .interactiveDismissDisabled(viewModel.isSafeLogoutBlockingUI)
    }

    private var profileSettingsSheetRoot: some View {
        List {
            ProfileSettingsPrivacyPermissionsSection()
            profileSettingsPrivacySection()
            profileSettingsNotificationsSection()
            if !settingsFanGeoPlusUsesBusinessDisplay {
                profileSettingsFanGeoPlusSection()
            }
            profileSettingsExperienceSection()
            profileSettingsProGamesSection()
            profileSettingsHelpSafetySection()
            profileSettingsLegalSection()
            profileSettingsAccountSection()
            ProfileSettingsAboutSection()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
        }
        .listStyle(.plain)
        .listRowSeparator(.hidden)
        .listSectionSeparator(.hidden)
        .listSectionSpacing(SettingsPremiumChrome.profileSectionListSpacing)
        .scrollContentBackground(.hidden)
        .background(SettingsPremiumChrome.screenBackground(colorScheme).ignoresSafeArea())
        .sheet(isPresented: $showProfileDiscoveryHelpSheet) {
            ProfileDiscoveryHelpSheet()
        }
        .sheet(isPresented: $showFanActivityHelpSheet) {
            FanActivityHelpSheet()
        }
    }

    private func presentFromProfileSettings(_ present: @escaping () -> Void) {
        showProfileSettingsSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            present()
        }
    }

    @MainActor
    private func presentBusinessDashboardQuickAction(
        source: String,
        keepsVenueOwnerRoute: Bool = false,
        _ present: () -> Void
    ) {
        if !keepsVenueOwnerRoute {
            venueOwnerDashboardSheet = nil
        }
        showAddLocationSheet = false
        showBusinessProSubscriptionSheet = false
        showBusinessUsageSheet = false
        showBusinessActiveVenueSelectionSheet = false
        showBusinessFavoriteTeamsSheet = false
        showReportedCommentsSheet = false
        businessDashboardQuickActionNotice = nil
        present()
    }

    private var settingsBusinessProRow: some View {
        let isPro = settingsBusinessMembershipStatus?.computedIsPro == true

        return settingsBusinessEntitlementCard(isPro: isPro) {
            settingsBusinessProButton(isProOverride: isPro)
        }
        .onAppear {
            logBusinessProVisibilityInBusinessSettings(rowRendered: true)
            logBusinessEntitlementStyleDebug(computedIsPro: isPro, appliedStyle: isPro ? "premiumGold" : "regularNeutral")
        }
        .onChange(of: isPro) { _, newValue in
            logBusinessEntitlementStyleDebug(computedIsPro: newValue, appliedStyle: newValue ? "premiumGold" : "regularNeutral")
        }
    }

    private func settingsBusinessProButton(
        presentingFromProfileSettings: Bool = false,
        isProOverride: Bool? = nil
    ) -> some View {
        let isPro = isProOverride ?? (settingsBusinessMembershipStatus?.computedIsPro == true)

        return Button {
            logBusinessProVisibilityInBusinessSettings(rowRendered: true)
            if presentingFromProfileSettings {
                presentFromProfileSettings {
                    presentBusinessDashboardQuickAction(source: "businessPro") {
                        showBusinessProSubscriptionSheet = true
                    }
                }
            } else {
                presentBusinessDashboardQuickAction(source: "businessPro") {
                    showBusinessProSubscriptionSheet = true
                }
            }
        } label: {
            settingsRow(
                title: settingsBusinessMembershipStatus?.businessPlanDisplayTitle(languageCode: appLanguageRaw) ?? (isPro ? L10n.t("business_pro", languageCode: appLanguageRaw) : L10n.t("business_regular", languageCode: appLanguageRaw)),
                subtitle: settingsBusinessProRowSubtitle,
                systemImage: isPro ? "crown.fill" : "lock.shield.fill",
                tint: isPro ? SettingsPremiumChrome.proGold(colorScheme) : FGColor.accentGreen
            ) {
                if isPro {
                    settingsBusinessProBadge()
                }
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            logBusinessProVisibilityInBusinessSettings(rowRendered: true)
        }
    }

    @ViewBuilder
    private func settingsBusinessEntitlementCard<Content: View>(
        isPro: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        if isPro {
            SettingsBusinessProEntitlementCardContainer(content: content)
        } else {
            settingsSectionCard(content: content)
        }
    }

    private struct SettingsBusinessProEntitlementCardContainer<Content: View>: View {
        let content: () -> Content
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                        .fill(SettingsPremiumChrome.cardFill(colorScheme))
                    RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    SettingsPremiumChrome.proGold(colorScheme).opacity(colorScheme == .dark ? 0.24 : 0.18),
                                    SettingsPremiumChrome.proGoldDeep(colorScheme).opacity(colorScheme == .dark ? 0.12 : 0.08),
                                    SettingsPremiumChrome.cardHighlight(colorScheme)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                    .strokeBorder(SettingsPremiumChrome.proGold(colorScheme).opacity(colorScheme == .dark ? 0.52 : 0.42), lineWidth: 1)
            }
            .shadow(color: SettingsPremiumChrome.proGold(colorScheme).opacity(colorScheme == .dark ? 0.18 : 0.14), radius: 18, y: 8)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.06), radius: 12, y: 6)
        }
    }

    private func settingsBusinessProBadge() -> some View {
        Text("PRO")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(SettingsPremiumChrome.proBadgeText(colorScheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                LinearGradient(
                    colors: [
                        SettingsPremiumChrome.proGold(colorScheme),
                        SettingsPremiumChrome.proGoldDeep(colorScheme)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule(style: .continuous)
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.20 : 0.46), lineWidth: 0.75)
            }
            .shadow(color: SettingsPremiumChrome.proGold(colorScheme).opacity(colorScheme == .dark ? 0.16 : 0.12), radius: 6, y: 2)
    }

    private func logBusinessProVisibilityInBusinessSettings(rowRendered: Bool) {
#if DEBUG
        print("[BusinessProVisibilityDebug] rowRenderedInBusinessSettings=\(rowRendered)")
#endif
    }

    private func logBusinessEntitlementStyleDebug(computedIsPro: Bool, appliedStyle: String) {
#if DEBUG
        print("[BusinessEntitlementStyleDebug] computedIsPro=\(computedIsPro) appliedStyle=\(appliedStyle)")
#endif
    }

    @ViewBuilder
    private var settingsBusinessActiveVenueSelectionCard: some View {
        if settingsShouldShowBusinessActiveVenueSelection {
            Button {
                showBusinessActiveVenueSelectionSheet = true
            } label: {
                settingsBusinessActiveVenueSelectionCardBody
            }
            .buttonStyle(.plain)
        }
    }

    private var settingsBusinessActiveVenueSelectionCardBody: some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SettingsPremiumChrome.proGold(colorScheme).opacity(colorScheme == .dark ? 0.18 : 0.12))
                Image(systemName: "checklist.checked")
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(SettingsPremiumChrome.proGold(colorScheme))
            }
            .frame(width: SettingsPremiumChrome.rowIconSize, height: SettingsPremiumChrome.rowIconSize)

            VStack(alignment: .leading, spacing: 4) {
                Text("Choose active venues")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                Text("Pick which \(settingsBusinessActiveVenueSelectionLimit) approved venues stay visible and can host games on Regular.")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text("1 opportunity remaining")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.proGold(colorScheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 12)
        .background(SettingsPremiumChrome.cardFill(colorScheme), in: RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                .strokeBorder(SettingsPremiumChrome.proGold(colorScheme).opacity(colorScheme == .dark ? 0.30 : 0.22), lineWidth: 0.75)
        }
        .contentShape(RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous))
    }

    private var settingsShouldShowBusinessActiveVenueSelection: Bool {
        settingsActiveVenueSelectionCTAVisible
    }

    private var settingsActiveVenueSelectionEvaluationKey: String {
        let businessId = settingsBusinessActiveVenueSelectionBusiness?.id.uuidString.lowercased() ?? "nil"
        let pro = settingsBusinessMembershipStatus?.computedIsPro == true
        let venueCount = viewModel.managedVenuesForOwner().count
        let selectedAt = settingsBusinessActiveVenueSelectionBusiness
            .flatMap { settingsNormalizedFreeActiveVenuesSelectedAt(for: $0) } ?? "nil"
        return "\(businessId)|\(pro)|\(venueCount)|\(selectedAt)"
    }

    private func refreshSettingsActiveVenueSelectionCTAVisibility() {
        let nextKey = settingsActiveVenueSelectionEvaluationKey
        guard nextKey != settingsActiveVenueSelectionCacheKey else { return }
        settingsActiveVenueSelectionCacheKey = nextKey
        let shouldShow = computeSettingsShouldShowBusinessActiveVenueSelection()
        guard shouldShow != settingsActiveVenueSelectionCTAVisible else { return }
        settingsActiveVenueSelectionCTAVisible = shouldShow
#if DEBUG
        SettingsPerf.log("activeVenueSelectionCTA=\(shouldShow) key=\(nextKey)")
#endif
    }

    private func computeSettingsShouldShowBusinessActiveVenueSelection() -> Bool {
        guard let business = settingsBusinessActiveVenueSelectionBusiness else {
            return false
        }
        let status = settingsBusinessMembershipStatus
        let rows = settingsBusinessActiveVenueSelectionRows(for: business)
        let approvedCount = rows.count
        let venueLimit = settingsBusinessActiveVenueSelectionLimit
        let selectedAt = settingsNormalizedFreeActiveVenuesSelectedAt(for: business)
        let computedIsPro = status?.computedIsPro == true
        return !computedIsPro
            && approvedCount > venueLimit
            && selectedAt == nil
    }

    private var settingsBusinessActiveVenueSelectionBusiness: BusinessRow? {
        if let businessId = viewModel.currentBusinessIdForAddLocation(),
           let business = viewModel.ownedBusinesses.first(where: { $0.id == businessId }) {
            return business
        }
        return viewModel.ownedBusinesses.first
    }

    private var settingsBusinessActiveVenueSelectionBusinessId: UUID {
        settingsBusinessActiveVenueSelectionBusiness?.id
            ?? viewModel.currentBusinessIdForAddLocation()
            ?? UUID()
    }

    private var settingsBusinessActiveVenueSelectionLimit: Int {
        max(1, settingsBusinessMembershipStatus?.venueLimit ?? BusinessMembershipPolicy.freeVenueListingLimit)
    }

    private var settingsBusinessActiveVenueSelectionRows: [VenueProfileRow] {
        guard let business = settingsBusinessActiveVenueSelectionBusiness else { return [] }
        return settingsBusinessActiveVenueSelectionRows(for: business)
    }

    private func settingsBusinessActiveVenueSelectionRows(for business: BusinessRow) -> [VenueProfileRow] {
        var seenVenueIDs = Set<UUID>()
        return viewModel.managedVenuesForOwner()
            .compactMap { row -> VenueProfileRow? in
                guard let id = row.id, seenVenueIDs.insert(id).inserted else { return nil }
                guard MapViewModel.venueIsOwnerVisibleManagedStatus(row) else { return nil }
                if row.business_id == business.id { return row }
                if let metadata = viewModel.approvedVenueClaimMetadataByVenueID[id] {
                    if metadata.businessId == business.id { return row }
                    let metadataOwner = OwnerBusinessEmail.normalized(metadata.ownerEmail ?? "")
                    let businessOwner = OwnerBusinessEmail.normalized(business.owner_email ?? "")
                    if metadata.businessId == nil,
                       !metadataOwner.isEmpty,
                       metadataOwner == businessOwner {
                        return row
                    }
                }
                if row.business_id == nil {
                    let rowOwner = OwnerBusinessEmail.normalized(row.owner_email ?? "")
                    let businessOwner = OwnerBusinessEmail.normalized(business.owner_email ?? "")
                    if !rowOwner.isEmpty, rowOwner == businessOwner { return row }
                    if viewModel.ownedBusinesses.count == 1 { return row }
                }
                return nil
            }
            .sorted {
                let lhsDate = settingsApprovedVenueDateInfo(for: $0).sortDate
                let rhsDate = settingsApprovedVenueDateInfo(for: $1).sortDate
                switch (lhsDate, rhsDate) {
                case let (left?, right?):
                    if left != right { return left > right }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
                return ($0.venue_name ?? "").localizedCaseInsensitiveCompare($1.venue_name ?? "") == .orderedAscending
            }
    }

    private func settingsNormalizedFreeActiveVenuesSelectedAt(for business: BusinessRow) -> String? {
        let value = business.free_active_venues_selected_at?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty || value.lowercased() == "null" { return nil }
        return value
    }

    private var settingsActiveVenueSelectionQuickActionFootnote: String? {
        guard settingsShouldShowBusinessActiveVenueSelection else { return nil }
        return "Regular businesses can choose active venues once after moving from Pro to Regular."
    }

    private var settingsSponsorInquiryCard: some View {
        Button {
            let businessId = viewModel.currentBusinessIdForAddLocation()
#if DEBUG
            print("[SponsorInquiryDebug] opened=true businessId=\(businessId?.uuidString.lowercased() ?? "nil")")
#endif
            showSponsorInquirySheet = true
        } label: {
            HStack(alignment: .center, spacing: FGSpacing.md) {
                ZStack {
                    Circle()
                        .fill(SettingsPremiumChrome.proGold(colorScheme).opacity(colorScheme == .dark ? 0.20 : 0.13))
                    Circle()
                        .strokeBorder(SettingsPremiumChrome.proGold(colorScheme).opacity(0.26), lineWidth: 1)
                    Image(systemName: "megaphone.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(SettingsPremiumChrome.proGold(colorScheme))
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Promote Your Venue")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                    Text("Reach local sports fans with business advertising opportunities.")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Learn More")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            LinearGradient(
                                colors: [
                                    SettingsPremiumChrome.proGold(colorScheme),
                                    Color(red: 0.62, green: 0.39, blue: 0.08)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: Capsule(style: .continuous)
                        )
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                    .frame(width: 14, height: 34, alignment: .center)
            }
            .padding(.horizontal, FGSpacing.md)
            .padding(.vertical, 12)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                        .fill(SettingsPremiumChrome.cardFill(colorScheme))
                    RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    SettingsPremiumChrome.proGold(colorScheme).opacity(colorScheme == .dark ? 0.12 : 0.08),
                                    SettingsPremiumChrome.cardHighlight(colorScheme),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                    .strokeBorder(SettingsPremiumChrome.proGold(colorScheme).opacity(colorScheme == .dark ? 0.28 : 0.20), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.06), radius: 12, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var settingsSponsorInquiryBusinessName: String {
        if let businessId = viewModel.currentBusinessIdForAddLocation(),
           let business = viewModel.ownedBusinesses.first(where: { $0.id == businessId }) {
            let name = business.display_name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        let ownedName = viewModel.ownedBusinesses.first?.display_name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !ownedName.isEmpty { return ownedName }
        let venueName = settingsBusinessDashboardVenueName.trimmingCharacters(in: .whitespacesAndNewlines)
        return venueName.isEmpty ? "My business" : venueName
    }

    private var settingsSponsorInquirySelectedVenueLine: String {
        guard let venue = settingsBusinessDashboardSelectedVenue else {
            return "Not selected"
        }
        let name = venue.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let city = venue.city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let state = venue.state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let location = [city, state].filter { !$0.isEmpty }.joined(separator: ", ")
        if name.isEmpty { return location.isEmpty ? "Selected venue unavailable" : location }
        return location.isEmpty ? name : "\(name) • \(location)"
    }

    @ViewBuilder
    private func profileSettingsAccountSection() -> some View {
        if viewModel.isLoggedIn || viewModel.isVenueOwnerLoggedIn {
            Section {
                settingsSectionCard {
                    if viewModel.isLoggedIn {
                        if isBusinessAccountProfileContext {
                            settingsBusinessProButton(presentingFromProfileSettings: true)

                            profileSettingsBusinessAccountFanGeoPlusRows
                        }

                        ProfileSettingsRouteButton(route: .resetPassword, source: "resetPassword") {
                            settingsRow(
                                title: L10n.t("settings_reset_password", languageCode: appLanguageRaw),
                                subtitle: L10n.t("settings_send_reset_email", languageCode: appLanguageRaw),
                                systemImage: "key",
                                showsChevron: true
                            )
                        }

                        if viewModel.isVenueOwnerLoggedIn {
                            settingsRowDivider()

                            ProfileSettingsRouteButton(route: .venueResetPassword, source: "venueResetPassword") {
                                settingsRow(title: "Reset venue password", subtitle: "Send a venue owner reset email.", systemImage: "key", showsChevron: true)
                            }
                        }
                    } else if viewModel.isVenueOwnerLoggedIn {
                        settingsBusinessProButton(presentingFromProfileSettings: true)

                        profileSettingsBusinessAccountFanGeoPlusRows

                        ProfileSettingsRouteButton(route: .venueResetPassword, source: "venueResetPassword") {
                            settingsRow(title: "Reset venue password", subtitle: "Send a venue owner reset email.", systemImage: "key", showsChevron: true)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 16))
                .listRowBackground(Color.clear)

                settingsSectionCard {
                    if let profileSettingsLogoutError,
                       !profileSettingsLogoutError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        SettingsSheetStatusBanner(
                            title: "Could not log out",
                            message: profileSettingsLogoutError,
                            tint: FGColor.dangerRed,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .padding(.horizontal, FGSpacing.md)
                        .padding(.vertical, FGSpacing.sm)

                        settingsRowDivider()
                    }

                    if viewModel.isLoggedIn {
                        Button {
                            showProfileSettingsLogoutConfirmation = true
                        } label: {
                            settingsRow(
                                title: viewModel.isSafeLogoutBlockingUI
                                    ? L10n.t("settings_logging_out", languageCode: appLanguageRaw)
                                    : L10n.t("log_out", languageCode: appLanguageRaw),
                                subtitle: viewModel.isSafeLogoutBlockingUI
                                    ? L10n.t("settings_signing_out_securely", languageCode: appLanguageRaw)
                                    : nil,
                                systemImage: "rectangle.portrait.and.arrow.right",
                                tint: FGColor.dangerRed.opacity(0.82),
                                showsChevron: false
                            ) {
                                if viewModel.isSafeLogoutBlockingUI {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isSafeLogoutBlockingUI)

                        settingsRowDivider()

                        Button {
                            presentFromProfileSettings { showDeleteAccountSheet = true }
                        } label: {
                            settingsRow(
                                title: L10n.t("settings_delete_account", languageCode: appLanguageRaw),
                                subtitle: L10n.t("settings_permanent_removal", languageCode: appLanguageRaw),
                                systemImage: "trash",
                                tint: FGColor.dangerRed.opacity(0.82)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isSafeLogoutBlockingUI)

                        if viewModel.isVenueOwnerLoggedIn {
                            settingsRowDivider()

                            Button {
                                presentFromProfileSettings { showDeleteVenueOwnerSheet = true }
                            } label: {
                                settingsRow(
                                    title: "Delete venue access",
                                    subtitle: "Remove owner profile, listings, and uploads.",
                                    systemImage: "trash",
                                    tint: FGColor.dangerRed.opacity(0.82)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isSafeLogoutBlockingUI)
                        }
                    } else if viewModel.isVenueOwnerLoggedIn {
                        Button {
                            showProfileSettingsLogoutConfirmation = true
                        } label: {
                            settingsRow(
                                title: viewModel.isSafeLogoutBlockingUI ? "Logging out..." : "Logout",
                                subtitle: viewModel.isSafeLogoutBlockingUI ? "Signing out securely." : "Sign out of this business account.",
                                systemImage: "rectangle.portrait.and.arrow.right",
                                tint: FGColor.dangerRed.opacity(0.82),
                                showsChevron: false
                            ) {
                                if viewModel.isSafeLogoutBlockingUI {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isSafeLogoutBlockingUI)

                        settingsRowDivider()

                        Button {
                            presentFromProfileSettings { showDeleteVenueOwnerSheet = true }
                        } label: {
                            settingsRow(
                                title: "Delete account",
                                subtitle: "Permanent owner profile removal.",
                                systemImage: "trash",
                                tint: FGColor.dangerRed.opacity(0.82)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isSafeLogoutBlockingUI)
                    }
                }
                .listRowInsets(
                    EdgeInsets(
                        top: SettingsPremiumChrome.accountDestructiveTopSpacing,
                        leading: 16,
                        bottom: 14,
                        trailing: 16
                    )
                )
                .listRowBackground(Color.clear)
            } header: {
                settingsSectionHeader(L10n.t("account", languageCode: appLanguageRaw))
            }
        }
    }

    @ViewBuilder
    private func profileSettingsPrivacySection() -> some View {
        if canShowPrivateChatFaceIDSetting || canShowLiveActivitySharing || canShowPrivacyAdChoices {
            Section {
                settingsSectionCard {
                    if canShowPrivateChatFaceIDSetting {
                        privateChatFaceIDSettingsRow
                    }

                    if canShowPrivateChatFaceIDSetting && (canShowLiveActivitySharing || canShowPrivacyAdChoices) {
                        settingsRowDivider()
                    }

                    if canShowLiveActivitySharing {
                        settingsToggleRow(
                            title: L10n.t("profile_discovery_title", languageCode: appLanguageRaw),
                            subtitle: L10n.t("profile_discovery_subtitle", languageCode: appLanguageRaw),
                            systemImage: "person.crop.circle.badge.checkmark",
                            isOn: profileDiscoverabilityBinding,
                            isUpdating: viewModel.isUpdatingProfileDiscoverabilitySetting,
                            tint: FGColor.accentBlue,
                            infoAccessibilityLabel: L10n.t("profile_discovery_info_a11y", languageCode: appLanguageRaw),
                            infoAccessibilityHint: L10n.t("privacy_setting_info_hint", languageCode: appLanguageRaw),
                            onInfo: { showProfileDiscoveryHelpSheet = true }
                        )

                        settingsRowDivider()

                        settingsToggleRow(
                            title: L10n.t("activity_status_privacy_title", languageCode: appLanguageRaw),
                            subtitle: L10n.t("activity_status_privacy_subtitle", languageCode: appLanguageRaw),
                            systemImage: "circle.fill",
                            isOn: activityStatusVisibilityBinding,
                            isUpdating: viewModel.isUpdatingActivityStatusVisibilitySetting,
                            tint: FGColor.accentGreen
                        )

                        settingsRowDivider()

                        shareMyFanActivitySettingsRow
                    }

                    if canShowLiveActivitySharing && canShowPrivacyAdChoices {
                        settingsRowDivider()
                    }

                    if canShowPrivacyAdChoices {
                        privacyAdChoicesSettingsRow
                    }
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(Color.clear)
            } header: {
                settingsSectionHeader(L10n.t("privacy_and_security", languageCode: appLanguageRaw))
            }
        }
    }

    private var shareMyFanActivitySettingsRow: some View {
        HStack(alignment: .center, spacing: 0) {
            ProfileSettingsRouteButton(route: .liveActivitySharing, source: "liveActivitySharing") {
                HStack(alignment: .center, spacing: FGSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                        Image(systemName: "person.2.wave.2.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(FGColor.accentGreen)
                    }
                    .frame(width: SettingsPremiumChrome.rowIconSize, height: SettingsPremiumChrome.rowIconSize)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.t("share_my_fan_activity_title", languageCode: appLanguageRaw))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                            .lineLimit(2)
                        Text(L10n.t("share_my_fan_activity_subtitle", languageCode: appLanguageRaw))
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, FGSpacing.md)
                .padding(.vertical, 10)
                .frame(minHeight: SettingsPremiumChrome.rowMinHeight, alignment: .center)
                .contentShape(Rectangle())
            }

            // Sibling of RouteButton so info taps never open audience selection.
            SettingsPrivacyInfoButton(
                accessibilityLabel: L10n.t("share_my_fan_activity_info_a11y", languageCode: appLanguageRaw),
                accessibilityHint: L10n.t("privacy_setting_info_hint", languageCode: appLanguageRaw)
            ) {
                showFanActivityHelpSheet = true
            }

            ProfileSettingsRouteButton(route: .liveActivitySharing, source: "liveActivitySharingChevron") {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                    .frame(width: 44, height: 44, alignment: .center)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .padding(.trailing, FGSpacing.sm)
        }
        .accessibilityElement(children: .contain)
    }

    private var canShowPrivacyAdChoices: Bool {
        GoogleMobileAdsBootstrap.privacyOptionsRequired
    }

    private var privacyAdChoicesSettingsRow: some View {
        Button {
            Task {
                await GoogleMobileAdsBootstrap.presentPrivacyOptionsIfRequired()
            }
        } label: {
            settingsRow(
                title: L10n.t("privacy_and_ad_choices", languageCode: appLanguageRaw),
                subtitle: L10n.t("privacy_and_ad_choices_subtitle", languageCode: appLanguageRaw),
                systemImage: "hand.raised.fill",
                tint: FGColor.accentBlue,
                showsChevron: true
            )
        }
        .buttonStyle(.plain)
    }

    private var privateChatFaceIDSettingsRow: some View {
        settingsToggleRow(
            title: L10n.t("require_face_id_private_chat", languageCode: appLanguageRaw),
            subtitle: L10n.t("private_chat_face_id_description", languageCode: appLanguageRaw),
            systemImage: "faceid",
            isOn: privateChatFaceIDBinding,
            isUpdating: false,
            tint: FGColor.accentBlue
        )
        .onAppear {
            guard isBusinessAccountProfileContext else { return }
            print("[BusinessPrivacySettingsDebug] faceIDToggleVisible=true")
            print("[BusinessPrivacySettingsDebug] usingSharedFaceIDSetting=true")
        }
    }

    private func presentGuestFanAuthFromProfileSettings() {
        showProfileSettingsSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
        }
    }

    private func profileSettingsNotificationsSection() -> some View {
        Section {
            settingsSectionCard {
                Group {
                    if viewModel.isAuthenticatedForSocialFeatures {
                        ProfileSettingsRouteButton(route: .notifications, source: "notifications") {
                            fanGeoAlertsSettingsSummaryRow
                        }
                    } else {
                        Button {
                            presentGuestFanAuthFromProfileSettings()
                        } label: {
                            fanGeoAlertsSettingsSummaryRow
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .opacity(viewModel.isAuthenticatedForSocialFeatures ? 1 : 0.48)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
            .listRowBackground(Color.clear)
        } header: {
            settingsSectionHeader(L10n.t("FanGeo Alerts", languageCode: appLanguageRaw))
        }
    }

    private var fanGeoAlertsSettingsSummaryRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: FGSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(FGColor.dangerRed.opacity(0.88))
                }
                .frame(width: SettingsPremiumChrome.rowIconSize, height: SettingsPremiumChrome.rowIconSize)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("FanGeo Alerts", languageCode: appLanguageRaw))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                    Text(
                        viewModel.isAuthenticatedForSocialFeatures
                            ? L10n.t("fangeo_alerts_choose_what_to_manage", languageCode: appLanguageRaw)
                            : L10n.t("fangeo_alerts_sign_in_to_manage", languageCode: appLanguageRaw)
                    )
                    .font(.system(size: 12.5, weight: .regular, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                    .padding(.top, 4)
            }

            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 10, alignment: .leading),
                        GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 10, alignment: .leading)
                    ],
                    alignment: .leading,
                    spacing: 10
                ) {
                    fanGeoAlertsManageBullet(
                        L10n.t("live_game_alerts", languageCode: appLanguageRaw),
                        systemImage: "sportscourt.fill",
                        tint: FGColor.dangerRed.opacity(0.88)
                    )
                    fanGeoAlertsManageBullet(
                        L10n.t("friend_activity", languageCode: appLanguageRaw),
                        systemImage: "person.2.fill",
                        tint: Color(red: 0.58, green: 0.36, blue: 0.86)
                    )
                    fanGeoAlertsManageBullet(
                        L10n.t("favorite_team_alerts", languageCode: appLanguageRaw),
                        systemImage: "star.fill",
                        tint: SettingsPremiumChrome.proGold(colorScheme)
                    )
                    fanGeoAlertsManageBullet(
                        L10n.t("venue_activity", languageCode: appLanguageRaw),
                        systemImage: "mappin.and.ellipse",
                        tint: FGColor.accentBlue
                    )
                    fanGeoAlertsManageBullet(
                        L10n.t("pickup_invites", languageCode: appLanguageRaw),
                        systemImage: "figure.run",
                        tint: FGColor.accentGreen
                    )
                    fanGeoAlertsManageBullet(
                        L10n.t("apple_calendar_sync", languageCode: appLanguageRaw),
                        systemImage: "calendar.badge.checkmark",
                        tint: FGColor.accentBlue
                    )
                }
            }
            .padding(.leading, SettingsPremiumChrome.rowIconSize + FGSpacing.md)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func fanGeoAlertsManageBullet(_ title: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 14, alignment: .center)
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func profileSettingsFanGeoPlusSection() -> some View {
        Section {
            settingsSectionCard {
                fanGeoPlusComingSoonCard
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
            .listRowBackground(Color.clear)
        } header: {
            settingsSectionHeader("FanGeo+")
        }
    }

    @ViewBuilder
    private var profileSettingsBusinessAccountFanGeoPlusRows: some View {
        if settingsFanGeoPlusUsesBusinessDisplay {
            settingsRowDivider()

            fanGeoPlusComingSoonCard

            settingsRowDivider()
        }
    }

    private var settingsFanGeoPlusUsesBusinessDisplay: Bool {
        isBusinessAccountProfileContext
    }

    private func syncFanGeoPlusDisplayFromEntitlements() {
        if settingsFanGeoPlusUsesBusinessDisplay {
            fanGeoPlusEntitlementDisplayActive = FanGeoBusinessEntitlements.effectiveBusinessFanGeoPlus
        } else {
            fanGeoPlusEntitlementDisplayActive = FanGeoUserEntitlements.adFreeEnabled
        }
    }

    private func logBusinessFanGeoPlusSettingsRender() {
#if DEBUG
        guard settingsFanGeoPlusUsesBusinessDisplay else { return }
        print("[BusinessFanGeoPlusDebug] settingsRowRender business_id=\(FanGeoBusinessEntitlements.businessId?.uuidString.lowercased() ?? "nil")")
        print("[BusinessFanGeoPlusDebug] business_fangeo_plus_enabled=\(FanGeoBusinessEntitlements.businessFanGeoPlusManuallyEnabled)")
        print("[BusinessFanGeoPlusDebug] includedWithPaidPro=\(FanGeoBusinessEntitlements.includedWithPaidPro)")
        print("[BusinessFanGeoPlusDebug] effectiveBusinessFanGeoPlus=\(FanGeoBusinessEntitlements.effectiveBusinessFanGeoPlus)")
#endif
    }

    @ViewBuilder
    private var fanGeoPlusSettingsSubtitle: some View {
        if settingsFanGeoPlusUsesBusinessDisplay {
            fanGeoPlusBusinessSettingsSubtitle
        } else {
            fanGeoPlusFanSettingsSubtitle
        }
    }

    @ViewBuilder
    private var fanGeoPlusFanSettingsSubtitle: some View {
        if fanGeoPlusEntitlementIsActive {
            Text("Active • Ad-free experience enabled")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Regular account • Ads may appear")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("FanGeo+ memberships coming soon.")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var fanGeoPlusBusinessSettingsSubtitle: some View {
        if FanGeoBusinessEntitlements.effectiveBusinessFanGeoPlus {
            if FanGeoBusinessEntitlements.businessFanGeoPlusManuallyEnabled {
                Text("Manual FanGeo+ • Ad-free business experience enabled")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if FanGeoBusinessEntitlements.includedWithPaidPro {
                Text("Included with Paid Pro • Ad-free business experience enabled")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Regular business • Ads may appear")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Regular business • Ads may appear")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("FanGeo+ memberships coming soon.")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fanGeoPlusComingSoonCard: some View {
        let isActive = fanGeoPlusEntitlementIsActive

        return HStack(alignment: .center, spacing: FGSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                Image(systemName: "crown.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(SettingsPremiumChrome.proGold(colorScheme))
            }
            .frame(width: SettingsPremiumChrome.rowIconSize, height: SettingsPremiumChrome.rowIconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text("FanGeo+")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                    .lineLimit(1)
                Text(isActive ? "Ad-free experience enabled." : "Ad-free experience.")
                    .font(.system(size: 12.5, weight: .regular, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            fanGeoPlusSettingsSummaryBadge(isActive: isActive)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 12)
        .frame(minHeight: SettingsPremiumChrome.rowMinHeight, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isActive
                ? "FanGeo plus, ad-free experience enabled, active"
                : "FanGeo plus, ad-free experience, coming soon"
        )
    }

    private func fanGeoPlusSettingsSummaryBadge(isActive: Bool) -> some View {
        Group {
            if isActive {
                Text("Active")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .tracking(0.35)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(FGColor.accentGreen, in: Capsule(style: .continuous))
            } else {
                Text("Coming Soon")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .tracking(0.35)
                    .foregroundStyle(SettingsPremiumChrome.proBadgeText(colorScheme))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        LinearGradient(
                            colors: [
                                SettingsPremiumChrome.proGold(colorScheme),
                                SettingsPremiumChrome.proGoldDeep(colorScheme)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: Capsule(style: .continuous)
                    )
            }
        }
        .accessibilityLabel(isActive ? "FanGeo+ Active" : "FanGeo+ Coming Soon")
    }

    private var fanGeoPlusSettingsRow: some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(
                        fanGeoPlusEntitlementIsActive
                            ? SettingsPremiumChrome.proGold(colorScheme)
                            : SettingsPremiumChrome.secondaryText(colorScheme)
                    )
            }
            .frame(width: SettingsPremiumChrome.rowIconSize, height: SettingsPremiumChrome.rowIconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text("FanGeo+")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                    .lineLimit(1)

                fanGeoPlusSettingsSubtitle
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                if isFanGeoPlusEntitlementRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(fanGeoPlusEntitlementIsActive ? SettingsPremiumChrome.proGold(colorScheme) : FGColor.accentGreen)
                        .accessibilityLabel("Refreshing FanGeo+ status")
                } else {
                    Button {
                        Task { await refreshFanGeoPlusEntitlementFromSettings() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                            .frame(width: 28, height: 28)
                            .background(SettingsPremiumChrome.iconSurface(colorScheme), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Refresh FanGeo+ status")
                }

                settingsFanGeoPlusStatusBadge(isActive: fanGeoPlusEntitlementIsActive)
            }
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
        .frame(minHeight: SettingsPremiumChrome.rowMinHeight, alignment: .center)
        .contentShape(Rectangle())
    }

    private func refreshFanGeoPlusEntitlementFromSettings() async {
        guard !isFanGeoPlusEntitlementRefreshing else { return }
        isFanGeoPlusEntitlementRefreshing = true
        defer { isFanGeoPlusEntitlementRefreshing = false }
        if settingsFanGeoPlusUsesBusinessDisplay {
            await viewModel.refreshCurrentBusinessFanGeoPlusEntitlementFromServer(reason: "settingsManualRefresh")
        } else {
            await viewModel.refreshCurrentUserAdFreeEntitlementFromServer(reason: "settingsManualRefresh")
        }
        syncFanGeoPlusDisplayFromEntitlements()
        logBusinessFanGeoPlusSettingsRender()
    }

    private var fanGeoPlusEntitlementIsActive: Bool {
        if settingsFanGeoPlusUsesBusinessDisplay {
            return FanGeoBusinessEntitlements.effectiveBusinessFanGeoPlus
        }
        return fanGeoPlusEntitlementDisplayActive
    }

    private func settingsFanGeoPlusStatusBadge(isActive: Bool) -> some View {
        Group {
            if isActive {
                Text("Active")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .tracking(0.4)
                    .foregroundStyle(SettingsPremiumChrome.proBadgeText(colorScheme))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        LinearGradient(
                            colors: [
                                SettingsPremiumChrome.proGold(colorScheme),
                                SettingsPremiumChrome.proGoldDeep(colorScheme)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: Capsule(style: .continuous)
                    )
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.20 : 0.46), lineWidth: 0.75)
                    }
            } else {
                Text("Regular")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        SettingsPremiumChrome.iconSurface(colorScheme),
                        in: Capsule(style: .continuous)
                    )
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(SettingsPremiumChrome.divider(colorScheme), lineWidth: 0.75)
                    }
            }
        }
        .accessibilityLabel(isActive ? "FanGeo+ Active" : "FanGeo+ Regular")
    }

    private func profileSettingsExperienceSection() -> some View {
        Section {
            settingsSectionCard {
                ProfileSettingsRouteButton(route: .timeZone, source: "timeZone") {
                    settingsRow(title: L10n.t("time_zone", languageCode: appLanguageRaw), subtitle: viewModel.selectedTimeZone.settingsRowSubtitle, systemImage: "clock", showsChevron: true)
                }

                settingsRowDivider()

                ProfileSettingsRouteButton(route: .language, source: "language") {
                    settingsRow(
                        title: L10n.t("language", languageCode: appLanguageRaw),
                        subtitle: selectedAppLanguage.nativeName,
                        systemImage: "globe.americas.fill",
                        showsChevron: true
                    )
                }
                .onAppear {
#if DEBUG
                    print("[LocalizationDebug] languageSettingVisible=true")
                    print("[LocalizationDebug] selectedLanguage=\(selectedAppLanguage.code)")
#endif
                }

                settingsRowDivider()

                ProfileSettingsRouteButton(route: .appearance, source: "appearance") {
                    settingsRow(
                        title: L10n.t("appearance", languageCode: appLanguageRaw),
                        subtitle: appearancePreference.displayName,
                        systemImage: "circle.lefthalf.filled",
                        showsChevron: true
                    )
                }
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
            .listRowBackground(Color.clear)
        } header: {
            settingsSectionHeader("Experience")
        }
    }

    private func profileSettingsProGamesSection() -> some View {
        Section {
            Group {
                if viewModel.isAuthenticatedForSocialFeatures {
                    profileSettingsProGamesPreferencesCard
                } else {
                    Button {
                        presentGuestFanAuthFromProfileSettings()
                    } label: {
                        profileSettingsProGamesPreferencesCard
                    }
                    .buttonStyle(.plain)
                }
            }
            .opacity(viewModel.isAuthenticatedForSocialFeatures ? 1 : 0.48)
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
            .listRowBackground(Color.clear)
        } header: {
            settingsSectionHeader(L10n.t("pro_sports_games", languageCode: appLanguageRaw) + " Preferences")
        }
    }

    private var profileSettingsProGamesPreferencesCard: some View {
        settingsSectionCard {
            settingsRow(
                title: "Automatically follow Favorite Teams",
                subtitle: "Show upcoming \(L10n.t("pro_sports_games", languageCode: appLanguageRaw)) involving your favorite teams in Going.",
                systemImage: "star.circle.fill",
                tint: FGColor.accentBlue,
                showsChevron: false
            ) {
                Toggle("Automatically follow games from my Favorite Teams", isOn: favoriteTeamProGameAlertsToggleBinding)
                    .labelsHidden()
                    .disabled(!viewModel.isAuthenticatedForSocialFeatures)
            }

            settingsRowDivider()

            proGamesFavoriteTeamWindowRow
                .opacity(
                    viewModel.isAuthenticatedForSocialFeatures && notificationSettingsStore.favoriteTeamProGameAlertsEnabled ? 1 : 0.48
                )
                .disabled(!viewModel.isAuthenticatedForSocialFeatures || !notificationSettingsStore.favoriteTeamProGameAlertsEnabled)

            if !viewModel.isAuthenticatedForSocialFeatures {
                Text("Sign in to follow teams and receive game alerts.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.bottom, 10)
            }
        }
    }

    private var proGamesFavoriteTeamWindowRow: some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(FGColor.accentGreen)
            }
            .frame(width: SettingsPremiumChrome.rowIconSize, height: SettingsPremiumChrome.rowIconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text("Favorite Team Game Window")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                Text("How far ahead Going should look for your teams.")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("Favorite Team Game Window", selection: $proGamesFavoriteTeamWindowDays) {
                ForEach(ProGamesFavoriteTeamAutoFollowPreference.Window.allCases) { window in
                    Text(window.title).tag(window.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
        .frame(minHeight: SettingsPremiumChrome.rowMinHeight, alignment: .center)
    }

    @ViewBuilder
    func settingsSectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme).opacity(0.72))
            .tracking(0.8)
            .textCase(nil)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private func businessOwnersLoggedOutSectionHeader() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Business Owners")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
            Text("Own a sports bar, restaurant, gym, or venue?")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func loggedOutBusinessOwnerEntryCard() -> some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(FGColor.businessGreen.opacity(colorScheme == .dark ? 0.24 : 0.16))
                Image(systemName: "building.2.crop.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(FGColor.businessGreen)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text("Grow Your Sports Crowd")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                    .lineLimit(2)
                Text("Claim your venue and host watch parties.")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                Text("Business Tools")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.businessGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background {
                        Capsule(style: .continuous)
                            .fill(FGColor.businessGreen.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                    .frame(width: 14, height: 14, alignment: .center)
            }
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 11)
        .frame(minHeight: SettingsPremiumChrome.rowMinHeight, alignment: .center)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                    .fill(SettingsPremiumChrome.cardFill(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.92))
                RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                    .fill(FGColor.businessGreen.opacity(colorScheme == .dark ? 0.12 : 0.08))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                .strokeBorder(FGColor.businessGreen.opacity(colorScheme == .dark ? 0.24 : 0.18), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.06), radius: 10, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }



    func settingsSectionCard<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        SettingsSectionCardContainer(content: content)
    }

    struct SettingsSectionCardContainer<Content: View>: View {
        let content: () -> Content
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                        .fill(SettingsPremiumChrome.cardFill(colorScheme))
                    RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    SettingsPremiumChrome.cardHighlight(colorScheme),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                    .strokeBorder(SettingsPremiumChrome.cardStroke(colorScheme), lineWidth: 0.75)
            }
            .compositingGroup()
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.12 : 0.05),
                radius: SettingsPremiumChrome.scrollCardShadowRadius,
                y: SettingsPremiumChrome.scrollCardShadowYOffset
            )
        }
    }

    @ViewBuilder
    func settingsRowDivider() -> some View {
        Divider()
            .overlay(SettingsPremiumChrome.divider(colorScheme))
            .opacity(0.42)
            .padding(.leading, 58)
            .padding(.trailing, FGSpacing.md)
    }

    @ViewBuilder
    func settingsDestructiveSpacer() -> some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(SettingsPremiumChrome.divider(colorScheme))
                .opacity(0.22)
                .padding(.leading, 58)
                .padding(.trailing, FGSpacing.md)
            Color.clear
                .frame(height: 6)
        }
    }

    @ViewBuilder
    func settingsInlineNote(
        _ text: String,
        tint: Color? = nil,
        systemImage: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: FGSpacing.sm) {
            if let systemImage, !systemImage.isEmpty {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint ?? FGColor.mutedText(colorScheme))
                    .padding(.top, 2)
            }

            Text(text)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(tint ?? SettingsPremiumChrome.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    func settingsRow(title: String, subtitle: String?, systemImage: String, tint: Color = FGColor.accentGreen, showsChevron: Bool = true) -> some View {
        settingsRow(title: title, subtitle: subtitle, systemImage: systemImage, tint: tint, showsChevron: showsChevron) {
            EmptyView()
        }
    }

    @ViewBuilder
    func settingsRow(title: String, subtitle: String?, assetImage: String, showsChevron: Bool = true) -> some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                Image(assetImage)
                    .renderingMode(.original)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
            }
            .frame(width: SettingsPremiumChrome.rowIconSize, height: SettingsPremiumChrome.rowIconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                    .frame(width: 14, height: 14, alignment: .center)
            }
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
        .frame(minHeight: SettingsPremiumChrome.rowMinHeight, alignment: .center)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    func settingsRow<Trailing: View>(
        title: String,
        subtitle: String?,
        systemImage: String,
        tint: Color = FGColor.accentGreen,
        showsChevron: Bool = true,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
            }
            .frame(width: SettingsPremiumChrome.rowIconSize, height: SettingsPremiumChrome.rowIconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            trailing()

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                    .frame(width: 14, height: 14, alignment: .center)
            }
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
        .frame(minHeight: SettingsPremiumChrome.rowMinHeight, alignment: .center)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func liveActivitySharingRow() -> some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            HStack(alignment: .center, spacing: FGSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                    Image(systemName: "person.2.wave.2.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(FGColor.accentBlue)
                }
                .frame(width: SettingsPremiumChrome.rowIconSize, height: SettingsPremiumChrome.rowIconSize)

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("Live Activity Sharing", languageCode: appLanguageRaw))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                        .lineLimit(2)
                    Text(liveSharingModeSubtitle)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !viewModel.isUpdatingLiveVisibilitySetting else { return }
                showLiveSharingModeDialog = true
            }

            Spacer(minLength: 0)

            if viewModel.isUpdatingLiveVisibilitySetting {
                ProgressView()
                    .controlSize(.small)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                .frame(width: 14, height: 14, alignment: .center)

            Toggle(L10n.t("Live Activity Sharing", languageCode: appLanguageRaw), isOn: liveVisibilityBinding)
                .labelsHidden()
                .disabled(viewModel.isUpdatingLiveVisibilitySetting)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
        .frame(minHeight: SettingsPremiumChrome.rowMinHeight, alignment: .center)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !viewModel.isUpdatingLiveVisibilitySetting else { return }
            showLiveSharingModeDialog = true
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    func settingsToggleRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isOn: Binding<Bool>,
        isUpdating: Bool,
        tint: Color = FGColor.accentBlue,
        infoAccessibilityLabel: String? = nil,
        infoAccessibilityHint: String? = nil,
        onInfo: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
            }
            .frame(width: SettingsPremiumChrome.rowIconSize, height: SettingsPremiumChrome.rowIconSize)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .center, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                        .lineLimit(2)

                    if let onInfo, let infoAccessibilityLabel {
                        SettingsPrivacyInfoButton(
                            accessibilityLabel: infoAccessibilityLabel,
                            accessibilityHint: infoAccessibilityHint
                                ?? L10n.t("privacy_setting_info_hint", languageCode: appLanguageRaw),
                            action: onInfo
                        )
                        .padding(.leading, -6)
                    }
                }

                Text(subtitle)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isUpdating {
                ProgressView()
                    .controlSize(.small)
            }

            Toggle(title, isOn: isOn)
                .labelsHidden()
                .disabled(isUpdating)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
        .frame(minHeight: SettingsPremiumChrome.rowMinHeight, alignment: .center)
        .accessibilityElement(children: onInfo == nil ? .combine : .contain)
    }

    /// Non-interactive settings row (no chevron) for read-only info such as venue claim status.
    @ViewBuilder
    func settingsInfoRow(title: String, subtitle: String?, systemImage: String, tint: Color = FGColor.accentGreen) -> some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
            }
            .frame(width: SettingsPremiumChrome.rowIconSize, height: SettingsPremiumChrome.rowIconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
        .frame(minHeight: SettingsPremiumChrome.rowMinHeight, alignment: .center)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private var shouldShowInlineBusinessDashboard: Bool {
        viewModel.isVenueOwnerLoggedIn
            && viewModel.hasBusinessAccountForOwner()
            && !viewModel.hasArchivedBusinessAccountForOwner()
            && !viewModel.managedVenuesForOwner().isEmpty
    }

    private var businessProfileVenueHydrationState: BusinessProfileVenueHydrationState {
        let managedVenues = viewModel.managedVenuesForOwner()
        let managedCount = managedVenues.count
        let selectedVenueId = viewModel.ownerVenueDatabaseId

        guard !managedVenues.isEmpty else {
            if viewModel.isVenueOwnerBusinessDataLoading {
                return BusinessProfileVenueHydrationState(isReady: false, reason: "businessDataLoading", selectedVenueId: selectedVenueId, managedCount: managedCount)
            }
            if settingsBusinessProfileHydrationInFlight {
                return BusinessProfileVenueHydrationState(isReady: false, reason: "businessProfileHydrationInFlight", selectedVenueId: selectedVenueId, managedCount: managedCount)
            }
            return BusinessProfileVenueHydrationState(isReady: false, reason: "noManagedVenues", selectedVenueId: selectedVenueId, managedCount: managedCount)
        }
        guard let selectedVenueId else {
            return BusinessProfileVenueHydrationState(isReady: false, reason: "selectedVenueNil", selectedVenueId: nil, managedCount: managedCount)
        }
        guard let selectedVenue = managedVenues.first(where: { $0.id == selectedVenueId }) else {
            return BusinessProfileVenueHydrationState(isReady: false, reason: "selectedVenueStale", selectedVenueId: selectedVenueId, managedCount: managedCount)
        }
        guard MapViewModel.venueIsActiveForBusinessLimit(selectedVenue) else {
            return BusinessProfileVenueHydrationState(isReady: false, reason: "selectedVenueInactive", selectedVenueId: selectedVenueId, managedCount: managedCount)
        }
        return BusinessProfileVenueHydrationState(isReady: true, reason: "ready", selectedVenueId: selectedVenueId, managedCount: managedCount)
    }

    private var businessProfileVenueHydrationLogToken: String {
        let state = businessProfileVenueHydrationState
        return "\(state.isReady)|\(state.reason)|\(state.selectedVenueId?.uuidString.lowercased() ?? "nil")|\(state.managedCount)"
    }

    private var businessProfileVenueSelectorIsHydrating: Bool {
        let state = businessProfileVenueHydrationState
        return !state.isReady && state.reason != "noManagedVenues"
    }

    private func logBusinessProfileHydrationState() {
#if DEBUG
        let state = businessProfileVenueHydrationState
        if state.isReady {
            print("[BusinessProfileHydrationDebug] ready=true selectedVenueId=\(state.selectedVenueId?.uuidString.lowercased() ?? "nil") managedCount=\(state.managedCount)")
        } else {
            print("[BusinessProfileHydrationDebug] ready=false reason=\(state.reason)")
        }
#endif
    }

    private func logBusinessProfileHydrationBlockedEarlyTap(action: String, reason: String) {
#if DEBUG
        print("[BusinessProfileHydrationDebug] blockedEarlyTap action=\(action) reason=\(reason)")
#endif
    }

    @MainActor
    private func businessProfileVenueHydrationAllowsAction(_ action: String) -> Bool {
        let state = businessProfileVenueHydrationState
        guard state.isReady else {
            logBusinessProfileHydrationBlockedEarlyTap(action: action, reason: state.reason)
            return false
        }
        return true
    }

    private var settingsBusinessIdentityBusinessRow: BusinessRow? {
        if let businessId = viewModel.currentBusinessIdForAddLocation(),
           let business = viewModel.ownedBusinesses.first(where: { $0.id == businessId }) {
            return business
        }
        return viewModel.ownedBusinesses.first
    }

    private var settingsBusinessIdentityInitialDisplayName: String {
        settingsBusinessIdentityBusinessRow?.display_name ?? ""
    }

    private var settingsBusinessIdentityInitialHandle: String? {
        let raw = settingsBusinessIdentityBusinessRow?.business_handle?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    private var settingsBusinessIdentitySuggestedHandlePlaceholder: String {
        BusinessProfileDefaults.defaultHandle(email: viewModel.venueOwnerEmail)
    }

    private var settingsInlineBusinessDashboard: some View {
        BusinessVenueDashboardOverviewView(
            data: settingsBusinessDashboardResolvedData,
            businessId: viewModel.currentBusinessIdForAddLocation(),
            businessUsageStatus: settingsBusinessMembershipStatus,
            activeVenueSelectionNotice: businessDashboardQuickActionNotice,
            activeVenueSelectionFootnote: settingsActiveVenueSelectionQuickActionFootnote,
            onChooseActiveVenues: settingsShouldShowBusinessActiveVenueSelection
                ? { showBusinessActiveVenueSelectionSheet = true }
                : nil,
            onNotifications: {
                presentBusinessDashboardQuickAction(source: "notifications") {
                    showReportedCommentsSheet = true
                }
            },
            onMenu: {
                openBusinessVenueToolRoute(.manageVenue)
            },
            onAddGame: {
                openBusinessVenueToolRoute(.manageVenue)
            },
            onAddVenue: {
                openAddLocationFromBusinessDashboard()
            },
            onClaimVenue: {
                openAddLocationFromBusinessDashboard()
            },
            onTonightGames: {
                openBusinessVenueToolRoute(.manageGames)
            },
            onPredictions: {
                openBusinessVenueToolRoute(.statistics)
            },
            onAnalytics: {
                openBusinessVenueToolRoute(.statistics)
            },
            onUsage: {
                presentBusinessDashboardQuickAction(source: "usageQuickAction") {
                    showBusinessUsageSheet = true
                }
            },
            favoriteTeams: FavoriteTeamsStore.resolvedTeams(
                fromIDs: Array(viewModel.businessFavoriteTeamIDs).sorted()
            ),
            onManageFavoriteTeams: {
                presentBusinessDashboardQuickAction(source: "favoriteTeamsQuickAction") {
                    showBusinessFavoriteTeamsSheet = true
                }
            },
            onManageVenues: {
                presentBusinessDashboardQuickAction(source: "manageVenuesQuickAction") {
                    businessProfileManagedVenuesSheetToken &+= 1
                }
            },
            onBusinessIdentity: {
                presentBusinessDashboardQuickAction(source: "businessIdentityQuickAction") {
                    showBusinessIdentitySheet = true
                }
            },
            onEditApprovedVenue: openManagedVenueDetailsForEditing,
            onCommentsReports: {
                presentBusinessDashboardQuickAction(source: "commentsReportsQuickAction") {
                    showReportedCommentsSheet = true
                }
            },
            onViewAllGames: {
                openBusinessVenueToolRoute(.manageGames)
            },
            onRefreshVenues: {
                await refreshSettingsManagedVenuesSection()
            },
            onRefreshPendingVenue: { venue in
                await refreshPendingVenueClaimFromDashboard(venue)
            },
            onResendPendingVenue: { venue in
                await resendPendingVenueClaimFromDashboard(venue)
            },
            onCancelPendingVenue: { venue in
                await viewModel.cancelBusinessVenueClaim(claimId: venue.id)
            },
            showsManagedVenuesSection: true,
            isStatisticsProActive: settingsBusinessStatisticsAccessGranted,
            isAddVenueAllowed: settingsBusinessCanCreateVenueFromServer,
            isHostedGameAllowed: settingsBusinessCanHostGameFromServer,
            isVenueHydrationReady: businessProfileVenueHydrationState.isReady,
            venueHydrationReason: businessProfileVenueHydrationState.reason
        )
        .onAppear {
            refreshSettingsBusinessDashboardCache()
            logBusinessProfileHydrationState()
            logSettingsInlineBusinessDashboardDebug()
        }
        .onReceive(viewModel.$ownedBusinessVenues) { _ in
            refreshSettingsBusinessDashboardCache()
        }
        .onReceive(viewModel.$pendingVenueClaimsForSettings) { _ in
            refreshSettingsBusinessDashboardCache()
        }
        .onReceive(viewModel.$ownerVenueDatabaseId) { _ in
            refreshSettingsBusinessDashboardCache()
        }
        .onChange(of: inlineBusinessDashboardGames.map(\.id)) { _, _ in
            refreshSettingsBusinessDashboardCache()
        }
        .onChange(of: settingsBusinessMembershipStatus) { _, _ in
            refreshSettingsBusinessDashboardCache()
        }
        .onChange(of: viewModel.selectedTimeZone) { _, _ in
            refreshSettingsBusinessDashboardCache()
        }
        .onChange(of: businessProfileVenueHydrationLogToken) { _, _ in
            logBusinessProfileHydrationState()
        }
        .task(id: settingsInlineBusinessDashboardLoadToken) {
            await refreshSettingsInlineBusinessDashboardPreload()
        }
    }

    private var settingsBusinessDashboardResolvedData: BusinessVenueDashboardData {
        settingsBusinessDashboardCachedData ?? settingsBusinessDashboardData
    }

    private func refreshSettingsBusinessDashboardCache() {
        let next = settingsBusinessDashboardData
        if settingsBusinessDashboardCachedData != next {
            settingsBusinessDashboardCachedData = next
        }
    }

    private var settingsInlineBusinessDashboardLoadToken: String {
        if let venueID = viewModel.ownerVenueDatabaseId {
            return venueID.uuidString
        }
        return OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
    }

    private var settingsBusinessStatisticsAccessGranted: Bool {
        settingsBusinessMembershipStatus?.statisticsAccessGranted == true
    }

    private var settingsBusinessCanCreateVenueFromServer: Bool {
        guard let status = settingsBusinessMembershipStatus, status.loadedFromServer else { return false }
        return status.canAddVenue
    }

    private var settingsBusinessCanHostGameFromServer: Bool {
        guard let status = settingsBusinessMembershipStatus, status.loadedFromServer else { return false }
        return status.canAddHostedGame
    }

    private var settingsBusinessProRowSubtitle: String {
        guard let status = settingsBusinessMembershipStatus else {
            return "Checking server-controlled access..."
        }
        guard status.computedIsPro else {
            return status.displayPlanLimitsSummarySubtitle
        }
        return status.businessPlanDisplaySubtitle
    }

    private func refreshSettingsBusinessHostedGameCycleAudit() async {
        guard let businessId = settingsBusinessMembershipStatus?.businessId ?? viewModel.currentBusinessIdForAddLocation() else {
            settingsBusinessHostedGameCycleAudit = nil
            settingsBusinessHostedGameCycleAuditLoading = false
            return
        }

        settingsBusinessHostedGameCycleAudit = nil
        settingsBusinessHostedGameCycleAuditUnavailable = false
        settingsBusinessHostedGameCycleAuditLoading = true
        do {
            let audit = try await viewModel.loadBusinessHostedGamesThisCycle(businessId: businessId)
            settingsBusinessHostedGameCycleAudit = audit
        } catch {
            settingsBusinessHostedGameCycleAudit = nil
            settingsBusinessHostedGameCycleAuditUnavailable = true
        }
        settingsBusinessHostedGameCycleAuditLoading = false
    }

    private static let settingsApprovedVenueDateDisplayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    private var settingsBusinessDashboardData: BusinessVenueDashboardData {
        BusinessVenueDashboardData(
            venueName: settingsBusinessDashboardVenueName,
            locationLine: settingsBusinessDashboardLocationLine,
            isVerified: viewModel.venueCoreIdentityLockedForSelectedVenue() || viewModel.venueIsApproved,
            managedVenueCount: viewModel.managedVenuesForOwner().count,
            venuePhotoURL: settingsBusinessDashboardVenuePhotoURL,
            venuePhotoThumbnailURL: settingsBusinessDashboardVenuePhotoThumbnailURL,
            fansGoing: settingsBusinessDashboardFansGoing,
            activeChats: settingsBusinessDashboardActiveChats,
            predictions: settingsBusinessDashboardPredictions,
            atmosphereRating: settingsBusinessDashboardAtmosphereRating,
            gameSectionContext: settingsBusinessDashboardGameSectionContext,
            games: settingsBusinessDashboardGameItems,
            approvedVenues: settingsBusinessDashboardApprovedVenueItems,
            pendingVenues: settingsBusinessDashboardPendingVenueItems
        )
    }

    private var settingsBusinessDashboardSelectedVenue: VenueProfileRow? {
        let managedVenues = viewModel.managedVenuesForOwner()
        if let venueID = viewModel.ownerVenueDatabaseId,
           let selected = managedVenues.first(where: { $0.id == venueID }) {
            return selected
        }
        return nil
    }

    private var settingsBusinessDashboardApprovedVenueItems: [BusinessVenueDashboardApprovedVenueItem] {
        let pendingVenueIDs = Set(viewModel.pendingVenueClaimsForSettings.compactMap(\.venue_id))
        let rows = viewModel.managedVenuesForOwner()
            .compactMap { row -> (item: BusinessVenueDashboardApprovedVenueItem, approvedAt: Date?, approvedAtDebug: String)? in
                guard let id = row.id, !pendingVenueIDs.contains(id) else { return nil }
                let name = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let city = row.city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let state = row.state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let approvedDate = settingsApprovedVenueDateInfo(for: row)
                return (
                    BusinessVenueDashboardApprovedVenueItem(
                        id: id,
                        name: name.isEmpty ? "Approved venue" : name,
                        locationLine: [city, state].filter { !$0.isEmpty }.joined(separator: ", "),
                        approvedDateText: approvedDate.displayText,
                        ownershipApprovalLine: ManagedVenueOwnershipDisplay.ownershipApprovalLine(
                            originType: row.origin_type,
                            approvedDateText: approvedDate.displayText
                        ),
                        venuePhotoURL: row.cover_photo_url?.trimmingCharacters(in: .whitespacesAndNewlines),
                        venuePhotoThumbnailURL: row.cover_photo_thumbnail_url?.trimmingCharacters(in: .whitespacesAndNewlines),
                        isPlanLocked: MapViewModel.venueDisplaysAsPlanLocked(
                            row,
                            effectiveMembership: settingsBusinessMembershipStatus ?? viewModel.effectiveBusinessMembershipStatus
                        )
                    ),
                    approvedDate.sortDate,
                    approvedDate.debugRaw
                )
            }
            .sorted { lhs, rhs in
                switch (lhs.approvedAt, rhs.approvedAt) {
                case let (left?, right?):
                    if left != right { return left > right }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
                return lhs.item.name.localizedCaseInsensitiveCompare(rhs.item.name) == .orderedAscending
            }

        return rows.enumerated().map { index, row in
#if DEBUG
            print("[BusinessApprovedVenuesDebug] venueId=\(row.item.id.uuidString.lowercased()) venueName=\(row.item.name) approvedAt=\(row.approvedAtDebug) sortIndex=\(index)")
#endif
            return row.item
        }
    }

    private func settingsApprovedVenueDateInfo(for row: VenueProfileRow) -> (displayText: String, sortDate: Date?, debugRaw: String) {
        let claimApprovedRaw = row.id.flatMap { venueId -> String? in
            guard let metadata = viewModel.approvedVenueClaimMetadataByVenueID[venueId] else { return nil }
            return metadata.approvedAtRaw ?? metadata.createdAtRaw
        }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !claimApprovedRaw.isEmpty {
            return settingsApprovedVenueDateInfo(raw: claimApprovedRaw)
        }

        let venueCreatedRaw = row.created_at?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !venueCreatedRaw.isEmpty {
            return settingsApprovedVenueDateInfo(raw: venueCreatedRaw)
        }

        return ("Approved date unavailable", nil, "nil")
    }

    private func settingsApprovedVenueDateInfo(raw: String) -> (displayText: String, sortDate: Date?, debugRaw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let date = SupabaseTimestampParsing.parseTimestamptz(trimmed) ?? settingsParseSupabaseTimestamptz(trimmed) else {
            return ("Approved \(String(trimmed.prefix(10)))", nil, trimmed)
        }
        return (
            "Approved \(Self.settingsApprovedVenueDateDisplayFormatter.string(from: date))",
            date,
            trimmed
        )
    }

    private var settingsBusinessDashboardPendingVenueItems: [BusinessVenueDashboardPendingVenueItem] {
        viewModel.pendingVenueClaimsForSettings
            .map(settingsBusinessDashboardPendingVenueItem(for:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func settingsBusinessDashboardPendingVenueItem(
        for claim: VenueClaimPendingSettingsRow
    ) -> BusinessVenueDashboardPendingVenueItem {
        let photoURL = claim.cover_photo_url?.trimmingCharacters(in: .whitespacesAndNewlines)
        return BusinessVenueDashboardPendingVenueItem(
            id: claim.id,
            name: settingsPendingClaimTitle(claim),
            locationLine: settingsPendingClaimLocationLine(claim),
            ownershipApprovalLine: "Business venue • Pending review",
            submittedDateText: settingsPendingClaimSubmittedDateText(claim),
            venuePhotoURL: photoURL?.isEmpty == false ? photoURL : nil,
            venuePhotoThumbnailURL: nil
        )
    }

    private var settingsBusinessDashboardVenueName: String {
        let selectedName = settingsBusinessDashboardSelectedVenue?.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !selectedName.isEmpty { return selectedName }

        let ownerName = viewModel.ownerVenueName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ownerName.isEmpty { return ownerName }
        if businessProfileVenueHydrationState.reason == "noManagedVenues" { return "No venue yet" }
        return businessProfileVenueHydrationState.isReady ? "Your venue" : "Loading venues..."
    }

    private var settingsBusinessDashboardLocationLine: String {
        let selectedCity = settingsBusinessDashboardSelectedVenue?.city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedState = settingsBusinessDashboardSelectedVenue?.state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ownerCity = viewModel.ownerVenueCity.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownerState = viewModel.ownerVenueState.trimmingCharacters(in: .whitespacesAndNewlines)
        let city = selectedCity.isEmpty ? ownerCity : selectedCity
        let state = selectedState.isEmpty ? ownerState : selectedState
        let parts = [city, state].filter { !$0.isEmpty }
        return parts.isEmpty ? "Venue dashboard" : parts.joined(separator: ", ")
    }

    private var settingsBusinessDashboardVenuePhotoURL: String? {
        let selected = settingsBusinessDashboardSelectedVenue?.cover_photo_url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !selected.isEmpty { return selected }

        let owner = viewModel.venueCoverPhotoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return owner.isEmpty ? nil : owner
    }

    private var settingsBusinessDashboardVenuePhotoThumbnailURL: String? {
        let selected = settingsBusinessDashboardSelectedVenue?.cover_photo_thumbnail_url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !selected.isEmpty { return selected }

        let owner = viewModel.venueCoverPhotoThumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return owner.isEmpty ? nil : owner
    }

    private var settingsBusinessDashboardEventIDs: [UUID] {
        inlineBusinessDashboardGames.compactMap(\.id)
    }

    private var settingsBusinessDashboardFansGoing: Int {
        settingsBusinessDashboardEventIDs.reduce(0) { $0 + viewModel.interestCountForVenueEvent($1) }
    }

    private var settingsBusinessDashboardActiveChats: Int {
        settingsBusinessDashboardEventIDs.reduce(0) { total, id in
            total + (viewModel.fanUpdatesStore.venueEventComments[id]?.count ?? 0)
        }
    }

    private var settingsBusinessDashboardPredictions: Int {
        settingsBusinessDashboardEventIDs.reduce(0) { total, id in
            total + (viewModel.venueEventPredictionSummaries[id]?.totalCount ?? 0)
        }
    }

    private var settingsBusinessDashboardTodayGamesCount: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return inlineBusinessDashboardGames.reduce(0) { total, row in
            guard let day = settingsBusinessDashboardGameDay(row),
                  calendar.isDate(day, inSameDayAs: today) else {
                return total
            }
            return total + 1
        }
    }

    private var settingsBusinessDashboardAtmosphereRating: String {
        guard let venueID = viewModel.ownerVenueDatabaseId,
              let bar = viewModel.bars.first(where: { $0.id == venueID }),
              viewModel.reviewCountDisplay(for: bar) > 0,
              let rating = viewModel.mergedDisplayRating(for: bar) else {
            return "New"
        }
        return String(format: "%.1f", rating)
    }

    private var settingsBusinessDashboardGameSectionContext: BusinessVenueDashboardGameSectionContext {
        BusinessVenueDashboardGameSectionResolver.resolve(
            gameDates: settingsBusinessDashboardUpcomingRows.map(\.start),
            calendar: Calendar.current
        )
    }

    private var settingsBusinessDashboardUpcomingRows: [(row: VenueEventRow, start: Date)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return inlineBusinessDashboardGames.compactMap { row in
            guard let start = settingsBusinessDashboardGameStartDate(row),
                  calendar.startOfDay(for: start) >= today else {
                return nil
            }
            return (row, start)
        }
        .sorted { $0.start < $1.start }
    }

    private var settingsBusinessDashboardGameItems: [BusinessVenueDashboardGameItem] {
        let sourceRows = Array(settingsBusinessDashboardUpcomingRows.prefix(3).map(\.row))

        return sourceRows.compactMap { row in
            guard let id = row.id else { return nil }
            let score = viewModel.venueOwnerEngagementScore(venueEventID: id)
            let energy = settingsBusinessDashboardEnergy(score: score)
            return BusinessVenueDashboardGameItem(
                id: id,
                title: settingsBusinessDashboardGameTitle(row),
                subtitle: settingsBusinessDashboardGameSubtitle(row),
                timeText: settingsBusinessDashboardGameTimeText(row),
                sportIconName: viewModel.iconForSport(row.sport ?? ""),
                goingCount: viewModel.interestCountForVenueEvent(id),
                energyLabel: energy.label,
                energyTint: energy.tint
            )
        }
    }

    private func settingsBusinessDashboardGameTitle(_ row: VenueEventRow) -> String {
        let title = VenueGameCompetitorDisplay.publicTitle(
            eventTitle: row.event_title,
            sport: row.sport,
            homeTeam: row.home_team,
            awayTeam: row.away_team
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Game" : title
    }

    private func settingsBusinessDashboardGameSubtitle(_ row: VenueEventRow) -> String {
        let league = row.external_league?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let league, !league.isEmpty { return league }

        let sport = row.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return sport.isEmpty ? "Venue game" : sport
    }

    private func settingsBusinessDashboardGameTimeText(_ row: VenueEventRow) -> String {
        BusinessVenueDashboardGameDateTimeFormatter.compactLabel(
            startDate: FanGeoLiveEnergyTiming.parseScheduledStart(row.scheduled_start_at),
            eventDateRaw: row.event_date,
            eventTimeRaw: row.event_time,
            timeZoneOption: viewModel.selectedTimeZone,
            calendar: Calendar.current
        )
    }

    private func settingsBusinessDashboardGameStartDate(_ row: VenueEventRow) -> Date? {
        if let start = FanGeoLiveEnergyTiming.parseScheduledStart(row.scheduled_start_at) {
            return start
        }
        return settingsBusinessDashboardGameDay(row)
    }

    private func settingsBusinessDashboardGameDay(_ row: VenueEventRow) -> Date? {
        if let start = FanGeoLiveEnergyTiming.parseScheduledStart(row.scheduled_start_at) {
            return start
        }

        let raw = row.event_date?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter.date(from: raw)
    }

    private func settingsBusinessDashboardEnergy(score: Int) -> (label: String, tint: Color) {
        // Display-only labels for venueOwnerEngagementScore buckets (thresholds unchanged).
        if score >= 30 {
            return (L10n.t("game_activity_busy", languageCode: appLanguageRaw), FGColor.accentGreen)
        }
        if score >= 8 {
            return (L10n.t("game_activity_building", languageCode: appLanguageRaw), FGColor.accentYellow)
        }
        return (L10n.t("game_activity_typical", languageCode: appLanguageRaw), FGColor.accentBlue)
    }

    private func refreshSettingsInlineBusinessDashboard(loadEngagementMetrics: Bool = false) async {
        guard shouldShowInlineBusinessDashboard else { return }
        let rows = await viewModel.loadMyVenueScheduledGames()
        let ids = rows.compactMap(\.id)

        await MainActor.run {
            inlineBusinessDashboardGames = rows
            logSettingsInlineBusinessDashboardDebug()
        }

        guard loadEngagementMetrics else { return }

        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    await viewModel.loadComments(for: id)
                    await viewModel.loadVibes(for: id)
                }
            }
        }

        await viewModel.loadVenueEventPredictionSummaries(eventIDs: ids)
        await MainActor.run {
            logSettingsInlineBusinessDashboardDebug()
        }
    }

    private func refreshSettingsInlineBusinessDashboardPreload() async {
        guard shouldShowInlineBusinessDashboard else { return }
        let snapshot = await viewModel.loadBusinessDashboardPreload()
        applySettingsBusinessDashboardPreloadSnapshot(snapshot)
    }

    @MainActor
    private func applySettingsBusinessDashboardPreloadSnapshot(
        _ snapshot: BusinessDashboardPreloadSnapshot?,
        requestId: Int? = nil
    ) {
        if let requestId, requestId != settingsBusinessProfileLatestRequestId { return }
        guard let snapshot else { return }
        inlineBusinessDashboardGames = snapshot.scheduledGames
        if let status = snapshot.entitlementStatus {
            if settingsBusinessMembershipStatus?.computedIsPro == true && !status.loadedFromServer {
                return
            }
            settingsBusinessMembershipStatus = status
            viewModel.effectiveBusinessMembershipStatus = status
            settingsBusinessProfileLastEntitlementSignature = settingsBusinessEntitlementSignature
        }
        logSettingsInlineBusinessDashboardDebug()
    }

    private func refreshSettingsBusinessProfile(
        trigger: String,
        refreshBusinessData: Bool,
        debounce: Bool = false
    ) async {
        guard isBusinessAccountProfileContext || viewModel.isVenueOwnerLoggedIn else { return }
        let startedAt = Date()
        let cachedDataAvailableAtStart = settingsBusinessProfileHasCachedData
        let passiveRefresh = isPassiveSettingsBusinessProfileRefresh(trigger: trigger)
        if passiveRefresh {
            if settingsBusinessProfileHydrationInFlight {
                logBusinessProfilePerformance(
                    event: "refreshSkipped trigger=\(trigger) reason=inFlight cachedDataAvailable=\(cachedDataAvailableAtStart)"
                )
#if DEBUG
                SettingsPerf.log("expensive task skipped=refreshSettingsBusinessProfile reason=inFlight trigger=\(trigger)")
#endif
                return
            }
            if let lastRefresh = settingsBusinessProfileLastPassiveRefreshAt,
               startedAt.timeIntervalSince(lastRefresh) < settingsBusinessProfilePassiveRefreshTTL {
                let ageMs = Int(startedAt.timeIntervalSince(lastRefresh) * 1000)
                logBusinessProfilePerformance(
                    event: "refreshSkipped trigger=\(trigger) reason=ttl ageMs=\(ageMs) cachedDataAvailable=\(cachedDataAvailableAtStart)"
                )
#if DEBUG
                SettingsPerf.log("expensive task skipped=refreshSettingsBusinessProfile reason=ttl ageMs=\(ageMs) trigger=\(trigger)")
#endif
                return
            }
            settingsBusinessProfileLastPassiveRefreshAt = startedAt
        }
        let requestId = nextSettingsBusinessProfileRefreshRequestId()
        settingsBusinessProfileHydrationInFlight = true
        logBusinessProfilePerformance(
            event: "refreshStarted trigger=\(trigger) requestId=\(requestId) cachedDataAvailable=\(cachedDataAvailableAtStart) refreshBusinessData=\(refreshBusinessData)"
        )
        logBusinessProfileHydrationState()
        defer {
            Task { @MainActor in
                guard requestId == settingsBusinessProfileLatestRequestId else { return }
                settingsBusinessProfileHydrationInFlight = false
                let finishedAt = Date()
                let durationMs = Int(finishedAt.timeIntervalSince(startedAt) * 1000)
                let didUIClearCachedState = cachedDataAvailableAtStart && !settingsBusinessProfileHasCachedData
                logBusinessProfilePerformance(
                    event: "refreshFinished trigger=\(trigger) requestId=\(requestId) durationMs=\(durationMs) cachedDataAvailable=\(settingsBusinessProfileHasCachedData) didUIClearCachedState=\(didUIClearCachedState)"
                )
                logBusinessProfileHydrationState()
            }
        }
        if debounce {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard !Task.isCancelled else { return }

        var preloadStatus: BusinessVenueGamePostingStatus?
        if refreshBusinessData {
            if !settingsBusinessProfileHasCachedData {
                await MainActor.run {
                    settingsBusinessMembershipStatus = nil
                }
            } else {
#if DEBUG
                SettingsPerf.log("expensive task skipped=clearMembershipStatus reason=cachedBusinessDataAvailable")
#endif
            }
            let snapshot = await viewModel.loadBusinessDashboardPreload(force: trigger == "manualRefresh")
            preloadStatus = snapshot?.entitlementStatus
            applySettingsBusinessDashboardPreloadSnapshot(snapshot, requestId: requestId)
        } else if shouldShowInlineBusinessDashboard {
            await refreshSettingsInlineBusinessDashboard()
        }

        if preloadStatus == nil {
            await refreshSettingsBusinessProStatus(trigger: trigger, requestId: requestId)
        }
        await viewModel.refreshCurrentBusinessFanGeoPlusEntitlementFromServer(reason: "settingsBusinessProfile:\(trigger)")
        syncFanGeoPlusDisplayFromEntitlements()
    }

    private var settingsBusinessProfilePassiveRefreshTTL: TimeInterval { 30 }

    private func isPassiveSettingsBusinessProfileRefresh(trigger: String) -> Bool {
        trigger == "accountTabAppears" || trigger == "foreground"
    }

    private func logBusinessProfilePerformance(event: String) {
#if DEBUG
        print("[BusinessProfilePerf] \(event) cachedDataAvailable=\(settingsBusinessProfileHasCachedData) businessDataLoading=\(viewModel.isVenueOwnerBusinessDataLoading) hydrationInFlight=\(settingsBusinessProfileHydrationInFlight)")
#endif
    }

    private func nextSettingsBusinessProfileRefreshRequestId() -> Int {
        settingsBusinessProfileRefreshSequence += 1
        settingsBusinessProfileLatestRequestId = settingsBusinessProfileRefreshSequence
        return settingsBusinessProfileLatestRequestId
    }

    private var settingsBusinessEntitlementSignature: String {
        let businessId = viewModel.currentBusinessIdForAddLocation()?.uuidString.lowercased() ?? "nil"
        let ownerEmail = OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
        let entitlementUpdatedAt = settingsBusinessEntitlementUpdatedAt(for: viewModel.currentBusinessIdForAddLocation()) ?? "nil"
        return "\(businessId)|\(ownerEmail)|\(entitlementUpdatedAt)"
    }

    private func settingsBusinessEntitlementUpdatedAt(for businessId: UUID?) -> String? {
        let rows = viewModel.ownedBusinesses
        guard let businessId else {
            return rows
                .compactMap { $0.entitlement_updated_at?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted()
                .last
        }
        return rows
            .first(where: { $0.id == businessId })?
            .entitlement_updated_at?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshSettingsBusinessProStatus(trigger: String, requestId: Int) async {
        guard viewModel.hasBusinessAccountForOwner() || viewModel.currentBusinessIdForAddLocation() != nil else { return }
        let previousStatus = settingsBusinessMembershipStatus
        let currentBusinessId = viewModel.currentBusinessIdForAddLocation()
        let businessId = trigger == "businessProSheet"
            ? (previousStatus?.businessId ?? currentBusinessId)
            : currentBusinessId
        let status = await viewModel.businessVenueGamePostingStatus(
            storeKitBusinessProActive: false,
            businessId: businessId
        )
        let ignoredStaleResponse = requestId != settingsBusinessProfileLatestRequestId
        guard !ignoredStaleResponse else { return }

        if previousStatus?.computedIsPro == true && !status.loadedFromServer {
            return
        }

        if settingsBusinessMembershipStatus != status {
            settingsBusinessMembershipStatus = status
            viewModel.effectiveBusinessMembershipStatus = status
        }
        settingsBusinessProfileLastEntitlementSignature = settingsBusinessEntitlementSignature
        logBusinessStatisticsGateDebug(status)
    }

    private func logBusinessStatisticsGateDebug(_ status: BusinessVenueGamePostingStatus) {
#if DEBUG
        print("[BusinessStatisticsGateDebug] businessId=\(status.businessId?.uuidString.lowercased() ?? "nil") planType=\(status.planType) planStatus=\(status.planStatus) statisticsEnabled=\(status.statisticsEnabled) computedIsPro=\(status.computedIsPro) isStatisticsLocked=\(status.isStatisticsLocked)")
#endif
    }

    /// Manual Managed venues header refresh — same batched path as the Managed Venues sheet / pending-claim refresh.
    private func refreshSettingsManagedVenuesSection() async {
        if settingsManagedVenuesManualRefreshInFlight { return }
        settingsManagedVenuesManualRefreshInFlight = true
        defer { settingsManagedVenuesManualRefreshInFlight = false }

        guard viewModel.isVenueOwnerLoggedIn || isBusinessAccountProfileContext else {
            viewModel.showSocialActionToast(
                L10n.t(
                    "business_managed_venues_refresh_failed",
                    languageCode: L10n.normalizedLanguageCode(appLanguageRaw)
                ),
                isError: true
            )
            return
        }

#if DEBUG
        print("[BusinessManagedVenuesDebug] manualRefreshPath=ownedBusinessesAndPendingClaims")
#endif
        await viewModel.refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
        await viewModel.refreshPendingVenueClaimsForSettings()
        await viewModel.refreshVenueClaimStatusLineFromDatabase()
        await viewModel.refreshManagedVenueUpcomingGamesSummaries()
        await MainActor.run {
            refreshSettingsBusinessDashboardCache()
        }
    }

    private func refreshPendingVenueClaimFromDashboard(_ venue: BusinessVenueDashboardPendingVenueItem) async -> Bool {
        let removed = await viewModel.refreshPendingVenueClaimDirectly(claimId: venue.id)
        await refreshSettingsInlineBusinessDashboard()
        return removed
    }

    private func resendPendingVenueClaimFromDashboard(_ venue: BusinessVenueDashboardPendingVenueItem) async -> Bool {
        let sent = await viewModel.resendPendingVenueClaimRequest(claimId: venue.id)
        await refreshSettingsInlineBusinessDashboard()
        return sent
    }

    private func logSettingsInlineBusinessDashboardDebug() {
#if DEBUG
        print("[BusinessDashboardDebug] inlineOverviewRendered")
        print("[BusinessDashboardDebug] venueLoaded=\(!settingsBusinessDashboardVenueName.isEmpty)")
        print("[BusinessDashboardDebug] gamesLoaded=\(inlineBusinessDashboardGames.count)")
        print("[BusinessDashboardDebug] crowdMetrics=\(settingsBusinessDashboardFansGoing)")
        print("[BusinessDashboardDebug] predictionsLoaded=\(settingsBusinessDashboardPredictions)")
        print("[BusinessDashboardCleanup] removedDuplicateIdentityRow=true")
#endif
    }

    private func settingsVenueClaimApprovedForStatusRow() -> Bool {
        viewModel.venueOwnerToolsUnlockedForUI()
    }

    /// Reloads businesses, managed venues, pending claims, and selected venue (via ``MapViewModel/refreshOwnedBusinessesAndVenuesAfterOwnerLogin()``), then claim status line.
    private func performPendingClaimRefresh(claimId: UUID) async {
#if DEBUG
        print("[PendingLocationRefresh] tapped claim_id=\(claimId.uuidString)")
#endif
        await MainActor.run { pendingRefreshingClaimId = claimId }
        defer {
            Task { @MainActor in
                if pendingRefreshingClaimId == claimId {
                    pendingRefreshingClaimId = nil
                }
            }
        }
        await viewModel.refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
        await viewModel.refreshPendingVenueClaimsForSettings()
        await viewModel.refreshVenueClaimStatusLineFromDatabase()
#if DEBUG
        let pendingCount = await MainActor.run { viewModel.pendingVenueClaimsForSettings.count }
        let rejectedCount = await MainActor.run { viewModel.rejectedVenueClaimsForSettings.count }
        let managedCount = await MainActor.run { viewModel.managedVenuesForOwner().count }
        print("[PendingLocationRefresh] complete pendingClaims=\(pendingCount) rejectedClaims=\(rejectedCount) managedVenues=\(managedCount)")
#endif
    }

    private func settingsApprovedVenueRows() -> [VenueProfileRow] {
        viewModel.managedVenuesForOwner()
            .sorted {
                let lhsDate = settingsApprovedVenueDateInfo(for: $0).sortDate
                let rhsDate = settingsApprovedVenueDateInfo(for: $1).sortDate
                switch (lhsDate, rhsDate) {
                case let (left?, right?):
                    if left != right { return left > right }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
                let lhs = $0.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let rhs = $1.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
    }

    @ViewBuilder
    private func settingsVenueReviewSections() -> some View {
        let approvedCount = settingsApprovedVenueRows().count
        let pendingCount = viewModel.pendingVenueClaimsForSettings.count
        let rejectedCount = viewModel.rejectedVenueClaimsForSettings.count

        VStack(alignment: .leading, spacing: 0) {
            Text("Venue portfolio")
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .padding(.horizontal, FGSpacing.md)
                .padding(.top, FGSpacing.md)
                .padding(.bottom, FGSpacing.sm)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: FGSpacing.sm) {
                    settingsVenueStatusSummaryPill(
                        title: "\(approvedCount) Approved",
                        tint: approvedCount > 0 ? FGColor.accentGreen : FGColor.mutedText(colorScheme)
                    )
                    settingsVenueStatusSummaryPill(
                        title: "\(pendingCount) Pending",
                        tint: pendingCount > 0 ? FGColor.accentYellow : FGColor.mutedText(colorScheme)
                    )
                    settingsVenueStatusSummaryPill(
                        title: "\(rejectedCount) Rejected",
                        tint: rejectedCount > 0 ? FGColor.dangerRed : FGColor.mutedText(colorScheme)
                    )
                }
                .padding(.horizontal, FGSpacing.md)
                .padding(.bottom, FGSpacing.md)
            }

            if pendingCount > 0 {
                settingsBlockDivider()
                settingsPendingVenueClaimsList()
            }

            if rejectedCount > 0 {
                settingsBlockDivider()
                rejectedVenueClaimsList()
            }
        }
    }

    @ViewBuilder
    private func settingsVenueStatusSummaryPill(title: String, tint: Color) -> some View {
        FGStatusPill(title: title, kind: .custom(tint: tint))
    }

    @ViewBuilder
    private func settingsBlockDivider() -> some View {
        Divider()
            .overlay(FGColor.divider(colorScheme))
            .padding(.horizontal, FGSpacing.md)
    }

    private static let rejectedVenueClaimMessage =
        "This location request was rejected. Please submit a new venue request."

    @ViewBuilder
    private func rejectedVenueClaimsList() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Rejected locations")
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .padding(.horizontal, FGSpacing.md)
                .padding(.top, FGSpacing.md)
                .padding(.bottom, FGSpacing.xs)

            ForEach(Array(viewModel.rejectedVenueClaimsForSettings.enumerated()), id: \.element.id) { index, claim in
                let rowBusy = pendingRefreshingClaimId == claim.id
                let anyRowRefreshing = pendingRefreshingClaimId != nil
                if index > 0 {
                    settingsRowDivider()
                }
                HStack(alignment: .top, spacing: FGSpacing.md) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(settingsPendingClaimTitle(claim))
                            .font(FGTypography.cardTitle)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                        if let line = settingsPendingClaimCityStateLine(claim) {
                            Text(line)
                                .font(FGTypography.caption)
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        }
                        FGStatusPill(title: "Rejected", kind: .custom(tint: FGColor.dangerRed))
                        Text(Self.rejectedVenueClaimMessage)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.dangerRed)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 2) {
                        Button {
                            Task {
                                await viewModel.acknowledgeRejectedVenueClaim(claimId: claim.id)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(Color.secondary)
                                Text("Dismiss")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                            .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.58 : 0.96))
                            .clipShape(Capsule(style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss rejected location message")

                        Button {
                            Task { await performPendingClaimRefresh(claimId: claim.id) }
                        } label: {
                            Group {
                                if rowBusy {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 15, weight: .semibold))
                                        .symbolRenderingMode(.hierarchical)
                                        .foregroundStyle(anyRowRefreshing ? Color.secondary.opacity(0.45) : Color.secondary)
                                }
                            }
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                            .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.58 : 0.96))
                            .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(anyRowRefreshing || viewModel.isVenueOwnerBusinessDataLoading)
                        .accessibilityLabel("Refresh status for this location")
                    }
                }
                .padding(.horizontal, FGSpacing.md)
                .padding(.vertical, FGSpacing.md)
                .transition(.opacity.combined(with: .scale(scale: 0.99)))
            }
        }
        .animation(.easeOut(duration: 0.22), value: viewModel.rejectedVenueClaimsForSettings.map(\.id))
    }

    private func settingsBusinessAccountSubtitle() -> String {
        if viewModel.hasArchivedBusinessAccountForOwner() {
            return "Business account archived"
        }
        if viewModel.hasPendingVerifiedBusinessVenueSetup,
           viewModel.pendingBusinessDraftMatchesBusinessAuthEmail(viewModel.venueOwnerEmail) {
            return "Finish setup — add your first venue for FanGeo review."
        }
        guard viewModel.hasBusinessAccountForOwner() else {
            return "Not set up — create your business account to get started."
        }
        if let member = settingsBusinessMemberSinceLine() {
            return "Active • \(member)"
        }
        return "Active"
    }

    private func settingsBusinessMemberSinceLine() -> String? {
        let raws = viewModel.ownedBusinesses
            .compactMap(\.created_at)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let raw = raws.sorted().first else { return nil }
        guard let date = settingsParseSupabaseTimestamptz(raw) else {
            return String(format: L10n.t("member_since_format", languageCode: appLanguageRaw), raw)
        }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return String(format: L10n.t("member_since_format", languageCode: appLanguageRaw), f.string(from: date))
    }

    private func settingsSocialToastBanner(text: String, isError: Bool) -> some View {
        HStack(spacing: FGSpacing.sm) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? FGColor.accentYellow : FGColor.accentGreen)
            Text(text)
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(2)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, FGSpacing.sm)
        .background(.ultraThinMaterial)
        .clipShape(Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.06), radius: 10, y: 4)
    }

    private func settingsParseSupabaseTimestamptz(_ raw: String) -> Date? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: t) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: t)
    }

    private func settingsLocationStatusTint() -> Color {
        switch viewModel.businessSettingsLocationChrome() {
        case .approved:
            return .green
        case .pendingReview:
            return .orange
        case .rejected:
            return .red
        case .archivedBusinessAccount:
            return .red
        case .noLocationsYet, .needsBusinessAccountFirst:
            return .secondary
        }
    }

    private func settingsPendingClaimTitle(_ claim: VenueClaimPendingSettingsRow) -> String {
        let n = claim.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? "Location request" : n
    }

    private func settingsPendingClaimCityStateLine(_ claim: VenueClaimPendingSettingsRow) -> String? {
        let city = claim.venue_city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let st = claim.venue_state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let country = claim.venue_country.map(BusinessLocationCountryPolicy.countryName(for:)) ?? ""
        let line = [city, st, country].filter { !$0.isEmpty }.joined(separator: ", ")
        return line.isEmpty ? nil : line
    }

    private func settingsPendingClaimLocationLine(_ claim: VenueClaimPendingSettingsRow) -> String {
        if let cityState = settingsPendingClaimCityStateLine(claim) {
            return cityState
        }
        let address = claim.venue_address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return address
    }

    @ViewBuilder
    private func settingsPendingVenueClaimsList() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pending review")
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .padding(.horizontal, FGSpacing.md)
                .padding(.top, FGSpacing.md)
                .padding(.bottom, FGSpacing.xs)

            ForEach(Array(viewModel.pendingVenueClaimsForSettings.enumerated()), id: \.element.id) { index, claim in
                if index > 0 {
                    settingsRowDivider()
                }
                settingsPendingVenueClaimRow(claim)
            }
        }
    }

    @ViewBuilder
    private func settingsPendingVenueClaimRow(_ claim: VenueClaimPendingSettingsRow) -> some View {
        let photoURL = claim.cover_photo_url?.trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(alignment: .center, spacing: FGSpacing.md) {
            settingsPendingVenueClaimThumbnail(photoURL: photoURL)

            VStack(alignment: .leading, spacing: 4) {
                Text(settingsPendingClaimTitle(claim))
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)
                if let line = settingsPendingClaimCityStateLine(claim) {
                    Text(line)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                } else if let address = claim.venue_address?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty {
                    Text(address)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }
                Text("Business venue • Pending review")
                    .font(FGTypography.metadata.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(2)
                Text(settingsPendingClaimSubmittedDateText(claim))
                    .font(FGTypography.metadata)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            FGStatusPill(title: "Pending", kind: .pending)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, FGSpacing.sm)
    }

    @ViewBuilder
    private func settingsPendingVenueClaimThumbnail(photoURL: String?) -> some View {
        let trimmed = photoURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ZStack {
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .fill(Color.orange.opacity(colorScheme == .dark ? 0.18 : 0.10))
            if !trimmed.isEmpty, let url = URL(string: trimmed) {
                CachedRemoteImagePhaseView(url: url, bucket: .venue) { phase in
                    switch phase {
                    case .success(let uiImage):
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        Image(systemName: "building.2.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.orange)
                    case .empty:
                        ProgressView()
                            .tint(.orange)
                    }
                }
            } else {
                Image(systemName: "building.2.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
    }

    private func settingsPendingClaimSubmittedDateText(_ claim: VenueClaimPendingSettingsRow) -> String {
        guard let raw = claim.created_at?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "Submitted date unavailable"
        }
        guard let date = SupabaseTimestampParsing.parseTimestamptz(raw) ?? settingsParseSupabaseTimestamptz(raw) else {
            return "Submitted \(String(raw.prefix(10)))"
        }
        return "Submitted \(date.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    /// Signed-out Profile: open Discover Venues (Calendar-style; guests may browse).
    private func openDiscoverForVenuesFromProfile() {
        if viewModel.discoverMapContentMode != .venues {
            viewModel.clearDiscoverMapContentSelectionsWhenSwitching(to: .venues)
            viewModel.discoverMapContentMode = .venues
        }
        selectedTab = .discover
    }

    /// Signed-out Profile: open Discover Pickup Games (Following/Calendar-style; guests may browse).
    private func openDiscoverForPickupGamesFromProfile() {
        if viewModel.discoverMapContentMode != .pickupGames {
            viewModel.clearDiscoverMapContentSelectionsWhenSwitching(to: .pickupGames)
            viewModel.discoverMapContentMode = .pickupGames
        }
        if viewModel.discoverPickupSubMode != .games {
            viewModel.discoverPickupSubMode = .games
        }
        selectedTab = .discover
    }

    /// Presents add-location sheet with a blank form (used from Current managed venue menu).
    private func openAddLocationFromPicker() {
        openAddLocationIfAllowed(action: "picker")
    }

    private func openManagedVenueDetailsForEditing(venueID: UUID) {
        Task {
            await viewModel.selectManagedVenue(id: venueID)
            openBusinessVenueToolRoute(.manageVenue)
        }
    }

    private func openBusinessVenueToolRoute(_ route: VenueOwnerDashboardSheetRoute) {
        Task {
            switch route {
            case .manageVenue, .manageGames, .statistics:
                let allowed = await MainActor.run {
                    businessProfileVenueHydrationAllowsAction(route.rawValue)
                }
                guard allowed else { return }
            case .businessDashboard:
                break
            }

            if await viewModel.businessBanGuardBlocks(path: "businessDashboard", action: route.rawValue) {
                return
            }

            if route == .manageVenue {
                guard await prepareVenueDetailsPresentationFromSettings(source: route.rawValue) else {
                    return
                }
            }

            await MainActor.run {
                switch route {
                case .manageVenue:
                    setVenueOwnerDashboardRoute(route, source: "openBusinessVenueToolRoute")
                case .manageGames:
                    guard viewModel.ensureValidSelectedManagedVenueForPresentation(source: route.rawValue) else {
#if DEBUG
                        print("[VenueOwnerEmptyStateDebug] noManagedVenues=true")
#endif
                        logBusinessProfileHydrationBlockedEarlyTap(action: route.rawValue, reason: "noValidSelectedVenueAfterRepair")
                        presentAddLocationSheet(reason: "businessDashboard")
                        return
                    }
                    setVenueOwnerDashboardRoute(route, source: "openBusinessVenueToolRoute")
                case .statistics:
                    guard viewModel.ensureValidSelectedManagedVenueForPresentation(source: route.rawValue) else {
                        businessDashboardQuickActionNotice = "Statistics unlock once an active managed venue is ready."
                        logBusinessProfileHydrationBlockedEarlyTap(action: route.rawValue, reason: "noValidSelectedVenueAfterRepair")
                        return
                    }
                    setVenueOwnerDashboardRoute(route, source: "openBusinessVenueToolRoute")
                case .businessDashboard:
                    setVenueOwnerDashboardRoute(route, source: "openBusinessVenueToolRoute")
                }
            }
        }
    }

    private func prepareVenueDetailsPresentationFromSettings(source: String) async -> Bool {
        let hasValidatedSelection = await MainActor.run {
            viewModel.ensureValidSelectedManagedVenueForPresentation(source: source)
        }
        guard hasValidatedSelection else {
            showVenueDetailsUnavailableNotice(source: source, reason: "noValidSelectedVenue")
            return false
        }

        guard let selectedVenueId = await MainActor.run(body: { viewModel.ownerVenueDatabaseId }) else {
            showVenueDetailsUnavailableNotice(source: source, reason: "missingSelectedVenueId")
            return false
        }

        guard let row = await viewModel.loadVenueProfile(),
              row.id == selectedVenueId,
              venueDetailsRowIsActiveForPresentation(row) else {
            showVenueDetailsUnavailableNotice(source: source, reason: "profileLoadFailedOrInactive")
            return false
        }

        await MainActor.run {
            viewModel.applyVenueProfileRowToOwnerState(row)
            businessDashboardQuickActionNotice = nil
        }
        return true
    }

    @MainActor
    private func showVenueDetailsUnavailableNotice(source: String, reason: String) {
        venueOwnerDashboardSheet = nil
        businessDashboardQuickActionNotice = "Venue Details are unavailable until an active managed venue is ready."
        logBusinessProfileHydrationBlockedEarlyTap(action: source, reason: reason)
    }

    private func venueDetailsRowIsActiveForPresentation(_ row: VenueProfileRow) -> Bool {
        let status = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return status.isEmpty || status == "active"
    }

    @MainActor
    private func setVenueOwnerDashboardRoute(
        _ route: VenueOwnerDashboardSheetRoute,
        source: String
    ) {
        let oldRoute = venueOwnerDashboardSheet
        guard oldRoute != route else {
#if DEBUG
            print("[BusinessDashboardRouteDebug] preventedDuplicateRoute route=\(route.rawValue)")
#endif
            return
        }
#if DEBUG
        print("[BusinessDashboardRouteDebug] routeSet source=\(source) oldRoute=\(oldRoute?.rawValue ?? "nil") newRoute=\(route.rawValue) selectedVenueId=\(viewModel.ownerVenueDatabaseId?.uuidString.lowercased() ?? "nil")")
#endif
        presentBusinessDashboardQuickAction(source: source, keepsVenueOwnerRoute: true) {
            venueOwnerDashboardSheet = route
        }
    }

    private func openAddLocationFromBusinessDashboard() {
        openAddLocationIfAllowed(action: "businessDashboard")
    }

    private func openAddLocationIfAllowed(action: String) {
        Task {
            if await viewModel.businessBanGuardBlocks(path: "addLocationSheet", action: action) {
                return
            }

            await MainActor.run {
                guard settingsBusinessCanCreateVenueFromServer else {
                    addLocationSubmitBanner = BusinessLimitCopy.Token.venueLimitReached
                    presentBusinessDashboardQuickAction(source: "\(action)LimitReached") {
                        showBusinessUsageSheet = true
                    }
                    return
                }
                presentAddLocationSheet(reason: action)
            }
        }
    }

    private func presentAddLocationSheet(reason: String) {
#if DEBUG
        print("[AddLocationForm] initialized fresh")
        print("[AddLocationForm] opened from \(reason)")
#endif
        addLocationSubmitBanner = nil
        addLocationSheetFormState.reset(reason: reason == "picker" ? "open" : reason)
        presentBusinessDashboardQuickAction(source: "addLocation.\(reason)") {
            showAddLocationSheet = true
        }
    }

    private func addLocationSubmitBannerForegroundStyle() -> Color {
        if addLocationSubmitBanner == BusinessLimitCopy.Token.venueLimitReached { return .red }
        if viewModel.hasActiveVenueClaimRejectionForBusinessUI { return .red }
        if viewModel.businessSettingsLocationChrome() == .rejected { return .red }
        return .green
    }

    private func addLocationSubmitBannerForegroundColor() -> Color {
        addLocationSubmitBannerForegroundStyle()
    }

    /// After Add Location succeeds we set ``addLocationSubmitBanner``; copy tracks ``approval_status`` via pending rows + location chrome.
    private func addLocationSubmitBannerDisplayText() -> String? {
        guard addLocationSubmitBanner != nil else { return nil }
        if addLocationSubmitBanner == BusinessLimitCopy.Token.venueLimitReached {
            return BusinessLimitCopy.venueLimitReached(languageCode: appLanguageRaw)
        }
        if !viewModel.pendingVenueClaimsForSettings.isEmpty {
            return "Location request submitted. FanGeo will review it before this location can manage games."
        }
        if viewModel.hasActiveVenueClaimRejectionForBusinessUI {
            return Self.rejectedVenueClaimMessage
        }
        switch viewModel.businessSettingsLocationChrome() {
        case .approved:
            return "Your location is approved and can now manage listings, games, and venue activity."
        case .pendingReview:
            return "Location request submitted. FanGeo will review it before this location can manage games."
        case .rejected:
            return Self.rejectedVenueClaimMessage
        case .archivedBusinessAccount:
            return nil
        case .noLocationsYet, .needsBusinessAccountFirst:
            return "Location request submitted. FanGeo will review it before this location can manage games."
        }
    }
}








































// MARK: - Venue owner sign-out
// Account-tab business log out uses ``MapViewModel/logoutUser()`` (full Supabase sign-out + session cleanup).
// ``MapViewModel/venueOwnerLocalSignOutPreservingSupabaseSession()`` remains for flows that must keep the auth session while clearing owner UI.
