import CoreLocation
import SwiftUI

/// Composition root: presents Discover, Live, Schedule, Going, Chat, and Account tabs using shared view models from the root container.
///
/// Inactive tabs stay in the hierarchy with opacity and hit testing disabled so map and list state survive tab switches. The root bootstrap container usually preloads startup data first; this view keeps a fallback ``.task`` only for timeout / degraded-entry cases.
struct MainTabView: View {
    private static var hasForcedDiscoverTabThisProcess = false
    private static var didResetImageCacheDiagnosticsThisProcess = false

    @ObservedObject var viewModel: MapViewModel
    /// Owned by `ContentView`; kept as a plain reference so Chat-only publications do not
    /// invalidate the complete root shell. Chat leaves observe this object directly.
    let chatViewModel: ChatViewModel
    @ObservedObject private var chatMainTabState: ChatMainTabState
    private let chatTabBadgeState: ChatTabBadgeState
    let performsInitialBootstrap: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("selectedMainTab") private var selectedTabStorage: String = AppTab.discover.rawValue

    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @AppStorage(PrivateChatSecuritySettings.requireFaceIDSettingKey) private var requireDeviceAuthForPrivateChat = false
    @State private var chatGateAlertMessage: String?
    @State private var didRunInitialPrivateChatTabGate = false
    @State private var showBlockingFanIdentitySetup = false
    @State private var lastAutoPresentedFanIdentitySetupUserId: UUID?
    @State private var privateChatUnlockedForCurrentSelection = false
    @State private var discoverCalendarOverlayPresented = false
    /// Sticky lazy mount: Discover at launch; other tabs insert on first selection and stay mounted.
    @State private var mountedTabs: Set<AppTab> = [.discover]
    /// Two-phase first mount: tabs whose heavy subtree has been constructed. A newly mounted
    /// tab renders a one-frame lightweight shell first so the selection change can commit
    /// before the expensive first construction runs (see `scheduleFirstMountContentActivation`).
    @State private var activatedTabContent: Set<AppTab> = [.discover]
    @State private var didStartChatSocialRealtime = false
    @State private var chatSocialRealtimeDeferTask: Task<Void, Never>?
    @State private var foregroundDeferredBatchTask: Task<Void, Never>?
    /// Last tab the user picked from the floating bar. Used only to report late startup routing
    /// that lands on a different tab (see ``TabTapPerf/selectionOverwritten(from:to:reason:)``).
    @State private var lastManualTabSelection: AppTab?
    @State private var tabSwitchStartAt: Date?
    @State private var tabSwitchCachedData: Bool?
    @State private var tabSwitchFromTab: AppTab?
    @State private var tabPreloadTasks: [AppTab: Task<Void, Never>] = [:]
    @State private var lastTabPreloadAt: [AppTab: Date] = [:]
    @State private var postAuthBadgeRefreshTask: Task<Void, Never>?
    @State private var postAuthBadgeRefreshUserId: UUID?
    @State private var lastPostAuthBadgeRefreshAt: Date?
    @State private var lastPostAuthBadgeRefreshUserId: UUID?

    private static let pokesBadgePollIntervalUnseenSeconds = 22
    private static let pokesBadgePollIntervalIdleSeconds = 105
    private static let chatSocialRealtimeGracePeriodSeconds: TimeInterval = 9
    private static let foregroundDeferredBatchDelayNs: UInt64 = 1_750_000_000
    private static let tabPreloadFreshnessInterval: TimeInterval = 30
    private static let tabIntentPreloadDeferDelayNs: UInt64 = 90_000_000
    private static let liveMatchesTabPreloadFreshnessInterval: TimeInterval = 90
    private static let postAuthBadgeRefreshThrottleInterval: TimeInterval = 4
    private static let postAuthBadgeRefreshCoalesceDelayNs: UInt64 = 140_000_000

    init(
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel,
        performsInitialBootstrap: Bool
    ) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        self.chatViewModel = chatViewModel
        _chatMainTabState = ObservedObject(wrappedValue: chatViewModel.mainTabState)
        self.chatTabBadgeState = chatViewModel.tabBadgeState
        self.performsInitialBootstrap = performsInitialBootstrap
    }

    private var selectedTab: AppTab {
        let restored = AppTab(rawValue: selectedTabStorage) ?? .discover
        // SceneStorage can restore `.account` at process start. Honoring it during the
        // FIRST body evaluation constructs SettingsScreen/ProfileIdentityCard before
        // `.onAppear` forces Discover, overflowing the main-thread stack in SwiftUI
        // generic-metadata instantiation (device crashes 2026-07-20, bug_type 309,
        // "stack guard region" SIGSEGV in ProfileIdentityCard.body). Treat Account as
        // Discover until the startup Discover force has run this process.
        if restored == .account, !Self.hasForcedDiscoverTabThisProcess {
#if DEBUG
            Self.logSuppressedSceneRestoredAccountOnce()
#endif
            return .discover
        }
        return restored
    }

#if DEBUG
    private static var didLogSuppressedSceneRestoredAccount = false
    private static func logSuppressedSceneRestoredAccountOnce() {
        guard !didLogSuppressedSceneRestoredAccount else { return }
        didLogSuppressedSceneRestoredAccount = true
        print("[StartupDiscover] suppressedSceneRestoredAccount=true reason=firstBodyPassBeforeDiscoverForce")
    }
#endif

    private var selectedTabBinding: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                beginTabSwitch(to: newTab, reason: "selectedTabBinding")
                mountTab(newTab, reason: "selectedTabBinding")
                selectedTabStorage = newTab.rawValue
#if DEBUG
                if MemoryAuditProbe.isEnabled {
                    MemoryAuditProbe.log("tab", details: "selected=\(newTab.rawValue) mounted=\(mountedTabs.map(\.rawValue).sorted().joined(separator: ","))")
                }
#endif
            }
        )
    }

    private func localized(_ key: String) -> String {
        L10n.t(key, languageCode: appLanguageRaw)
    }

    enum AppTab: String, CaseIterable {
        case discover
        case live
        case calendar
        case following
        case chat
        case account
    }

    /// Vertical space occupied by the floating capsule tab bar (padding + control height). Keeps Chat tab content above the overlay.
    private static let floatingTabBarStackHeight: CGFloat = 92

    var body: some View {
        let _ = MainTabObservationPerf.mainBodyEvaluated(selectedTab: selectedTab.rawValue)
        tabShellWithLifecycleModifiers
            .environmentObject(viewModel)
            .environmentObject(chatViewModel)
            .overlay {
                MainTabTransientOverlayLayer(viewModel: viewModel)
            }
            .overlay {
                MainTabSessionOverlayLayer(viewModel: viewModel)
            }
            .onChange(of: viewModel.safeLogoutNeedsDiscoverReset) { _, needsReset in
                guard needsReset else { return }
                SafeLogoutDebug.step("main_tab_reset_observed", detail: "onChange")
                settleSafeLogoutToDiscoverRoot()
            }
            .onChange(of: viewModel.safeLoginNeedsDiscoverReset) { _, needsReset in
                guard needsReset else { return }
                settleSafeLoginToDiscoverRoot()
            }
            .onChange(of: viewModel.safeLogoutPhase) { _, phase in
                if phase == .loggingOut {
                    chatViewModel.clearForSignOut()
                }
            }
            .onChange(of: viewModel.safeLoginPhase) { _, phase in
                if phase == .authenticating || phase == .preparingSession {
                    chatViewModel.clearForSignOut()
                }
            }
            .background {
                FanGeoAnnouncementMainTabRouter(viewModel: viewModel) { tabRaw in
                    guard let tab = AppTab(rawValue: tabRaw) else { return }
                    selectTab(tab, animated: false, reason: "announcementCTA")
                }
            }
            .fullScreenCover(isPresented: $showBlockingFanIdentitySetup) {
                FanGeoIdentitySetupView(viewModel: viewModel, mode: .complete) {
                    showBlockingFanIdentitySetup = false
                }
                .interactiveDismissDisabled()
            }
            .alert(
                "Private chat",
                isPresented: Binding(
                    get: { chatGateAlertMessage != nil },
                    set: { if !$0 { chatGateAlertMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {
                    chatGateAlertMessage = nil
                }
            } message: {
                Text(chatGateAlertMessage ?? "")
            }
            .onAppear {
                // Observation-race reconciliation: if the reset flag is already true when this
                // MainTabView appears (root remounted between false→true, so `onChange` never
                // fired), settle to the signed-out Discover root now. Settlement is idempotent.
                if viewModel.safeLogoutNeedsDiscoverReset {
                    SafeLogoutDebug.step("main_tab_reset_observed", detail: "onAppearReconcile")
                    settleSafeLogoutToDiscoverRoot()
                }
                guard !didRunInitialPrivateChatTabGate else { return }
                didRunInitialPrivateChatTabGate = true
                print("[FaceIDSettingsDebug] defaultPrivateChatFaceID=false")
                print("[PrivateChatSecurityDebug] requireFaceIDSetting=\(requireDeviceAuthForPrivateChat)")
                Task { await enforcePrivateChatGateOnLaunchIfNeeded() }
            }
    }

    /// Type-erased boundary — do not remove. The full tab shell (root ZStack of
    /// tab roots + the ~30-modifier lifecycle chain) produced a concrete generic
    /// type deep enough that Swift runtime metadata instantiation
    /// (__swift_instantiateConcreteTypeFromMangledNameV2) recursed past the
    /// main-thread stack guard at launch (EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE).
    /// Erasing here and at `tabShellBase` interrupts that recursive metadata path.
    private var tabShellWithLifecycleModifiers: AnyView {
        AnyView(tabShellLifecycleChain)
    }

    /// Root ZStack erased before the lifecycle modifier chain so the chain
    /// composes over AnyView instead of the nested tab-root tuple type.
    private var tabShellBase: AnyView {
        let _ = MainTabObservationPerf.rootShellEvaluated(selectedTab: selectedTab.rawValue)
        return AnyView(
        ZStack {
            if selectedTab == .chat {
                // Keep this ZStack child mounted so toggling DM open does not reshuffle tab roots.
                chatTabRootBackground
                    .ignoresSafeArea()
                    .opacity(chatMainTabState.hidesFloatingTabBarForDirectChat ? 0 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            lazyPreservedRoot(tab: .discover) {
                DiscoverScreen(
                    viewModel: viewModel,
                    chatViewModel: chatViewModel,
                    isCalendarOverlayPresented: $discoverCalendarOverlayPresented,
                    isDiscoverTabSelected: selectedTab == .discover
                )
            }

            lazyPreservedRoot(tab: .live) {
                LiveScreen(
                    viewModel: viewModel,
                    chatViewModel: chatViewModel,
                    selectedTab: selectedTabBinding
                )
            }

            lazyPreservedRoot(tab: .calendar) {
                CalendarScreen(
                    viewModel: viewModel,
                    selectedTab: selectedTabBinding,
                    isCalendarTabSelected: selectedTab == .calendar
                )
            }

            lazyPreservedRoot(tab: .following) {
                FollowingScreen(
                    viewModel: viewModel,
                    selectedTab: selectedTabBinding,
                    suppressInitialAutoRefresh: true,
                    isFollowingTabSelected: selectedTab == .following
                )
            }

            lazyPreservedRoot(tab: .chat) {
                chatTabRoot
            }

            // Account must NOT use sticky mount. SceneStorage can restore `.account` at
            // process start; constructing SettingsScreen/ProfileIdentityCard then triggers
            // SwiftUI generic-metadata stack overflow before Discover is forced.
            // Mount Account only while it is the selected tab (true conditional, not opacity).
            // During safe logout, never construct Account/Profile — keep Discover underneath the overlay.
            if selectedTab == .account, !viewModel.isSafeLogoutBlockingUI {
                // AnyView keeps SettingsScreen's deep concrete type out of the
                // root ZStack tuple (same metadata-recursion protection as above).
                AnyView(
                    SettingsScreen(
                        viewModel: viewModel,
                        selectedTab: selectedTabBinding,
                        isAccountTabSelected: true
                    )
#if DEBUG
                    .onAppear {
                        MainTabTypeSafetyDebug.log("accountLeafMounted=true")
                    }
#endif
                )
            }

            if !chatMainTabState.hidesFloatingTabBarForDirectChat {
                floatingTabBarChrome
                    .opacity(discoverCalendarOverlayPresented && selectedTab == .discover ? 0.32 : 1)
                    .blur(radius: discoverCalendarOverlayPresented && selectedTab == .discover ? 1.25 : 0)
                    .allowsHitTesting(!(discoverCalendarOverlayPresented && selectedTab == .discover))
                    .animation(.easeInOut(duration: 0.24), value: discoverCalendarOverlayPresented)

            }
        }
        )
    }

    private var tabShellLifecycleChain: some View {
        tabShellBase
        .overlay(alignment: .top) {
            dmInAppNotificationBannerLayer
        }
        .onAppear {
#if DEBUG
            MainTabTypeSafetyDebug.log("rootShellAppeared selectedTab=\(selectedTab.rawValue)")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                MainTabTypeSafetyDebug.log("rootShellAliveSeconds=10")
                try? await Task.sleep(nanoseconds: 50_000_000_000)
                MainTabTypeSafetyDebug.log("rootShellAliveSeconds=60")
            }
#endif
            if !Self.didResetImageCacheDiagnosticsThisProcess {
                Self.didResetImageCacheDiagnosticsThisProcess = true
                ImageCacheDebug.resetSessionStats(reason: "coldLaunch")
            }
            AdDebugContext.setVisibleTab(selectedTabStorage)
            // Discover only at process start. Never mount a SceneStorage-restored Account
            // root before forcing Discover — Account embeds ProfileIdentityCard and can
            // blow the main-thread stack guard during SwiftUI metadata instantiation.
            mountedTabs.insert(.discover)
            viewModel.isCalendarTabSelected = false
            viewModel.startAutomaticTimeZoneChangeMonitoringIfNeeded()
            viewModel.isLiveTabSelected = false
            viewModel.isDiscoverTabSelectedForEnrichment = true
            if !Self.hasForcedDiscoverTabThisProcess {
                Self.hasForcedDiscoverTabThisProcess = true
                selectTab(.discover, animated: false, reason: "startupForceDiscover")
#if DEBUG
                print("[StartupDiscover] selectedTab=\(AppTab.discover.rawValue)")
                print("[PerfLazyTab] deferredAccountUntilSelected=true")
                TabPerfDebug.log("[TabPerfDebug] tabAppeared=\(AppTab.discover.rawValue)")
#endif
            } else {
                mountTab(selectedTab, reason: "mainTabOnAppear")
                viewModel.isCalendarTabSelected = selectedTab == .calendar
                viewModel.isLiveTabSelected = selectedTab == .live
                viewModel.isDiscoverTabSelectedForEnrichment = selectedTab == .discover
#if DEBUG
                print("[PerfLazyTab] restoredSelected tab=\(selectedTab.rawValue)")
                TabPerfDebug.log("[TabPerfDebug] tabAppeared=\(selectedTab.rawValue)")
#endif
            }
#if DEBUG
            if ProfileSettingsSequentialNavValidation.isExplicitlyEnabled {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    selectTab(.account, animated: false, reason: "settingsNavSequentialValidation")
                    print("[SettingsNavigationDebug] sequentialValidationForcedAccountTab=true")
                }
            }
#endif
            logBottomTabStructure()
            TabTapPerf.startLaunchStallWatchdog()
            // After the first shell frame, so the Taptic handoff never lands on the first tab tap.
            Task { @MainActor in
                await Task.yield()
                FGInteractionHaptics.prewarm()
            }
            updateDirectChatReadStateVisibility()
            evaluateBlockingFanIdentitySetupPresentation(reason: "mainTabOnAppear")
            scheduleDeferredChatSocialRealtimeStartupIfNeeded()
            if selectedTab == .chat, viewModel.isAuthenticatedForSocialFeatures {
                Task { await startChatSocialRealtimeIfNeeded(reason: "launchVisibleChatTab") }
            }
            syncPresenceHeartbeatLocation()
            PresenceService.shared.startIfNeeded(
                userID: viewModel.currentUserAuthId,
                isAuthenticated: viewModel.isAuthenticatedForSocialFeatures,
                reason: "mainTabOnAppear"
            )
            if viewModel.isAuthenticatedForSocialFeatures {
                ActivityStatusMinuteClock.shared.start(reason: "mainTabOnAppear")
            }

            schedulePostAuthBadgeRefresh(reason: "mainTabOnAppear")
            routePostSignupDiscoverWelcomeGuideIfReady(reason: "mainTabOnAppear")
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: chatMainTabState.hidesFloatingTabBarForDirectChat)
        .onChange(of: viewModel.switchToAccountForVenueClaim) { _, shouldSwitch in
            guard shouldSwitch else { return }
            viewModel.switchToAccountForVenueClaim = false
            selectTab(.account, reason: "switchToAccountForVenueClaim")
        }
        .task(id: viewModel.postSignupPresentation) {
            routePostSignupDiscoverWelcomeGuideIfReady(reason: "postSignupPresentationTask")
        }
        .task(id: viewModel.postAccountCreationLanguageSelectorRevision) {
            routePostAccountCreationLanguageSelectorIfReady(reason: "postAccountCreationLanguageTask")
        }
        // Splash timeout fallback: finish critical path only; warm preload handles the rest.
        .task {
            guard performsInitialBootstrap else { return }
            // Joins the launch-owned bootstrap. Starting a second one here previously ran auth
            // restore under this `.task`, which the view tree could cancel mid-flight.
            await BootstrapLoadingCoordinator.joinCriticalBootstrap(
                viewModel: viewModel,
                chatViewModel: chatViewModel,
                owner: "mainTabFallback"
            )
            if performsInitialBootstrap,
               !LaunchBootstrapState.didBootstrapScheduleWarmPreload {
                LaunchWarmPreloadCoordinator.shared.beginIfNeeded(
                    viewModel: viewModel,
                    chatViewModel: chatViewModel,
                    accountTabVisible: selectedTab == .account
                )
                UserPreferencesWarmCacheCoordinator.shared.beginIfNeeded(
                    viewModel: viewModel,
                    delayMs: 1_400
                )
            }
            schedulePostAuthBadgeRefresh(reason: "criticalBootstrapCompleted")
            scheduleDeferredChatSocialRealtimeStartupIfNeeded()
        }
        .onChange(of: viewModel.isAuthenticatedForSocialFeatures) { _, authenticated in
            updateDirectChatReadStateVisibility()
            if !authenticated {
                cancelPostAuthBadgeRefresh(reason: "authUnavailable")
                didStartChatSocialRealtime = false
                chatSocialRealtimeDeferTask?.cancel()
                chatSocialRealtimeDeferTask = nil
                cancelTabPreloadTasks()
                LaunchWarmPreloadCoordinator.shared.cancel()
                UserPreferencesWarmCacheCoordinator.shared.cancel()
                PresenceService.shared.stop(reason: "authUnavailable")
                ActivityStatusMinuteClock.shared.stop(reason: "authUnavailable")
                FansNearbyService.shared.clear(reason: "signedOut")
                chatViewModel.clearForSignOut()
                viewModel.clearPendingSaveProGameIntent()
                viewModel.presentSaveProGameSignInPrompt = false
            } else {
                scheduleDeferredChatSocialRealtimeStartupIfNeeded()
                LaunchWarmPreloadCoordinator.shared.beginIfNeeded(
                    viewModel: viewModel,
                    chatViewModel: chatViewModel,
                    accountTabVisible: selectedTab == .account,
                    forceRefresh: true
                )
                UserPreferencesWarmCacheCoordinator.shared.beginIfNeeded(
                    viewModel: viewModel,
                    delayMs: 900,
                    forceRefresh: true
                )
                Task { await viewModel.ensurePickupInviteRealtimeIfNeeded() }
                syncPresenceHeartbeatLocation()
                PresenceService.shared.startIfNeeded(
                    userID: viewModel.currentUserAuthId,
                    isAuthenticated: true,
                    reason: "authBecameAvailable"
                )
                ActivityStatusMinuteClock.shared.start(reason: "authBecameAvailable")
                schedulePostAuthBadgeRefresh(reason: "authBecameAvailable", force: true)
                // Private Chat was cleared on sign-out; start B's inbox without waiting for the Chat tab.
                Task { @MainActor in
                    await chatViewModel.beginInitialInboxLoadIfNeeded(source: "login")
                }
                viewModel.completePendingSaveProGameAfterLoginIfNeeded()
            }
        }
        .onChange(of: viewModel.currentUserAuthId) { oldValue, newValue in
            if newValue == nil || newValue != lastAutoPresentedFanIdentitySetupUserId {
                lastAutoPresentedFanIdentitySetupUserId = nil
            }
            FansNearbyService.shared.clear(reason: "accountSwitch")
            if oldValue != newValue {
                ChatFansLiveNowSessionCache.clear(authId: nil)
                if newValue == nil {
                    chatViewModel.resetForAccountChange(newAuthId: nil, reason: "currentUserCleared")
                } else if oldValue != nil {
                    // Authenticated A → B without relying on a signed-out gap.
                    chatViewModel.resetForAccountChange(newAuthId: newValue, reason: "accountSwitch")
                    Task { @MainActor in
                        await chatViewModel.beginInitialInboxLoadIfNeeded(source: "login")
                    }
                } else {
                    // nil → B after sign-in; state already cleared on logout.
                    Task { @MainActor in
                        await chatViewModel.beginInitialInboxLoadIfNeeded(source: "login")
                    }
                }
            }
            syncPresenceHeartbeatLocation()
            PresenceService.shared.startIfNeeded(
                userID: newValue,
                isAuthenticated: viewModel.isAuthenticatedForSocialFeatures,
                reason: "currentUserChanged"
            )
            if newValue == nil {
                ActivityStatusMinuteClock.shared.stop(reason: "currentUserCleared")
                cancelPostAuthBadgeRefresh(reason: "currentUserCleared")
            } else {
                ActivityStatusMinuteClock.shared.start(reason: "currentUserChanged")
                schedulePostAuthBadgeRefresh(reason: "currentUserChanged", force: true)
                routePostAccountCreationLanguageSelectorIfReady(reason: "currentUserAuthIdChanged")
                routePostSignupDiscoverWelcomeGuideIfReady(reason: "currentUserAuthIdChanged")
            }
        }
        .onChange(of: viewModel.privateSessionClearNonce) { _, _ in
            cancelPostAuthBadgeRefresh(reason: "privateSessionCleared")
            chatViewModel.clearForSignOut()
            cancelTabPreloadTasks()
            LaunchWarmPreloadCoordinator.shared.cancel()
            PresenceService.shared.stop(reason: "privateSessionCleared")
            ActivityStatusMinuteClock.shared.stop(reason: "privateSessionCleared")
        }
        .onChange(of: viewModel.profileEditPresentationEvaluationKey) { _, _ in
            evaluateBlockingFanIdentitySetupPresentation(reason: "profilePresentationStateChanged")
        }
        .onChange(of: chatMainTabState.pendingDmOpenPreview) { _, preview in
            handlePendingDmOpenPreviewChange(preview)
        }
        .onChange(of: chatMainTabState.pendingGroupOpenConversationId) { _, groupId in
            handlePendingGroupOpenConversationChange(groupId)
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhaseChange(phase)
        }
        .onChange(of: viewModel.discoverNavigateToAccountForUserAuth) { _, go in
            guard go else { return }
            selectTab(.account, reason: "discoverNavigateToAccountForUserAuth")
            privateChatUnlockedForCurrentSelection = false
            updateDirectChatReadStateVisibility()
            viewModel.discoverNavigateToAccountForUserAuth = false
        }
        .sheet(isPresented: Binding(
            get: { viewModel.presentSaveProGameSignInPrompt },
            set: { presented in
                if !presented {
                    // Swipe-dismiss / system dismiss without choosing Sign In — cancel pending.
                    if viewModel.presentSaveProGameSignInPrompt {
                        viewModel.cancelSaveProGameSignInPrompt()
                    }
                } else {
                    viewModel.presentSaveProGameSignInPrompt = true
                }
            }
        )) {
            SaveProGameSignInPromptSheet(viewModel: viewModel)
        }
        .onChange(of: viewModel.discoverFocusVenueId) { _, venueId in
            guard venueId != nil else { return }
            selectTab(.discover, reason: "discoverFocusVenueId")
        }
        .onChange(of: viewModel.requestDiscoverTabForHomeCrowd) { _, go in
            guard go else { return }
            selectTab(.discover, reason: "homeCrowdPick")
            viewModel.requestDiscoverTabForHomeCrowd = false
        }
        .onChange(of: selectedTabStorage) { _, newRaw in
            AdDebugContext.setVisibleTab(newRaw)
#if DEBUG
            if LiveRenderDiagnostics.enabled {
                print("[LiveTabDebug] selectedTab=\(newRaw)")
            }
#endif
            guard let tab = AppTab(rawValue: newRaw) else { return }
            TabTapPerf.shellVisible(tab: newRaw)
            mountTab(tab, reason: "selectedTabStorage")
            let switchStartedAt = tabSwitchStartAt ?? Date()
            let usedCachedData = tabSwitchCachedData ?? tabHasCachedData(tab)
#if DEBUG
            TabPerfDebug.log("[TabPerfDebug] selectedTab=\(newRaw)")
            TabPerfDebug.log("[TabPerfDebug] tabAppeared=\(newRaw)")
            TabPerfDebug.log("[TabPerfDebug] cacheAge=\(tabCacheAgeDescription(tab)) tab=\(newRaw)")
            TabPerfDebug.log("[TabPerfDebug] tabSwitchStart=\(switchStartedAt.timeIntervalSince1970)")
            TabPerfDebug.log("[TabPerfDebug] usedCachedData=\(usedCachedData)")
#endif
            DispatchQueue.main.async {
                logTabFirstContentVisible(tab: tab, startedAt: switchStartedAt, usedCachedData: usedCachedData)
            }
            // Only build the diagnostics dictionary when ad diagnostics are actually
            // enabled; otherwise this allocated + sorted + joined on every tab switch.
            if AdDiagnostics.enabled {
                AdDebugDiagnostics.logEvent(
                    event: "lazyTabMountState",
                    format: "context",
                    placement: "mainTabs",
                    fields: [
                        "selectedTab": newRaw,
                        "mountedTabs": mountedTabs.map(\.rawValue).sorted().joined(separator: ","),
                        "discoverPreservedOffscreen": "\(newRaw != AppTab.discover.rawValue && mountedTabs.contains(.discover))"
                    ]
                )
            }
            viewModel.isCalendarTabSelected = tab == .calendar
            viewModel.isLiveTabSelected = tab == .live
            viewModel.isDiscoverTabSelectedForEnrichment = tab == .discover
            switch tab {
            case .discover:
                privateChatUnlockedForCurrentSelection = false
                updateDirectChatReadStateVisibility()
            case .account:
                privateChatUnlockedForCurrentSelection = false
                updateDirectChatReadStateVisibility()
            case .calendar:
                privateChatUnlockedForCurrentSelection = false
                updateDirectChatReadStateVisibility()
                Task { @MainActor in
                    await Task.yield()
                    viewModel.noteCalendarTabBecameActive()
                }
            case .chat:
                updateDirectChatReadStateVisibility()
                guard viewModel.isAuthenticatedForSocialFeatures else { return }
                Task {
                    await Task.yield()
                    await startChatSocialRealtimeIfNeeded(reason: "chatTabSelected")
                    if !viewModel.didCompleteTabIntentPreloadRecently("chat", within: 25) {
                        chatViewModel.requestBadgeRecalculation(reason: "chat_tab_selected", includeInboxSummaries: true)
                    } else {
                        AppPerfDebug.refreshSkipped(tab: "chat", source: "badgeRecalculation", reason: "tabPreloadRecent")
                    }
                }
            default:
                privateChatUnlockedForCurrentSelection = false
                updateDirectChatReadStateVisibility()
                return
            }
        }
        .task(id: pokesBadgeRefreshLoopToken) {
            await runPokesBadgeRefreshLoop()
        }
        .environmentObject(chatViewModel)
        .onChange(of: viewModel.pendingFollowingMapVenueID) { _, id in
            guard id != nil else { return }
            selectTab(.discover, reason: "pendingFollowingMapVenueID")
        }
        .onChange(of: viewModel.pendingFollowingMapPickupGameID) { _, id in
            guard id != nil else { return }
            selectTab(.discover, reason: "pendingFollowingMapPickupGameID")
            Task {
                await viewModel.consumeFollowingPickupGameNavigationIfPending()
            }
        }
    }

    private func evaluateBlockingFanIdentitySetupPresentation(reason: String) {
        let name = viewModel.currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let handle = viewModel.currentUserUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let missingRequiredFields = name.isEmpty && handle.isEmpty
        let authState: String = {
            if viewModel.isVenueOwnerLoggedIn { return "venueOwner" }
            if viewModel.isLoggedIn { return "fanAuthenticated" }
            return "signedOut"
        }()
        let suppressReason: String? = {
            if !viewModel.isLoggedIn { return "notAuthenticated" }
            if viewModel.isVenueOwnerLoggedIn { return "venueOwnerSession" }
            if viewModel.isAuthSessionRestoringForProfilePresentation { return "sessionRestoring" }
            if viewModel.isUserProfileLoadingForPresentation { return "profileLoading" }
            if !viewModel.hasLoadedUserProfileForPresentation { return "profileNotLoaded" }
            if !viewModel.userProfileExistsForPresentation { return "profileMissingOrNotCreated" }
            if !missingRequiredFields { return "requiredFieldsPresent" }
            if let userId = viewModel.currentUserAuthId,
               lastAutoPresentedFanIdentitySetupUserId == userId,
               !showBlockingFanIdentitySetup {
                return "alreadyPresentedThisSession"
            }
            return nil
        }()
        let shouldPresent = suppressReason == nil

#if DEBUG
        print("[ProfileEditPresentationDebug] authState=\(authState)")
        print("[ProfileEditPresentationDebug] profileLoading=\(viewModel.isUserProfileLoadingForPresentation)")
        print("[ProfileEditPresentationDebug] profileLoaded=\(viewModel.hasLoadedUserProfileForPresentation)")
        print("[ProfileEditPresentationDebug] missingRequiredFields=\(missingRequiredFields)")
        print("[ProfileEditPresentationDebug] shouldPresentEditProfile=\(shouldPresent)")
        print("[ProfileEditPresentationDebug] suppressReason=\(suppressReason ?? "none")")
#endif

        guard shouldPresent else {
            if showBlockingFanIdentitySetup,
               suppressReason == "requiredFieldsPresent" || suppressReason == "notAuthenticated" || suppressReason == "venueOwnerSession" {
                showBlockingFanIdentitySetup = false
            }
            return
        }

        if let userId = viewModel.currentUserAuthId {
            lastAutoPresentedFanIdentitySetupUserId = userId
        }
        showBlockingFanIdentitySetup = true
    }

    private func mountTab(_ tab: AppTab, reason: String) {
        if mountedTabs.contains(tab) { return }
        mountedTabs.insert(tab)
        scheduleFirstMountContentActivation(tab, reason: reason)
#if DEBUG
        print("[PerfLazyTab] mounted tab=\(tab.rawValue) reason=\(reason)")
        MainTabTypeSafetyDebug.log("tabLeafMounted=\(tab.rawValue) reason=\(reason)")
#endif
    }

    /// Two-phase first mount: lets SwiftUI commit the frame that flips the tab (chrome +
    /// lightweight shell) before the heavy destination subtree is constructed. First
    /// construction of a tab root (NavigationStack, lists, generic-metadata instantiation)
    /// previously ran inside the same transaction as the selection write, so the visible
    /// switch could not paint until it finished — the first-visit stall. The heavy content
    /// mounts one runloop turn later; lifecycle is otherwise unchanged: the subtree still
    /// constructs only after first selection and stays sticky afterwards.
    private func scheduleFirstMountContentActivation(_ tab: AppTab, reason: String) {
        guard !activatedTabContent.contains(tab) else { return }
        let mountedAt = Date()
        TabTapPerf.firstMountShellShown(tab: tab.rawValue, reason: reason)
        Task { @MainActor in
            // One hop lands after the runloop turn that commits the shell frame.
            await Task.yield()
            guard !activatedTabContent.contains(tab) else { return }
            activatedTabContent.insert(tab)
            TabTapPerf.firstMountContentActivated(
                tab: tab.rawValue,
                msFromMount: Int(Date().timeIntervalSince(mountedAt) * 1000),
                reason: reason
            )
        }
    }

    /// After successful safe logout: land on Discover without remounting Account/Profile.
    private func settleSafeLogoutToDiscoverRoot() {
        SafeLogoutDebug.log("settle to Discover begin selected=\(selectedTab.rawValue)")
        selectTab(.discover, animated: false, reason: "safeLogoutDiscoverReset")
        // Drop sticky Account restoration for the next authenticated session.
        // Account is conditional-only; forcing Discover prevents SceneStorage reopening Profile.
        viewModel.acknowledgeSafeLogoutUISettled(reason: "mainTabDiscoverActive")
        SafeLogoutDebug.log("settle to Discover complete")
    }

    /// After successful safe login / account switch: mount Discover first, never previous Account tab.
    private func settleSafeLoginToDiscoverRoot() {
        SafeLoginDebug.log("settle to Discover begin selected=\(selectedTab.rawValue)")
        selectTab(.discover, animated: false, reason: "safeLoginDiscoverReset")
        viewModel.acknowledgeSafeLoginUISettled(reason: "mainTabDiscoverActive")
        SafeLoginDebug.log("settle to Discover complete")
    }

    private func selectTab(
        _ tab: AppTab,
        animated: Bool = true,
        reason: String = "userSelection",
        isUserInitiated: Bool = false
    ) {
        let touchAt = Date()
        let previousTab = selectedTab
        if !isUserInitiated, previousTab != tab, lastManualTabSelection == previousTab {
            TabTapPerf.selectionOverwritten(from: previousTab.rawValue, to: tab.rawValue, reason: reason)
        }
        // Everything up to the storage write must stay cheap: this is the only work standing
        // between the touch and the frame that shows the new tab. Diagnostics and preload
        // scheduling run afterwards, before SwiftUI applies the transaction.
        noteTabSwitchStart(from: previousTab, to: tab)
        mountTab(tab, reason: reason)
        // Tab chrome must flip selection synchronously without spring-wrapping the whole shell.
        // Animation here delayed perceived selection and competed with opacity crossfades.
        if animated {
            withAnimation(.easeInOut(duration: 0.12)) {
                selectedTabStorage = tab.rawValue
            }
        } else {
            selectedTabStorage = tab.rawValue
        }
        let selectMs = Int(Date().timeIntervalSince(touchAt) * 1000)
        TabTapPerf.selectedTabChanged(tab: tab.rawValue)

        finishTabSwitchBookkeeping(from: previousTab, to: tab, reason: reason)
        TabPerformanceDebug.log("tab touch received requested=\(tab.rawValue) reason=\(reason)")
        TabPerformanceDebug.log("selected-tab state changed to=\(tab.rawValue) touchToSelectionMs=\(selectMs)")
        if selectMs >= 50 {
            TabPerformanceDebug.log("synchronous main-thread intervalMs=\(selectMs) source=selectTab")
            TabTapPerf.mainActorBusy(ms: Double(selectMs), source: "selectTab")
        }
    }

    /// Floating-bar tap entry point for every tab.
    ///
    /// Selection is written first; haptics run afterwards so the Taptic Engine handoff never sits
    /// between the touch and the frame that shows the new tab.
    private func handleTabBarTap(_ tab: AppTab, reason: String) {
        TabTapPerf.tapReceived(
            tab: tab.rawValue,
            reason: reason,
            alreadySelected: selectedTab == tab,
            overlayHitTestable: tabBarOverlayHitTestable
        )
        lastManualTabSelection = tab
        UserInteractionPriorityGate.noteUserTabInteraction(tab.rawValue)
        selectTab(tab, animated: false, reason: reason, isUserInitiated: true)
        FGInteractionHaptics.selection()
    }

    /// True when a full-screen layer above the floating tab bar is currently accepting touches.
    /// Used only for diagnostics — it mirrors the `allowsHitTesting` conditions already in the shell.
    private var tabBarOverlayHitTestable: Bool {
        if viewModel.isSafeLogoutBlockingUI { return true }
        if viewModel.isSafeLoginBlockingUI { return true }
        if viewModel.wowMomentOverlay.presentation != nil { return true }
        if discoverCalendarOverlayPresented, selectedTab == .discover { return true }
        return false
    }

    /// Selects Discover for a newly completed fan signup unless a higher-priority pending route exists.
    private func routePostSignupDiscoverWelcomeGuideIfReady(reason: String) {
        guard viewModel.hasPostSignupDiscoverWelcomeGuide else { return }
        if chatMainTabState.pendingDmOpenPreview != nil {
#if DEBUG
            print("[PostSignupRoute] deferDiscover reason=pendingDm source=\(reason)")
#endif
            return
        }
        if viewModel.switchToAccountForVenueClaim {
#if DEBUG
            print("[PostSignupRoute] deferDiscover reason=venueClaim source=\(reason)")
#endif
            return
        }
        selectTab(.discover, animated: true, reason: "postSignupWelcomeGuide:\(reason)")
    }

    /// Selects Discover so the post-account-creation language selector can present (fans and businesses).
    private func routePostAccountCreationLanguageSelectorIfReady(reason: String) {
        guard viewModel.hasPendingPostAccountCreationLanguageSelector else { return }
        if chatMainTabState.pendingDmOpenPreview != nil {
#if DEBUG
            print("[FirstLaunchLanguage] deferDiscover reason=pendingDm source=\(reason)")
#endif
            return
        }
        if viewModel.switchToAccountForVenueClaim {
#if DEBUG
            print("[FirstLaunchLanguage] deferDiscover reason=venueClaim source=\(reason)")
#endif
            return
        }
        selectTab(.discover, animated: true, reason: "postAccountCreationLanguage:\(reason)")
    }

    /// Cheap state the `selectedTabStorage` observer needs; must run before the selection write.
    private func noteTabSwitchStart(from previousTab: AppTab, to tab: AppTab) {
        tabSwitchFromTab = previousTab
        tabSwitchStartAt = Date()
        tabSwitchCachedData = tabHasCachedData(tab)
    }

    /// Diagnostics + preload scheduling. Runs after the selection write so neither can delay it.
    private func finishTabSwitchBookkeeping(from previousTab: AppTab, to tab: AppTab, reason: String) {
        let cacheHit = tabSwitchCachedData ?? false
        TabPerf.selectedTab(tab.rawValue)
        TabPerf.tabSwitchStarted(from: previousTab.rawValue, to: tab.rawValue)
        AppPerfDebug.tabSwitchStart(
            tab: tab.rawValue,
            from: previousTab.rawValue,
            cacheHit: cacheHit,
            source: reason
        )
        startTabIntentPreload(tab, reason: reason)
        UIPerformanceDiagnostics.signpost(
            "tab switch",
            "from=\(previousTab.rawValue) to=\(tab.rawValue) reason=\(reason)"
        )
        DebugLogGate.tabSwitchPerfVerbose(
            "[TabSwitchPerf] begin from=\(previousTab.rawValue) to=\(tab.rawValue) cached=\(cacheHit) reason=\(reason)"
        )
#if DEBUG
        if DebugLogGate.verboseTabSwitchPerfLogging {
            print("[UISmoothnessDebug] tabTransition=\(previousTab.rawValue)->\(tab.rawValue)")
            TabPerfDebug.log("[TabPerfDebug] selectedTab=\(tab.rawValue)")
            TabPerfDebug.log("[TabPerfDebug] tabSwitchStart=\(tabSwitchStartAt?.timeIntervalSince1970 ?? 0)")
            TabPerfDebug.log("[TabPerfDebug] usedCachedData=\(cacheHit)")
            TabPerfDebug.log("[TabPerfDebug] reason=\(reason)")
        }
#endif
    }

    private func beginTabSwitch(to tab: AppTab, reason: String) {
        let previousTab = selectedTab
        noteTabSwitchStart(from: previousTab, to: tab)
        finishTabSwitchBookkeeping(from: previousTab, to: tab, reason: reason)
    }

    private func logTabFirstContentVisible(tab: AppTab, startedAt: Date, usedCachedData: Bool) {
        TabTapPerf.firstFrame(tab: tab.rawValue, cachedContentUsable: usedCachedData)
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        let from = tabSwitchFromTab?.rawValue ?? "unknown"
        TabPerf.tabSwitchRendered(tab: tab.rawValue, durationMs: ms)
        AppPerfDebug.tabSwitchEnd(tab: tab.rawValue, durationMs: ms, cacheHit: usedCachedData, source: "firstPaint")
        UIPerformanceDiagnostics.log("tabSwitch from=\(from) to=\(tab.rawValue) ms=\(ms) cached=\(usedCachedData)")
        DebugLogGate.tabSwitchPerfSummary(
            "[TabSwitchPerf] firstContentVisible from=\(from) to=\(tab.rawValue) durationMs=\(ms) cached=\(usedCachedData)"
        )
        switch tab {
        case .chat:
            UIPerformanceDiagnostics.signpost("DM inbox open", "ms=\(ms)")
            DebugLogGate.tabSwitchPerfVerbose("[TabPreloadDebug] tab=chat readyMs=\(ms)")
        case .account:
            UIPerformanceDiagnostics.signpost("Profile tab open", "ms=\(ms)")
            DebugLogGate.tabSwitchPerfVerbose("[TabPreloadDebug] tab=account readyMs=\(ms)")
#if DEBUG
            // Lock + reduce/sort over cache stats: DEBUG-only so it never runs on the
            // Release tab-selection path.
            ImageCacheDebug.printSessionSummary(reason: "tabVisible:account")
            ImagePerf.summary(context: "tabVisible:account")
#endif
        case .following:
            DebugLogGate.tabSwitchPerfVerbose("[TabPreloadDebug] tab=following readyMs=\(ms)")
        case .discover:
            DebugLogGate.tabSwitchPerfVerbose("[TabPreloadDebug] tab=discover readyMs=\(ms)")
#if DEBUG
            ImageCacheDebug.printSessionSummary(reason: "tabVisible:discover")
            ImagePerf.summary(context: "tabVisible:discover")
#endif
        default:
            break
        }
#if DEBUG
        if DebugLogGate.verboseTabSwitchPerfLogging {
            TabPerfDebug.log("[TabPerfDebug] selectedTab=\(tab.rawValue)")
            TabPerfDebug.log("[TabPerfDebug] firstContentVisibleMs=\(ms)")
            TabPerfDebug.log("[TabPerfDebug] firstPaintMs=\(ms) tab=\(tab.rawValue)")
            TabPerfDebug.log("[TabPerfDebug] usedCachedData=\(usedCachedData)")
        }
#endif
        tabSwitchStartAt = nil
        tabSwitchCachedData = nil
        tabSwitchFromTab = nil
    }

    private func startTabIntentPreload(_ tab: AppTab, reason: String) {
        // Launch already ran discover core + painted from cache; skip deferred Task.sleep + empty work.
        if tab == .discover,
           !viewModel.bars.isEmpty,
           reason.contains("startup") || reason == "startupForceDiscover" {
            StartupPerf.duplicateSkipped(reason: "discoverTabIntentStartupWarm")
            TabPerf.refreshSkipped(name: "tabIntentPreload:discover", reason: "startupAlreadyWarmed")
            return
        }
        let warmAtStart = tabHasCachedData(tab)
        if let last = lastTabPreloadAt[tab],
           Date().timeIntervalSince(last) < Self.tabPreloadFreshnessInterval,
           warmAtStart {
            TabPerf.refreshSkipped(name: "tabIntentPreload:\(tab.rawValue)", reason: "freshCache")
            DebugLogGate.tabSwitchPerfVerbose("[TabSwitchPerf] preloadSkipped tab=\(tab.rawValue) reason=fresh cached=true")
#if DEBUG
            if DebugLogGate.verboseTabSwitchPerfLogging {
                print("[TabPreloadDebug] tab=\(tab.rawValue)")
                print("[TabPreloadDebug] warm=true")
                print("[TabPreloadDebug] skippedReason=fresh")
            }
#endif
            return
        }
        if tabPreloadTasks[tab] != nil {
            TabPerf.duplicateRefreshCoalesced(name: "tabIntentPreload:\(tab.rawValue)")
            DebugLogGate.tabSwitchPerfVerbose("[TabSwitchPerf] preloadSkipped tab=\(tab.rawValue) reason=inFlight cached=\(warmAtStart)")
#if DEBUG
            if DebugLogGate.verboseTabSwitchPerfLogging {
                print("[TabPreloadDebug] tab=\(tab.rawValue)")
                print("[TabPreloadDebug] warm=\(warmAtStart)")
                print("[TabPreloadDebug] skippedReason=inFlight")
            }
#endif
            return
        }

        let startedAt = Date()
        TabPerf.refreshStarted(name: "tabIntentPreload:\(tab.rawValue)")
        DebugLogGate.tabSwitchPerfVerbose("[TabSwitchPerf] preloadStarted tab=\(tab.rawValue) cached=\(warmAtStart) reason=\(reason)")
#if DEBUG
        if DebugLogGate.verboseTabSwitchPerfLogging {
            print("[TabPreloadDebug] tab=\(tab.rawValue)")
            print("[TabPreloadDebug] warm=\(warmAtStart)")
            print("[TabPreloadDebug] reason=\(reason)")
            print("[TabPreloadDebug] skippedReason=deferred")
        }
#endif
        DebugLogGate.tabSwitchPerfVerbose("[TabDeferredRefresh] tab=\(tab.rawValue) reason=\(reason) scheduled")
        let task = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: Self.tabIntentPreloadDeferDelayNs)
            guard !Task.isCancelled else { return }
            DebugLogGate.tabSwitchPerfVerbose("[TabDeferredRefresh] tab=\(tab.rawValue) reason=\(reason) started")
            await runTabIntentPreload(tab: tab, reason: reason)
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            lastTabPreloadAt[tab] = Date()
            tabPreloadTasks[tab] = nil
            TabPerf.refreshFinished(name: "tabIntentPreload:\(tab.rawValue)", durationMs: ms)
            DebugLogGate.tabSwitchPerfVerbose("[TabSwitchPerf] preloadFinished tab=\(tab.rawValue) durationMs=\(ms)")
            DebugLogGate.tabSwitchPerfVerbose("[TabDeferredRefresh] tab=\(tab.rawValue) reason=\(reason) finished")
#if DEBUG
            if DebugLogGate.verboseTabSwitchPerfLogging {
                print("[TabPreloadDebug] tab=\(tab.rawValue)")
                print("[TabPreloadDebug] durationMs=\(ms)")
            }
#endif
        }
        tabPreloadTasks[tab] = task
    }

    private func runTabIntentPreload(tab: AppTab, reason: String) async {
        guard !hasConfirmedSuspensionGateForPreload else { return }
        let tabKey = tab.rawValue
        viewModel.markTabIntentPreloadBegan(tabKey)
        defer { viewModel.markTabIntentPreloadEnded(tabKey) }
        let preloadStartedAt = Date()
        let cacheHit = tabHasCachedData(tab)
        AppPerfDebug.networkFetchStarted(tab: tabKey, source: "tabIntentPreload:\(reason)")
        defer {
            let ms = Int(Date().timeIntervalSince(preloadStartedAt) * 1000)
            AppPerfDebug.networkFetchFinished(
                tab: tabKey,
                source: "tabIntentPreload:\(reason)",
                durationMs: ms,
                cacheHit: cacheHit
            )
        }
        switch tab {
        case .chat:
            guard viewModel.isAuthenticatedForSocialFeatures else { return }
            if chatViewModel.shouldSkipChatTabIntentPreload() {
                TabPerf.refreshSkipped(name: "tabIntentPreload:chat", reason: "freshCache")
                DebugLogGate.tabSwitchPerfVerbose("[TabSwitchPerf] preloadSkipped tab=chat reason=fresh cached=true")
#if DEBUG
                if DebugLogGate.verboseTabSwitchPerfLogging {
                    print("[TabPreloadDebug] tab=chat")
                    print("[TabPreloadDebug] skippedReason=fresh")
                }
#endif
                return
            }
            await chatViewModel.prefetchTabIntentChatBadgeData()
        case .following:
            // Going paints from cached cards; full refresh is deferred in FollowingScreen.
            TabPerf.refreshSkipped(name: "tabIntentPreload:following", reason: "deferredToScreen")
#if DEBUG
            if DebugLogGate.verboseTabSwitchPerfLogging {
                print("[TabPreloadDebug] tab=following")
                print("[TabPreloadDebug] skippedReason=deferred")
            }
#endif
            return
        case .account:
            guard viewModel.isAuthenticatedForSocialFeatures else { return }
            if tabHasCachedData(.account) {
                TabPerf.refreshSkipped(name: "tabIntentPreload:account", reason: "cachedIdentity")
#if DEBUG
                if DebugLogGate.verboseTabSwitchPerfLogging {
                    print("[TabPreloadDebug] tab=account")
                    print("[TabPreloadDebug] skippedReason=fresh")
                }
#endif
                if viewModel.canReceiveProfilePokes {
                    await viewModel.refreshUnseenPokesBadgeIfNeeded()
                }
                return
            }
            await viewModel.prefetchLightweightUserDataForStartup()
            if viewModel.canReceiveProfilePokes {
                await viewModel.refreshUnseenPokesBadgeIfNeeded()
            }
        case .discover:
            guard viewModel.bars.isEmpty else {
                TabPerf.refreshSkipped(name: "tabIntentPreload:discover", reason: "cachedVenues")
#if DEBUG
                if DebugLogGate.verboseTabSwitchPerfLogging {
                    print("[TabPreloadDebug] tab=discover")
                    print("[TabPreloadDebug] skippedReason=fresh")
                }
#endif
                return
            }
            await viewModel.refreshDiscoverCoreInBackground()
        case .calendar:
            if viewModel.canFanUsePickupGamesUI {
                await viewModel.refreshCalendarTabPickupSources(reason: "tabPreload")
                // Prefer joining launch warm when it already seeded Schedule caches.
                if viewModel.lastCalendarTabPickupSourcesRefreshAt != nil {
                    CalendarActivationPerf.warmJoined(source: "tabPreload")
                }
                SchedulePerf.preload(action: "completed", source: "tabPreload")
            }
        case .live:
            if viewModel.liveMatchesAreFreshForTabPreload(
                within: Self.liveMatchesTabPreloadFreshnessInterval
            ) {
                TabPerf.refreshSkipped(name: "tabIntentPreload:live", reason: "freshCache")
                DebugLogGate.tabSwitchPerfVerbose("[TabSwitchPerf] preloadSkipped tab=live reason=fresh cached=true")
#if DEBUG
                if DebugLogGate.verboseTabSwitchPerfLogging {
                    print("[TabPreloadDebug] tab=live")
                    print("[TabPreloadDebug] skippedReason=fresh")
                }
#endif
                return
            }
            await viewModel.refreshLiveMatchesForLiveTabActivation(forceRefresh: false)
        }
    }

    private var hasConfirmedSuspensionGateForPreload: Bool {
        if viewModel.activeAccountBan != nil { return true }
        if viewModel.activeBusinessAccountBan != nil,
           viewModel.isBusinessBanGatePresented
            || viewModel.hasAuthenticatedVenueOwnerSession
            || viewModel.currentUserIsBusinessAccount
            || viewModel.venueOwnerMode {
            return true
        }
        return false
    }

    private func cancelTabPreloadTasks() {
        for task in tabPreloadTasks.values {
            task.cancel()
        }
        tabPreloadTasks.removeAll()
        lastTabPreloadAt.removeAll()
    }

    private func tabHasCachedData(_ tab: AppTab) -> Bool {
        switch tab {
        case .discover:
            return !viewModel.bars.isEmpty
        case .live:
            return !viewModel.liveMatches.isEmpty
        case .calendar:
            return !viewModel.events.isEmpty
        case .following:
            return !viewModel.followingTabGoingItems.isEmpty
                || !viewModel.followingTabSavedVenues.isEmpty
                || !viewModel.myPickupGameJoinRequestCards.isEmpty
                || !viewModel.myPickupGamesForSettings.isEmpty
        case .chat:
            return !chatViewModel.friends.isEmpty
                || !chatViewModel.incomingRequests.isEmpty
                || !chatViewModel.outgoingRequests.isEmpty
                || chatViewModel.unreadDirectMessageCount > 0
        case .account:
            return viewModel.currentUserAuthId != nil
                || !viewModel.currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func tabCacheAgeDescription(_ tab: AppTab) -> String {
        let date: Date?
        switch tab {
        case .discover:
            date = viewModel.lastDiscoverCoreRefreshAt
        case .live:
            date = nil
        case .calendar:
            date = viewModel.lastCalendarTabPickupSourcesRefreshAt ?? viewModel.lastDiscoverCoreRefreshAt
        case .following:
            date = [
                viewModel.lastSavedProGamesFetchAt,
                viewModel.lastFollowingTabGlobalRefreshAt,
                viewModel.lastSuccessfulFollowingJoinRequestsRefreshAt
            ].compactMap { $0 }.max()
        case .chat:
            date = nil
        case .account:
            date = nil
        }
        guard let date else { return "nil" }
        return String(format: "%.1f", Date().timeIntervalSince(date))
    }

    private func handlePendingDmOpenPreviewChange(_ preview: UserPreview?) {
        guard preview != nil else {
            routePostSignupDiscoverWelcomeGuideIfReady(reason: "pendingDmCleared")
            return
        }
        if requireDeviceAuthForPrivateChat && viewModel.isAuthenticatedForSocialFeatures {
            Task { await selectChatTabAfterDeviceAuth() }
        } else {
            if !requireDeviceAuthForPrivateChat {
                print("[PrivateChatSecurityDebug] biometricPromptSkippedReason=settingDisabled")
            }
            privateChatUnlockedForCurrentSelection = true
            selectTab(.chat, reason: "pendingDmOpenPreview")
            updateDirectChatReadStateVisibility()
        }
    }

    private func handlePendingGroupOpenConversationChange(_ groupId: UUID?) {
        guard groupId != nil else { return }
        if requireDeviceAuthForPrivateChat && viewModel.isAuthenticatedForSocialFeatures {
            Task { await selectChatTabAfterDeviceAuth() }
        } else {
            privateChatUnlockedForCurrentSelection = true
            selectTab(.chat, reason: "pendingGroupOpenConversationId")
            updateDirectChatReadStateVisibility()
        }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        guard phase == .active else {
            viewModel.noteAnnouncementsAppBackgrounded()
            PresenceService.shared.stop(reason: "scenePhase.\(String(describing: phase))")
            ActivityStatusMinuteClock.shared.stop(reason: "scenePhase.\(String(describing: phase))")
            if requireDeviceAuthForPrivateChat {
                privateChatUnlockedForCurrentSelection = false
                updateDirectChatReadStateVisibility()
            }
            return
        }
        Task { await handleAppBecameActive() }
        viewModel.refreshAutomaticTimeZonePresentationIfNeeded()
    }

    /// Scene restore: if the saved tab is Chat, require local auth or bounce away from private messages.
    private func enforcePrivateChatGateOnLaunchIfNeeded() async {
        guard selectedTab == .chat else { return }
        mountTab(.chat, reason: "enforcePrivateChatGateOnLaunch")
        guard viewModel.isAuthenticatedForSocialFeatures else { return }
        guard requireDeviceAuthForPrivateChat else {
            print("[PrivateChatSecurityDebug] biometricPromptSkippedReason=settingDisabled")
            await MainActor.run {
                privateChatUnlockedForCurrentSelection = true
                updateDirectChatReadStateVisibility()
            }
            return
        }

        print("[PrivateChatSecurityDebug] biometricPromptRequired=true")
        let outcome = await PrivateChatAccessGate.authenticateForPrivateChat()
        if outcome == .granted {
            await MainActor.run {
                privateChatUnlockedForCurrentSelection = true
                updateDirectChatReadStateVisibility()
            }
            return
        }

        await MainActor.run {
            selectTab(.discover, reason: "privateChatGateDenied")
            privateChatUnlockedForCurrentSelection = false
            updateDirectChatReadStateVisibility()
            switch outcome {
            case .authenticationFailed:
                chatGateAlertMessage = PrivateChatAccessGate.authenticationFailedMessage
            case .deviceSecurityNotConfigured:
                chatGateAlertMessage = PrivateChatAccessGate.noPasscodeMessage
            case .granted:
                break
            }
        }
    }

    /// Floating tab: enter Chat only after Face ID / Touch ID / passcode when the setting is enabled.
    private func selectChatTabAfterDeviceAuth() async {
        guard selectedTab != .chat else { return }

        if !viewModel.isAuthenticatedForSocialFeatures {
            await MainActor.run {
                privateChatUnlockedForCurrentSelection = true
                lastManualTabSelection = .chat
                selectTab(.chat, reason: "selectChatTabAfterDeviceAuth", isUserInitiated: true)
                updateDirectChatReadStateVisibility()
            }
            return
        }

        guard requireDeviceAuthForPrivateChat else {
            print("[PrivateChatSecurityDebug] biometricPromptSkippedReason=settingDisabled")
            await MainActor.run {
                privateChatUnlockedForCurrentSelection = true
                lastManualTabSelection = .chat
                selectTab(.chat, reason: "selectChatTabAfterDeviceAuth", isUserInitiated: true)
                updateDirectChatReadStateVisibility()
            }
            return
        }

        print("[PrivateChatSecurityDebug] biometricPromptRequired=true")
        let outcome = await PrivateChatAccessGate.authenticateForPrivateChat()
        await MainActor.run {
            switch outcome {
            case .granted:
                privateChatUnlockedForCurrentSelection = true
                lastManualTabSelection = .chat
                selectTab(.chat, reason: "selectChatTabAfterDeviceAuth", isUserInitiated: true)
                updateDirectChatReadStateVisibility()
            case .authenticationFailed:
                privateChatUnlockedForCurrentSelection = false
                updateDirectChatReadStateVisibility()
                chatGateAlertMessage = PrivateChatAccessGate.authenticationFailedMessage
            case .deviceSecurityNotConfigured:
                privateChatUnlockedForCurrentSelection = false
                updateDirectChatReadStateVisibility()
                chatGateAlertMessage = PrivateChatAccessGate.noPasscodeMessage
            }
        }
    }

    private func updateDirectChatReadStateVisibility() {
        let chatVisible = selectedTab == .chat
        let unlocked = chatVisible
            && viewModel.isAuthenticatedForSocialFeatures
            && (!requireDeviceAuthForPrivateChat || privateChatUnlockedForCurrentSelection)
        chatViewModel.setDirectChatReadStateVisibility(
            chatTabVisible: chatVisible,
            privateChatUnlocked: unlocked
        )
    }

    private func syncPresenceHeartbeatLocation() {
        guard let coordinate = viewModel.currentUserLocation else { return }
        PresenceService.shared.updateHeartbeatLocation(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }

    private func schedulePostAuthBadgeRefresh(reason: String, force: Bool = false) {
        guard viewModel.isAuthenticatedForSocialFeatures,
              let userId = viewModel.currentUserAuthId else {
            DebugLogGate.debug("[NotificationPerf] badgeRefreshSkipped reason=noAuthenticatedUser trigger=\(reason)")
            DebugLogGate.debug("[BadgeLoginRefreshDebug] skipped because no authenticated user reason=\(reason)")
            return
        }

        DebugLogGate.debug("[BadgeLoginRefreshDebug] auth event/session restored reason=\(reason) userId=\(userId.uuidString.lowercased())")

        if postAuthBadgeRefreshTask != nil, postAuthBadgeRefreshUserId == userId {
            DebugLogGate.debug("[NotificationPerf] badgeRefreshCoalesced trigger=\(reason) userId=\(userId.uuidString.lowercased())")
            DebugLogGate.debug("[BadgeLoginRefreshDebug] coalesced reason=\(reason) userId=\(userId.uuidString.lowercased())")
            return
        }

        if !force,
           lastPostAuthBadgeRefreshUserId == userId,
           let lastPostAuthBadgeRefreshAt,
           Date().timeIntervalSince(lastPostAuthBadgeRefreshAt) < Self.postAuthBadgeRefreshThrottleInterval {
            DebugLogGate.debug("[NotificationPerf] badgeRefreshSkipped reason=throttled trigger=\(reason) userId=\(userId.uuidString.lowercased())")
            DebugLogGate.debug("[BadgeLoginRefreshDebug] throttled reason=\(reason) userId=\(userId.uuidString.lowercased())")
            return
        }

        postAuthBadgeRefreshTask?.cancel()
        DebugLogGate.debug("[NotificationPerf] badgeRefreshScheduled trigger=\(reason) force=\(force)")
        postAuthBadgeRefreshUserId = userId
        postAuthBadgeRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: Self.postAuthBadgeRefreshCoalesceDelayNs)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await runPostAuthBadgeRefresh(userId: userId, reason: reason)
            if postAuthBadgeRefreshUserId == userId {
                postAuthBadgeRefreshTask = nil
                postAuthBadgeRefreshUserId = nil
            }
        }
    }

    private func cancelPostAuthBadgeRefresh(reason: String) {
        postAuthBadgeRefreshTask?.cancel()
        postAuthBadgeRefreshTask = nil
        postAuthBadgeRefreshUserId = nil
        DebugLogGate.debug("[BadgeLoginRefreshDebug] cancelled reason=\(reason)")
    }

    private func runPostAuthBadgeRefresh(userId: UUID, reason: String) async {
        guard viewModel.isAuthenticatedForSocialFeatures,
              viewModel.currentUserAuthId == userId else {
            DebugLogGate.debug("[NotificationPerf] badgeRefreshSkipped reason=sessionChanged trigger=\(reason)")
            DebugLogGate.debug("[BadgeLoginRefreshDebug] skipped because no authenticated user reason=\(reason)")
            return
        }

        let startedAt = Date()
        lastPostAuthBadgeRefreshAt = Date()
        lastPostAuthBadgeRefreshUserId = userId
        DebugLogGate.debug("[NotificationPerf] badgeRefreshStarted trigger=\(reason)")

        await chatViewModel.refreshFriendRequestListsOnly()
        DebugLogGate.debug("[BadgeLoginRefreshDebug] pending friend requests count=\(chatTabBadgeState.pendingBadgeCount)")

        // Launch coalesces unread (critical → warm); force on auth change / foreground so badges stay live.
        let forceUnread =
            reason.contains("auth")
            || reason.contains("currentUser")
            || reason == "foreground"
            || reason.contains("BecameAvailable")
        await chatViewModel.refreshUnreadDirectMessageCount(force: forceUnread)
        if !forceUnread {
            StartupPerf.phase("postAuthBadgeUnreadCoalesceAllowed", details: "reason=\(reason)")
        }
        await chatViewModel.ensureSignedInSocialRealtimeIfNeeded()

        if viewModel.canFanUsePickupGamesUI {
            await viewModel.loadIncomingPickupGameInvites(forceRefresh: true)
            await viewModel.loadMyPickupGameJoinRequestsForFollowing(
                forceRefresh: true,
                reason: "postAuthBadgeRefresh_\(reason)"
            )
            await viewModel.loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: true)
            await viewModel.ensurePickupInviteRealtimeIfNeeded()
            DebugLogGate.debug("[BadgeLoginRefreshDebug] pending pickup invites count=\(viewModel.incomingPickupGameInvites.count)")
        } else {
            DebugLogGate.debug("[BadgeLoginRefreshDebug] pending pickup invites count=0")
        }

        DebugLogGate.debug(
            "[BadgeLoginRefreshDebug] tab badge updated friendRequests=\(chatTabBadgeState.pendingBadgeCount) dmUnread=\(chatTabBadgeState.unreadDirectMessageCount) pickupInvites=\(viewModel.incomingPickupGameInvites.count) hostedPickupRequests=\(viewModel.pendingPickupGameJoinRequestCount) playingPickupCards=\(viewModel.myPickupGameJoinRequestCards.count)"
        )
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        DebugLogGate.debug("[NotificationPerf] badgeRefreshFinished trigger=\(reason) durationMs=\(ms) friendRequests=\(chatTabBadgeState.pendingBadgeCount) dmUnread=\(chatTabBadgeState.unreadDirectMessageCount) pickupInvites=\(viewModel.incomingPickupGameInvites.count)")
    }

    private func logBottomTabStructure() {
#if DEBUG
        print("[NavigationDebug] bottomTabStructure=Discover|Live|Schedule|Going|Chat|Profile")
#endif
    }

    /// In-app toast when a DM arrives while the thread isn’t open (see ``ChatViewModel/dmInAppNotification``).
    private var dmInAppNotificationBannerLayer: some View {
        VStack {
            if let banner = chatMainTabState.dmInAppNotification,
               !chatMainTabState.hidesFloatingTabBarForDirectChat {
                dmInAppNotificationCard(banner)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: banner.id) {
                        try? await Task.sleep(nanoseconds: 8_500_000_000)
                        await MainActor.run {
                            if chatMainTabState.dmInAppNotification?.id == banner.id {
                                chatViewModel.dismissDmInAppNotification()
                            }
                        }
                    }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(chatMainTabState.dmInAppNotification != nil && !chatMainTabState.hidesFloatingTabBarForDirectChat)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: chatMainTabState.dmInAppNotification?.id)
        .zIndex(90)
    }

    private func dmInAppNotificationCard(_ banner: ChatViewModel.DmInAppNotificationPayload) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ProfileAvatarView(preview: banner.senderPreview, size: 42)

            Button {
                chatViewModel.openConversationFromDmBanner()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(banner.senderPreview.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text(banner.bodyPreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                chatViewModel.dismissDmInAppNotification()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notification")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 14, y: 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    /// Independent overlay: does not participate in `DirectChatView` layout; hidden during DM threads via ``ChatViewModel/hidesFloatingTabBarForDirectChat``.
    private var floatingTabBarChrome: some View {
        let _ = MainTabObservationPerf.floatingBarEvaluated(selectedTab: selectedTab.rawValue)
        return VStack {
            Spacer()

            HStack(spacing: 6) {
                tabButton(.discover, title: localized("discover"), icon: "map.fill")

                tabButton(.live, title: localized("live"), icon: "dot.radiowaves.left.and.right", glow: FGColor.accentGreen)

                calendarTabButton()

                followingTabButton()

                chatTabButton()

                Button {
                    handleTabBarTap(.account, reason: "accountTabButton")
                } label: {
                    accountTabAvatar
                }
                .buttonStyle(FGPremiumPressButtonStyle(hapticOnPress: false))
                .disabled(viewModel.isSafeLogoutBlockingUI)
            }
            .padding(8)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(floatingTabBarTint)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(floatingTabBarBorder, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.30 : 0.12), radius: colorScheme == .dark ? 18 : 10, y: 8)
            .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.08 : 0.04), radius: 10, y: 2)
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
        .allowsHitTesting(!viewModel.isSafeLogoutBlockingUI)
        .zIndex(2)
        .opacity(viewModel.isSafeLogoutBlockingUI ? 0.45 : 1)
    }

    /// Lazy sticky mount: unmounted tabs render nothing; mounted tabs use off-screen preservation when inactive.
    /// Returns AnyView so each tab root's deep concrete type stays out of the
    /// root ZStack tuple (generic-metadata stack-overflow protection).
    /// Content is still constructed lazily — only after the tab is mounted.
    private func lazyPreservedRoot<Content: View>(
        tab: AppTab,
        @ViewBuilder content: () -> Content
    ) -> AnyView {
        guard mountedTabs.contains(tab) else {
            return AnyView(
                Color.clear
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            )
        }
        guard activatedTabContent.contains(tab) else {
            // One-frame lightweight shell while the heavy subtree's first construction is
            // deferred to the next runloop turn (see scheduleFirstMountContentActivation).
            return AnyView(preservedRoot(tab: tab) { firstMountShellPlaceholder(for: tab) })
        }
        return AnyView(preservedRoot(tab: tab, content: content))
    }

    /// Matches each destination's base background so the shell → content swap is imperceptible.
    private func firstMountShellPlaceholder(for tab: AppTab) -> some View {
        Group {
            if tab == .chat {
                chatTabRootBackground
            } else {
                FGColor.screenGradient(colorScheme)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // Renders a tab’s root off-screen when inactive so SwiftUI state is preserved without receiving touches.
    @ViewBuilder
    private func preservedRoot<Content: View>(
        tab: AppTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isSelected = selectedTab == tab
        // While a DM thread is open, collapse only inactive tab roots so the custom ZStack tab shell
        // does not expand under the keyboard. Never branch the active Chat root — that recreates
        // FriendsTabView/NavigationStack and pops Direct Chat.
        let collapseInactiveForDirectChat =
            chatMainTabState.hidesFloatingTabBarForDirectChat && !isSelected
        content()
            .environment(\.hostTabAdInteractionEnabled, isSelected)
            .opacity(isSelected ? 1 : 0)
            .allowsHitTesting(isSelected)
            .accessibilityHidden(!isSelected)
            .zIndex(isSelected ? 1 : 0)
            .animation(nil, value: isSelected)
            .modifier(DirectChatInactiveTabCollapseModifier(collapse: collapseInactiveForDirectChat))
            .id(tab)
    }

    /// Chat tab content keeps a single stable modifier chain so NavigationStack identity
    /// (and the Direct Chat destination) survives floating-tab hide toggles.
    private var chatTabRoot: some View {
        FriendsTabView(
            mapViewModel: viewModel,
            viewModel: chatViewModel,
            isTabSelected: selectedTab == .chat
        )
        .padding(
            .bottom,
            chatMainTabState.hidesFloatingTabBarForDirectChat ? 0 : Self.floatingTabBarStackHeight
        )
        .background(chatTabRootBackground.ignoresSafeArea())
    }
    
    private var isBusinessAccountTabContext: Bool {
        viewModel.isVenueOwnerLoggedIn || viewModel.venueOwnerMode || viewModel.currentUserIsBusinessAccount
    }

    private var businessTabIsPro: Bool {
        viewModel.businessDashboardPreloadSnapshot?.entitlementStatus?.computedIsPro == true
    }

    private var businessTabHasPendingVenueClaim: Bool {
        !viewModel.pendingVenueClaimsForSettings.isEmpty
    }

    private var businessTabShowsPendingClaimDot: Bool {
        BusinessStatusIconChrome.showsPendingClaimDot(
            isPro: businessTabIsPro,
            hasPendingVenueClaim: businessTabHasPendingVenueClaim
        )
    }

    private var businessTabStatusColor: Color {
        BusinessStatusIconChrome.statusColor(
            isPro: businessTabIsPro,
            hasPendingVenueClaim: businessTabHasPendingVenueClaim,
            colorScheme: colorScheme
        )
    }

    private var accountIconColor: Color {
        if isBusinessAccountTabContext {
            return businessTabStatusColor
        }

        if viewModel.isLoggedIn {
            return .green
        }

        return .gray
    }

    private var accountIconName: String {

        if isBusinessAccountTabContext {
            return "building.2.fill"
        }

        return "person.circle.fill"
    }

    private var floatingTabBarTint: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.34)
            : Color.white.opacity(0.58)
    }

    private var chatTabRootBackground: Color {
        colorScheme == .dark ? Color.black : Color(.systemBackground)
    }

    private var floatingTabBarBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.white.opacity(0.55)
    }

    private var selectedTabBackgroundColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.86) : Color.black.opacity(0.92)
    }

    private var unselectedTabForegroundColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.74) : FGColor.secondaryText(colorScheme)
    }

    private var accountIconBackgroundColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.white.opacity(0.92)
    }
    
    private func chatTabButton() -> some View {
        Button {
            // Face ID off / signed-out: select synchronously on first tap (no Task hop).
            if !viewModel.isAuthenticatedForSocialFeatures || !requireDeviceAuthForPrivateChat {
                privateChatUnlockedForCurrentSelection = true
                handleTabBarTap(.chat, reason: "chatTabButton")
                updateDirectChatReadStateVisibility()
            } else {
                TabTapPerf.tapReceived(
                    tab: "chat",
                    reason: "chatTabButtonDeviceAuth",
                    alreadySelected: selectedTab == .chat,
                    overlayHitTestable: tabBarOverlayHitTestable
                )
                UserInteractionPriorityGate.noteUserTabInteraction("chat")
                FGInteractionHaptics.selection()
                TabPerformanceDebug.log("tab touch received requested=chat reason=chatTabButton")
                // Warm the inbox while the biometric prompt is up; `selectTab` is not reached
                // on this branch until the gate resolves, so it cannot schedule the preload.
                startTabIntentPreload(.chat, reason: "chatTabButtonIntent")
                Task { await selectChatTabAfterDeviceAuth() }
            }
        } label: {
            MainTabChatBadgeObserver(state: chatTabBadgeState) { unreadCount, pendingCount, requiresSignIn in
                ZStack(alignment: .topTrailing) {
                    HStack(spacing: 5) {
                        chatTabMessageIconWithUnreadBadge(
                            unreadCount: unreadCount,
                            requiresSignIn: requiresSignIn
                        )
                        if selectedTab == .chat {
                            Text(localized("chat"))
                        }
                    }
                    .font(.caption)
                    .fontWeight(.bold)
                    .padding(.horizontal, selectedTab == .chat ? 12 : 10)
                    .padding(.vertical, 10)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .foregroundStyle(selectedTab == .chat ? Color.white : unselectedTabForegroundColor)
                    .background(selectedTab == .chat ? selectedTabBackgroundColor : Color.clear)
                    .clipShape(Capsule())
                    .softActiveGlow(selectedTab == .chat, color: FGColor.accentBlue)

                    if pendingCount > 0 {
                        chatTabPillBadge(count: pendingCount)
                            .offset(x: 6, y: -6)
                    }
                }
            }
        }
        .buttonStyle(FGPremiumPressButtonStyle(hapticOnPress: false))
        .disabled(viewModel.isSafeLogoutBlockingUI)
    }

    /// Same gate as ``FriendsTabView`` inbox (not ``MapViewModel/canUsePrivateChat``, which can lag session used by ``ChatViewModel``).
    private func chatTabUnreadBadgeVisible(unreadCount: Int, requiresSignIn: Bool) -> Bool {
        !requiresSignIn && unreadCount > 0
    }

    /// Manual unread pill: SwiftUI `.badge` on custom floating-tab labels is unreliable; match inbox ``unreadDirectMessageCount``.
    /// Fixed layout size + padded overlay keeps the pill inside the tab row ``Capsule`` / floating bar clips (offsets do not expand layout).
    private func chatTabMessageIconWithUnreadBadge(
        unreadCount n: Int,
        requiresSignIn: Bool
    ) -> some View {
        let show = chatTabUnreadBadgeVisible(
            unreadCount: n,
            requiresSignIn: requiresSignIn
        )
        let label = n > 99 ? "99+" : "\(n)"

        return ZStack {
            Color.clear.frame(width: 44, height: 28)

            Image(systemName: "message.fill")
                .font(.system(size: 15, weight: .semibold))
        }
        .overlay(alignment: .topTrailing) {
            if show {
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, n > 9 ? 5 : 4)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 1, green: 0.42, blue: 0.12),
                                        Color(red: 0.92, green: 0.18, blue: 0.08)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    // Inset from the reserved rect so the capsule tab bar and outer rounded bar do not clip the pill.
                    .padding(.top, 4)
                    .padding(.trailing, 4)
                    .accessibilityLabel("\(n) unread messages")
            }
        }
    }

    private func chatTabPillBadge(count: Int) -> some View {
        let label = count > 99 ? "99+" : "\(count)"
        return Text(label)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.red)
            .clipShape(Capsule())
    }

    private func calendarTabButton() -> some View {
        return Button {
            handleTabBarTap(.calendar, reason: "calendarTabButton")
        } label: {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 5) {
                    Image(systemName: "calendar")

                    if selectedTab == .calendar {
                        Text(localized("Schedule"))
                    }
                }
                .font(.caption)
                .fontWeight(.bold)
                .padding(.horizontal, selectedTab == .calendar ? 12 : 10)
                .padding(.vertical, 10)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .foregroundStyle(selectedTab == .calendar ? Color.white : unselectedTabForegroundColor)
                .background(selectedTab == .calendar ? selectedTabBackgroundColor : Color.clear)
                .clipShape(Capsule())
                .softActiveGlow(selectedTab == .calendar, color: FGColor.accentBlue)

            }
        }
        .buttonStyle(FGPremiumPressButtonStyle(hapticOnPress: false))
        .disabled(viewModel.isSafeLogoutBlockingUI)
    }

    private func followingTabButton() -> some View {
        Button {
            handleTabBarTap(.following, reason: "followingTabButton")
        } label: {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 5) {
                    Image(systemName: "heart.fill")

                    if selectedTab == .following {
                        Text(localized("going"))
                    }
                }
                .font(.caption)
                .fontWeight(.bold)
                .padding(.horizontal, selectedTab == .following ? 12 : 10)
                .padding(.vertical, 10)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .foregroundStyle(selectedTab == .following ? Color.white : unselectedTabForegroundColor)
                .background(selectedTab == .following ? selectedTabBackgroundColor : Color.clear)
                .clipShape(Capsule())
                .softActiveGlow(selectedTab == .following, color: FGColor.accentGreen)

                if goingTabHasActivity {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1))
                        .offset(x: 7, y: -6)
                        .accessibilityLabel("Pickup games activity")
                }
            }
        }
        .buttonStyle(FGPremiumPressButtonStyle(hapticOnPress: false))
        .disabled(viewModel.isSafeLogoutBlockingUI)
    }

    private var goingTabHasActivity: Bool {
        viewModel.hasUnreadPickupActivity
            || viewModel.pickupActivityCount > 0
            || viewModel.pendingPickupGameJoinRequestCount > 0
            || !viewModel.incomingPickupGameInvites.isEmpty
    }

    private func tabButton(_ tab: AppTab, title: String, icon: String, glow: Color = FGColor.accentBlue) -> some View {
        Button {
            handleTabBarTap(tab, reason: "tabButton")
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                
                if selectedTab == tab {
                    Text(title)
                }
            }
            .font(.caption)
            .fontWeight(.bold)
            .padding(.horizontal, selectedTab == tab ? 12 : 10)
            .padding(.vertical, 10)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .foregroundStyle(selectedTab == tab ? Color.white : unselectedTabForegroundColor)
            .background(selectedTab == tab ? selectedTabBackgroundColor : Color.clear)
            .clipShape(Capsule())
            .softActiveGlow(selectedTab == tab, color: glow)
        }
        .buttonStyle(FGPremiumPressButtonStyle(hapticOnPress: false))
        .disabled(viewModel.isSafeLogoutBlockingUI)
    }
    
    private var accountTabIcon: String {
        if isBusinessAccountTabContext {
            return "building.2.fill"
        }

        if viewModel.isLoggedIn {
            return "person.circle.fill"
        }

        return "person.circle"
    }

    private var accountTabTitle: String {
        if isBusinessAccountTabContext {
            return localized("business")
        }

        if viewModel.isLoggedIn {
            return localized("profile")
        }

        return "Login"
    }

    private var pokesBadgeRefreshLoopToken: String {
        let auth = viewModel.currentUserAuthId?.uuidString ?? "anonymous"
        return "\(auth)|pokes=\(viewModel.canReceiveProfilePokes)|unseen=\(viewModel.hasUnseenPokes)"
    }

    private func pokesBadgePollIntervalSeconds() -> Int {
        viewModel.hasUnseenPokes
            ? Self.pokesBadgePollIntervalUnseenSeconds
            : Self.pokesBadgePollIntervalIdleSeconds
    }

    private func runPokesBadgeRefreshLoop() async {
        guard viewModel.canReceiveProfilePokes else {
            viewModel.clearUnseenPokesBadgeState()
            return
        }

        while !Task.isCancelled {
            guard viewModel.canReceiveProfilePokes else {
                viewModel.clearUnseenPokesBadgeState()
                return
            }

            if scenePhase != .active {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }

            let intervalSeconds = pokesBadgePollIntervalSeconds()
            DebugLogGate.debug("[PerfPhase2D] pokesBadgePoll interval=\(intervalSeconds)")
            await viewModel.refreshUnseenPokesBadgeIfNeeded()

            do {
                try await Task.sleep(nanoseconds: UInt64(intervalSeconds) * 1_000_000_000)
            } catch {
                return
            }
        }
    }

    private var hasOpenVenueEventCommentsSheet: Bool {
        !viewModel.venueEventCommentsRealtimeTasks.isEmpty
            || !viewModel.venueEventCommentsRealtimeChannels.isEmpty
            || !viewModel.venueEventCommentsRealtimeListenerTokens.isEmpty
    }

    private func scheduleDeferredChatSocialRealtimeStartupIfNeeded() {
        guard viewModel.isAuthenticatedForSocialFeatures else { return }
        guard !didStartChatSocialRealtime else { return }
        chatSocialRealtimeDeferTask?.cancel()
        DebugLogGate.debug("[PerfPhase2D] chatRealtimeDeferred reason=gracePeriodScheduled")
        chatSocialRealtimeDeferTask = Task {
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(Self.chatSocialRealtimeGracePeriodSeconds * 1_000_000_000)
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await startChatSocialRealtimeIfNeeded(reason: "bootstrapGracePeriod")
        }
    }

    private func startChatSocialRealtimeIfNeeded(reason: String) async {
        guard !viewModel.shouldSuppressAuthenticatedRefreshForSafeLogout else { return }
        guard viewModel.isAuthenticatedForSocialFeatures else { return }
        guard !didStartChatSocialRealtime else {
            AppPerfDebug.realtimeRestarted(false, source: "chatSocialAlreadyStarted:\(reason)")
            await chatViewModel.ensureSignedInSocialRealtimeIfNeeded()
            return
        }
        didStartChatSocialRealtime = true
        chatSocialRealtimeDeferTask?.cancel()
        chatSocialRealtimeDeferTask = nil
        DebugLogGate.debug("[PerfPhase2D] chatRealtimeStarted reason=\(reason)")
        AppPerfDebug.realtimeRestarted(true, source: "chatSocialStarted:\(reason)")
        await chatViewModel.ensureSignedInSocialRealtimeIfNeeded()
    }

    private func handleAppBecameActive() async {
        DebugLogGate.debug("[PerfPhase2D] foregroundBatch criticalStart")
        let foregroundRefreshStart = UIPerformanceDiagnostics.timestamp()
        defer {
            let ms = UIPerformanceDiagnostics.elapsedMs(since: foregroundRefreshStart)
            let currentTab = AppTab(rawValue: selectedTabStorage)?.rawValue ?? "unknown"
            UIPerformanceDiagnostics.log("visibleTabForegroundRefresh ms=\(UIPerformanceDiagnostics.formattedMs(ms)) tab=\(currentTab)")
        }

        // User-initiated logout owns teardown — never restart presence/session/chat mid-pipeline.
        if viewModel.shouldSuppressAuthenticatedRefreshForSafeLogout {
#if DEBUG
            print("[Auth] foregroundAuthenticatedWorkSkipped reason=logoutInProgress")
#endif
            return
        }

        await viewModel.refreshDiscoverBannerAnnouncementOnAppForeground()

        let hasSession = await viewModel.hasValidSession()
        if !hasSession {
            if viewModel.isAuthSessionRestoringForProfilePresentation
                || viewModel.authSessionState == .loadingSession
                || viewModel.resolvingEmailConfirmation {
#if DEBUG
                print("[BusinessSessionRestoreDebug] forceLogoutSuppressedDuringRestore=true reason=foregroundInvalidSession")
#endif
                return
            }
            let shouldPreserveForRestore = await MainActor.run {
                viewModel.shouldPreserveMissingSessionForRestore()
            }
            if shouldPreserveForRestore {
                await viewModel.markTransientMissingSessionPreserved(
                    reason: "foregroundInvalidSession",
                    source: "MainTabView.handleAppBecameActive"
                )
#if DEBUG
                print("[BusinessLogoutTrace] transientMissingSessionPreserved=true reason=foregroundInvalidSession")
#endif
                Task {
                    await viewModel.bootstrapAuthSessionOnly()
                }
                return
            }
            await viewModel.forceLogout(reason: "foregroundInvalidSession", source: "MainTabView.handleAppBecameActive")
            await MainActor.run {
                chatViewModel.clearForSignOut()
                didStartChatSocialRealtime = false
                chatSocialRealtimeDeferTask?.cancel()
                chatSocialRealtimeDeferTask = nil
            }
            return
        }

        if viewModel.hasAuthenticatedVenueOwnerSession {
            await viewModel.refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
            await viewModel.refreshCurrentBusinessFanGeoPlusEntitlementFromServer(reason: "foreground")
            viewModel.checkVenueApprovalStatus()
        }

        if viewModel.isLoggedIn, !viewModel.isVenueOwnerLoggedIn {
            await viewModel.enforceFanSingleSessionOnForeground()
            await viewModel.startFanSingleSessionRealtimeIfNeeded()
            await viewModel.refreshCurrentUserAdFreeEntitlementFromServer(reason: "foreground")
        }

        guard viewModel.isAuthenticatedForSocialFeatures else { return }
        await PushNotificationRegistrationService.shared.refreshPushTokenRegistration(reason: "foreground")
        syncPresenceHeartbeatLocation()
        PresenceService.shared.startIfNeeded(
            userID: viewModel.currentUserAuthId,
            isAuthenticated: true,
            reason: "appBecameActive"
        )
        ActivityStatusMinuteClock.shared.start(reason: "appBecameActive")
        schedulePostAuthBadgeRefresh(reason: "foreground")
        await viewModel.checkCurrentUserAdminStatus()

        let currentTab = AppTab(rawValue: selectedTabStorage) ?? .discover

        if viewModel.isLoggedIn, !viewModel.isVenueOwnerLoggedIn {
            await viewModel.refreshUnseenPokesBadgeIfNeeded()
        }

        if currentTab == .chat {
            let hadChatRealtime = didStartChatSocialRealtime
            await startChatSocialRealtimeIfNeeded(reason: "foregroundVisibleChatTab")
            if hadChatRealtime {
                chatViewModel.scheduleEnsureSocialRealtimeAfterForeground()
            }
            await enforcePrivateChatGateOnLaunchIfNeeded()
        }

        if hasOpenVenueEventCommentsSheet {
            await viewModel.verifyFanChatRealtimeAfterForeground()
        }

        if viewModel.canFanUsePickupGamesUI {
            await viewModel.restartPickupInviteRealtimeAfterForeground()
            if currentTab == .calendar {
                await viewModel.refreshCalendarTabPickupSources(reason: "foregroundVisibleCalendar")
            } else if currentTab == .following {
                await viewModel.loadMyPickupGameJoinRequestsForFollowing()
            }
        }

        foregroundDeferredBatchTask?.cancel()
        foregroundDeferredBatchTask = Task {
            await runForegroundDeferredBatch(visibleTab: currentTab)
        }
    }

    private func runForegroundDeferredBatch(visibleTab: AppTab) async {
        DebugLogGate.debug("[PerfPhase2D] foregroundBatch deferredStart")
        do {
            try await Task.sleep(nanoseconds: Self.foregroundDeferredBatchDelayNs)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        if visibleTab != .chat {
            if viewModel.isAuthenticatedForSocialFeatures {
                if didStartChatSocialRealtime {
                    chatViewModel.scheduleEnsureSocialRealtimeAfterForeground()
                } else {
                    await startChatSocialRealtimeIfNeeded(reason: "foregroundDeferred")
                }
            } else {
                DebugLogGate.debug("[PerfPhase2D] foregroundBatch skipped reason=chatSocialNotAuthenticated")
            }
        } else {
            DebugLogGate.debug("[PerfPhase2D] foregroundBatch skipped reason=chatSocialVisibleTabHandled")
        }

        if !hasOpenVenueEventCommentsSheet {
            await viewModel.verifyFanChatRealtimeAfterForeground()
        } else {
            DebugLogGate.debug("[PerfPhase2D] foregroundBatch skipped reason=fanChatVerifySheetOpen")
        }

        guard viewModel.canFanUsePickupGamesUI else { return }

        if visibleTab != .calendar {
            await viewModel.loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: true)
        } else {
            DebugLogGate.debug("[PerfPhase2D] foregroundBatch skipped reason=pickupCalendarVisibleTabHandled")
        }

        if visibleTab != .following {
            await viewModel.loadMyPickupGameJoinRequestsForFollowing()
        } else {
            DebugLogGate.debug("[PerfPhase2D] foregroundBatch skipped reason=pickupFollowingVisibleTabHandled")
        }
    }

    /// Avatar only; pickup participation activity now belongs in Going.
    private var accountTabAvatar: some View {
        ZStack(alignment: .topTrailing) {
            accountTabAvatarCircleOnly
                .frame(width: 44, height: 44)
                .clipShape(Circle())

            if accountTabPokesBadgeVisible {
                PokesUnseenAvatarBadge(style: .tab)
                    .offset(x: 0, y: -2)
            }

            if businessTabShowsPendingClaimDot {
                businessPendingClaimDot
                    .offset(x: -4, y: 2)
            }
        }
        .frame(width: 52, height: 52)
        .accessibilityLabel(accountTabPokesBadgeVisible ? "Account, new Pokes" : accountTabTitle)
        .onAppear {
            DebugLogGate.debug("[PokesBadgeUI] accountBadge visible=\(accountTabPokesBadgeVisible)")
        }
        .onChange(of: accountTabPokesBadgeVisible) { _, visible in
            DebugLogGate.debug("[PokesBadgeUI] accountBadge visible=\(visible)")
        }
    }

    private var accountTabPokesBadgeVisible: Bool {
        viewModel.canReceiveProfilePokes && viewModel.hasUnseenPokes
    }

    private var accountTabAvatarCircleOnly: some View {
        Group {
            if isBusinessAccountTabContext {
                Image(systemName: accountIconName)
                    .font(.title3)
                    .foregroundStyle(accountIconColor)
                    .frame(width: 44, height: 44)
                    .background(accountIconBackgroundColor)
            } else if viewModel.isLoggedIn {
                UserAvatarView(
                    avatarThumbnailURL: viewModel.currentUserAvatarThumbnailURL,
                    avatarURL: viewModel.currentUserAvatarURL,
                    avatarDisplayRefreshToken: viewModel.currentUserAvatarDisplayRefreshToken,
                    displayName: UserAvatarView.accountResolvedDisplayName(
                        isLoggedIn: viewModel.isLoggedIn,
                        currentUserDisplayName: viewModel.currentUserDisplayName,
                        isVenueOwnerLoggedIn: viewModel.isVenueOwnerLoggedIn,
                        ownerVenueName: viewModel.ownerVenueName,
                        userEmail: viewModel.currentUserEmail,
                        venueOwnerEmail: viewModel.venueOwnerEmail
                    ),
                    email: UserAvatarView.accountEmailLine(
                        isLoggedIn: viewModel.isLoggedIn,
                        userEmail: viewModel.currentUserEmail,
                        venueOwnerEmail: viewModel.venueOwnerEmail
                    ),
                    size: 44,
                    fallbackStyle: colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome,
                    imagePlaceholderTint: colorScheme == .dark ? .white : nil
                )
                .id("\(viewModel.currentUserAuthId?.uuidString ?? "none")|\(viewModel.currentUserAvatarURL)|\(viewModel.currentUserAvatarThumbnailURL)|\(viewModel.currentUserAvatarDisplayRefreshToken.uuidString)")
            } else {
                Image(systemName: accountIconName)
                    .font(.title3)
                    .foregroundStyle(accountIconColor)
                    .frame(width: 44, height: 44)
                    .background(accountIconBackgroundColor)
            }
        }
    }

    private var businessPendingClaimDot: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 10, height: 10)
            .overlay {
                Circle()
                    .strokeBorder(accountIconBackgroundColor.opacity(0.96), lineWidth: 2)
            }
            .shadow(color: Color.orange.opacity(0.24), radius: 4, y: 1)
            .accessibilityHidden(true)
    }
}

/// Shallow badge leaf: only this subtree observes unread/request/auth-gate changes.
private struct MainTabChatBadgeObserver<Content: View>: View {
    @ObservedObject var state: ChatTabBadgeState
    @ViewBuilder let content: (_ unreadCount: Int, _ pendingCount: Int, _ requiresSignIn: Bool) -> Content

    var body: some View {
        let _ = MainTabObservationPerf.chatBadgeLeafEvaluated()
        content(
            state.unreadDirectMessageCount,
            state.pendingBadgeCount,
            state.requiresSignIn
        )
        .onChange(of: state.unreadDirectMessageCount) { _, count in
#if DEBUG
            print("[ChatTabBadge] unreadCount=\(count)")
            print("[ChatTabBadge] visible=\(!state.requiresSignIn && count > 0)")
            print("[MainActorDebug] MainTabChatBadgeObserver actor=MainActor")
#endif
        }
        .onChange(of: state.requiresSignIn) { _, requiresSignIn in
#if DEBUG
            let count = state.unreadDirectMessageCount
            print("[ChatTabBadge] unreadCount=\(count)")
            print("[ChatTabBadge] visible=\(!requiresSignIn && count > 0)")
#endif
        }
    }
}

/// Collapses inactive tab roots only while Direct Chat is open.
/// Active Chat tab always uses `collapse == false`, so its NavigationStack identity stays stable.
private struct DirectChatInactiveTabCollapseModifier: ViewModifier {
    let collapse: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if collapse {
            content
                .frame(maxWidth: 0, maxHeight: 0)
                .clipped()
        } else {
            // No frame/clip — preserves Discover edge-to-edge map rendering.
            content
        }
    }
}

/// Root-owned transient overlays (FanXP reward + Wow Moment toasts) as a named
/// leaf so their concrete types stay out of MainTabView.body's modifier chain.
struct MainTabTransientOverlayLayer: View {
    @ObservedObject var viewModel: MapViewModel

    var body: some View {
        ZStack {
            FanXPRewardOverlayHost(manager: viewModel.fanXPRewardOverlay)
                .id(ObjectIdentifier(viewModel.fanXPRewardOverlay))
            WowMomentToastHost(manager: viewModel.wowMomentOverlay)
                .id(ObjectIdentifier(viewModel.wowMomentOverlay))
        }
#if DEBUG
        .onAppear {
            MainTabTypeSafetyDebug.log("transientOverlayMounted=true")
        }
#endif
    }
}

/// Blocking session-transition overlays (safe logout / safe login) as a named
/// leaf. Mounted conditionally, exactly as the previous inline overlay was.
struct MainTabSessionOverlayLayer: View {
    @ObservedObject var viewModel: MapViewModel

    var body: some View {
        if viewModel.isSafeLogoutBlockingUI {
            SafeLogoutProgressOverlay(viewModel: viewModel)
                .zIndex(10_000)
                .transition(.opacity)
#if DEBUG
                .onAppear {
                    MainTabTypeSafetyDebug.log("sessionOverlayMounted=safeLogout")
                }
#endif
        } else if viewModel.isSafeLoginBlockingUI {
            SafeLoginProgressOverlay(viewModel: viewModel)
                .zIndex(10_000)
                .transition(.opacity)
#if DEBUG
                .onAppear {
                    MainTabTypeSafetyDebug.log("sessionOverlayMounted=safeLogin")
                }
#endif
        }
    }
}

#if DEBUG
enum MainTabTypeSafetyDebug {
    private nonisolated static let banner = "===== MAIN TAB TYPE SAFETY ====="

    nonisolated static func log(_ message: String) {
        print("\(banner) \(message)")
    }
}
#endif
