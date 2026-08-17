import Combine
import CoreLocation
import MapKit
import SwiftUI

enum WatchingExpiredVenueGameDiagnostics {
    nonisolated static let enabled = false
}

enum SavedProGameStatusDiagnostics {
    nonisolated static let enabled = true
}

struct FollowingScreen: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var selectedTab: MainTabView.AppTab
    @EnvironmentObject private var chatViewModel: ChatViewModel
    var suppressInitialAutoRefresh = false
    var isFollowingTabSelected: Bool = true

    @Environment(\.colorScheme) private var followingColorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var favoriteActionBanner: String?
    @State private var didHandleInitialAutoRefresh = false

    /// Venue events the user marked "Interested" from Following without a Supabase row (table has no status column).
    @AppStorage("gameon.following.interestedOnlyVenueEventIDs") private var interestedOnlyEncoded: String = ""
    @AppStorage(FavoriteTeamsStore.appStorageKey) private var favoriteTeamIDsRaw: String = ""
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @AppStorage(ProGameNotificationPreferenceKeys.favoriteTeamAlerts) private var favoriteTeamProGameAlertsEnabled = false
    @AppStorage(ProGamesFavoriteTeamAutoFollowPreference.windowDaysKey) private var proGamesFavoriteTeamWindowDays = ProGamesFavoriteTeamAutoFollowPreference.Window.next30.rawValue
    @AppStorage("gameon.going.completedFavoriteTeamProGamesCleared.v1") private var clearedCompletedFavoriteTeamProGamesRaw: String = ""
    @State private var pickupDetailNav: PickupDetailNavigationToken?
    @State private var followingPickupWithdrawConfirm: PickupJoinWithdrawConfirmState?
    @State private var followingPickupWithdrawInFlight = false
    @State private var followingPickupPlayingClearConfirm: PickupPlayingClearConfirmState?

    @State private var followingMyPickupClockTick: Date = Date()
    @State private var followingMyPickupFormMode: PickupGameFormMode?
    @State private var followingMyPickupDeleteTarget: PickupGameRow?
    @State private var followingMyPickupOrganizerRequestsGame: PickupGameRow?
    @State private var followingMyPickupDetailGame: PickupGameRow?
    @State private var proGamePredictionSheet: ProGamePredictionSheetContext?
    @State private var proGameMatchDetailSelection: LiveMatch?
    @State private var goingAddToVenueChooser: CalendarAddToVenueChooserContext?
    @State private var goingAddToVenueImportPrefill: VenueOwnerScheduleImportPrefill?
    @State private var showGoingManageGamesFromHostedStatus = false
    /// Venue IDs already hosting each Going game key (stableKey) — from existing import duplicate source of truth.
    @State private var goingAddToVenueHostedByGameKey: [String: [VenueGameImportHostedVenueSummary]] = [:]
    @State private var pendingProGameNotificationMatchID: String?
    @State private var followingPickupInviteGame: PickupGameRow?
    @State private var followingPickupInviteDetail: PickupGameInviteDisplay?
    @State private var followingPendingPostCreateInviteGame: PickupGameRow?
    @State private var pickupInviteResponseInFlightId: UUID?
    @State private var followingMyPickupBanner: String?
    @State private var selectedGoingMode: GoingParticipationMode = .venueGames
    @State private var selectedGoingWatchFilter: GoingWatchFilter = .all
    @State private var selectedGoingPlayFilter: GoingPlayFilter = .all
    @State private var goingPlayFilterMenuOpen = false
    @State private var selectedGoingProGamesFilter: GoingProGamesFilter = .all
    @State private var selectedBusinessProGameFilter: BusinessProGameFilter = .all
    /// Ephemeral Discover Today dashboard day scope (not persisted).
    @State private var goingDayScope: GoingDayScope = .all
    /// Set when the user enters Play → Playing; consumed once authoritative cards are ready.
    @State private var pendingPlayingActivityAcknowledgement = false
    @State private var cachedGoingVenueGameItems: [FollowingGoingDisplayItem] = []
    @State private var cachedPlayingGameCards: [PickupGameJoinRequestCardDisplay] = []
    @State private var goingTabPerf = GoingTabPerfState()
    @State private var followingHostingPickupLoadInFlight = false
    @State private var showFavoriteTeamsPicker = false

    private enum GoingDayScope: Equatable {
        case all
        case today
    }

    private struct GoingTabPerfState {
        var cachedManualSavedProGamesForDisplay: [SavedProGame] = []
        var cachedFavoriteTeamProGamesForDisplay: [FavoriteTeamProGame] = []
        var firstPaintRecorded = false
        var backgroundRefreshInFlight = false
        var deferredWorkReady = false
        var screenAppearAt: CFAbsoluteTime?
        var lastVisibleSurfacePrepareAt: Date?
        var lastVisibleSurfacePrepareFingerprint: String?
        var lastBackgroundRefreshAt: Date?
        var deferredBackgroundRefreshTask: Task<Void, Never>?
        var deferredSurfacePrepareTask: Task<Void, Never>?
        var avatarPrefetchTask: Task<Void, Never>?
        var lastProGamesDisplayRebuildAt: Date?
        var proGamesDisplayRebuildTask: Task<Void, Never>?
        var proGamesDisplayRebuildInFlight = false
        var lastProGamesDisplayFingerprint: String?
        var lastFollowingDisplayCachesFingerprint: String?
        var proGamesStatusIndicatorVisible = false
        var proGamesStatusIndicatorShowTask: Task<Void, Never>?
        var tabSelectionActivationGeneration: UInt64 = 0
        var tabSelectionActivationActive = false
        var handledTabSelectionActivationGeneration: UInt64 = 0
        static let visibleSurfacePrepareTTL: TimeInterval = 25
        static let backgroundRefreshTTL: TimeInterval = 25
        static let proGamesDisplayRebuildTTL: TimeInterval = 25
        static let calendarProReuseTTL: TimeInterval = 45
        static let favoriteTeamRefreshDeferMinMs = 300
        static let favoriteTeamRefreshDeferMaxMs = 700
        static let deferredWorkDelayMs = 200
        static let deferredBackgroundRefreshDelayNs: UInt64 = 200_000_000
        static let proGamesStatusIndicatorMinVisibleDelayNs: UInt64 = 300_000_000
    }

    /// First-open two-phase: background paints before list/card construction.
    /// Stays true after the first activation so later visits remain immediate.
    @State private var goingHeavyContentReady = false

    private let followingMyPickupMinuteTicker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// Nil while Going tab is not selected so lazy mount does not trigger global refresh at launch.
    private var followingTabTaskIdentity: String? {
        guard isFollowingTabSelected else { return nil }
        return viewModel.currentUserAuthId?.uuidString ?? "signedOut"
    }

    private var favoriteTeamAutoFollowTaskIdentity: String? {
        guard isFollowingTabSelected, activeGoingMode == .proGames, !isBusinessProGamesOnly else { return nil }
        let auth = viewModel.currentUserAuthId?.uuidString ?? "signedOut"
        return [
            auth,
            favoriteTeamProGameAlertsEnabled ? "on" : "off",
            "\(proGamesFavoriteTeamWindowDays)",
            favoriteTeamIDsRaw
        ].joined(separator: "|")
    }

    private var businessFavoriteTeamProGamesTaskIdentity: String? {
        guard isFollowingTabSelected, activeGoingMode == .proGames, isBusinessProGamesOnly else { return nil }
        let auth = viewModel.currentUserAuthId?.uuidString ?? "signedOut"
        let businessId = viewModel.currentBusinessIdForAddLocation()?.uuidString ?? "noBusiness"
        let teams = viewModel.businessFavoriteTeamIDs.sorted().joined(separator: ",")
        return "\(auth)|\(businessId)|\(teams)"
    }

    private var isBusinessProGamesOnly: Bool {
        viewModel.hasAuthenticatedVenueOwnerSession
    }

    private var activeGoingMode: GoingParticipationMode {
        isBusinessProGamesOnly ? .proGames : selectedGoingMode
    }

    private var goingProNativeAdsHostVisible: Bool {
        isFollowingTabSelected && activeGoingMode == .proGames
    }

    private var goingProGamesAdPlan: GoingProGamesAdPlan {
        GoingProGamesAdPlacement.plan(
            savedGames: manualSavedProGamesForDisplay,
            favoriteTeamGames: favoriteTeamProGamesForDisplay,
            businessMyTeamSavedGames: businessMyTeamSavedProGamesForDisplay,
            businessMyTeamAutoGames: businessMyTeamProGamesForDisplay
        )
    }

    var body: some View {
        let _ = SwiftUIRecompPerf.rootBodyEvaluated(screen: "Going")
        followingLifecycleRoot
    }

    private var followingLifecycleRoot: some View {
        attachFollowingPresentation(to: followingLifecycleCore)
    }

    private var followingLifecycleCore: some View {
        followingLifecycleEventHandlers
    }

    private var followingScreenShell: some View {
        followingRootContent
    }

    @ViewBuilder
    private var followingRootContent: some View {
        if isFollowingTabSelected {
            if goingHeavyContentReady {
                followingActiveContent
            } else {
                goingFirstFrameShell
            }
        } else {
            followingOffTabPlaceholder
        }
    }

    /// Preserved-tab shell: skip Going lists, cards, and avatar work while off-screen.
    private var followingOffTabPlaceholder: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }

    /// One-frame background while cached paint / list construction yields past the selection frame.
    private var goingFirstFrameShell: some View {
        ZStack {
            Color.clear
                .fanGeoScreenBackground()
                .ignoresSafeArea()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var followingActiveContent: some View {
        ZStack {
            Color.clear
                .fanGeoScreenBackground()
                .ignoresSafeArea()

            if viewModel.isAuthenticatedForSocialFeatures {
                loggedInContent
            } else {
                loggedOutContent
            }
        }
    }

    private var followingLifecycleEventHandlers: some View {
        followingLifecycleTabOnChange
            .background {
                Color.clear
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                    .onChange(of: viewModel.pendingDiscoverTodayDashboardNav) { _, _ in
                        applyPendingDiscoverTodayDashboardNavIfNeeded()
                    }
                    .onChange(of: viewModel.pendingOpenGoingPickupInvites) { _, open in
                        guard open, isFollowingTabSelected else { return }
                        consumePendingGoingActionCenterDeepLinks()
                    }
                    .onChange(of: viewModel.pendingOpenGoingHostingApprovals) { _, open in
                        guard open, isFollowingTabSelected else { return }
                        consumePendingGoingActionCenterDeepLinks()
                    }
            }
    }

    private var followingLifecycleOnChanges: some View {
        followingLifecycleTasks
        .onChange(of: scenePhase) {
            handleFollowingScenePhaseChange(scenePhase)
        }
        .onChange(of: viewModel.isAuthenticatedForSocialFeatures) { _, _ in
            handleFollowingSocialAuthChange()
        }
        .onChange(of: viewModel.followingTabGoingItems.count) { _, _ in
            guard isFollowingTabSelected else { return }
            rebuildFollowingDisplayCaches(reason: "goingItemsChanged", prefetchAvatars: false)
        }
        .onChange(of: viewModel.myPickupGameJoinRequestCards) { _, _ in
            guard isFollowingTabSelected else { return }
            rebuildFollowingDisplayCaches(reason: "pickupJoinCardsChanged", prefetchAvatars: false)
        }
        .onChange(of: viewModel.savedProGames.count) { _, _ in
            guard isFollowingTabSelected else { return }
            scheduleGoingProGamesDisplayCacheRebuild(reason: "savedProGamesChanged")
        }
        .onChange(of: viewModel.favoriteTeamProGames.count) { _, _ in
            guard isFollowingTabSelected else { return }
            scheduleGoingProGamesDisplayCacheRebuild(reason: "favoriteTeamProGamesChanged")
        }
        .onChange(of: favoriteTeamProGameAlertsEnabled) { _, _ in
            guard isFollowingTabSelected else { return }
            scheduleGoingProGamesDisplayCacheRebuild(reason: "autoFollowToggled")
        }
        .onChange(of: clearedCompletedFavoriteTeamProGamesRaw) { _, _ in
            guard isFollowingTabSelected else { return }
            scheduleGoingProGamesDisplayCacheRebuild(reason: "clearedCompletedChanged")
        }
        .onChange(of: viewModel.incomingPickupGameInvites.count) { _, _ in
            guard isFollowingTabSelected else { return }
            prefetchVisibleGoingAvatars(reason: "incomingPickupInvitesChanged")
        }
        .onChange(of: viewModel.pendingProGameNotificationDeepLink) { _, request in
            guard let request else { return }
            pendingProGameNotificationMatchID = request.matchID
            selectedGoingMode = .proGames
            sanitizeBusinessGoingModeIfNeeded()
            viewModel.clearPendingProGameNotificationDeepLink()
            Task { await fulfillProGameNotificationDeepLinkIfReady() }
        }
    }

    private var followingLifecycleTabOnChange: some View {
        followingLifecycleOnChanges
        .onChange(of: isFollowingTabSelected) {
            handleFollowingTabSelectionChange(isFollowingTabSelected)
        }
    }

    private var followingLifecycleTasks: some View {
        followingLifecycleAuthOnChange
        .task(id: followingTabTaskIdentity) {
            guard isFollowingTabSelected else { return }
            guard viewModel.isAuthenticatedForSocialFeatures else { return }
            AppPerfDebug.screenLoadStart(tab: "following", source: "goingTabTask")
            _ = runGoingTabSelectionActivationIfNeeded(
                source: "goingTabTask",
                deferredRefreshReason: "goingTabActivation"
            )
        }
        .task(id: favoriteTeamAutoFollowTaskIdentity) {
            guard favoriteTeamAutoFollowTaskIdentity != nil else { return }
            await scheduleDeferredFavoriteTeamProGamesRefresh(reason: "autoFollowStateChanged")
        }
        .task(id: businessFavoriteTeamProGamesTaskIdentity) {
            guard businessFavoriteTeamProGamesTaskIdentity != nil else { return }
            await scheduleDeferredBusinessFavoriteTeamProGamesRefresh(reason: "businessFavoriteTeamsChanged")
        }
    }

    private var followingLifecycleAuthOnChange: some View {
        followingScreenShell
        .onAppear(perform: handleFollowingScreenAppear)
        .onChange(of: viewModel.currentUserAuthId) {
            handleFollowingAuthIdChange(viewModel.currentUserAuthId)
        }
    }

    private func handleFollowingScreenAppear() {
        if !isFollowingTabSelected {
            _ = paintGoingTabFromCachedStateImmediately(reason: "appear")
        }
        if isFollowingTabSelected {
            activateGoingHeavyContentIfNeeded(source: "onAppear")
            scheduleGoingProGamesDisplayCacheRebuild(reason: "appear")
        }
        sanitizeBusinessGoingModeIfNeeded()
        if suppressInitialAutoRefresh && !didHandleInitialAutoRefresh {
            didHandleInitialAutoRefresh = true
            return
        }
        guard isFollowingTabSelected else { return }
        guard viewModel.isAuthenticatedForSocialFeatures else { return }
        if goingHeavyContentReady {
            _ = runGoingTabSelectionActivationIfNeeded(source: "onAppear")
        }
    }

    private func handleFollowingAuthIdChange(_ newId: UUID?) {
        scheduleGoingProGamesDisplayCacheRebuild(reason: "authChanged")
        sanitizeBusinessGoingModeIfNeeded()
        guard isFollowingTabSelected else { return }
        if newId != nil {
            let cachedPaint = paintGoingTabFromCachedStateImmediately(reason: "authChanged")
            logGoingTabPerfSummary(
                cachedPaint: cachedPaint,
                deferredRefresh: !goingTabRecentlyBackgroundRefreshed(within: GoingTabPerfState.backgroundRefreshTTL),
                reason: "authChanged"
            )
            scheduleGoingTabDeferredSurfacePrepare(reason: "authChanged")
            scheduleGoingTabDeferredBackgroundRefresh(reason: "authChanged")
        } else {
            clearFollowingUserSpecificState()
            interestedOnlyEncoded = ""
        }
    }

    private func handleFollowingScenePhaseChange(_ phase: ScenePhase) {
        guard phase == .active, isFollowingTabSelected else { return }
        guard viewModel.isAuthenticatedForSocialFeatures, viewModel.canFanUsePickupGamesUI else { return }
        Task {
            await viewModel.loadMyPickupGameJoinRequestsForFollowing(reason: "foreground")
            await viewModel.loadIncomingPickupGameInvites()
            await viewModel.clearExpiredHostedPickupGamesIfNeeded(now: Date(), reason: "followingForeground")
        }
    }

    private func handleFollowingSocialAuthChange() {
        rebuildFollowingDisplayCaches(reason: "socialAuthChanged", prefetchAvatars: false)
        scheduleGoingProGamesDisplayCacheRebuild(reason: "socialAuthChanged")
        sanitizeBusinessGoingModeIfNeeded()
        Task { await syncFollowingAfterAuthChange() }
    }

    private func handleFollowingTabSelectionChange(_ visible: Bool) {
        if visible {
            let firstOpen = !goingHeavyContentReady
            AppPerfDebug.screenLoadStart(tab: "following", source: "tabVisible")
            GoingActivationPerf.selected(source: "tabVisible", firstOpen: firstOpen)
            GoingActivationPerf.shellVisible(cachedContentUsable: goingTabHasCachedContentForImmediatePaint())
            prepareGoingTabSelectionGeneration()
            activateGoingHeavyContentIfNeeded(source: "tabVisible")
            applyPendingDiscoverTodayDashboardNavIfNeeded()
            consumePendingGoingActionCenterDeepLinks()
            Task { @MainActor in
                await Task.yield()
                TabPerf.tabSwitchRendered(tab: "following")
                await fulfillProGameNotificationDeepLinkIfReady()
            }
        } else {
            goingDayScope = .all
            goingTabPerf.firstPaintRecorded = false
            cancelGoingTabDeferredWork(reason: "tabHidden")
            goingTabPerf.tabSelectionActivationActive = false
            goingTabPerf.handledTabSelectionActivationGeneration = 0
        }
    }

    /// First selection: paint the screen background, then enable heavy lists after one yield.
    private func activateGoingHeavyContentIfNeeded(source: String) {
        guard isFollowingTabSelected else { return }
        if goingHeavyContentReady {
            _ = runGoingTabSelectionActivationIfNeeded(source: source)
            GoingActivationPerf.stableReady(cachedContentUsable: goingTabHasCachedContentForImmediatePaint())
            return
        }
        Task { @MainActor in
            await Task.yield()
            guard isFollowingTabSelected, !goingHeavyContentReady else { return }
            let started = CFAbsoluteTimeGetCurrent()
            goingHeavyContentReady = true
            _ = runGoingTabSelectionActivationIfNeeded(source: source)
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            GoingActivationPerf.publishMs(ms, reason: "heavyContentReady:\(source)")
            GoingActivationPerf.stableReady(cachedContentUsable: goingTabHasCachedContentForImmediatePaint())
            if ms >= 50 {
                TabTapPerf.mainActorBusy(ms: ms, source: "goingHeavyContentReady")
            }
        }
    }

    /// Cancels deferred Going work when the tab is no longer selected. Does not clear cached display content.
    private func cancelGoingTabDeferredWork(reason: String) {
        var canceledDeferred = false
        if let task = goingTabPerf.deferredSurfacePrepareTask {
            task.cancel()
            goingTabPerf.deferredSurfacePrepareTask = nil
            canceledDeferred = true
        }
        if let task = goingTabPerf.deferredBackgroundRefreshTask {
            task.cancel()
            goingTabPerf.deferredBackgroundRefreshTask = nil
            canceledDeferred = true
        }
        if let task = goingTabPerf.proGamesDisplayRebuildTask {
            task.cancel()
            goingTabPerf.proGamesDisplayRebuildTask = nil
            canceledDeferred = true
        }
        if let task = goingTabPerf.avatarPrefetchTask {
            task.cancel()
            goingTabPerf.avatarPrefetchTask = nil
            DebugLogGate.goingTabPerfVerbose("[GoingTabPerf] prefetchCanceled reason=\(reason)")
        }
        // Invalidate any in-flight stage that still holds an older generation.
        goingTabPerf.tabSelectionActivationGeneration &+= 1
        if canceledDeferred {
            DebugLogGate.goingTabPerfVerbose("[GoingTabPerf] deferredTaskCanceled reason=\(reason)")
        }
    }

    private func isGoingTabSelectionGenerationCurrent(_ generation: UInt64) -> Bool {
        isFollowingTabSelected && generation == goingTabPerf.tabSelectionActivationGeneration
    }

    /// Begins a new Going tab selection session (tab became visible).
    private func prepareGoingTabSelectionGeneration() {
        guard isFollowingTabSelected else { return }
        if !goingTabPerf.tabSelectionActivationActive {
            goingTabPerf.tabSelectionActivationGeneration &+= 1
            goingTabPerf.tabSelectionActivationActive = true
        }
    }

    /// Returns the current selection generation when this caller wins activation; nil if duplicate.
    private func claimGoingTabSelectionActivation(source: String) -> UInt64? {
        prepareGoingTabSelectionGeneration()
        let generation = goingTabPerf.tabSelectionActivationGeneration
        if goingTabPerf.handledTabSelectionActivationGeneration == generation {
            DebugLogGate.goingTabPerfVerbose("[GoingTabPerf] activationSkipped reason=duplicateGeneration")
            return nil
        }
        goingTabPerf.handledTabSelectionActivationGeneration = generation
        return generation
    }

    /// Standard tab-selection activation: cached paint + deferred surface prep + background refresh.
    @discardableResult
    private func runGoingTabSelectionActivationIfNeeded(
        source: String,
        deferredRefreshReason: String? = nil
    ) -> Bool {
        guard isFollowingTabSelected else { return false }
        guard viewModel.isAuthenticatedForSocialFeatures else { return false }
        guard claimGoingTabSelectionActivation(source: source) != nil else { return false }

        markGoingScreenAppear(source: source)
        let cachedPaint = paintGoingTabFromCachedStateImmediately(reason: source)
        if !cachedPaint {
            goingTabPerf.deferredWorkReady = false
            goingTabPerf.firstPaintRecorded = false
        }
        GoingActivationPerf.activation(
            cachedRows: viewModel.followingTabGoingItems.count
                + viewModel.myPickupGameJoinRequestCards.count
                + viewModel.savedProGames.count,
            source: source
        )
        logGoingTabPerfSummary(
            cachedPaint: cachedPaint,
            deferredRefresh: !goingTabRecentlyBackgroundRefreshed(within: GoingTabPerfState.backgroundRefreshTTL),
            reason: source
        )
        scheduleGoingTabDeferredSurfacePrepare(reason: source)
        scheduleGoingTabDeferredBackgroundRefresh(reason: deferredRefreshReason ?? source)
        return true
    }

    private func goingTabRecentlyPrepared(within interval: TimeInterval) -> Bool {
        guard let last = goingTabPerf.lastVisibleSurfacePrepareAt else { return false }
        return Date().timeIntervalSince(last) < interval
    }

    private func goingTabRecentlyBackgroundRefreshed(within interval: TimeInterval) -> Bool {
        guard let last = goingTabPerf.lastBackgroundRefreshAt else { return false }
        return Date().timeIntervalSince(last) < interval
    }

    @discardableResult
    private func paintGoingTabFromCachedStateImmediately(reason: String) -> Bool {
        if viewModel.savedProGames.isEmpty, let userID = viewModel.currentUserAuthId {
            viewModel.reloadSavedProGamesFromStorage(for: userID)
        }
        rebuildFollowingDisplayCaches(reason: "\(reason):cachedPaint", prefetchAvatars: false)
        let proPaintSource = applyGoingProGamesDisplayCacheForFirstPaint(reason: reason)
        let hasCachedContent = goingTabHasCachedContentForImmediatePaint()
        if hasCachedContent {
            goingTabPerf.deferredWorkReady = true
            recordGoingFirstPaintIfNeeded(source: "\(reason)Cached", proPaintSource: proPaintSource)
        }
        return hasCachedContent
    }

    private func goingTabHasCachedContentForImmediatePaint() -> Bool {
        !viewModel.followingTabGoingItems.isEmpty
            || !goingTabPerf.cachedManualSavedProGamesForDisplay.isEmpty
            || !goingTabPerf.cachedFavoriteTeamProGamesForDisplay.isEmpty
            || !viewModel.savedProGames.isEmpty
            || !viewModel.favoriteTeamProGames.isEmpty
            || !viewModel.myPickupGameJoinRequestCards.isEmpty
            || !viewModel.myPickupGamesForSettings.isEmpty
            || !viewModel.incomingPickupGameInvites.isEmpty
    }

    private func logGoingTabPerfSummary(cachedPaint: Bool, deferredRefresh: Bool, reason: String) {
        DebugLogGate.goingTabPerfSummary(
            "[GoingTabPerf] cachedPaint=\(cachedPaint) " +
            "deferredRefresh=\(deferredRefresh) " +
            "delayMs=\(GoingTabPerfState.deferredWorkDelayMs) " +
            "reason=\(reason)"
        )
    }

    /// Stable snapshot of Going tab inputs that ``prepareGoingTabVisibleSurface`` rebuilds from.
    private func goingTabVisibleSurfaceDataFingerprint() -> String {
        let auth = viewModel.currentUserAuthId?.uuidString ?? "signedOut"
        let going = viewModel.followingTabGoingItems
            .map { "\($0.id.uuidString):\($0.isServerGoing ? 1 : 0):\($0.isInterestedOnlyLocal ? 1 : 0)" }
            .sorted()
            .joined(separator: ",")
        let saved = viewModel.savedProGames.map(\.id).sorted().joined(separator: ",")
        let favorite = viewModel.favoriteTeamProGames.map(\.id).sorted().joined(separator: ",")
        let playing = viewModel.myPickupGameJoinRequestCards
            .map { "\($0.id.uuidString):\($0.pill.rawValue)" }
            .sorted()
            .joined(separator: ",")
        let hosting = (
            viewModel.myPickupGamesForSettings.map(\.id.uuidString)
            + viewModel.myRemovedPickupGamesForSettings.map(\.id.uuidString)
        ).sorted().joined(separator: ",")
        let invites = viewModel.incomingPickupGameInvites
            .map(\.id.uuidString)
            .sorted()
            .joined(separator: ",")
        let prefs = [
            favoriteTeamProGameAlertsEnabled ? "autoOn" : "autoOff",
            "\(proGamesFavoriteTeamWindowDays)",
            favoriteTeamIDsRaw
        ].joined(separator: "|")
        return [
            "auth=\(auth)",
            "going=\(going)",
            "saved=\(saved)",
            "favorite=\(favorite)",
            "playing=\(playing)",
            "hosting=\(hosting)",
            "invites=\(invites)",
            "prefs=\(prefs)"
        ].joined(separator: ";")
    }

    /// Stable snapshot of Going > Pro display inputs used by ``rebuildGoingProGamesDisplayCaches``.
    private func goingProGamesDisplayFingerprint() -> String {
        let saved = viewModel.savedProGames
            .map { "\($0.stableKey):\($0.matchStatus.rawValue):\($0.scoreHome)-\($0.scoreAway)" }
            .sorted()
            .joined(separator: ",")
        let favorite = viewModel.favoriteTeamProGames
            .map { "\($0.game.stableKey):\($0.favoriteTeamID)" }
            .sorted()
            .joined(separator: ",")
        let prefs = [
            favoriteTeamProGameAlertsEnabled ? "autoOn" : "autoOff",
            "\(proGamesFavoriteTeamWindowDays)",
            favoriteTeamIDsRaw,
            clearedCompletedFavoriteTeamProGamesRaw
        ].joined(separator: "|")
        return "saved=\(saved);favorite=\(favorite);prefs=\(prefs)"
    }

    /// True when Schedule, Calendar, warm cache, or a recent fetch already populated Pro datasets.
    private func goingProDataRecentlyWarmedFromScheduleOrCalendar(
        within interval: TimeInterval = GoingTabPerfState.calendarProReuseTTL
    ) -> Bool {
        let savedFresh = viewModel.lastSavedProGamesFetchAt.map { Date().timeIntervalSince($0) < interval } ?? false
        let warmFresh = viewModel.lastUserPreferencesWarmCacheAt.map { Date().timeIntervalSince($0) < interval } ?? false
        let calendarFresh = viewModel.calendarProGamesRefreshAtByDay.values.contains {
            Date().timeIntervalSince($0) < interval
        }
        let favoriteFresh = viewModel.lastFavoriteTeamProGamesRefreshAt.map {
            Date().timeIntervalSince($0) < interval
        } ?? false
        let hasSavedData = !viewModel.savedProGames.isEmpty
        let hasFavoriteData = !viewModel.favoriteTeamProGames.isEmpty
        return (savedFresh || warmFresh || calendarFresh) && hasSavedData
            || favoriteFresh && hasFavoriteData
    }

    @discardableResult
    private func applyGoingProGamesDisplayCacheForFirstPaint(reason: String) -> String {
        let fingerprint = goingProGamesDisplayFingerprint()
        let hasDisplayCache =
            !goingTabPerf.cachedManualSavedProGamesForDisplay.isEmpty
            || !goingTabPerf.cachedFavoriteTeamProGamesForDisplay.isEmpty
        let hasSourceData =
            !viewModel.savedProGames.isEmpty || !viewModel.favoriteTeamProGames.isEmpty

        if hasDisplayCache, goingTabPerf.lastProGamesDisplayFingerprint == fingerprint {
            DebugLogGate.goingTabPerfVerbose(
                "[GoingProPerf] firstPaint cached=true source=displayCache"
            )
            return "displayCache"
        }
        if hasSourceData {
            if goingTabShouldSkipProGamesDisplayRebuild(fingerprint: fingerprint) {
                DebugLogGate.goingTabPerfVerbose(
                    "[GoingProPerf] displayRebuildSkipped reason=fingerprintUnchanged"
                )
                DebugLogGate.goingTabPerfVerbose(
                    "[GoingProPerf] firstPaint cached=true source=displayCache"
                )
                return "displayCache"
            }
            rebuildGoingProGamesDisplayCachesSynchronously(reason: "\(reason):firstPaint")
            DebugLogGate.goingTabPerfVerbose(
                "[GoingProPerf] firstPaint cached=true source=memoryRebuild"
            )
            return "memoryRebuild"
        }
        DebugLogGate.goingTabPerfVerbose(
            "[GoingProPerf] firstPaint cached=false source=none"
        )
        return "none"
    }

    private func goingTabShouldSkipProGamesDisplayRebuild(fingerprint: String) -> Bool {
        guard goingTabPerf.lastProGamesDisplayFingerprint == fingerprint else { return false }
        if !goingTabPerf.cachedManualSavedProGamesForDisplay.isEmpty
            || !goingTabPerf.cachedFavoriteTeamProGamesForDisplay.isEmpty {
            return true
        }
        return viewModel.savedProGames.isEmpty && viewModel.favoriteTeamProGames.isEmpty
    }

    private func scheduleGoingTabDeferredSurfacePrepare(reason: String) {
        let fingerprint = goingTabVisibleSurfaceDataFingerprint()
        if goingTabRecentlyPrepared(within: GoingTabPerfState.visibleSurfacePrepareTTL),
           goingTabPerf.lastVisibleSurfacePrepareFingerprint == fingerprint {
            TabPerf.refreshSkipped(name: "goingTabVisibleSurface", reason: "freshUnchangedFingerprint")
            DebugLogGate.goingTabPerfVerbose(
                "[GoingTabPerf] surfacePrepareSkipped reason=freshUnchangedFingerprint"
            )
            return
        }
        if goingTabPerf.deferredSurfacePrepareTask != nil {
            TabPerf.duplicateRefreshCoalesced(name: "goingTabVisibleSurface")
            return
        }
        let generation = goingTabPerf.tabSelectionActivationGeneration
        goingTabPerf.deferredSurfacePrepareTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: GoingTabPerfState.deferredBackgroundRefreshDelayNs)
            guard !Task.isCancelled else {
                DebugLogGate.goingTabPerfVerbose("[GoingTabPerf] deferredTaskCanceled reason=surfacePrepareCancelled")
                return
            }
            guard isGoingTabSelectionGenerationCurrent(generation) else {
                DebugLogGate.goingTabPerfVerbose("[GoingTabPerf] deferredTaskCanceled reason=leftBeforeSurfacePrepare")
                goingTabPerf.deferredSurfacePrepareTask = nil
                return
            }
            await prepareGoingTabVisibleSurface(reason: reason)
            goingTabPerf.deferredSurfacePrepareTask = nil
        }
    }

    private func scheduleGoingTabDeferredBackgroundRefresh(reason: String) {
        if goingTabRecentlyBackgroundRefreshed(within: GoingTabPerfState.backgroundRefreshTTL) {
            TabPerf.refreshSkipped(name: "goingTabBackgroundRefresh", reason: "freshCache")
            GoingPerfDebug.duplicateRefreshSkipped(source: reason, reason: "freshCache")
            DebugLogGate.tabSwitchPerfVerbose("[TabDeferredRefresh] tab=going reason=\(reason) skipped=fresh")
            return
        }
        if goingTabPerf.backgroundRefreshInFlight {
            TabPerf.duplicateRefreshCoalesced(name: "goingTabBackgroundRefresh")
            GoingPerfDebug.duplicateRefreshSkipped(source: reason, reason: "inFlight")
            DebugLogGate.tabSwitchPerfVerbose("[TabDeferredRefresh] tab=going reason=\(reason) skipped=inFlight")
            return
        }
        if goingTabPerf.deferredBackgroundRefreshTask != nil {
            TabPerf.duplicateRefreshCoalesced(name: "goingTabBackgroundRefresh")
            GoingPerfDebug.duplicateRefreshSkipped(source: reason, reason: "deferredScheduled")
            DebugLogGate.tabSwitchPerfVerbose("[TabDeferredRefresh] tab=going reason=\(reason) skipped=deferredScheduled")
            return
        }
        let generation = goingTabPerf.tabSelectionActivationGeneration
        goingTabPerf.deferredBackgroundRefreshTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: GoingTabPerfState.deferredBackgroundRefreshDelayNs)
            guard !Task.isCancelled else {
                DebugLogGate.goingTabPerfVerbose("[GoingTabPerf] deferredTaskCanceled reason=backgroundRefreshCancelled")
                return
            }
            guard isGoingTabSelectionGenerationCurrent(generation) else {
                DebugLogGate.goingTabPerfVerbose("[GoingTabPerf] deferredTaskCanceled reason=leftBeforeBackgroundRefresh")
                goingTabPerf.deferredBackgroundRefreshTask = nil
                return
            }
            DebugLogGate.tabSwitchPerfVerbose("[TabDeferredRefresh] tab=going reason=\(reason) started")
            await performGoingTabBackgroundRefresh(reason: reason, selectionGeneration: generation)
            if isGoingTabSelectionGenerationCurrent(generation) {
                goingTabPerf.lastBackgroundRefreshAt = Date()
            }
            DebugLogGate.tabSwitchPerfVerbose("[TabDeferredRefresh] tab=going reason=\(reason) finished")
            goingTabPerf.deferredBackgroundRefreshTask = nil
        }
    }

    @MainActor
    private func fulfillProGameNotificationDeepLinkIfReady() async {
        guard isFollowingTabSelected else { return }
        guard let matchID = pendingProGameNotificationMatchID else { return }

        selectedGoingMode = .proGames
        sanitizeBusinessGoingModeIfNeeded()

        await prepareGoingTabVisibleSurface(reason: "proGameNotificationDeepLink")
        await performGoingTabBackgroundRefresh(
            reason: "proGameNotificationDeepLink",
            selectionGeneration: goingTabPerf.tabSelectionActivationGeneration
        )
        await viewModel.refreshLiveMatchesForLiveTab(forceRefresh: false)

        if let match = viewModel.resolveLiveMatchForProGameNotificationDeepLink(matchID: matchID) {
            proGameMatchDetailSelection = match
        }

        pendingProGameNotificationMatchID = nil
    }

    @ViewBuilder
    private func attachFollowingPresentation<Content: View>(to content: Content) -> some View {
        content
        .sheet(item: $pickupDetailNav, onDismiss: {
            Task {
                await viewModel.loadMyPickupGameJoinRequestsForFollowing(
                    forceRefresh: true,
                    reason: "pickupDetailDismiss"
                )
            }
        }) { token in
            DiscoverPickupGameDetailSheet(viewModel: viewModel, token: token)
                .environmentObject(chatViewModel)
                .onAppear {
                    viewModel.acknowledgePickupFollowingActivity(for: token.id)
                }
        }
        .alert(item: $followingPickupWithdrawConfirm) { state in
            Alert(
                title: Text(state.intent.alertTitle),
                message: Text(state.intent.alertMessage),
                primaryButton: .destructive(Text("Yes, withdraw")) {
                    Task { await performFollowingPickupWithdraw(state) }
                },
                secondaryButton: .cancel()
            )
        }
        .alert(item: $followingPickupPlayingClearConfirm) { state in
            Alert(
                title: Text(L10n.t("pickup_playing_clear_confirm_title", languageCode: L10n.normalizedLanguageCode(appLanguageRaw))),
                message: Text(
                    L10n.t(
                        state.warnUnrated
                            ? "pickup_playing_clear_confirm_unrated_message"
                            : "pickup_playing_clear_confirm_rated_message",
                        languageCode: L10n.normalizedLanguageCode(appLanguageRaw)
                    )
                ),
                primaryButton: .destructive(
                    Text(
                        L10n.t(
                            state.warnUnrated
                                ? "pickup_playing_clear_anyway"
                                : "pickup_playing_clear_from_going",
                            languageCode: L10n.normalizedLanguageCode(appLanguageRaw)
                        )
                    )
                ) {
                    viewModel.markPickupFollowingPlayingCompletedUserCleared(pickupGameId: state.pickupGameId)
                    rebuildFollowingDisplayCaches(reason: "playingManualClear", prefetchAvatars: false)
                },
                secondaryButton: .cancel(Text(L10n.t("cancel", languageCode: L10n.normalizedLanguageCode(appLanguageRaw))))
            )
        }
        .sheet(item: $followingMyPickupFormMode) { mode in
            NavigationStack {
                SettingsPickupGameFormView(
                    viewModel: viewModel,
                    mode: mode,
                    onCreated: { row in
                        followingPendingPostCreateInviteGame = row
                    }
                ) {
                    followingMyPickupFormMode = nil
                    Task {
                        await viewModel.loadMyPickupGamesForSettings(forceRefresh: true, reason: "followingFormDismiss")
                        await viewModel.refreshPickupGamesForDiscoverMap(force: true)
                        logFollowingMyPickupGames(action: "formDismissReload")
                    }
                }
            }
        }
        .onChange(of: followingMyPickupFormMode) { _, newValue in
            guard newValue == nil, let row = followingPendingPostCreateInviteGame else { return }
            followingPendingPostCreateInviteGame = nil
            followingPickupInviteGame = row
        }
        .sheet(item: $followingPickupInviteGame, onDismiss: {
            Task {
                await viewModel.loadIncomingPickupGameInvites()
                await viewModel.loadMyPickupGamesForSettings()
            }
        }) { game in
            PickupGameInviteFriendsSheet(viewModel: viewModel, game: game)
                .environmentObject(chatViewModel)
        }
        .sheet(item: $followingPickupInviteDetail) { item in
            PickupGameInviteDetailSheet(
                item: item,
                isResponding: pickupInviteResponseInFlightId == item.id,
                onRespond: { status in
                    await respondToPickupInvite(item, status: status)
                    followingPickupInviteDetail = nil
                }
            )
        }
        .sheet(item: $followingMyPickupOrganizerRequestsGame, onDismiss: {
            Task {
                await viewModel.loadMyPickupGamesForSettings()
                logFollowingMyPickupGames(action: "requestsSheetDismiss")
            }
        }) { game in
            PickupOrganizerRequestsSheet(viewModel: viewModel, game: game)
                .environmentObject(viewModel)
        }
        .sheet(item: $followingMyPickupDetailGame, onDismiss: {
            Task {
                await viewModel.loadMyPickupGamesForSettings()
                logFollowingMyPickupGames(action: "detailSheetDismiss")
            }
        }) { game in
            FollowingMyPickupHostedGameDetailSheet(
                viewModel: viewModel,
                game: game,
                now: followingMyPickupClockTick,
                colorScheme: followingColorScheme,
                onDone: { followingMyPickupDetailGame = nil },
                onEdit: {
                    followingMyPickupDetailGame = nil
                    followingMyPickupFormMode = .edit(game)
                },
                onDelete: {
                    followingMyPickupDetailGame = nil
                    followingMyPickupDeleteTarget = game
                },
                onManageRequests: {
                    followingMyPickupDetailGame = nil
                    followingMyPickupOrganizerRequestsGame = game
                },
                onInvite: {
                    followingMyPickupDetailGame = nil
                    followingPickupInviteGame = game
                }
            )
            .environmentObject(chatViewModel)
        }
        .sheet(item: $proGamePredictionSheet) { context in
            ProGamePredictionSheet(viewModel: viewModel, game: context.game)
        }
        .sheet(item: $proGameMatchDetailSelection) { match in
            LiveMatchDetailSheet(match: match, viewModel: viewModel)
                .environmentObject(chatViewModel)
        }
        .sheet(item: $goingAddToVenueChooser) { context in
            CalendarAddToVenueChooserSheet(
                viewModel: viewModel,
                match: context.match,
                venues: goingAddToVenueChooserVenues(excludingHostedOf: context.match),
                onSelect: { venueId in
                    let match = context.match
                    goingAddToVenueChooser = nil
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 320_000_000)
                        presentGoingAddToVenueImport(match: match, venueId: venueId)
                    }
                },
                onCancel: {
                    goingAddToVenueChooser = nil
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
        .sheet(item: $goingAddToVenueImportPrefill) { prefill in
            VenueOwnerDashboardView(
                viewModel: viewModel,
                entryPoint: .gamesManager,
                scheduleImportPrefill: prefill
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
            .onDisappear {
                Task {
                    await refreshGoingAddToVenueHostedStatus(for: prefill.match)
                }
            }
        }
        .sheet(isPresented: $showGoingManageGamesFromHostedStatus) {
            VenueOwnerDashboardView(
                viewModel: viewModel,
                entryPoint: .gamesManager
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
        .sheet(isPresented: $showFavoriteTeamsPicker) {
            AnyView(
                FavoriteTeamsPickerSheet(
                    selectedIDs: Binding(
                        get: { FavoriteTeamsStore.decodeIDs(from: favoriteTeamIDsRaw) },
                        set: { newIDs in
                            let ordered = FavoriteTeamsStore.uniquedIDs(newIDs)
                            favoriteTeamIDsRaw = FavoriteTeamsStore.encodeIDs(ordered)
                            Task {
                                await viewModel.syncFavoriteTeamsToSupabase(teamIDs: ordered)
                            }
                        }
                    )
                )
            )
        }
        .alert(followingMyPickupDeleteAlertTitle, isPresented: Binding(
            get: { followingMyPickupDeleteTarget != nil },
            set: { if !$0 { followingMyPickupDeleteTarget = nil } }
        )) {
            Button("Keep game", role: .cancel) { followingMyPickupDeleteTarget = nil }
            Button(followingMyPickupDeleteButtonTitle, role: .destructive) {
                guard let row = followingMyPickupDeleteTarget else { return }
                followingMyPickupDeleteTarget = nil
                Task { await performFollowingMyPickupDelete(row) }
            }
        } message: {
            Text(followingMyPickupDeleteAlertMessage)
        }
        .overlay(alignment: .bottom) {
            if let text = followingMyPickupBanner, !text.isEmpty {
                Text(text)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.primaryText(followingColorScheme))
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.vertical, FGSpacing.sm)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding()
            }
        }
    }

    /// Reload Following when fan or business-owner auth changes while a Supabase session may already exist.
    private func syncFollowingAfterAuthChange() async {
        if viewModel.isAuthenticatedForSocialFeatures, isBusinessProGamesOnly {
            let cachedPaint = paintGoingTabFromCachedStateImmediately(reason: "authChanged")
            logGoingTabPerfSummary(
                cachedPaint: cachedPaint,
                deferredRefresh: !goingTabRecentlyBackgroundRefreshed(within: GoingTabPerfState.backgroundRefreshTTL),
                reason: "authChanged"
            )
            scheduleGoingTabDeferredSurfacePrepare(reason: "authChanged")
            scheduleGoingTabDeferredBackgroundRefresh(reason: "authChanged")
        } else if viewModel.isAuthenticatedForSocialFeatures, viewModel.canUseFollowingTab {
            let cachedPaint = paintGoingTabFromCachedStateImmediately(reason: "authChanged")
            logGoingTabPerfSummary(
                cachedPaint: cachedPaint,
                deferredRefresh: !goingTabRecentlyBackgroundRefreshed(within: GoingTabPerfState.backgroundRefreshTTL),
                reason: "authChanged"
            )
            scheduleGoingTabDeferredSurfacePrepare(reason: "authChanged")
            scheduleGoingTabDeferredBackgroundRefresh(reason: "authChanged")
        } else {
            clearFollowingUserSpecificState()
            interestedOnlyEncoded = ""
        }
    }

    private func sanitizeBusinessGoingModeIfNeeded() {
        guard isBusinessProGamesOnly, selectedGoingMode != .proGames else { return }
        selectedGoingMode = .proGames
    }

    private func performFollowingPickupWithdraw(_ state: PickupJoinWithdrawConfirmState) async {
        followingPickupWithdrawInFlight = true
        followingPickupWithdrawConfirm = nil
        defer { followingPickupWithdrawInFlight = false }
        do {
            try await viewModel.withdrawMyPickupJoinRequest(requestId: state.requestId, pickupGameId: state.pickupGameId)
        } catch {
            viewModel.showSocialActionToast(error.localizedDescription, isError: true)
        }
    }

    private var followingMyPickupDeleteTargetIsExpired: Bool {
        guard let row = followingMyPickupDeleteTarget,
              let deadline = row.pickupHistoryClientCleanupDeadline() else {
            return false
        }
        return followingMyPickupClockTick >= deadline
    }

    private var followingMyPickupDeleteAlertTitle: String {
        followingMyPickupDeleteTargetIsExpired ? "Clear expired pickup game?" : "Cancel this pickup game?"
    }

    private var followingMyPickupDeleteButtonTitle: String {
        followingMyPickupDeleteTargetIsExpired ? "Clear expired" : "Cancel game"
    }

    private var followingMyPickupDeleteAlertMessage: String {
        followingMyPickupDeleteTargetIsExpired
            ? "This removes the expired hosted pickup game from your active Hosting list."
            : "Players who requested or joined will be notified."
    }

    // MARK: - Logged out

    private var loggedOutContent: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                FanGeoPagePurposeHeader(
                    title: L10n.t("going_tab_title", languageCode: appLanguageRaw),
                    subtitle: ""
                )
                .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 4)
                FanGeoActionCenterHeaderButton()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)

            SignedOutFeatureView(
                icon: "bookmark.fill",
                title: L10n.t("going_signed_out_title", languageCode: appLanguageRaw),
                description: L10n.t("going_signed_out_body", languageCode: appLanguageRaw),
                accent: FGColor.accentBlue,
                onSignIn: {
                    viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
                },
                onCreateAccount: {
                    viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: true)
                }
            )
        }
        .padding(.bottom, 92)
    }

    // MARK: - Logged in

    private var loggedInContent: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                goingHubHeader()
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.bottom, 8)

                ScrollView {
                    goingHubContent
                        .padding(.horizontal, FGSpacing.md)
                        .padding(.bottom, 110)
                }
                .refreshable {
                    if isBusinessProGamesOnly {
                        await reloadBusinessProGamesData(reason: "pullToRefresh")
                        logGoingHubDebug(reason: "pullToRefresh")
                        return
                    }
                    if activeGoingMode == .proGames {
                        await viewModel.refreshGoingProGames(reason: "pullToRefresh")
                        await refreshFavoriteTeamProGames(reason: "pullToRefresh", forceRefresh: true)
                    } else {
                        await viewModel.fetchSavedProGames(forceRefresh: true, reason: "pullToRefresh")
                    }
                    await viewModel.refreshFollowingTabDataGlobally()
                    await viewModel.loadMyPickupGameJoinRequestsForFollowing(
                        forceRefresh: true,
                        reason: "pullToRefresh"
                    )
                    logFollowingMyPickupGames(action: "pullToRefresh")
                    logGoingHubDebug(reason: "pullToRefresh")
                }
                .onReceive(followingMyPickupMinuteTicker) { date in
                    followingMyPickupClockTick = date
                    runFollowingHostedPickupAutoClearIfNeeded(now: date, reason: "followingMinuteTick")
                    guard isFollowingTabSelected else { return }
                    rebuildFollowingDisplayCaches(reason: "goingCompletedVisibilityTick", prefetchAvatars: false)
                    scheduleGoingProGamesDisplayCacheRebuild(reason: "goingCompletedVisibilityTick")
                }
                .onChange(of: viewModel.pendingPickupCreatorRatingNotificationDeepLink) { _, request in
                    guard let request else { return }
                    fulfillPickupCreatorRatingNotificationDeepLink(
                        pickupGameId: request.pickupGameId,
                        scrollProxy: proxy
                    )
                }
                .onAppear {
                    if let request = viewModel.pendingPickupCreatorRatingNotificationDeepLink {
                        fulfillPickupCreatorRatingNotificationDeepLink(
                            pickupGameId: request.pickupGameId,
                            scrollProxy: proxy
                        )
                    }
                }
            }
        }
        .onAppear {
            logGoingHubDebug(reason: "appear")
        }
    }

    private func goingHubHeader() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                FanGeoPagePurposeHeader(
                    title: L10n.t("going_tab_title", languageCode: appLanguageRaw),
                    subtitle: goingHubHeaderSubtitle
                )
                .padding(.top, 8)

                Spacer(minLength: 8)

                FanGeoActionCenterHeaderButton()
            }

            if let favoriteActionBanner {
                Text(favoriteActionBanner)
                    .font(FGTypography.metadata)
                    .fontWeight(.semibold)
                    .foregroundStyle(FGColor.accentYellow)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(FGColor.accentYellow.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: FGRadius.small, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var goingHubHeaderSubtitle: String {
        if isBusinessProGamesOnly {
            return L10n.t("going_tab_subtitle_business", languageCode: appLanguageRaw)
        }
        return L10n.t("going_tab_subtitle", languageCode: appLanguageRaw)
    }

    private var goingHubContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            goingModeSwitcher

            Group {
                switch activeGoingMode {
                case .venueGames:
                    goingVenueTabsGroup
                case .pickupGames:
                    goingGamesTabsGroup
                case .proGames:
                    goingProGamesGroup
                }
            }
            .id(activeGoingMode)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
        .padding(.top, 6)
    }

    private var goingVenueGameItems: [FollowingGoingDisplayItem] {
        let base = cachedGoingVenueGameItems
        guard goingDayScope == .today else { return base }
        return base.filter { isGoingVenueEventOnLocalToday($0.venueEvent) }
    }

    private func applyPendingDiscoverTodayDashboardNavIfNeeded() {
        guard isFollowingTabSelected else { return }
        guard let intent = viewModel.pendingDiscoverTodayDashboardNav else { return }
        switch intent {
        case .goingVenueGamesToday:
            selectedGoingMode = .venueGames
            selectedGoingWatchFilter = .games
            goingDayScope = .today
            viewModel.clearPendingDiscoverTodayDashboardNav()
#if DEBUG
            print("[DiscoverTodayDashboard] applied goingVenueGamesToday")
#endif
        case .goingPickupGamesToday:
            selectedGoingMode = .pickupGames
            selectedGoingPlayFilter = .all
            goingDayScope = .today
            viewModel.clearPendingDiscoverTodayDashboardNav()
#if DEBUG
            print("[DiscoverTodayDashboard] applied goingPickupGamesToday")
#endif
        case .goingVenueGamesUpcoming:
            selectedGoingMode = .venueGames
            selectedGoingWatchFilter = .games
            goingDayScope = .all
            viewModel.clearPendingDiscoverTodayDashboardNav()
#if DEBUG
            print("[DiscoverTodayDashboard] applied goingVenueGamesUpcoming")
#endif
        case .goingPickupGamesUpcoming:
            selectedGoingMode = .pickupGames
            selectedGoingPlayFilter = .all
            goingDayScope = .all
            viewModel.clearPendingDiscoverTodayDashboardNav()
#if DEBUG
            print("[DiscoverTodayDashboard] applied goingPickupGamesUpcoming")
#endif
        case .accountSuggestedFans, .chatFansLiveNow:
            break
        }
    }

    /// Cached: this runs inside Going display-cache rebuild filter loops on every
    /// tab activation; a per-call `DateFormatter()` here was rebuilt for every row.
    private static let goingLocalDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func isGoingVenueEventOnLocalToday(_ row: VenueEventRow, now: Date = Date()) -> Bool {
        if let start = FanGeoLiveEnergyTiming.parseScheduledStart(row.scheduled_start_at, eventId: row.id) {
            return Calendar.current.isDate(start, inSameDayAs: now)
        }
        let todayYMD = Self.goingLocalDayFormatter.string(from: now)
        let eventYMD = (row.event_date ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard eventYMD.count >= 10 else { return false }
        return String(eventYMD.prefix(10)) == todayYMD
    }

    private func isPickupStartOnLocalToday(_ rawStart: String, now: Date = Date()) -> Bool {
        guard let start = PickupGameModels.parseSupabaseTimestamptz(rawStart) else { return false }
        return Calendar.current.isDate(start, inSameDayAs: now)
    }

    private func rebuildFollowingDisplayCaches(reason: String, prefetchAvatars: Bool = true) {
#if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
#endif
        let sorted = MapViewModel.sortFollowingGoingItemsChronologically(
            viewModel.followingTabGoingItems
                .filter(\.isActiveGoingTabPlan)
                .filter { GoingTabCompletedGameVisibility.isVenueGameVisibleInGoingTab(row: $0.venueEvent) }
        )
        let playing = viewModel.myPickupGameJoinRequestCards.filter { card in
            switch card.pill {
            case .pending, .approved, .declined:
                return true
            case .cancelled, .withdrawing, .canceledByOrganizer:
                return false
            }
        }.filter { card in
            guard let game = viewModel.pickupGamesFollowingTabCache[card.pickupGameId] else { return true }
            return viewModel.isPickupPlayingCardVisibleInGoing(
                game: game,
                now: followingMyPickupClockTick
            )
        }
        let fingerprint = followingDisplayCachesFingerprint(venueItems: sorted, playingCards: playing)
        if fingerprint == goingTabPerf.lastFollowingDisplayCachesFingerprint {
            DebugLogGate.goingTabPerfVerbose(
                "[GoingTabPerf] displayPublishSkipped reason=unchangedFingerprint rebuildReason=\(reason)"
            )
            if prefetchAvatars {
                prefetchVisibleGoingAvatars(reason: reason)
            }
#if DEBUG
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            GoingActivationPerf.snapshotBuildMs(ms, reason: "\(reason):skipped")
            DebugLogGate.goingTabPerfVerbose(
                "[RenderPerf] view=FollowingScreen renderMs=\(String(format: "%.2f", ms)) rebuildReason=\(reason):skipped"
            )
#endif
            return
        }
        cachedGoingVenueGameItems = sorted
        cachedPlayingGameCards = playing
        goingTabPerf.lastFollowingDisplayCachesFingerprint = fingerprint
        logGoingTabSortDebug(sorted)
        if prefetchAvatars {
            prefetchVisibleGoingAvatars(reason: reason)
        }
#if DEBUG
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        GoingActivationPerf.snapshotBuildMs(ms, reason: reason)
        GoingActivationPerf.publishMs(ms, reason: reason)
        DebugLogGate.goingTabPerfVerbose(
            "[RenderPerf] view=FollowingScreen renderMs=\(String(format: "%.2f", ms)) rebuildReason=\(reason)"
        )
        DebugLogGate.goingTabPerfVerbose(
            "[PickupPlayingDebug] visiblePlayingCount=\(cachedPlayingGameCards.count)"
        )
#endif
    }

    private func followingDisplayCachesFingerprint(
        venueItems: [FollowingGoingDisplayItem],
        playingCards: [PickupGameJoinRequestCardDisplay]
    ) -> String {
        let going = venueItems
            .map { "\($0.id.uuidString):\($0.isServerGoing ? 1 : 0):\($0.isInterestedOnlyLocal ? 1 : 0)" }
            .joined(separator: ",")
        let playing = playingCards
            .map {
                let rated = viewModel.hasSubmittedPickupCreatorRating(for: $0.pickupGameId)
                let ratedAt = viewModel.myPickupCreatorRatingCreatedAt(for: $0.pickupGameId)?.timeIntervalSince1970 ?? 0
                let cleared = viewModel.isPickupFollowingPlayingCompletedUserCleared(pickupGameId: $0.pickupGameId) ? 1 : 0
                let post = viewModel.pickupCreatorRatingPostSubmitPromptGameIds.contains($0.pickupGameId) ? 1 : 0
                return "\($0.id.uuidString):\($0.pill.rawValue):r\(rated ? 1 : 0):t\(Int(ratedAt)):c\(cleared):p\(post)"
            }
            .joined(separator: ",")
        return "going=\(going);playing=\(playing)"
    }

    private func prefetchVisibleGoingAvatars(reason: String) {
        guard isFollowingTabSelected else {
            DebugLogGate.goingTabPerfVerbose("[GoingTabPerf] prefetchCanceled reason=notSelected:\(reason)")
            return
        }
        var seen = Set<URL>()
        var urls: [URL] = []

        func appendURL(thumbnail: String?, full: String?, refreshToken: UUID) {
            guard let raw = ImageDisplayURL.forListDisplay(
                thumbnail: thumbnail,
                full: full ?? "",
                refreshToken: refreshToken
            ),
                  let url = URL(string: raw),
                  seen.insert(url).inserted else { return }
            urls.append(url)
        }

        for card in cachedPlayingGameCards.prefix(10) {
            appendURL(
                thumbnail: viewModel.pickupOrganizerAvatarThumbnailForDetail(userId: card.organizerUserId),
                full: viewModel.pickupOrganizerAvatarFullForDetail(userId: card.organizerUserId),
                refreshToken: viewModel.pickupOrganizerAvatarRefreshTokenForDetail(userId: card.organizerUserId)
            )
        }

        for item in viewModel.incomingPickupGameInvites.prefix(6) {
            appendURL(
                thumbnail: ImageDisplayURL.canonicalStorageURLString(item.inviterProfile?.avatar_thumbnail_url),
                full: ImageDisplayURL.canonicalStorageURLString(item.inviterProfile?.avatar_url),
                refreshToken: UserAvatarView.stableRefreshToken(
                    userId: item.invite.inviter_user_id,
                    thumbnailURL: item.inviterProfile?.avatar_thumbnail_url,
                    avatarURL: item.inviterProfile?.avatar_url
                )
            )
        }

        guard !urls.isEmpty else {
#if DEBUG
            print("[SmoothPerf] operation=goingAvatarPrefetch skipped=noURLs durationMs=0 coalesced=false avatarCount=0 reason=\(reason)")
#endif
            return
        }

        goingTabPerf.avatarPrefetchTask?.cancel()
        let generation = goingTabPerf.tabSelectionActivationGeneration
        let candidateURLs = Array(urls.prefix(8))
        goingTabPerf.avatarPrefetchTask = Task(priority: .utility) {
            let startedAt = Date()
            await Task.yield()
            guard !Task.isCancelled else {
                await MainActor.run {
                    DebugLogGate.goingTabPerfVerbose("[GoingTabPerf] prefetchCanceled reason=taskCancelled:\(reason)")
                }
                return
            }
            let stillSelected = await MainActor.run { isGoingTabSelectionGenerationCurrent(generation) }
            guard stillSelected else {
                await MainActor.run {
                    DebugLogGate.goingTabPerfVerbose("[GoingTabPerf] prefetchCanceled reason=leftTab:\(reason)")
                    goingTabPerf.avatarPrefetchTask = nil
                }
                return
            }
            var uncached: [URL] = []
            for url in candidateURLs {
                if await DiscoverMapImageCache.shared.cachedImage(for: url, bucket: .avatar) == nil {
                    uncached.append(url)
                }
            }
            guard !uncached.isEmpty else {
#if DEBUG
                print("[SmoothPerf] operation=goingAvatarPrefetch skipped=alreadyCached durationMs=0 coalesced=false avatarCount=\(candidateURLs.count) reason=\(reason)")
#endif
                await MainActor.run { goingTabPerf.avatarPrefetchTask = nil }
                return
            }
            guard !Task.isCancelled else {
                await MainActor.run {
                    DebugLogGate.goingTabPerfVerbose("[GoingTabPerf] prefetchCanceled reason=taskCancelledBeforeFetch:\(reason)")
                    goingTabPerf.avatarPrefetchTask = nil
                }
                return
            }
            let stillOnGoing = await MainActor.run { isGoingTabSelectionGenerationCurrent(generation) }
            guard stillOnGoing else {
                await MainActor.run {
                    DebugLogGate.goingTabPerfVerbose("[GoingTabPerf] prefetchCanceled reason=leftBeforeFetch:\(reason)")
                    goingTabPerf.avatarPrefetchTask = nil
                }
                return
            }
            await DiscoverMapImageCache.shared.prefetch(urls: uncached, bucket: .avatar)
#if DEBUG
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            print("[SmoothPerf] operation=goingAvatarPrefetch skipped=none durationMs=\(ms) coalesced=false avatarCount=\(uncached.count) reason=\(reason)")
#endif
            await MainActor.run {
                if goingTabPerf.avatarPrefetchTask != nil {
                    goingTabPerf.avatarPrefetchTask = nil
                }
            }
        }
    }

    private func logGoingTabSortDebug(_ items: [FollowingGoingDisplayItem]) {
#if DEBUG
        let firstStart = items.first.map { goingTabSortDebugStartString(for: $0.venueEvent) } ?? "nil"
        print("[GoingTabSortDebug] count=\(items.count) firstStart=\(firstStart)")
#endif
    }

    private func goingTabSortDebugStartString(for row: VenueEventRow) -> String {
        if let raw = row.scheduled_start_at?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw
        }
        let date = row.event_date?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let time = row.event_time?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let combined = [date, time].filter { !$0.isEmpty }.joined(separator: " ")
        return combined.isEmpty ? "nil" : combined
    }

    private func watchingVenueGameIsCompleted(_ item: FollowingGoingDisplayItem) -> Bool {
        let completed = VenueGameExpiration.isWatchingCompleted(row: item.venueEvent)
#if DEBUG
        if completed, WatchingExpiredVenueGameDiagnostics.enabled {
            VenueGameExpiration.logAuditOncePerEvaluation(row: item.venueEvent, eventID: item.id)
            print("[WatchingExpiredVenueGame] detected event_id=\(item.id.uuidString.lowercased())")
        }
#endif
        return completed
    }

    private var goingModeSwitcher: some View {
        GameOnSegmentedControl(
            tabs: goingModeTabs,
            selection: $selectedGoingMode,
            titleMinimumScaleFactor: 0.58,
            tabHorizontalPadding: 5
        )
    }

    private var goingModeTabs: [GameOnSegmentedTab<GoingParticipationMode>] {
        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        let proGames = GameOnSegmentedTab(
            id: GoingParticipationMode.proGames,
            title: GoingParticipationMode.proGames.title,
            systemImage: GoingParticipationMode.proGames.systemImage,
            badge: savedProGamesTabBadge,
            tint: GoingParticipationMode.proGames.tint,
            accessibilityLabel: L10n.t("going_a11y_pro_games", languageCode: languageCode)
        )
        if isBusinessProGamesOnly {
            return [proGames]
        }
        return [
            GameOnSegmentedTab(
                id: GoingParticipationMode.venueGames,
                title: GoingParticipationMode.venueGames.title,
                systemImage: GoingParticipationMode.venueGames.systemImage,
                badge: venueGamesTabBadge,
                tint: GoingParticipationMode.venueGames.tint,
                accessibilityLabel: L10n.t("going_a11y_watch", languageCode: languageCode)
            ),
            GameOnSegmentedTab(
                id: GoingParticipationMode.pickupGames,
                title: GoingParticipationMode.pickupGames.title,
                systemImage: GoingParticipationMode.pickupGames.systemImage,
                badge: pickupGamesTabBadge,
                tint: GoingParticipationMode.pickupGames.tint,
                showsActivityDot: !viewModel.incomingPickupGameInvites.isEmpty,
                accessibilityLabel: L10n.t("going_a11y_play", languageCode: languageCode),
                activityAccessibilityLabel: L10n.t("going_a11y_play_activity", languageCode: languageCode)
            ),
            proGames
        ]
    }

    private var goingVenueTabsGroup: some View {
        VStack(alignment: .leading, spacing: 14) {
            goingWatchFilterRow

            if goingDayScope == .today {
                goingTodayScopeBanner
            }

            if goingWatchVisibleItems.isEmpty {
                goingRichEmptyCard(
                    title: L10n.t(
                        GoingWatchProjection.emptyTitleKey(for: selectedGoingWatchFilter),
                        languageCode: goingWatchLanguageCode
                    ),
                    description: L10n.t(
                        GoingWatchProjection.emptySupportingKey(for: selectedGoingWatchFilter),
                        languageCode: goingWatchLanguageCode
                    ),
                    buttonTitle: goingWatchEmptyButtonTitle,
                    buttonAction: goingWatchEmptyButtonAction,
                    buttonAccent: FGColor.intentWatch
                )
            } else {
                goingWatchUnifiedListContent
            }
        }
        .onAppear {
#if DEBUG
            print("[GoingTabDebug] renamedWatchingTabToImGoing=true")
            print("[GoingTabDebug] imGoingTabVisible=true")
#endif
        }
    }

    private var goingWatchLanguageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var goingWatchUnifiedItems: [GoingWatchItem] {
        GoingWatchProjection.unified(
            games: goingVenueGameItems,
            spots: goingVenueSavedVenuesForDisplay
        )
    }

    private var goingWatchVisibleItems: [GoingWatchItem] {
        GoingWatchProjection.filtered(goingWatchUnifiedItems, filter: selectedGoingWatchFilter)
    }

    private var goingWatchFilterCounts: GoingWatchProjection.FilterCounts {
        GoingWatchProjection.filterCounts(goingWatchUnifiedItems)
    }

    private var goingWatchEmptyButtonTitle: String {
        switch selectedGoingWatchFilter {
        case .favoriteSpots:
            return L10n.t("explore_watch_spots", languageCode: goingWatchLanguageCode)
        default:
            if goingDayScope == .today {
                return L10n.t("show_all", languageCode: goingWatchLanguageCode)
            }
            return L10n.t("explore_discover", languageCode: goingWatchLanguageCode)
        }
    }

    private var goingWatchEmptyButtonAction: () -> Void {
        {
            switch selectedGoingWatchFilter {
            case .favoriteSpots:
                openDiscoverWatchSpotsFromGoing()
            default:
                if goingDayScope == .today {
                    goingDayScope = .all
                } else {
                    openDiscoverFromGoing()
                }
            }
        }
    }

    private var goingWatchFilterRow: some View {
        let counts = goingWatchFilterCounts
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: GoingWatchFilterChipMetrics.rowSpacing) {
                goingWatchFilterChips(counts: counts)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: GoingWatchFilterChipMetrics.rowSpacing) {
                    goingWatchFilterChips(counts: counts)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func goingWatchFilterChips(
        counts: GoingWatchProjection.FilterCounts
    ) -> some View {
        ForEach(GoingWatchFilter.allCases, id: \.self) { filter in
            GoingWatchFilterChip(
                filter: filter,
                count: goingWatchChipCount(for: filter, counts: counts),
                selected: selectedGoingWatchFilter == filter,
                languageCode: goingWatchLanguageCode,
                colorScheme: followingColorScheme
            ) {
                selectedGoingWatchFilter = filter
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func goingWatchChipCount(
        for filter: GoingWatchFilter,
        counts: GoingWatchProjection.FilterCounts
    ) -> Int {
        switch filter {
        case .all: return counts.all
        case .games: return counts.games
        case .favoriteSpots: return counts.favoriteSpots
        }
    }

    private var goingWatchUnifiedListContent: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(goingWatchVisibleItems) { item in
                switch item.source {
                case .game:
                    if let game = item.game {
                        goingPlanCard(game, isCompleted: watchingVenueGameIsCompleted(game))
                    }
                case .favoriteSpot:
                    if let spot = item.spot {
                        venueCard(spot)
                    }
                }
            }
        }
    }

    private var goingGamesTabsGroup: some View {
        VStack(alignment: .leading, spacing: 14) {
            goingPlayCreateAndFilterRow

            if goingDayScope == .today {
                goingTodayScopeBanner
            }

            if !viewModel.canFanUsePickupGamesUI {
                emptyCard(
                    icon: "figure.run",
                    title: L10n.t("Games unavailable", languageCode: goingPlayLanguageCode),
                    subtitle: L10n.t("Switch to a fan account to join and play games.", languageCode: goingPlayLanguageCode)
                )
            } else if shouldShowGoingPlayLoadingState {
                pickupSubtabLoadingCard(message: L10n.t("Loading games…", languageCode: goingPlayLanguageCode))
            } else if goingPlayVisibleItems.isEmpty {
                goingRichEmptyCard(
                    title: L10n.t(
                        GoingPlayProjection.emptyTitleKey(for: selectedGoingPlayFilter),
                        languageCode: goingPlayLanguageCode
                    ),
                    description: L10n.t(
                        GoingPlayProjection.emptySupportingKey(for: selectedGoingPlayFilter),
                        languageCode: goingPlayLanguageCode
                    ),
                    buttonTitle: goingPlayEmptyButtonTitle,
                    buttonAction: goingPlayEmptyButtonAction,
                    buttonAccent: FGColor.intentPlay
                )
            } else {
                goingPlayUnifiedListContent
            }

            if selectedGoingPlayFilter == .hosting,
               !viewModel.myRemovedPickupGamesForSettings.isEmpty {
                goingPlayHostingHistorySection
            }
        }
        .onAppear {
            pendingPlayingActivityAcknowledgement = true
            acknowledgePlayingPickupActivityIfReady(reason: "playAppear")
            Task { await loadGoingPlayRootAfterAppear() }
        }
        .onChange(of: shouldShowGoingPlayLoadingState) { _, isLoading in
            guard !isLoading else { return }
            acknowledgePlayingPickupActivityIfReady(reason: "playLoadReady")
        }
        .onChange(of: viewModel.isPickupFollowingJoinListRefreshing) { _, refreshing in
            guard !refreshing else { return }
            acknowledgePlayingPickupActivityIfReady(reason: "playRefreshSettled")
        }
        .onChange(of: viewModel.goingPlayTeamParticipations.count) { _, _ in
            rebuildFollowingDisplayCaches(reason: "goingPlayTeamParticipationsChanged", prefetchAvatars: false)
        }
        .onChange(of: viewModel.pickupDiscoverTeamIdentityByGameId.count) { _, _ in
            rebuildFollowingDisplayCaches(reason: "goingPlayTeamIdentitiesChanged", prefetchAvatars: false)
        }
        .onDisappear {
            pendingPlayingActivityAcknowledgement = false
            goingPlayFilterMenuOpen = false
        }
    }

    private var goingPlayCreateAndFilterRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                openCreatePickupFromGoing()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .accessibilityHidden(true)
                    Text(L10n.t("Create Game", languageCode: goingPlayLanguageCode))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(FGColor.accentGreen, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canFanUsePickupGamesUI)
            .opacity(viewModel.canFanUsePickupGamesUI ? 1 : 0.55)
            .accessibilityLabel(L10n.t("Create Game", languageCode: goingPlayLanguageCode))

            Spacer(minLength: 8)

            goingPlayFilterButton
        }
        .overlay(alignment: .topTrailing) {
            if goingPlayFilterMenuOpen {
                goingPlayFilterMenu
                    .padding(.top, 44)
                    .zIndex(20)
            }
        }
        .zIndex(goingPlayFilterMenuOpen ? 20 : 0)
    }

    private var goingPlayFilterButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                goingPlayFilterMenuOpen.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityHidden(true)
                Text(L10n.t("going_play_filter", languageCode: goingPlayLanguageCode))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(goingPlayFilterMenuOpen ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(FGColor.primaryText(followingColorScheme))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.systemBackground).opacity(followingColorScheme == .dark ? 0.55 : 1))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(FGColor.divider(followingColorScheme).opacity(0.85), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(
                format: L10n.t("going_play_filter_a11y_format", languageCode: goingPlayLanguageCode),
                locale: Locale(identifier: goingPlayLanguageCode.replacingOccurrences(of: "-", with: "_")),
                L10n.t(selectedGoingPlayFilter.titleKey, languageCode: goingPlayLanguageCode)
            )
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(L10n.t(selectedGoingPlayFilter.titleKey, languageCode: goingPlayLanguageCode))
    }

    private var goingPlayFilterMenu: some View {
        let counts = goingPlayFilterCounts
        return VStack(alignment: .leading, spacing: 2) {
            goingPlayFilterMenuRow(.all, count: counts.all)
            goingPlayFilterMenuRow(.hosting, count: counts.hosting)
            goingPlayFilterMenuRow(.invites, count: counts.invites)
            Divider()
                .padding(.vertical, 6)
            goingPlayFilterMenuRow(.pickups, count: counts.pickups)
            goingPlayFilterMenuRow(.teamEvents, count: counts.teamEvents)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .frame(width: 226, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(followingColorScheme == .dark ? 0.35 : 0.14), radius: 16, y: 6)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(FGColor.divider(followingColorScheme).opacity(0.55), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func goingPlayFilterMenuRow(_ filter: GoingPlayFilter, count: Int) -> some View {
        let selected = selectedGoingPlayFilter == filter
        let title = L10n.t(filter.titleKey, languageCode: goingPlayLanguageCode)
        let tint: Color = {
            switch filter {
            case .all: return FGColor.intentPlay
            case .hosting: return FGColor.accentGreen
            case .invites: return FGColor.intentTeams
            case .pickups: return FGColor.accentGreen
            case .teamEvents: return FGColor.intentTeams
            }
        }()
        return Button {
            selectedGoingPlayFilter = filter
            withAnimation(.easeInOut(duration: 0.16)) {
                goingPlayFilterMenuOpen = false
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: filter.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 15, weight: selected ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(followingColorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Text(GoingPlayProjection.compactCountBadge(count))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(filter == .all ? .white : FGColor.secondaryText(followingColorScheme))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(filter == .all ? FGColor.intentPlay : Color.gray.opacity(followingColorScheme == .dark ? 0.28 : 0.12))
                    )
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(minHeight: 54)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? tint.opacity(followingColorScheme == .dark ? 0.16 : 0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var goingProGamesGroup: some View {
        Group {
            if isBusinessProGamesOnly {
                goingTabbedPanel(showsDivider: true) {
                    businessProGamesFilterControl
                } content: {
                    VStack(alignment: .leading, spacing: 10) {
                        goingProGamesUpdatingStatusBanner
                        savedProGamesContent
                    }
                    .animation(.easeInOut(duration: 0.2), value: goingTabPerf.proGamesStatusIndicatorVisible)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    goingProGamesUpdatingStatusBanner
                    savedProGamesContent
                }
                .animation(.easeInOut(duration: 0.2), value: goingTabPerf.proGamesStatusIndicatorVisible)
            }
        }
    }

    private var goingProGamesBackgroundWorkActive: Bool {
        guard activeGoingMode == .proGames else { return false }
        return goingTabPerf.backgroundRefreshInFlight || goingTabPerf.proGamesDisplayRebuildInFlight
    }

    private var goingProGamesStatusIndicatorMessage: String {
        goingTabPerf.backgroundRefreshInFlight
            ? "Refreshing schedule…"
            : "Updating games…"
    }

    private func syncGoingProGamesStatusIndicator() {
        if goingProGamesBackgroundWorkActive {
            guard goingTabPerf.proGamesStatusIndicatorShowTask == nil else { return }
            goingTabPerf.proGamesStatusIndicatorShowTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: GoingTabPerfState.proGamesStatusIndicatorMinVisibleDelayNs)
                guard !Task.isCancelled else { return }
                guard goingProGamesBackgroundWorkActive else {
                    goingTabPerf.proGamesStatusIndicatorShowTask = nil
                    return
                }
                goingTabPerf.proGamesStatusIndicatorVisible = true
                goingTabPerf.proGamesStatusIndicatorShowTask = nil
            }
        } else {
            goingTabPerf.proGamesStatusIndicatorShowTask?.cancel()
            goingTabPerf.proGamesStatusIndicatorShowTask = nil
            goingTabPerf.proGamesStatusIndicatorVisible = false
        }
    }

    @ViewBuilder
    private var goingProGamesUpdatingStatusBanner: some View {
        if goingTabPerf.proGamesStatusIndicatorVisible {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(goingProGamesStatusIndicatorMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(goingProGamesStatusIndicatorMessage)
        }
    }

    @ViewBuilder
    private var savedProGamesContent: some View {
        if isBusinessProGamesOnly {
            businessProGamesContent
        } else {
            fanSavedProGamesContent
        }
    }

    private var fanSavedProGamesContent: some View {
        let languageCode = goingProLanguageCode
        let counts = goingProFilterCounts
        let feed = goingProUnifiedFeedItems
        return VStack(alignment: .leading, spacing: 14) {
            goingProFavoriteTeamsCard

            Text(L10n.t("going_play_upcoming", languageCode: languageCode))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.mutedText(followingColorScheme))
                .textCase(.uppercase)
                .tracking(0.6)
                .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    GoingProFilterChip(
                        filter: .all,
                        count: counts.all,
                        selected: selectedGoingProGamesFilter == .all,
                        languageCode: languageCode,
                        colorScheme: followingColorScheme
                    ) {
                        selectedGoingProGamesFilter = .all
                    }
                    GoingProFilterChip(
                        filter: .saved,
                        count: counts.saved,
                        selected: selectedGoingProGamesFilter == .saved,
                        languageCode: languageCode,
                        colorScheme: followingColorScheme
                    ) {
                        selectedGoingProGamesFilter = .saved
                    }
                    GoingProFilterChip(
                        filter: .favoriteTeams,
                        count: counts.favoriteTeams,
                        selected: selectedGoingProGamesFilter == .favoriteTeams,
                        languageCode: languageCode,
                        colorScheme: followingColorScheme
                    ) {
                        selectedGoingProGamesFilter = .favoriteTeams
                    }
                }
                .padding(.vertical, 1)
            }

            if feed.isEmpty {
                goingRichEmptyCard(
                    title: L10n.t("going_pro_empty_title", languageCode: languageCode),
                    description: L10n.t("going_pro_empty_supporting", languageCode: languageCode),
                    buttonTitle: L10n.t("going_pro_explore", languageCode: languageCode),
                    buttonAction: openCalendarProGamesFromGoing,
                    buttonAccent: FGColor.intentProGames
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(feed) { item in
                        switch item {
                        case .game(let proItem):
                            savedProGameCard(
                                proItem.game,
                                badges: [],
                                showsUnsaveButton: proItem.isSaved,
                                showsScoreUpdatesControl: true,
                                favoriteTeamAlertItem: proItem.isSaved ? nil : proItem.favoriteAlertItem,
                                reasonBadges: goingProReasonKinds(for: proItem),
                                onClearCompleted: {
                                    if let favorite = proItem.favoriteAlertItem, !proItem.isSaved {
                                        clearCompletedFavoriteTeamProGame(favorite.game, scope: "fan")
                                    }
                                }
                            )
                        case .nativeAd(let slot):
                            goingNativeAdRow(slot: slot)
                        }
                    }
                }
            }
        }
        .padding(.top, 4)
        .task(id: goingProUnifiedItems.map(\.id).joined(separator: "|")) {
            guard goingTabPerf.deferredWorkReady || isFollowingTabSelected else { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            GoingPerfDebug.deferredWork("predictionVoteSummaries", source: "fanSavedProGamesContent")
            await viewModel.prefetchProGamePredictionSummaries(for: goingProUnifiedItems.map(\.game))
        }
    }

    private var businessProGamesContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            if selectedBusinessProGameFilter == .all {
                businessSavedProGamesSection
                businessMyTeamsProGamesSection
            } else {
                businessMyTeamsFilteredSection
            }
        }
        .padding(.top, 10)
    }

    private var businessSavedProGamesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            goingProGamesSectionHeader(
                title: L10n.t("Saved Games", languageCode: L10n.normalizedLanguageCode(appLanguageRaw)),
                description: L10n.t("saved_pro_games_description", languageCode: L10n.normalizedLanguageCode(appLanguageRaw))
            )
            goingSavedProGamesCompletedVisibilityNote
            if manualSavedProGamesForDisplay.isEmpty {
                emptyCard(
                    icon: "heart",
                    title: L10n.t("no_saved_pro_sports_games", languageCode: L10n.normalizedLanguageCode(appLanguageRaw)),
                    subtitle: L10n.t("save_pro_sports_games_for_business", languageCode: L10n.normalizedLanguageCode(appLanguageRaw))
                )
            } else {
                VStack(spacing: 12) {
                    ForEach(goingProGamesAdPlan.savedGamesItems) { item in
                        switch item {
                        case .game(let game):
                            savedProGameCard(game, badges: businessSavedProGameBadges(for: game))
                        case .nativeAd(let slot):
                            goingNativeAdRow(slot: slot)
                        }
                    }
                }
            }
        }
    }

    private var businessMyTeamsProGamesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            goingProGamesSectionHeader(
                title: "My Teams",
                description: "Games involving the teams you follow."
            )
            businessMyTeamsProGameList(emptyTitle: "No upcoming pro sports games found for your followed teams.")
        }
    }

    private var businessMyTeamsFilteredSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            goingProGamesSectionHeader(
                title: "My Teams",
                description: "Games involving the teams you follow."
            )
            businessMyTeamsProGameList(emptyTitle: "No My Teams pro sports games match right now.")
        }
    }

    @ViewBuilder
    private func businessMyTeamsProGameList(emptyTitle: String) -> some View {
        if viewModel.businessFavoriteTeamIDs.isEmpty {
            emptyCard(
                icon: "star",
                title: "No business favorite teams yet.",
                subtitle: "Add Favorite Teams from the Business Dashboard to use My Teams."
            )
        } else if businessMyTeamSavedProGamesForDisplay.isEmpty && businessMyTeamProGamesForDisplay.isEmpty {
            emptyCard(
                icon: "star",
                title: emptyTitle,
                subtitle: "Try adding more teams from the Business Dashboard."
            )
        } else {
            VStack(spacing: 12) {
                ForEach(goingProGamesAdPlan.businessMyTeamsItems) { item in
                    switch item {
                    case .savedGame(let game):
                        savedProGameCard(game, badges: businessSavedProGameBadges(for: game))
                    case .autoGame(let autoGame):
                        savedProGameCard(
                            autoGame.game,
                            badges: businessMyTeamProGameBadges(),
                            showsUnsaveButton: false,
                            showsScoreUpdatesControl: true,
                            favoriteTeamAlertItem: autoGame,
                            onClearCompleted: {
                                clearCompletedFavoriteTeamProGame(autoGame.game, scope: "business")
                            }
                        )
                    case .nativeAd(let slot):
                        goingNativeAdRow(slot: slot)
                    }
                }
            }
        }
    }

    private func goingNativeAdRow(slot: GoingNativeAdSlot) -> some View {
        GoingNativeAdCard(
            slot: slot,
            shouldRequestAd: FanGeoAdPolicy.shouldMountAdViews()
                && goingProNativeAdsHostVisible
                && goingTabPerf.deferredWorkReady
        )
    }

    private var businessProGamesFilterControl: some View {
        GameOnSegmentedControl(
            tabs: [
                GameOnSegmentedTab(
                    id: BusinessProGameFilter.all,
                    title: "All",
                    badge: businessAllProGamesBadge,
                    tint: FGColor.accentBlue
                ),
                GameOnSegmentedTab(
                    id: BusinessProGameFilter.myTeams,
                    title: "My Teams",
                    badge: businessMyTeamsProGamesBadge,
                    tint: FGColor.accentBlue
                )
            ],
            selection: $selectedBusinessProGameFilter
        )
    }

    private var manualSavedProGamesForDisplay: [SavedProGame] {
        goingTabPerf.cachedManualSavedProGamesForDisplay
    }

    private var favoriteTeamProGamesForDisplay: [FavoriteTeamProGame] {
        goingTabPerf.cachedFavoriteTeamProGamesForDisplay
    }

    private var goingProLanguageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var goingProUnifiedItems: [GoingProGameItem] {
        GoingProGamesProjection.unified(
            saved: manualSavedProGamesForDisplay,
            favorite: favoriteTeamProGamesForDisplay
        )
    }

    private var goingProVisibleItems: [GoingProGameItem] {
        GoingProGamesProjection.filtered(goingProUnifiedItems, filter: selectedGoingProGamesFilter)
    }

    private var goingProFilterCounts: GoingProGamesProjection.FilterCounts {
        GoingProGamesProjection.filterCounts(goingProUnifiedItems)
    }

    private var goingProUnifiedFeedItems: [GoingUnifiedProGameFeedItem] {
        GoingProGamesAdPlacement.unifiedFeedItems(games: goingProVisibleItems)
    }

    private func goingProReasonKinds(for item: GoingProGameItem) -> [GoingProReasonBadge.Kind] {
        var kinds: [GoingProReasonBadge.Kind] = []
        if item.isSaved { kinds.append(.saved) }
        if item.involvesFavoriteTeam { kinds.append(.favoriteTeam) }
        return kinds
    }

    private var goingProFavoriteTeamsCard: some View {
        let teams = resolvedFavoriteTeamsForGoing
        let languageCode = goingProLanguageCode
        let hasTeams = !teams.isEmpty
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.t("Favorite Teams", languageCode: languageCode))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(followingColorScheme))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button {
                    showFavoriteTeamsPicker = true
                } label: {
                    Text(L10n.t("going_favorite_teams_edit", languageCode: languageCode))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.accentBlue)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("going_favorite_teams_edit_a11y", languageCode: languageCode))
            }

            if hasTeams {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(teams) { team in
                            GoingProFavoriteTeamMark(
                                team: team,
                                languageCode: languageCode,
                                colorScheme: followingColorScheme
                            )
                        }
                        goingProAddFavoriteTeamControl
                    }
                    .padding(.vertical, 2)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.t("going_pro_no_favorites", languageCode: languageCode))
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                    goingProEmptyFavoritesAddButton
                }
            }

            Divider()
                .opacity(0.55)

            favoriteTeamAlertsToggleRow
                .disabled(!hasTeams)
                .opacity(hasTeams ? 1 : 0.55)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground).opacity(followingColorScheme == .dark ? 0.55 : 0.96))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(FGColor.divider(followingColorScheme).opacity(0.45), lineWidth: 1)
        }
    }

    private var goingProAddFavoriteTeamControl: some View {
        Button {
            showFavoriteTeamsPicker = true
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color.gray.opacity(followingColorScheme == .dark ? 0.28 : 0.12))
                        .frame(
                            width: SportsIdentityArtworkMetrics.favoriteSlot,
                            height: SportsIdentityArtworkMetrics.favoriteSlot
                        )
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                }
                Text(L10n.t("Add", languageCode: goingProLanguageCode))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(followingColorScheme))
            }
            .frame(width: 72)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("going_pro_add_a11y", languageCode: goingProLanguageCode))
    }

    private var goingProEmptyFavoritesAddButton: some View {
        Button {
            showFavoriteTeamsPicker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                Text(L10n.t("Add Team", languageCode: goingProLanguageCode))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(FGColor.accentBlue)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(FGColor.accentBlue.opacity(followingColorScheme == .dark ? 0.18 : 0.10))
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(FGColor.accentBlue.opacity(0.35), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("going_pro_add_a11y", languageCode: goingProLanguageCode))
    }

    private var resolvedFavoriteTeamsForGoing: [FavoriteTeam] {
        FavoriteTeamsStore.resolvedTeams(from: favoriteTeamIDsRaw)
    }

    private func markGoingScreenAppear(source: String) {
        goingTabPerf.screenAppearAt = CFAbsoluteTimeGetCurrent()
        GoingPerfDebug.screenAppear(source: source)
    }

    private func prepareGoingTabVisibleSurface(reason: String) async {
        guard isFollowingTabSelected else {
            DebugLogGate.goingTabPerfVerbose("[GoingTabPerf] deferredTaskCanceled reason=prepareNotSelected")
            return
        }
        if goingTabPerf.screenAppearAt == nil {
            markGoingScreenAppear(source: reason)
        }
        viewModel.seedSportsArtworkFromFetchedLiveMatches()
        await Task.yield()
        guard isFollowingTabSelected else {
            DebugLogGate.goingTabPerfVerbose("[GoingTabPerf] deferredTaskCanceled reason=prepareLeftMidYield")
            return
        }
        let started = CFAbsoluteTimeGetCurrent()
        if viewModel.savedProGames.isEmpty, let userID = viewModel.currentUserAuthId {
            viewModel.reloadSavedProGamesFromStorage(for: userID)
        }
        rebuildFollowingDisplayCaches(reason: reason, prefetchAvatars: false)
        if goingTabShouldSkipProGamesDisplayRebuild(fingerprint: goingProGamesDisplayFingerprint()) {
            DebugLogGate.goingTabPerfVerbose(
                "[GoingProPerf] displayRebuildSkipped reason=fingerprintUnchanged"
            )
        } else {
            await rebuildGoingProGamesDisplayCaches(reason: reason)
        }
        guard isFollowingTabSelected else {
            DebugLogGate.goingTabPerfVerbose("[GoingTabPerf] deferredTaskCanceled reason=prepareLeftBeforePublish")
            return
        }
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        AppPerfDebug.mainActorBlocked(ms: ms, tab: "following", source: "prepareGoingTabVisibleSurface")
        DebugLogGate.goingTabPerfVerbose(
            "[TabRenderPerf] tab=going visible=true renderMs=\(String(format: "%.2f", ms)) reason=\(reason)"
        )
        recordGoingFirstPaintIfNeeded(source: reason, proPaintSource: nil)
        goingTabPerf.deferredWorkReady = true
        goingTabPerf.lastVisibleSurfacePrepareAt = Date()
        goingTabPerf.lastVisibleSurfacePrepareFingerprint = goingTabVisibleSurfaceDataFingerprint()
    }

    private func recordGoingFirstPaintIfNeeded(source: String, proPaintSource: String? = nil) {
        guard !goingTabPerf.firstPaintRecorded else { return }
        goingTabPerf.firstPaintRecorded = true
        let elapsedMs = Int(((goingTabPerf.screenAppearAt.map { CFAbsoluteTimeGetCurrent() - $0 } ?? 0) * 1000).rounded())
        let usedCachedData =
            !viewModel.savedProGames.isEmpty
            || !viewModel.favoriteTeamProGames.isEmpty
            || !viewModel.followingTabGoingItems.isEmpty
            || !viewModel.myPickupGameJoinRequestCards.isEmpty
        let paintSource = proPaintSource ?? (
            !goingTabPerf.cachedManualSavedProGamesForDisplay.isEmpty
                || !goingTabPerf.cachedFavoriteTeamProGamesForDisplay.isEmpty
                ? "displayCache" : (usedCachedData ? "viewModel" : "none")
        )
        let cached = paintSource != "none"
        DebugLogGate.goingTabPerfVerbose(
            "[GoingProPerf] firstPaint cached=\(cached) source=\(paintSource)"
        )
        GoingPerfDebug.firstPaint(
            ms: max(0, elapsedMs),
            usedCachedData: usedCachedData,
            savedGamesCount: viewModel.savedProGames.count,
            favoriteTeamGamesCount: viewModel.favoriteTeamProGames.count,
            source: source
        )
    }

    private func performGoingTabBackgroundRefresh(reason: String, selectionGeneration: UInt64) async {
        guard viewModel.isAuthenticatedForSocialFeatures else { return }
        guard isGoingTabSelectionGenerationCurrent(selectionGeneration) else {
            DebugLogGate.goingTabPerfVerbose("[GoingTabPerf] deferredTaskCanceled reason=backgroundStaleGeneration")
            return
        }
        if goingTabPerf.backgroundRefreshInFlight {
            TabPerf.duplicateRefreshCoalesced(name: "goingTabBackgroundRefresh")
            GoingPerfDebug.duplicateRefreshSkipped(source: reason, reason: "inFlight")
            return
        }
        goingTabPerf.backgroundRefreshInFlight = true
        syncGoingProGamesStatusIndicator()
        defer {
            goingTabPerf.backgroundRefreshInFlight = false
            syncGoingProGamesStatusIndicator()
        }

        let startedAt = Date()
        GoingPerfDebug.refreshStarted(source: reason)
        defer {
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            DebugLogGate.goingTabPerfVerbose(
                "[GoingProPerf] backgroundWorkFinished durationMs=\(ms)"
            )
            GoingPerfDebug.refreshFinished(source: reason, durationMs: ms)
            if isGoingTabSelectionGenerationCurrent(selectionGeneration) {
                Task { await rebuildGoingProGamesDisplayCaches(reason: "refreshFinished:\(reason)") }
            }
        }

        if isBusinessProGamesOnly {
            await reloadBusinessProGamesData(reason: reason)
            return
        }

        guard viewModel.canUseFollowingTab else { return }
        guard isGoingTabSelectionGenerationCurrent(selectionGeneration) else {
            DebugLogGate.goingTabPerfVerbose("[GoingTabPerf] deferredTaskCanceled reason=backgroundLeftEarly")
            return
        }

        if goingProDataRecentlyWarmedFromScheduleOrCalendar() {
            DebugLogGate.goingTabPerfVerbose(
                "[GoingProPerf] refreshSkipped reason=calendarRecentlyRefreshed"
            )
            await scheduleDeferredGoingTabWork(
                reason: reason,
                deferFavoriteTeamRefresh: true,
                selectionGeneration: selectionGeneration
            )
            return
        }

        if viewModel.didCompleteTabIntentPreloadRecently("following", within: 12) {
            AppPerfDebug.refreshSkipped(tab: "following", source: reason, reason: "tabPreloadRecent")
            GoingPerfDebug.duplicateRefreshSkipped(source: reason, reason: "tabPreloadRecent")
            await viewModel.fetchSavedProGames(reason: "goingDeferred:\(reason)")
            await scheduleDeferredGoingTabWork(
                reason: reason,
                deferFavoriteTeamRefresh: true,
                selectionGeneration: selectionGeneration
            )
            return
        }

        if viewModel.isTabIntentPreloadInFlight("following") {
            while viewModel.isTabIntentPreloadInFlight("following") {
                await Task.yield()
                try? await Task.sleep(nanoseconds: 40_000_000)
                if Task.isCancelled { return }
                if !isGoingTabSelectionGenerationCurrent(selectionGeneration) { return }
            }
            GoingPerfDebug.duplicateRefreshSkipped(source: reason, reason: "awaitedTabPreload")
            if goingProDataRecentlyWarmedFromScheduleOrCalendar() {
                DebugLogGate.goingTabPerfVerbose(
                    "[GoingProPerf] refreshSkipped reason=calendarRecentlyRefreshed"
                )
                await scheduleDeferredGoingTabWork(
                    reason: reason,
                    deferFavoriteTeamRefresh: true,
                    selectionGeneration: selectionGeneration
                )
                return
            }
            await viewModel.fetchSavedProGames(reason: "goingDeferred:\(reason)")
            await scheduleDeferredGoingTabWork(
                reason: reason,
                deferFavoriteTeamRefresh: true,
                selectionGeneration: selectionGeneration
            )
            return
        }

        await viewModel.refreshFollowingTabDataGloballyUnlessFresh()
        guard isGoingTabSelectionGenerationCurrent(selectionGeneration) else {
            DebugLogGate.goingTabPerfVerbose("[GoingTabPerf] deferredTaskCanceled reason=backgroundLeftAfterGlobal")
            return
        }
        rebuildFollowingDisplayCaches(reason: "backgroundRefresh:\(reason)", prefetchAvatars: false)
        await viewModel.fetchSavedProGames(reason: "goingBackground:\(reason)")
        await viewModel.loadMyPickupGameJoinRequestsForFollowing(reason: reason)
        await viewModel.loadIncomingPickupGameInvites()
        await scheduleDeferredGoingTabWork(
            reason: reason,
            deferFavoriteTeamRefresh: false,
            selectionGeneration: selectionGeneration
        )
    }

    private func scheduleDeferredGoingTabWork(
        reason: String,
        deferFavoriteTeamRefresh: Bool,
        selectionGeneration: UInt64
    ) async {
        guard isGoingTabSelectionGenerationCurrent(selectionGeneration) else {
            DebugLogGate.goingTabPerfVerbose("[GoingTabPerf] deferredTaskCanceled reason=deferredWorkStale")
            return
        }
        let hasCachedFavorite =
            !viewModel.favoriteTeamProGames.isEmpty
            || !goingTabPerf.cachedFavoriteTeamProGamesForDisplay.isEmpty
        let shouldDeferFavorite = deferFavoriteTeamRefresh || hasCachedFavorite
        if shouldDeferFavorite {
            let delayMs = Int.random(
                in: GoingTabPerfState.favoriteTeamRefreshDeferMinMs...GoingTabPerfState.favoriteTeamRefreshDeferMaxMs
            )
            DebugLogGate.goingTabPerfVerbose(
                "[GoingProPerf] favoriteTeamRefreshDeferred delayMs=\(delayMs)"
            )
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            guard isGoingTabSelectionGenerationCurrent(selectionGeneration) else {
                DebugLogGate.goingTabPerfVerbose("[GoingTabPerf] deferredTaskCanceled reason=leftDuringFavoriteDefer")
                return
            }
        }
        GoingPerfDebug.deferredWork("favoriteTeamProGamesRefresh", source: reason)
        await refreshFavoriteTeamProGames(reason: reason)
        guard isGoingTabSelectionGenerationCurrent(selectionGeneration) else {
            DebugLogGate.goingTabPerfVerbose("[GoingTabPerf] deferredTaskCanceled reason=leftBeforeAvatarPrefetch")
            return
        }
        rebuildFollowingDisplayCaches(reason: "deferred:\(reason)", prefetchAvatars: false)
        GoingPerfDebug.deferredWork("goingAvatarPrefetch", source: reason)
        prefetchVisibleGoingAvatars(reason: "deferred:\(reason)")
    }

    private func scheduleDeferredFavoriteTeamProGamesRefresh(reason: String) async {
        let hasCached =
            !viewModel.favoriteTeamProGames.isEmpty
            || !goingTabPerf.cachedFavoriteTeamProGamesForDisplay.isEmpty
        if hasCached {
            let delayMs = Int.random(
                in: GoingTabPerfState.favoriteTeamRefreshDeferMinMs...GoingTabPerfState.favoriteTeamRefreshDeferMaxMs
            )
            DebugLogGate.goingTabPerfVerbose(
                "[GoingProPerf] favoriteTeamRefreshDeferred delayMs=\(delayMs)"
            )
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            guard !Task.isCancelled else { return }
        }
        await refreshFavoriteTeamProGames(reason: reason)
    }

    private func scheduleDeferredBusinessFavoriteTeamProGamesRefresh(reason: String) async {
        let hasCached = !viewModel.businessFavoriteTeamProGames.isEmpty
        if hasCached {
            let delayMs = Int.random(
                in: GoingTabPerfState.favoriteTeamRefreshDeferMinMs...GoingTabPerfState.favoriteTeamRefreshDeferMaxMs
            )
            DebugLogGate.goingTabPerfVerbose(
                "[GoingProPerf] favoriteTeamRefreshDeferred delayMs=\(delayMs)"
            )
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            guard !Task.isCancelled else { return }
        }
        await refreshBusinessFavoriteTeamProGames(reason: reason)
    }

    private func scheduleGoingProGamesDisplayCacheRebuild(reason: String) {
        let fingerprint = goingProGamesDisplayFingerprint()
        if goingTabShouldSkipProGamesDisplayRebuild(fingerprint: fingerprint) {
            DebugLogGate.goingTabPerfVerbose(
                "[GoingProPerf] displayRebuildSkipped reason=fingerprintUnchanged"
            )
            return
        }
        if goingTabRecentlyRebuiltProGamesDisplay(within: GoingTabPerfState.proGamesDisplayRebuildTTL) {
            return
        }
        if goingTabPerf.proGamesDisplayRebuildTask != nil {
            return
        }
        goingTabPerf.proGamesDisplayRebuildTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: GoingTabPerfState.deferredBackgroundRefreshDelayNs)
            guard !Task.isCancelled else { return }
            await rebuildGoingProGamesDisplayCaches(reason: reason)
            goingTabPerf.proGamesDisplayRebuildTask = nil
        }
    }

    private func goingTabRecentlyRebuiltProGamesDisplay(within interval: TimeInterval) -> Bool {
        guard let last = goingTabPerf.lastProGamesDisplayRebuildAt else { return false }
        return Date().timeIntervalSince(last) < interval
    }

    private func rebuildGoingProGamesDisplayCachesSynchronously(reason: String, force: Bool = false) {
        let fingerprint = goingProGamesDisplayFingerprint()
        if !force, goingTabShouldSkipProGamesDisplayRebuild(fingerprint: fingerprint) {
            DebugLogGate.goingTabPerfVerbose(
                "[GoingProPerf] displayRebuildSkipped reason=fingerprintUnchanged"
            )
            return
        }

        let snapshots = viewModel.savedProGames
            .map { viewModel.currentSavedProGameSnapshot($0) }
            .filter { GoingTabCompletedGameVisibility.isProGameVisibleInGoingTab($0) }
        let filteredFavorites = viewModel.favoriteTeamProGames
            .map(currentFavoriteTeamProGameSnapshot)
            .filter { !isCompletedFavoriteTeamProGameCleared($0.game, scope: "fan") }
            .filter { GoingTabCompletedGameVisibility.isProGameVisibleInGoingTab($0.game) }

        goingTabPerf.cachedManualSavedProGamesForDisplay = snapshots.sorted(by: SavedProGame.displaySort)
        goingTabPerf.cachedFavoriteTeamProGamesForDisplay = filteredFavorites.sorted {
            SavedProGame.displaySort($0.game, $1.game)
        }
        goingTabPerf.lastProGamesDisplayFingerprint = fingerprint
        goingTabPerf.lastProGamesDisplayRebuildAt = Date()
#if DEBUG
        print("[GoingPerfDebug] rebuildProGamesDisplayCachesSync reason=\(reason) saved=\(goingTabPerf.cachedManualSavedProGamesForDisplay.count) favorite=\(goingTabPerf.cachedFavoriteTeamProGamesForDisplay.count)")
#endif
    }

    private func applyImmediateGoingProDisplayCacheAfterClear(reason: String) {
        rebuildGoingProGamesDisplayCachesSynchronously(reason: reason, force: true)
    }

    private func rebuildGoingProGamesDisplayCaches(reason: String) async {
        let fingerprint = goingProGamesDisplayFingerprint()
        if goingTabShouldSkipProGamesDisplayRebuild(fingerprint: fingerprint) {
            DebugLogGate.goingTabPerfVerbose(
                "[GoingProPerf] displayRebuildSkipped reason=fingerprintUnchanged"
            )
            return
        }

        goingTabPerf.proGamesDisplayRebuildInFlight = true
        syncGoingProGamesStatusIndicator()
        defer {
            goingTabPerf.proGamesDisplayRebuildInFlight = false
            syncGoingProGamesStatusIndicator()
        }
        let snapshots = viewModel.savedProGames
            .map { viewModel.currentSavedProGameSnapshot($0) }
            .filter { GoingTabCompletedGameVisibility.isProGameVisibleInGoingTab($0) }
        let filteredFavorites = viewModel.favoriteTeamProGames
            .map(currentFavoriteTeamProGameSnapshot)
            .filter { !isCompletedFavoriteTeamProGameCleared($0.game, scope: "fan") }
            .filter { GoingTabCompletedGameVisibility.isProGameVisibleInGoingTab($0.game) }

        let sortedManual: [SavedProGame]
        let sortedFavorites: [FavoriteTeamProGame]
        if snapshots.count + filteredFavorites.count > 12 {
            sortedManual = await Task.detached(priority: .utility) {
                snapshots.sorted(by: SavedProGame.displaySort)
            }.value
            sortedFavorites = await Task.detached(priority: .utility) {
                filteredFavorites.sorted { SavedProGame.displaySort($0.game, $1.game) }
            }.value
        } else {
            sortedManual = snapshots.sorted(by: SavedProGame.displaySort)
            sortedFavorites = filteredFavorites.sorted { SavedProGame.displaySort($0.game, $1.game) }
        }

        goingTabPerf.cachedManualSavedProGamesForDisplay = sortedManual
        goingTabPerf.cachedFavoriteTeamProGamesForDisplay = sortedFavorites
        goingTabPerf.lastProGamesDisplayFingerprint = fingerprint
        goingTabPerf.lastProGamesDisplayRebuildAt = Date()
#if DEBUG
        print("[GoingPerfDebug] rebuildProGamesDisplayCaches reason=\(reason) saved=\(sortedManual.count) favorite=\(sortedFavorites.count)")
#endif
    }

    private var businessFavoriteTeamsForDisplay: [FavoriteTeam] {
        FavoriteTeamsStore.resolvedTeams(fromIDs: Array(viewModel.businessFavoriteTeamIDs).sorted())
    }

    private var businessMyTeamSavedProGamesForDisplay: [SavedProGame] {
        manualSavedProGamesForDisplay.filter { game in
            businessFavoriteTeamsForDisplay.contains { team in
                FavoriteTeamLiveMatcher.matchesLiveMatch(team, homeTeam: game.homeTeam, awayTeam: game.awayTeam)
            }
        }
    }

    private var businessMyTeamProGamesForDisplay: [FavoriteTeamProGame] {
        let manualKeys = Set(manualSavedProGamesForDisplay.map(\.stableKey))
        return viewModel.businessFavoriteTeamProGames
            .map(currentFavoriteTeamProGameSnapshot)
            .filter { !manualKeys.contains($0.game.stableKey) }
            .filter { !isCompletedFavoriteTeamProGameCleared($0.game, scope: "business") }
            .filter { GoingTabCompletedGameVisibility.isProGameVisibleInGoingTab($0.game) }
            .sorted { SavedProGame.displaySort($0.game, $1.game) }
    }

    private var goingPickupHostingGamesForDisplay: [PickupGameRow] {
        viewModel.myPickupGamesForSettings.filter {
            GoingTabCompletedGameVisibility.isPickupGameVisibleInGoingTab(
                row: $0,
                now: followingMyPickupClockTick
            )
        }.filter { row in
            guard goingDayScope == .today else { return true }
            return isPickupStartOnLocalToday(row.game_start_at, now: followingMyPickupClockTick)
        }
    }

    private func currentFavoriteTeamProGameSnapshot(_ item: FavoriteTeamProGame) -> FavoriteTeamProGame {
        FavoriteTeamProGame(
            game: viewModel.currentSavedProGameSnapshot(item.game),
            favoriteTeamID: item.favoriteTeamID,
            favoriteTeamName: item.favoriteTeamName
        )
    }

    private var businessAllProGamesBadge: String? {
        liveSubTabBadgeCount(manualSavedProGamesForDisplay.count + businessMyTeamProGamesForDisplay.count)
    }

    private var businessMyTeamsProGamesBadge: String? {
        liveSubTabBadgeCount(
            businessMyTeamSavedProGamesForDisplay.count + businessMyTeamProGamesForDisplay.count
        )
    }

    private func favoriteTeamAutoFollowMatch(for game: SavedProGame) -> FavoriteTeamProGame? {
        viewModel.favoriteTeamProGames.first { $0.game.stableKey == game.stableKey }
    }

    private func businessFavoriteTeamMatch(for game: SavedProGame) -> FavoriteTeamProGame? {
        viewModel.businessFavoriteTeamProGames.first { $0.game.stableKey == game.stableKey }
    }

    private func savedProGameBadges(for game: SavedProGame) -> [String] {
        var badges: [String] = []
        if favoriteTeamAutoFollowMatch(for: game) != nil {
            badges.append("Favorite Team")
        }
        return badges
    }

    private func favoriteTeamProGameBadges() -> [String] {
        ["Favorite Team"]
    }

    private func businessSavedProGameBadges(for game: SavedProGame) -> [String] {
        var badges: [String] = []
        if businessFavoriteTeamMatch(for: game) != nil || businessMyTeamSavedProGamesForDisplay.contains(where: { $0.stableKey == game.stableKey }) {
            badges.append("My Teams")
        }
        return badges
    }

    private func businessMyTeamProGameBadges() -> [String] {
        ["My Teams"]
    }

    private var goingSavedProGamesShowsCompletedVisibilityNote: Bool {
        manualSavedProGamesForDisplay.contains(where: \.isFinal)
    }

    @ViewBuilder
    private var goingSavedProGamesCompletedVisibilityNote: some View {
        if goingSavedProGamesShowsCompletedVisibilityNote {
            Text("ⓘ Completed games remain visible for 48 hours after they finish.")
                .font(.footnote)
                .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
                .padding(.top, 2)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isStaticText)
        }
    }

    /// Large section titles inside Business Pro Games (Saved Games / My Teams).
    private func goingProGamesSectionHeader(title: String, description: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(FGColor.primaryText(followingColorScheme))
                .accessibilityAddTraits(.isHeader)

            if let description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var favoriteTeamAlertsToggleRow: some View {
        Toggle(isOn: favoriteTeamAlertsBinding) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FGColor.accentBlue)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("Team Alerts", languageCode: goingProLanguageCode))
                        .font(FGTypography.caption.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(followingColorScheme))
                    Text(L10n.t("going_pro_team_alerts_subtitle", languageCode: goingProLanguageCode))
                        .font(FGTypography.metadata)
                        .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
        .tint(FGColor.accentBlue)
        .accessibilityLabel(L10n.t("Team Alerts", languageCode: goingProLanguageCode))
        .accessibilityValue(
            favoriteTeamProGameAlertsEnabled
                ? L10n.t("On", languageCode: goingProLanguageCode)
                : L10n.t("Off", languageCode: goingProLanguageCode)
        )
    }

    private var favoriteTeamAlertsBinding: Binding<Bool> {
        Binding(
            get: { favoriteTeamProGameAlertsEnabled },
            set: { enabled in
                Task {
                    await viewModel.setFavoriteTeamProGameAlertsEnabled(
                        enabled,
                        games: viewModel.favoriteTeamProGames,
                        reason: "goingProTeamAlertsToggle"
                    )
                    favoriteTeamProGameAlertsEnabled = viewModel.notificationSettingsStore.favoriteTeamProGameAlertsEnabled
                }
            }
        )
    }

    private func refreshFavoriteTeamProGamesIfVisible(reason: String) {
        guard isFollowingTabSelected, activeGoingMode == .proGames else { return }
        if isBusinessProGamesOnly {
            Task {
                await Task.yield()
                await refreshBusinessFavoriteTeamProGames(reason: reason)
            }
        } else {
            Task {
                await Task.yield()
                await refreshFavoriteTeamProGames(reason: reason)
            }
        }
    }

    private func refreshFavoriteTeamProGames(reason: String, forceRefresh: Bool = false) async {
        guard viewModel.isAuthenticatedForSocialFeatures,
              (viewModel.canUseFollowingTab || isBusinessProGamesOnly) else {
            await MainActor.run {
                viewModel.favoriteTeamProGames = []
            }
            return
        }
#if DEBUG
        print("[SavedProGames] favoriteTeamAutoFollowRefresh reason=\(reason)")
#endif
        let window = ProGamesFavoriteTeamAutoFollowPreference.Window.resolved(rawValue: proGamesFavoriteTeamWindowDays)
        await viewModel.refreshFavoriteTeamProGames(
            enabled: favoriteTeamProGameAlertsEnabled,
            windowDays: window.rawValue,
            favoriteTeamIDsRaw: favoriteTeamIDsRaw,
            forceRefresh: forceRefresh
        )
    }

    private func refreshBusinessFavoriteTeamProGames(reason: String, forceRefresh: Bool = false) async {
        guard viewModel.isAuthenticatedForSocialFeatures, isBusinessProGamesOnly else {
            await MainActor.run {
                viewModel.businessFavoriteTeamProGames = []
            }
            return
        }
#if DEBUG
        print("[BusinessFavoriteTeams] proGameRefresh reason=\(reason)")
#endif
        await viewModel.refreshBusinessFavoriteTeamProGames(windowDays: 30, forceRefresh: forceRefresh)
    }

    private var playingGamesContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if goingDayScope == .today {
                goingTodayScopeBanner
            }
            if !viewModel.canFanUsePickupGamesUI {
                emptyCard(
                    icon: "figure.run",
                    title: "Games unavailable",
                    subtitle: "Switch to a fan account to join and play games."
                )
            } else if shouldShowPlayingPickupLoadingState {
                pickupSubtabLoadingCard(message: "Loading games…")
            } else if goingPlayPlayingItems.isEmpty {
                goingRichEmptyCard(
                    title: L10n.t("going_play_empty_playing", languageCode: L10n.normalizedLanguageCode(appLanguageRaw)),
                    description: L10n.t("going_play_empty_playing_supporting", languageCode: L10n.normalizedLanguageCode(appLanguageRaw)),
                    buttonTitle: goingDayScope == .today
                        ? L10n.t("show_all", languageCode: L10n.normalizedLanguageCode(appLanguageRaw))
                        : L10n.t("explore_discover", languageCode: L10n.normalizedLanguageCode(appLanguageRaw)),
                    buttonAction: {
                        if goingDayScope == .today {
                            goingDayScope = .all
                        } else {
                            openDiscoverForPickupGamesFromGoing()
                        }
                    },
                    buttonAccent: FGColor.intentPlay
                )
            } else {
                goingPlayUnifiedListContent
            }
        }
        .padding(.top, 6)
        .onAppear {
            // Entering Playing arms a one-shot ack; later realtime refreshes while staying here do not.
            pendingPlayingActivityAcknowledgement = true
            acknowledgePlayingPickupActivityIfReady(reason: "playingAppear")
            Task { await refreshGoingPlayUnification(reason: "playingAppear") }
        }
        .onChange(of: shouldShowPlayingPickupLoadingState) { _, isLoading in
            guard !isLoading else { return }
            acknowledgePlayingPickupActivityIfReady(reason: "playingLoadReady")
        }
        .onChange(of: viewModel.isPickupFollowingJoinListRefreshing) { _, refreshing in
            guard !refreshing else { return }
            acknowledgePlayingPickupActivityIfReady(reason: "playingRefreshSettled")
        }
        .onDisappear {
            pendingPlayingActivityAcknowledgement = false
        }
    }

    private func acknowledgePlayingPickupActivityIfReady(reason: String) {
        guard pendingPlayingActivityAcknowledgement else { return }
        guard viewModel.canFanUsePickupGamesUI else { return }
        guard selectedGoingMode == .pickupGames else { return }
        guard !shouldShowPlayingPickupLoadingState else { return }
        guard !viewModel.isPickupFollowingJoinListRefreshing else { return }
        guard !viewModel.myPickupGameJoinRequestCards.isEmpty else { return }
        viewModel.acknowledgePickupFollowingGamesToPlayActivity()
        pendingPlayingActivityAcknowledgement = false
#if DEBUG
        print("[PickupFollowingActivity] uiAck reason=\(reason)")
#endif
    }

    private var hostingGamesContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if goingDayScope == .today {
                goingTodayScopeBanner
            }
            if !viewModel.canFanUsePickupGamesUI {
                emptyCard(
                    icon: "figure.run",
                    title: "Games unavailable",
                    subtitle: "Switch to a fan account to create and manage games."
                )
            } else {
                hostPickupInlineCTA

                if shouldShowHostingPickupLoadingState {
                    pickupSubtabLoadingCard(message: "Loading games…")
                } else if goingPlayHostingItems.isEmpty,
                          viewModel.myRemovedPickupGamesForSettings.isEmpty {
                    goingRichEmptyCard(
                        title: L10n.t("going_play_empty_hosting", languageCode: L10n.normalizedLanguageCode(appLanguageRaw)),
                        description: L10n.t("going_play_empty_hosting_supporting", languageCode: L10n.normalizedLanguageCode(appLanguageRaw)),
                        buttonTitle: goingDayScope == .today
                            ? L10n.t("show_all", languageCode: L10n.normalizedLanguageCode(appLanguageRaw))
                            : nil,
                        buttonAction: goingDayScope == .today ? { goingDayScope = .all } : nil,
                        buttonAccent: FGColor.intentPlay
                    )
                } else {
                    hostedGamesListContent
                }
            }
        }
        .padding(.top, 6)
        .onAppear {
            guard viewModel.canFanUsePickupGamesUI else { return }
            followingMyPickupClockTick = Date()
            let hasCachedHostingData =
                !viewModel.myPickupGamesForSettings.isEmpty
                || !viewModel.myRemovedPickupGamesForSettings.isEmpty
            let awaitingInitialHostLoad =
                viewModel.lastMyPickupGamesLightweightLoadAt == nil
                && !hasCachedHostingData
            if awaitingInitialHostLoad {
                followingHostingPickupLoadInFlight = true
            }
            if hasCachedHostingData {
                Task { @MainActor in
                    await Task.yield()
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    defer { followingHostingPickupLoadInFlight = false }
                    await loadHostingPickupGamesAfterAppear()
                }
            } else {
                Task {
                    defer { followingHostingPickupLoadInFlight = false }
                    await loadHostingPickupGamesAfterAppear()
                }
            }
            runFollowingHostedPickupAutoClearIfNeeded(now: Date(), reason: "followingHostingAppear")
        }
    }

    @MainActor
    private func loadHostingPickupGamesAfterAppear() async {
        await viewModel.loadMyPickupGamesForSettings()
        if let uid = viewModel.currentUserAuthId {
            await viewModel.refreshPickupCreatorPublicRatingStats(creatorUserIds: [uid])
        }
        await viewModel.clearExpiredHostedPickupGamesIfNeeded(now: Date(), reason: "followingHostingAppearLoaded")
        logFollowingMyPickupGames(action: "gamesListAppear")
        await refreshGoingPlayUnification(reason: "hostingAppear")
    }

    @MainActor
    private func refreshGoingPlayUnification(reason: String) async {
        guard viewModel.canFanUsePickupGamesUI else { return }
        let ids = cachedPlayingGameCards.map(\.pickupGameId)
            + viewModel.myPickupGamesForSettings.map(\.id)
            + viewModel.incomingPickupGameInvites.map(\.game.id)
        await viewModel.ensurePickupDiscoverTeamIdentities(forGameIds: ids)
        await viewModel.refreshGoingPlayTeamParticipations(reason: reason)
    }

    @MainActor
    private func loadGoingPlayRootAfterAppear() async {
        guard viewModel.canFanUsePickupGamesUI else { return }
        followingMyPickupClockTick = Date()
        await viewModel.loadIncomingPickupGameInvites()
        await loadHostingPickupGamesAfterAppear()
        runFollowingHostedPickupAutoClearIfNeeded(now: Date(), reason: "goingPlayRootAppear")
    }

    private var invitesGamesContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !viewModel.canFanUsePickupGamesUI {
                emptyCard(
                    icon: "envelope",
                    title: "Invites unavailable",
                    subtitle: "Switch to a fan account to receive pickup game invites."
                )
            } else if goingPlayInviteItems.isEmpty {
                goingRichEmptyCard(
                    title: L10n.t("going_play_empty_invites", languageCode: L10n.normalizedLanguageCode(appLanguageRaw)),
                    description: L10n.t("going_play_empty_invites_supporting", languageCode: L10n.normalizedLanguageCode(appLanguageRaw))
                )
            } else {
                incomingPickupGameInvitesContent
            }
        }
        .padding(.top, 6)
        .onAppear {
            guard viewModel.canFanUsePickupGamesUI else { return }
            Task { await viewModel.loadIncomingPickupGameInvites() }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: viewModel.incomingPickupGameInvites.count)
    }

    /// Playing sub-tab: same filtered list as `playingGamesContent`.
    private var pickupPlayingTabBadge: String? {
        liveSubTabBadgeCount(goingPlayPlayingItems.count)
    }

    private var goingVenueSavedVenuesForDisplay: [BarVenue] {
        viewModel.followingTabSavedVenues
    }

    private var goingVenueGamesVisibleCount: Int {
        goingVenueGameItems.count
    }

    private var goingVenueSavedVisibleCount: Int {
        goingVenueSavedVenuesForDisplay.count
    }

    private var venueGamesTabBadge: String? {
        let unified = goingWatchUnifiedItems.count
        logGoingVenueBadgeDebug(
            goingVisible: goingVenueGamesVisibleCount,
            savedVisible: goingVenueSavedVisibleCount,
            topVenueBadge: unified
        )
        return compactTabBadgeCount(unified)
    }

    private func logGoingVenueBadgeDebug(
        goingVisible: Int,
        savedVisible: Int,
        topVenueBadge: Int
    ) {
#if DEBUG
        print("[GoingVenueBadgeDebug] goingVisible=\(goingVisible)")
        print("[GoingVenueBadgeDebug] savedVisible=\(savedVisible)")
        print("[GoingVenueBadgeDebug] topVenueBadge=\(topVenueBadge)")
        print("[GoingVenueBadgeDebug] savedBadge=\(savedVisible)")
#endif
    }

    /// Incoming invites already filtered to actionable pending/maybe rows shown in Invites.
    private var goingPickupInvitesForDisplay: [PickupGameInviteDisplay] {
        viewModel.incomingPickupGameInvites
    }

    /// Going > Play top-segment badge: unique unified feed count.
    private var pickupGamesTabBadge: String? {
        let unified = goingPlayUnifiedItems.count
        logGoingPickupBadgeDebug(
            playingVisible: goingPlayPlayingItems.count,
            hostingVisible: goingPlayHostingItems.count,
            invitesVisible: goingPlayInviteItems.count,
            badgeTotal: unified
        )
        return compactTabBadgeCount(unified)
    }

    private func logGoingPickupBadgeDebug(
        playingVisible: Int,
        hostingVisible: Int,
        invitesVisible: Int,
        badgeTotal: Int
    ) {
#if DEBUG
        print("[GoingPickupBadgeDebug] playingVisible=\(playingVisible)")
        print("[GoingPickupBadgeDebug] hostingVisible=\(hostingVisible)")
        print("[GoingPickupBadgeDebug] invitesVisible=\(invitesVisible)")
        print("[GoingPickupBadgeDebug] badgeTotal=\(badgeTotal)")

        let visiblePlayingIds = Set(playingGameCards.map(\.id))
        for card in viewModel.myPickupGameJoinRequestCards where !visiblePlayingIds.contains(card.id) {
            let reason: String
            switch card.pill {
            case .cancelled, .withdrawing, .canceledByOrganizer:
                reason = "hidden"
            case .pending, .approved, .declined:
                if let game = viewModel.pickupGamesFollowingTabCache[card.pickupGameId] {
                    let status = game.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if status == "removed" {
                        reason = "removed"
                    } else if GoingTabCompletedGameVisibility.isPickupGameCompleted(
                        game,
                        now: followingMyPickupClockTick
                    ) {
                        reason = "expired"
                    } else {
                        reason = "hidden"
                    }
                } else {
                    reason = "hidden"
                }
            }
            print("[GoingPickupBadgeDebug] excluded reason=\(reason) id=\(card.id.uuidString.lowercased())")
        }

        let visibleHostingIds = Set(goingPickupHostingGamesForDisplay.map(\.id))
        for row in viewModel.myPickupGamesForSettings where !visibleHostingIds.contains(row.id) {
            let status = row.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let reason: String
            if status == "removed" {
                reason = "removed"
            } else if GoingTabCompletedGameVisibility.isPickupGameCompleted(
                row,
                now: followingMyPickupClockTick
            ) {
                reason = "expired"
            } else {
                reason = "hidden"
            }
            print("[GoingPickupBadgeDebug] excluded reason=\(reason) id=\(row.id.uuidString.lowercased())")
        }

        for row in viewModel.myRemovedPickupGamesForSettings {
            print("[GoingPickupBadgeDebug] excluded reason=removed id=\(row.id.uuidString.lowercased())")
        }
#endif
    }

    private var savedProGamesTabBadge: String? {
        let count = isBusinessProGamesOnly
            ? manualSavedProGamesForDisplay.count + businessMyTeamProGamesForDisplay.count
            : goingProUnifiedItems.count
        return compactTabBadgeCount(count)
    }

    private func compactTabBadgeCount(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 9 ? "9+" : "\(count)"
    }

    /// Second-level Going tabs always show a live count (including 0) for discoverability.
    private func liveSubTabBadgeCount(_ count: Int) -> String {
        count > 9 ? "9+" : "\(max(0, count))"
    }

    private var playingGameCards: [PickupGameJoinRequestCardDisplay] {
        let base = cachedPlayingGameCards
        guard goingDayScope == .today else { return base }
        return base.filter { isPickupStartOnLocalToday($0.game_start_at, now: followingMyPickupClockTick) }
    }

    private var goingPlayLanguageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var goingPlayPlayingItems: [GoingPlayFeedItem] {
        let items = GoingPlayProjection.playingItems(
            pickupCards: cachedPlayingGameCards,
            resolvedGame: { viewModel.resolvedPickupGameRow(for: $0) },
            teamIdentities: viewModel.pickupDiscoverTeamIdentityByGameId,
            teamParticipations: viewModel.goingPlayTeamParticipations,
            hostedGameIds: Set(viewModel.myPickupGamesForSettings.map(\.id)),
            languageCode: goingPlayLanguageCode,
            now: followingMyPickupClockTick
        )
        guard goingDayScope == .today else { return items }
        return items.filter { Calendar.current.isDate($0.startAt, inSameDayAs: followingMyPickupClockTick) }
    }

    private var goingPlayHostingItems: [GoingPlayFeedItem] {
        GoingPlayProjection.hostingItems(
            hostedRows: goingPickupHostingGamesForDisplay,
            teamIdentities: viewModel.pickupDiscoverTeamIdentityByGameId,
            languageCode: goingPlayLanguageCode,
            now: followingMyPickupClockTick
        )
    }

    private var goingPlayInviteItems: [GoingPlayFeedItem] {
        GoingPlayProjection.inviteItems(
            invites: goingPickupInvitesForDisplay,
            teamIdentities: viewModel.pickupDiscoverTeamIdentityByGameId,
            languageCode: goingPlayLanguageCode,
            now: followingMyPickupClockTick
        )
    }

    private var goingPlayUnifiedItems: [GoingPlayFeedItem] {
        GoingPlayProjection.unifiedItems(
            playing: goingPlayPlayingItems,
            hosting: goingPlayHostingItems,
            invites: goingPlayInviteItems,
            now: followingMyPickupClockTick
        )
    }

    private var goingPlayFilterCounts: GoingPlayProjection.FilterCounts {
        GoingPlayProjection.filterCounts(
            unified: goingPlayUnifiedItems,
            hosting: goingPlayHostingItems,
            invites: goingPlayInviteItems
        )
    }

    private var goingPlayVisibleItems: [GoingPlayFeedItem] {
        GoingPlayProjection.filteredItems(
            unified: goingPlayUnifiedItems,
            hosting: goingPlayHostingItems,
            invites: goingPlayInviteItems,
            filter: selectedGoingPlayFilter
        )
    }

    private var shouldShowGoingPlayLoadingState: Bool {
        shouldShowPlayingPickupLoadingState
            || (selectedGoingPlayFilter == .hosting && shouldShowHostingPickupLoadingState)
    }

    private var goingPlayEmptyButtonTitle: String? {
        if goingDayScope == .today {
            return L10n.t("show_all", languageCode: goingPlayLanguageCode)
        }
        switch selectedGoingPlayFilter {
        case .all, .pickups, .teamEvents:
            return L10n.t("explore_discover", languageCode: goingPlayLanguageCode)
        case .hosting, .invites:
            return nil
        }
    }

    private var goingPlayEmptyButtonAction: (() -> Void)? {
        if goingDayScope == .today {
            return { goingDayScope = .all }
        }
        switch selectedGoingPlayFilter {
        case .all, .pickups, .teamEvents:
            return { openDiscoverForPickupGamesFromGoing() }
        case .hosting, .invites:
            return nil
        }
    }

    private var goingTodayScopeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(FGColor.accentBlue)
            Text("Showing today")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(followingColorScheme))
            Spacer(minLength: 0)
            Button("Show all") {
                goingDayScope = .all
            }
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(FGColor.accentBlue)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(FGColor.accentBlue.opacity(followingColorScheme == .dark ? 0.16 : 0.10))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Showing today. Show all.")
    }

    /// Hosting sub-tab: same filtered list as `hostingGamesContent` / `goingPlayHostingItems`.
    private var pickupHostingTabBadge: String? {
        liveSubTabBadgeCount(goingPlayHostingItems.count)
    }

    /// Invites sub-tab: same filtered list as `invitesGamesContent` / `goingPlayInviteItems`.
    private var pickupInvitesTabBadge: String? {
        liveSubTabBadgeCount(goingPlayInviteItems.count)
    }

    private enum GoingTabbedPanelHeaderStyle {
        /// Compact muted label used by Venue / Pickup panels.
        case standard
        /// Clearer section introduction used by Pro Games.
        case sectionIntroduction
    }

    private func goingTabbedPanel<Tabs: View, Content: View>(
        title: String? = nil,
        subtitle: String? = nil,
        headerStyle: GoingTabbedPanelHeaderStyle = .standard,
        showsDivider: Bool = true,
        @ViewBuilder tabs: () -> Tabs,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let showsHeader = !trimmedTitle.isEmpty
        return VStack(alignment: .leading, spacing: 14) {
            if showsHeader {
                VStack(alignment: .leading, spacing: headerStyle == .sectionIntroduction ? 5 : 3) {
                    Text(trimmedTitle)
                        .font(headerStyle == .sectionIntroduction
                              ? .headline.weight(.semibold)
                              : .system(size: 12, weight: .semibold, design: .rounded))
                        .tracking(headerStyle == .sectionIntroduction ? 0 : 1.0)
                        .foregroundStyle(
                            headerStyle == .sectionIntroduction
                                ? FGColor.primaryText(followingColorScheme)
                                : FGColor.mutedText(followingColorScheme)
                        )
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle, !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(subtitle)
                            .font(headerStyle == .sectionIntroduction ? .subheadline : FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            tabs()

            if showsDivider {
                Divider()
                    .overlay(FGColor.divider(followingColorScheme).opacity(0.65))
                    .padding(.top, headerStyle == .sectionIntroduction ? 4 : 2)
            }

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground).opacity(followingColorScheme == .dark ? 0.38 : 0.72))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(FGColor.divider(followingColorScheme).opacity(0.72), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(followingColorScheme == .dark ? 0.20 : 0.055), radius: 10, y: 3)
    }

    private func goingCategoryBlock<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(FGColor.mutedText(followingColorScheme))

            content()
        }
    }

    private var goingHubParticipationSummaryCard: some View {
        HStack(spacing: 12) {
            goingHubMetricPill(
                value: viewModel.myPickupGamesForSettings.count + viewModel.myPickupGameJoinRequestCards.count,
                label: "Pickup",
                tint: FGColor.accentGreen
            )
            goingHubMetricPill(
                value: viewModel.followingTabGoingItems.count,
                label: "I’m Going",
                tint: Color.orange
            )
            goingHubMetricPill(
                value: chatViewModel.friends.count,
                label: "Social",
                tint: FGColor.accentBlue
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .modifier(FollowingCardChromeModifier(colorScheme: followingColorScheme, cornerRadius: 22))
    }

    private func goingHubMetricPill(value: Int, label: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(value > 0 ? "\(value)" : "0")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(followingColorScheme))
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(tint.opacity(followingColorScheme == .dark ? 0.13 : 0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var goingHubUpcomingSubtitle: String {
        let attendance = viewModel.followingTabGoingItems.count
        let joined = viewModel.myPickupGameJoinRequestCards.count
        let hosting = viewModel.myPickupGamesForSettings.count
        let total = attendance + joined + hosting
        guard total > 0 else { return "Your next games and plans will collect here." }
        if total == 1 { return "1 upcoming thing you’re part of." }
        return "\(total) upcoming things you’re part of."
    }

    private func consumePendingGoingActionCenterDeepLinks() {
        if viewModel.pendingOpenGoingPickupInvites {
            viewModel.pendingOpenGoingPickupInvites = false
            selectedGoingMode = .pickupGames
            selectedGoingPlayFilter = .invites
            return
        }
        if viewModel.pendingOpenGoingHostingApprovals {
            viewModel.pendingOpenGoingHostingApprovals = false
            selectedGoingMode = .pickupGames
            selectedGoingPlayFilter = .hosting
            if let gameId = viewModel.pendingHostingApprovalPickupGameId {
                viewModel.pendingHostingApprovalPickupGameId = nil
                viewModel.pendingPickupPlayingHighlightGameID = gameId
            }
        }
    }

    private var hostPickupInlineCTA: some View {
        Button {
            openCreatePickupFromGoing()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(FGColor.accentGreen, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Create Game")
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(followingColorScheme))
                    Text("Create a casual game and manage it here.")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FGColor.mutedText(followingColorScheme))
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .modifier(FollowingCardChromeModifier(colorScheme: followingColorScheme, cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canFanUsePickupGamesUI)
        .opacity(viewModel.canFanUsePickupGamesUI ? 1 : 0.55)
        .accessibilityLabel("Create Game")
    }

    private func openProGamePredictionSheet(for game: SavedProGame) {
#if DEBUG
        print("[ProPredictionPerf] tapReceived gameId=\(game.stableKey)")
#endif
        proGamePredictionSheet = ProGamePredictionSheetContext(game: game)
#if DEBUG
        print("[ProPredictionPerf] sheetPresented gameId=\(game.stableKey)")
#endif
    }

    private func savedProGameCard(
        _ game: SavedProGame,
        badges: [String],
        showsUnsaveButton: Bool = true,
        showsScoreUpdatesControl: Bool = true,
        favoriteTeamAlertItem: FavoriteTeamProGame? = nil,
        reasonBadges: [GoingProReasonBadge.Kind] = [],
        onClearCompleted: (() -> Void)? = nil
    ) -> some View {
        let displayGame = viewModel.currentSavedProGameSnapshot(game)
        let sportType = displayGame.liveSportVisualType
        let accent = sportType.catalogAccent
        let completedAccent = FGColor.mutedText(followingColorScheme)
        let liveAccent = FGColor.dangerRed
        let isLiveCard = displayGame.matchStatus.isHappeningNow && !displayGame.isFinal
        let cardAccent = displayGame.isFinal ? completedAccent : (isLiveCard ? liveAccent : accent)
        let borderOpacity = savedProGameCardBorderOpacity(displayGame)
        let featuredEvent = savedProGameFeaturedEvent(displayGame)

        let locationLine = GoingProGamesProjection.locationLine(
            for: displayGame,
            liveMatches: viewModel.liveMatches
        )
        let statusLine = GoingProGamesProjection.statusTimeLine(
            for: displayGame,
            languageCode: goingProLanguageCode,
            timeZoneOption: viewModel.selectedTimeZone
        )
        let matchupTitle = GoingProGamesProjection.matchupTitle(for: displayGame)
        let usesPremiumActiveGameCard = GoingProLiveCardPresentation.usesPremiumActiveGameCard(for: displayGame)
        let involvesFavoriteTeam = reasonBadges.contains(where: { kind in
            if case .favoriteTeam = kind { return true }
            return false
        }) || favoriteTeamAlertItem != nil
        let liveAlertsEnabled: Bool? = {
            guard showsScoreUpdatesControl, !displayGame.isFinal else { return nil }
            if let favoriteTeamAlertItem {
                return viewModel.favoriteTeamProGameScoreUpdatesEnabled(for: favoriteTeamAlertItem.game)
            }
            if showsUnsaveButton {
                return viewModel.savedProGameScoreUpdatesEnabled(for: displayGame)
            }
            return nil
        }()
        let livePresentation = GoingProLiveCardPresentation.make(
            game: displayGame,
            involvesFavoriteTeam: involvesFavoriteTeam,
            liveAlertsEnabled: liveAlertsEnabled,
            languageCode: goingProLanguageCode
        )
        let cardCornerRadius: CGFloat = usesPremiumActiveGameCard
            ? GoingProLiveScoreboardMetrics.cardCornerRadius
            : 16
        let cardPadding: CGFloat = usesPremiumActiveGameCard
            ? GoingProLiveScoreboardMetrics.cardPadding
            : 12

        return VStack(alignment: .leading, spacing: usesPremiumActiveGameCard ? 12 : 8) {
            if usesPremiumActiveGameCard {
                savedProGameLiveCardInterior(
                    displayGame: displayGame,
                    presentation: livePresentation,
                    tvSummary: displayGame.tvSummary,
                    favoriteTeamAlertItem: favoriteTeamAlertItem,
                    showsUnsaveButton: showsUnsaveButton
                )
            } else {
                savedProGameStandardCardInterior(
                    displayGame: displayGame,
                    sportType: sportType,
                    featuredEvent: featuredEvent,
                    matchupTitle: matchupTitle,
                    statusLine: statusLine,
                    locationLine: locationLine,
                    isLiveCard: isLiveCard,
                    cardAccent: cardAccent,
                    badges: badges,
                    reasonBadges: reasonBadges,
                    showsScoreUpdatesControl: showsScoreUpdatesControl,
                    showsUnsaveButton: showsUnsaveButton,
                    favoriteTeamAlertItem: favoriteTeamAlertItem
                )
            }

            if usesPremiumActiveGameCard {
                savedProGameLiveEventSummary(displayGame)
            } else if savedProGameShouldShowScore(displayGame) {
                savedProGameScoreboardSection(displayGame, isFinal: displayGame.isFinal, accent: cardAccent)
            } else {
                GoingProMatchupVisual(
                    game: displayGame,
                    liveMatches: viewModel.liveMatches,
                    isLive: isLiveCard,
                    colorScheme: followingColorScheme
                )
                .frame(maxWidth: .infinity)
            }

            if displayGame.supportsProGamePredictions {
                ProGamePredictionFooterRow(
                    game: displayGame,
                    summary: viewModel.proGamePredictionSummaries[displayGame.stableKey]
                ) {
                    openProGamePredictionSheet(for: displayGame)
                }
            }

            if goingCanUseAddToVenueShortcut {
                goingAddToVenueSection(for: displayGame)
            }
        }
        .padding(cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(savedProGameCardBackgroundFill(displayGame, accent: cardAccent))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .strokeBorder(cardAccent.opacity(borderOpacity), lineWidth: 1)
        )
        .overlay(alignment: .topLeading) {
            if usesPremiumActiveGameCard {
                GoingProLiveSportMark(
                    sportType: sportType,
                    featuredEvent: featuredEvent,
                    featuredEventSlug: displayGame.featuredEventSlug
                )
                .padding(10)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            savedProGameCardTrailingControls(
                displayGame: displayGame,
                cardAccent: cardAccent,
                showsUnsaveButton: showsUnsaveButton,
                showsStatusChip: !usesPremiumActiveGameCard,
                onClearCompleted: onClearCompleted
            )
        }
        .contentShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .onTapGesture {
            openGoingProGameDetail(displayGame)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            usesPremiumActiveGameCard
                ? livePresentation.accessibilityLabel
                : goingProGameAccessibilityLabel(
                    title: matchupTitle,
                    status: statusLine,
                    location: locationLine,
                    league: displayGame.league,
                    reasons: reasonBadges,
                    score: (isLiveCard || displayGame.isFinal)
                        ? "\(displayGame.scoreAway) \(displayGame.scoreHome)"
                        : nil
                )
        )
        .id(savedProGameCardRefreshToken(displayGame))
        .onAppear {
            logSavedProGameStatusDebug(displayGame)
            logSavedProGameScoringEventDebug(displayGame)
        }
        .task(id: goingAddToVenueHostedTaskId(for: displayGame)) {
            await refreshGoingAddToVenueHostedStatus(for: displayGame)
        }
    }

    @ViewBuilder
    private func savedProGameStandardCardInterior(
        displayGame: SavedProGame,
        sportType: LiveSportVisualType,
        featuredEvent: FeaturedEvent?,
        matchupTitle: String,
        statusLine: String,
        locationLine: String,
        isLiveCard: Bool,
        cardAccent: Color,
        badges: [String],
        reasonBadges: [GoingProReasonBadge.Kind],
        showsScoreUpdatesControl: Bool,
        showsUnsaveButton: Bool,
        favoriteTeamAlertItem: FavoriteTeamProGame?
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ProGameSportBadgeView(
                sportType: sportType,
                diameter: 52,
                featuredEvent: featuredEvent,
                featuredEventSlug: displayGame.featuredEventSlug
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(matchupTitle)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(followingColorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(statusLine)
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(isLiveCard ? FGColor.dangerRed : FGColor.secondaryText(followingColorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)

                    if !locationLine.isEmpty {
                        Text(locationLine)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                    }

                    ProGameLeagueChip(
                        sportType: sportType,
                        featuredEvent: featuredEvent,
                        league: displayGame.league
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !reasonBadges.isEmpty || !badges.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(reasonBadges, id: \.titleKey) { kind in
                            GoingProReasonBadge(
                                kind: kind,
                                languageCode: goingProLanguageCode,
                                colorScheme: followingColorScheme
                            )
                        }
                        if !badges.isEmpty {
                            savedProGameStatusBadges(badges, accent: cardAccent, isFinal: displayGame.isFinal)
                        }
                    }
                }

                if showsScoreUpdatesControl, !displayGame.isFinal {
                    if let favoriteTeamAlertItem {
                        favoriteTeamProGameAlertsControl(favoriteTeamAlertItem, accent: cardAccent)
                    } else if showsUnsaveButton {
                        savedProGameScoreUpdatesControl(displayGame, accent: cardAccent)
                    }
                }

                if let tv = displayGame.tvSummary, !tv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label(tv, systemImage: "tv.fill")
                        .font(FGTypography.metadata.weight(.semibold))
                        .foregroundStyle(cardAccent)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, savedProGameCardTrailingControlsReservedWidth)
        }
    }

    @ViewBuilder
    private func savedProGameLiveCardInterior(
        displayGame: SavedProGame,
        presentation: GoingProLiveCardPresentation,
        tvSummary: String?,
        favoriteTeamAlertItem: FavoriteTeamProGame?,
        showsUnsaveButton: Bool
    ) -> some View {
        VStack(spacing: 12) {
            Text(presentation.matchupTitle)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(followingColorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 44)
                .padding(.top, 2)
                .accessibilityAddTraits(.isHeader)

            GoingProLiveStatusHeadline(
                status: presentation.primaryStatus ?? .live,
                languageCode: goingProLanguageCode
            )

            if !presentation.contextChips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(presentation.contextChips.enumerated()), id: \.offset) { _, chip in
                        GoingProLiveContextChip(
                            chip: chip,
                            languageCode: goingProLanguageCode,
                            colorScheme: followingColorScheme,
                            action: liveAlertsAction(
                                for: chip,
                                displayGame: displayGame,
                                favoriteTeamAlertItem: favoriteTeamAlertItem,
                                showsUnsaveButton: showsUnsaveButton
                            )
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }

            GoingProLiveScoreboardView(
                game: displayGame,
                liveMatches: viewModel.liveMatches,
                presentation: presentation,
                colorScheme: followingColorScheme
            )
            .padding(.top, 2)

            if let tv = tvSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !tv.isEmpty {
                Label(tv, systemImage: "tv.fill")
                    .font(FGTypography.metadata.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.trailing, 4)
    }

    private func liveAlertsAction(
        for chip: GoingProLiveCardPresentation.ContextChip,
        displayGame: SavedProGame,
        favoriteTeamAlertItem: FavoriteTeamProGame?,
        showsUnsaveButton: Bool
    ) -> (() -> Void)? {
        switch chip {
        case .liveAlertsOn, .liveAlertsOff:
            break
        case .sport, .favoriteTeam:
            return nil
        }
        if let favoriteTeamAlertItem {
            return {
                Task {
                    let isEnabled = viewModel.favoriteTeamProGameScoreUpdatesEnabled(for: favoriteTeamAlertItem.game)
                    await viewModel.setFavoriteTeamProGameScoreUpdatesEnabled(
                        !isEnabled,
                        for: favoriteTeamAlertItem,
                        reason: "goingProFavoriteTeamAlertToggle"
                    )
                }
            }
        }
        guard showsUnsaveButton else { return nil }
        return {
            let isEnabled = viewModel.savedProGameScoreUpdatesEnabled(for: displayGame)
            viewModel.setSavedProGameScoreUpdatesEnabled(!isEnabled, for: displayGame)
        }
    }

    private func openGoingProGameDetail(_ game: SavedProGame) {
        if let match = viewModel.liveMatchForVenueImport(from: game) {
            proGameMatchDetailSelection = match
        }
    }

    private func goingProGameAccessibilityLabel(
        title: String,
        status: String,
        location: String,
        league: String,
        reasons: [GoingProReasonBadge.Kind],
        score: String?
    ) -> String {
        var parts = [title, status]
        if !location.isEmpty { parts.append(location) }
        if !league.isEmpty { parts.append(league) }
        if let score, !score.isEmpty { parts.append(score) }
        for kind in reasons {
            parts.append(L10n.t(kind.titleKey, languageCode: goingProLanguageCode))
        }
        return parts.joined(separator: ". ")
    }

    private var goingCanUseAddToVenueShortcut: Bool {
        viewModel.hasAuthenticatedVenueOwnerSession || viewModel.isVenueOwnerLoggedIn
    }

    private var goingAddToVenueChooserBaseVenues: [VenueProfileRow] {
        viewModel.managedVenuesForOwner().filter { MapViewModel.venueIsOwnerVisibleManagedStatus($0) }
    }

    private var goingAddToVenueSelectableVenues: [VenueProfileRow] {
        viewModel.managedVenuesForOwner().filter { MapViewModel.venueIsActiveForBusinessLimit($0) }
    }

    private func goingAddToVenueHostedTaskId(for game: SavedProGame) -> String? {
        guard goingCanUseAddToVenueShortcut else { return nil }
        guard goingLiveMatchForAddToVenue(game) != nil else { return nil }
        return game.stableKey
    }

    private func goingLiveMatchForAddToVenue(_ game: SavedProGame) -> LiveMatch? {
        viewModel.liveMatchForVenueImport(from: game)
    }

    private func goingProGameCanImportToVenue(_ match: LiveMatch) -> Bool {
        let id = match.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = match.homeTeam.trimmingCharacters(in: .whitespacesAndNewlines)
        let away = match.awayTeam.trimmingCharacters(in: .whitespacesAndNewlines)
        return !id.isEmpty && !home.isEmpty && !away.isEmpty
    }

    private func goingHostedVenues(for game: SavedProGame) -> [VenueGameImportHostedVenueSummary] {
        let cached = goingAddToVenueHostedByGameKey[game.stableKey] ?? []
        // Always prefer live managed-venue names so renames appear without waiting for a hosted re-fetch.
        return cached.map { summary in
            if let managedName = viewModel.managedVenuesForOwner()
                .first(where: { $0.id == summary.venueId })?
                .venue_name?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !managedName.isEmpty {
                return VenueGameImportHostedVenueSummary(venueId: summary.venueId, venueName: managedName)
            }
            return summary
        }
    }

    private func goingSelectableVenuesExcludingHosted(of match: LiveMatch, gameKey: String) -> [VenueProfileRow] {
        let hosted = Set((goingAddToVenueHostedByGameKey[gameKey] ?? []).map(\.venueId))
        return goingAddToVenueSelectableVenues.filter { row in
            guard let id = row.id else { return false }
            return !hosted.contains(id)
        }
    }

    private func goingAddToVenueChooserVenues(excludingHostedOf match: LiveMatch) -> [VenueProfileRow] {
        let gameKey = SavedProGame.stableKey(for: match)
        let hosted = Set((goingAddToVenueHostedByGameKey[gameKey] ?? []).map(\.venueId))
        return goingAddToVenueChooserBaseVenues.filter { row in
            guard let id = row.id else { return false }
            if hosted.contains(id), MapViewModel.venueIsActiveForBusinessLimit(row) {
                return false
            }
            return true
        }
    }

    @ViewBuilder
    private func goingAddToVenueSection(for game: SavedProGame) -> some View {
        let match = goingLiveMatchForAddToVenue(game)
        let canImport = match.map(goingProGameCanImportToVenue) ?? false
        let hosted = goingHostedVenues(for: game)
        let remaining = match.map { goingSelectableVenuesExcludingHosted(of: $0, gameKey: game.stableKey) } ?? []
        let showAdd = canImport && !remaining.isEmpty
        let showHosted = !hosted.isEmpty

        if showHosted || showAdd {
            VStack(alignment: .leading, spacing: 8) {
                if showHosted {
                    goingHostedAtVenueStatusButton(hosted)
                }
                if showAdd, let match {
                    goingAddToVenueButton(match: match, gameKey: game.stableKey)
                }
            }
        }
    }

    private func goingHostedAtVenueStatusButton(_ hosted: [VenueGameImportHostedVenueSummary]) -> some View {
        Button {
            showGoingManageGamesFromHostedStatus = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "building.2.fill")
                    .font(.caption.weight(.bold))
                Text(goingHostedAtStatusText(hosted))
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(FGColor.secondaryText(followingColorScheme))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FGColor.secondaryText(followingColorScheme).opacity(followingColorScheme == .dark ? 0.14 : 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        FGColor.divider(followingColorScheme).opacity(followingColorScheme == .dark ? 0.40 : 0.50),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(goingHostedAtStatusText(hosted))
    }

    private func goingHostedAtStatusText(_ hosted: [VenueGameImportHostedVenueSummary]) -> String {
        if hosted.count == 1 {
            return String(
                format: L10n.t("Hosted at %@", languageCode: appLanguageRaw),
                hosted[0].venueName
            )
        }
        return String(
            format: L10n.t("Hosted at %lld venues", languageCode: appLanguageRaw),
            Int64(hosted.count)
        )
    }

    private func goingAddToVenueButton(match: LiveMatch, gameKey: String) -> some View {
        Button {
            handleGoingAddToVenueTapped(match: match, gameKey: gameKey)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "building.2.fill")
                    .font(.caption.weight(.bold))
                Text(L10n.t("Add to Venue", languageCode: appLanguageRaw))
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
            }
            .foregroundStyle(FGColor.accentBlue)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FGColor.accentBlue.opacity(followingColorScheme == .dark ? 0.16 : 0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(FGColor.accentBlue.opacity(followingColorScheme == .dark ? 0.32 : 0.18), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("Add to Venue", languageCode: appLanguageRaw))
    }

    private func handleGoingAddToVenueTapped(match: LiveMatch, gameKey: String) {
        guard goingProGameCanImportToVenue(match) else { return }
        let remaining = goingSelectableVenuesExcludingHosted(of: match, gameKey: gameKey)
        guard !remaining.isEmpty else { return }

        if remaining.count == 1, let venueId = remaining.first?.id {
            presentGoingAddToVenueImport(match: match, venueId: venueId)
            return
        }

        goingAddToVenueChooser = CalendarAddToVenueChooserContext(match: match)
    }

    private func presentGoingAddToVenueImport(match: LiveMatch, venueId: UUID) {
        goingAddToVenueImportPrefill = VenueOwnerScheduleImportPrefill(match: match, venueId: venueId)
    }

    private func refreshGoingAddToVenueHostedStatus(for game: SavedProGame) async {
        guard goingCanUseAddToVenueShortcut else { return }
        guard let match = goingLiveMatchForAddToVenue(game), goingProGameCanImportToVenue(match) else {
            await MainActor.run {
                goingAddToVenueHostedByGameKey[game.stableKey] = []
            }
            return
        }

        let hosted = await viewModel.venueGameImportHostedVenues(
            externalGameID: match.id,
            externalSource: LiveSportsService.providerDescription
        )
        await MainActor.run {
            goingAddToVenueHostedByGameKey[game.stableKey] = hosted
        }
    }

    private func refreshGoingAddToVenueHostedStatus(for match: LiveMatch) async {
        let key = SavedProGame.stableKey(for: match)
        let hosted = await viewModel.venueGameImportHostedVenues(
            externalGameID: match.id,
            externalSource: LiveSportsService.providerDescription
        )
        await MainActor.run {
            goingAddToVenueHostedByGameKey[key] = hosted
        }
    }

    private func savedProGameCardBackgroundFill(_ game: SavedProGame, accent: Color) -> Color {
        if game.isFinal {
            return Color.gray.opacity(followingColorScheme == .dark ? 0.24 : 0.22)
        }
        if game.matchStatus.isHappeningNow {
            return FGColor.dangerRed.opacity(followingColorScheme == .dark ? 0.16 : 0.09)
        }
        return Color.clear
    }

    private func savedProGameCardBorderOpacity(_ game: SavedProGame) -> Double {
        if game.isFinal {
            return followingColorScheme == .dark ? 0.44 : 0.34
        }
        if game.matchStatus.isHappeningNow {
            return followingColorScheme == .dark ? 0.48 : 0.30
        }
        return followingColorScheme == .dark ? 0.38 : 0.22
    }

    /// Room for status chip + Share (44) + Clear / Unsave in the top-trailing cluster.
    private var savedProGameCardTrailingControlsReservedWidth: CGFloat { 168 }

    /// Shared height so status / Share / Clear visually center on one row.
    private var savedProGameTrailingControlHeight: CGFloat { 44 }

    @ViewBuilder
    private func savedProGameCardTrailingControls(
        displayGame: SavedProGame,
        cardAccent: Color,
        showsUnsaveButton: Bool,
        showsStatusChip: Bool = true,
        onClearCompleted: (() -> Void)?
    ) -> some View {
        HStack(alignment: .center, spacing: 6) {
            if showsStatusChip {
                savedProGameTrailingStatusChip(displayGame, cardAccent: cardAccent)
            }

            ProGameShareActionButton(game: displayGame, mapViewModel: viewModel) {
                followingProGameShareIconControl()
            }
            .environmentObject(chatViewModel)
            .fixedSize()
            .frame(height: savedProGameTrailingControlHeight)
            .zIndex(2)

            if showsUnsaveButton {
                savedProGameClearControl(displayGame)
                    .frame(height: savedProGameTrailingControlHeight)
                    .zIndex(2)
            } else if displayGame.isFinal, let onClearCompleted {
                completedFavoriteTeamProGameClearControl(onClearCompleted)
                    .frame(height: savedProGameTrailingControlHeight)
                    .zIndex(2)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func savedProGameTrailingStatusChip(_ game: SavedProGame, cardAccent: Color) -> some View {
        Text(savedProGameStatusText(game))
            .font(game.isFinal ? .caption.weight(.heavy) : .caption2.weight(.bold))
            .foregroundStyle(statusTint(for: game, fallback: cardAccent))
            .padding(.horizontal, game.isFinal ? 10 : 8)
            .padding(.vertical, game.isFinal ? 5 : 3)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        statusTint(for: game, fallback: cardAccent)
                            .opacity(
                                game.isFinal
                                    ? (followingColorScheme == .dark ? 0.20 : 0.12)
                                    : (followingColorScheme == .dark ? 0.18 : 0.10)
                            )
                    )
            )
            .frame(height: savedProGameTrailingControlHeight)
            .accessibilityLabel(savedProGameStatusText(game))
    }

    private func followingProGameShareIconControl() -> some View {
        let iconColor = followingColorScheme == .dark
            ? Color.white.opacity(0.78)
            : Color.secondary
        return ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 36, height: 36)
                .overlay {
                    Circle()
                        .strokeBorder(
                            Color.primary.opacity(followingColorScheme == .dark ? 0.22 : 0.12),
                            lineWidth: 1
                        )
                }
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func savedProGameClearControl(_ game: SavedProGame) -> some View {
        if game.isFinal {
            Button("Clear") {
                clearSavedProGame(game)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(FGColor.mutedText(followingColorScheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(FGColor.mutedText(followingColorScheme).opacity(followingColorScheme == .dark ? 0.14 : 0.08))
            )
            .buttonStyle(.plain)
            .contentShape(Capsule(style: .continuous))
            .accessibilityLabel("Clear completed pro sports game")
        } else {
            Button {
                clearSavedProGame(game)
            } label: {
                Image(systemName: "heart.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.red.opacity(0.95))
                    .frame(width: 32, height: 32)
                    .background(Color.red.opacity(followingColorScheme == .dark ? 0.18 : 0.10), in: Circle())
                    .overlay(Circle().strokeBorder(Color.red.opacity(followingColorScheme == .dark ? 0.38 : 0.24), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .accessibilityLabel(L10n.t("unsave_pro_sports_game_a11y", languageCode: appLanguageRaw))
        }
    }

    private func completedFavoriteTeamProGameClearControl(_ action: @escaping () -> Void) -> some View {
        Button("Clear") {
            action()
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(FGColor.mutedText(followingColorScheme))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(FGColor.mutedText(followingColorScheme).opacity(followingColorScheme == .dark ? 0.14 : 0.08))
        )
        .buttonStyle(.plain)
        .contentShape(Capsule(style: .continuous))
        .accessibilityLabel("Clear completed favorite team pro sports game")
    }

    private func savedProGameScoreUpdatesControl(
        _ game: SavedProGame,
        accent _: Color
    ) -> some View {
        let isEnabled = viewModel.savedProGameScoreUpdatesEnabled(for: game)
        let controlAccent = isEnabled ? FGColor.accentGreen : FGColor.mutedText(followingColorScheme)

        return Button {
            viewModel.setSavedProGameScoreUpdatesEnabled(!isEnabled, for: game)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isEnabled ? "bell.fill" : "bell.slash")
                    .font(.system(size: 11, weight: .bold))
                Text("Live Alerts \(isEnabled ? "ON" : "OFF")")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(controlAccent)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(controlAccent.opacity(followingColorScheme == .dark ? 0.16 : 0.09))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(controlAccent.opacity(followingColorScheme == .dark ? 0.28 : 0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Live alerts for this game \(isEnabled ? "on" : "off")")
        .accessibilityHint("Goals, halftime, cards and other live updates.")
    }

    private func favoriteTeamProGameAlertsControl(_ item: FavoriteTeamProGame, accent _: Color) -> some View {
        let isEnabled = viewModel.favoriteTeamProGameScoreUpdatesEnabled(for: item.game)
        let controlAccent = isEnabled ? FGColor.accentGreen : FGColor.mutedText(followingColorScheme)

        return Button {
            Task {
                await viewModel.setFavoriteTeamProGameScoreUpdatesEnabled(
                    !isEnabled,
                    for: item,
                    reason: "goingProFavoriteTeamAlertToggle"
                )
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isEnabled ? "bell.fill" : "bell.slash")
                    .font(.system(size: 11, weight: .bold))
                Text("Live Alerts \(isEnabled ? "ON" : "OFF")")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(controlAccent)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(controlAccent.opacity(followingColorScheme == .dark ? 0.16 : 0.09))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(controlAccent.opacity(followingColorScheme == .dark ? 0.28 : 0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Live alerts for this game \(isEnabled ? "on" : "off")")
        .accessibilityHint("Goals, halftime, cards and other live updates.")
    }

    private func clearSavedProGame(_ game: SavedProGame) {
        let displayGame = viewModel.currentSavedProGameSnapshot(game)
        let gameId = displayGame.stableKey
#if DEBUG
        print("[GoingProClearDebug] tapped gameId=\(gameId) source=manualSaved")
        print("[GoingProClearDebug] hitTestBlocked=false")
#endif
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            viewModel.removeSavedProGame(id: gameId) { error in
                Task { @MainActor in
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        applyImmediateGoingProDisplayCacheAfterClear(reason: "manualClearRollback")
                    }
                    viewModel.showSocialActionToast("Couldn't clear game. Try again.", isError: true)
#if DEBUG
                    print("[GoingProClearDebug] failed error=\(error.localizedDescription)")
#endif
                }
            }
            applyImmediateGoingProDisplayCacheAfterClear(reason: "manualClear")
            viewModel.showSocialActionToast(L10n.t("removed_from_pro_sports_games"), isError: false)
#if DEBUG
            print("[GoingProClearDebug] optimisticRemoved=true")
            print("[GoingProClearDebug] persisted=true")
#endif
        }
    }

    private func clearCompletedFavoriteTeamProGame(_ game: SavedProGame, scope: String) {
        guard game.isFinal else { return }
        let displayGame = viewModel.currentSavedProGameSnapshot(game)
        let gameId = displayGame.stableKey
#if DEBUG
        print("[GoingProClearDebug] tapped gameId=\(gameId) source=favoriteTeamAuto")
        print("[GoingProClearDebug] hitTestBlocked=false")
#endif
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            var tokens = clearedCompletedFavoriteTeamProGameTokens()
            tokens.insert(completedFavoriteTeamProGameClearToken(for: displayGame, scope: scope))
            clearedCompletedFavoriteTeamProGamesRaw = tokens.sorted().joined(separator: "\n")
            applyImmediateGoingProDisplayCacheAfterClear(reason: "favoriteTeamClear:\(scope)")
            viewModel.showSocialActionToast(L10n.t("cleared_completed_pro_sports_game"), isError: false)
#if DEBUG
            print("[GoingProClearDebug] optimisticRemoved=true")
            print("[GoingProClearDebug] persisted=true")
#endif
            Task {
                await viewModel.removeSavedProGameFromAppleCalendar(
                    identifier: displayGame.stableKey,
                    action: "remove",
                    forceBypassFreshness: true
                )
            }
        }
    }

    private func isCompletedFavoriteTeamProGameCleared(_ game: SavedProGame, scope: String) -> Bool {
        guard game.isFinal else { return false }
        return clearedCompletedFavoriteTeamProGameTokens().contains(
            completedFavoriteTeamProGameClearToken(for: game, scope: scope)
        )
    }

    private func clearedCompletedFavoriteTeamProGameTokens() -> Set<String> {
        Set(
            clearedCompletedFavoriteTeamProGamesRaw
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private func completedFavoriteTeamProGameClearToken(for game: SavedProGame, scope: String) -> String {
        let userScope = viewModel.currentUserAuthId?.uuidString.lowercased() ?? "guest"
        return "\(userScope)|\(scope)|\(game.stableKey)"
    }

    private func savedProGameStatusBadges(_ badges: [String], accent: Color, isFinal: Bool = false) -> some View {
        HStack(spacing: 6) {
            ForEach(badges, id: \.self) { badge in
                let badgeAccent = isFinal
                    ? FGColor.mutedText(followingColorScheme)
                    : accent
                Label(badge, systemImage: "star.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(badgeAccent)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(badgeAccent.opacity(followingColorScheme == .dark ? 0.18 : 0.10))
                    )
            }
        }
    }

    private func savedProGameFeaturedEvent(_ game: SavedProGame) -> FeaturedEvent? {
        guard let slug = game.featuredEventSlug?.trimmingCharacters(in: .whitespacesAndNewlines), !slug.isEmpty else {
            return nil
        }
        let normalizedSlug = LiveMatchFilters.normalizedSearchText(slug)
        return viewModel.activeFeaturedEvents.first {
            LiveMatchFilters.normalizedSearchText($0.slug) == normalizedSlug
        } ?? FeaturedEvent.fallbackEvents.first {
            LiveMatchFilters.normalizedSearchText($0.slug) == normalizedSlug
        }
    }

    private func savedProGameTitle(_ game: SavedProGame) -> String {
        "\(savedProGameTeamName(game.awayTeam)) at \(savedProGameTeamName(game.homeTeam))"
    }

    private func savedProGameTeamName(_ teamName: String) -> String {
        let trimmed = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              CountryFlagHelper.isCountry(trimmed),
              let flag = CountryFlagHelper.flag(for: trimmed, source: "GoingPro"),
              !flag.isEmpty else {
            return trimmed
        }
        return "\(flag) \(trimmed)"
    }

    private func savedProGameDateLine(_ game: SavedProGame) -> String {
        let date = game.startTime.formatted(.dateTime.month(.abbreviated).day().year())
        let time = CompactGameTimeFormatter.timeWithZone(
            for: game.startTime,
            timeZoneOption: viewModel.selectedTimeZone
        )
        return "\(date) · \(time)"
    }

    private func savedProGameStatusText(_ game: SavedProGame) -> String {
        switch game.matchStatus {
        case .live:
            return savedProGameLiveStatusText(game)
        case .halfTime:
            return "HT"
        case .fullTime:
            return "FINAL"
        case .scheduled:
            return "Scheduled"
        }
    }

    private func savedProGameLiveStatusText(_ game: SavedProGame) -> String {
        if savedProGameIsSoccer(game),
           let minute = game.minute,
           minute > 0 {
            return "LIVE \(minute)'"
        }

        if !savedProGameIsSoccer(game),
           let clock = savedProGameNonSoccerClockText(game) {
            return clock
        }

        return "LIVE"
    }

    private func savedProGameIsSoccer(_ game: SavedProGame) -> Bool {
        let text = LiveMatchFilters.normalizedSearchText("\(game.sport) \(game.league) \(game.featuredEventSlug ?? "")")
        guard !text.contains("american football"),
              !text.contains("nfl") else {
            return false
        }
        return text.contains("soccer")
            || text.contains("football")
            || text.contains("fifa")
            || text.contains("world cup")
            || text.contains("uefa")
            || text.contains("friendly")
            || text.contains("nations league")
    }

    private func savedProGameNonSoccerClockText(_ game: SavedProGame) -> String? {
        let trimmed = game.liveClockText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }

        let normalized = LiveMatchFilters.normalizedSearchText(trimmed)
        guard !["live", "ht", "ft", "final", "scheduled", "not started"].contains(normalized) else {
            return nil
        }
        if trimmed.contains(":") {
            return trimmed
        }
        if normalized.hasPrefix("q") || normalized.hasPrefix("p") || normalized.contains("period") {
            return trimmed
        }
        if normalized.hasPrefix("1st") || normalized.hasPrefix("2nd") || normalized.hasPrefix("3rd") || normalized.hasPrefix("4th") {
            return trimmed
        }
        return nil
    }

    private func logSavedProGameStatusDebug(_ game: SavedProGame) {
#if DEBUG
        guard SavedProGameStatusDiagnostics.enabled else { return }
        let resolved = viewModel.savedProGameDisplayStatusDebugSource(for: game)
        let resolvedGame = resolved.game
        print(
            "[SavedProGameStatusDebug] " +
            "gameId=\(resolvedGame.stableKey) " +
            "teams=\"\(resolvedGame.awayTeam) at \(resolvedGame.homeTeam)\" " +
            "rawStatus=\(resolvedGame.rawMatchStatus ?? "nil") " +
            "normalizedStatus=\(resolvedGame.matchStatus.rawValue) " +
            "score=\(resolvedGame.scoreAway)-\(resolvedGame.scoreHome) " +
            "sourceUsed=\"\(resolved.source)\""
        )
#endif
    }

    private func logSavedProGameScoringEventDebug(_ game: SavedProGame) {
        let displayGame = viewModel.currentSavedProGameSnapshot(game)
        LiveScoringEventDebug.log(
            gameId: displayGame.stableKey,
            eventId: displayGame.externalId,
            sport: displayGame.sport,
            sportType: displayGame.liveSportVisualType,
            matchStatus: displayGame.matchStatus,
            rawMatchStatus: displayGame.rawMatchStatus,
            homeTeam: displayGame.homeTeam,
            awayTeam: displayGame.awayTeam,
            timelineEvents: displayGame.timelineEvents ?? [],
            timelineFetched: !(displayGame.timelineEvents ?? []).isEmpty
        )
#if DEBUG
        ScoringTimelineDebug.log(
            gameId: displayGame.stableKey,
            scoreHome: displayGame.scoreHome,
            scoreAway: displayGame.scoreAway,
            homeTeam: displayGame.homeTeam,
            awayTeam: displayGame.awayTeam,
            sportType: displayGame.liveSportVisualType,
            timelineEvents: displayGame.timelineEvents ?? []
        )
#endif
    }

    private func savedProGameShouldShowScore(_ game: SavedProGame) -> Bool {
        if game.matchStatus.isHappeningNow || game.isFinal { return true }
        guard game.matchStatus == .scheduled else { return false }
        let snapshot = viewModel.currentSavedProGameSnapshot(game)
        if let match = viewModel.liveMatches.first(where: { SavedProGame.stableKey(for: $0) == game.stableKey }) {
            return match.scoresAreAvailable
        }
        return snapshot.scoreHome > 0 || snapshot.scoreAway > 0
    }

    private func savedProGameScoreboardSection(
        _ displayGame: SavedProGame,
        isFinal: Bool,
        accent: Color
    ) -> some View {
        let mergedTimelineEvents = goingProMergedTimelineEvents(for: displayGame)
        let timelineSummary = LiveScoringTimelineBuilder.resolvedGoalDisplaySummary(
            sportType: displayGame.liveSportVisualType,
            timelineEvents: mergedTimelineEvents,
            scoreAway: displayGame.scoreAway,
            scoreHome: displayGame.scoreHome,
            awayTeam: displayGame.awayTeam,
            homeTeam: displayGame.homeTeam,
            flagSource: "GoingPro"
        )
        let cardTimelineSummary = LiveCardTimelineBuilder.buildSummary(
            sportType: displayGame.liveSportVisualType,
            timelineEvents: mergedTimelineEvents,
            homeTeam: displayGame.homeTeam,
            awayTeam: displayGame.awayTeam,
            gameId: displayGame.stableKey,
            provider: displayGame.source
        )
        return ProGameScoreBlock(
            awayTeam: displayGame.awayTeam,
            homeTeam: displayGame.homeTeam,
            awayScore: displayGame.scoreAway,
            homeScore: displayGame.scoreHome,
            awayBadgeURL: savedProGameTeamBadgeURL(for: displayGame, team: displayGame.awayTeam),
            homeBadgeURL: savedProGameTeamBadgeURL(for: displayGame, team: displayGame.homeTeam),
            source: "GoingPro",
            league: displayGame.league,
            isFinal: isFinal,
            isLive: displayGame.matchStatus.isHappeningNow,
            accentColor: isFinal ? accent : FGColor.dangerRed,
            timelineSummary: timelineSummary?.hasContent == true ? timelineSummary : nil,
            cardTimelineSummary: cardTimelineSummary,
            gameId: displayGame.stableKey,
            showsFramedFinalBackground: isFinal
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            if isFinal {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(accent.opacity(followingColorScheme == .dark ? 0.30 : 0.18), lineWidth: 1)
            }
        }
        .onAppear {
            logGoingProScorerRenderDebug(
                displayGame: displayGame,
                mergedTimelineEvents: mergedTimelineEvents,
                timelineSummary: timelineSummary,
                latestScoringEvent: nil
            )
        }
        .accessibilityLabel(isFinal ? "Final score \(displayGame.finalScoreSummary)" : displayGame.finalScoreSummary)
    }

    @ViewBuilder
    private func savedProGameLiveEventSummary(_ displayGame: SavedProGame) -> some View {
        let mergedTimelineEvents = goingProMergedTimelineEvents(for: displayGame)
        let timelineSummary = LiveScoringTimelineBuilder.resolvedGoalDisplaySummary(
            sportType: displayGame.liveSportVisualType,
            timelineEvents: mergedTimelineEvents,
            scoreAway: displayGame.scoreAway,
            scoreHome: displayGame.scoreHome,
            awayTeam: displayGame.awayTeam,
            homeTeam: displayGame.homeTeam,
            flagSource: "GoingPro"
        )
        let cardTimelineSummary = LiveCardTimelineBuilder.buildSummary(
            sportType: displayGame.liveSportVisualType,
            timelineEvents: mergedTimelineEvents,
            homeTeam: displayGame.homeTeam,
            awayTeam: displayGame.awayTeam,
            gameId: displayGame.stableKey,
            provider: displayGame.source
        )
        let hasTimeline = timelineSummary?.hasContent == true
        let hasCards = cardTimelineSummary?.hasContent == true
        if hasTimeline || hasCards {
            VStack(alignment: .leading, spacing: 8) {
                if let timelineSummary, timelineSummary.hasContent {
                    ProGameScoringTimelineView(
                        summary: timelineSummary,
                        homeTeam: displayGame.homeTeam,
                        awayTeam: displayGame.awayTeam,
                        gameId: displayGame.stableKey,
                        headingText: timelineSummary.headingText,
                        headingFont: .caption.weight(.bold),
                        lineFont: .caption.weight(.medium),
                        headingColor: FGColor.dangerRed,
                        lineColor: FGColor.primaryText(followingColorScheme),
                        flagSource: "GoingPro"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let cardTimelineSummary, cardTimelineSummary.hasContent {
                    ProGameCardEventsView(
                        summary: cardTimelineSummary,
                        gameId: displayGame.stableKey,
                        headingText: "Cards",
                        headingColor: FGColor.secondaryText(followingColorScheme),
                        lineColor: FGColor.primaryText(followingColorScheme),
                        flagSource: "GoingPro"
                    )
                }
            }
            .padding(.top, 2)
            .onAppear {
                logGoingProScorerRenderDebug(
                    displayGame: displayGame,
                    mergedTimelineEvents: mergedTimelineEvents,
                    timelineSummary: timelineSummary,
                    latestScoringEvent: nil
                )
            }
        }
    }

    private func goingProMergedTimelineEvents(for displayGame: SavedProGame) -> [LiveTimelineEvent] {
        var byKey: [String: LiveTimelineEvent] = [:]
        for event in displayGame.timelineEvents ?? [] {
            byKey[event.id] = event
        }
        for match in goingProHydrationLiveMatches(for: displayGame) {
            for event in match.timelineEvents {
                byKey[event.id] = event
            }
        }
        return Array(byKey.values)
    }

    private func goingProHydrationLiveMatches(for displayGame: SavedProGame) -> [LiveMatch] {
        var matches: [LiveMatch] = []
        if let exact = viewModel.liveMatches.first(where: { SavedProGame.stableKey(for: $0) == displayGame.stableKey }) {
            matches.append(exact)
        }
        if let source = displayGame.source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty,
           let externalId = displayGame.externalId?.trimmingCharacters(in: .whitespacesAndNewlines), !externalId.isEmpty,
           let external = viewModel.liveMatches.first(where: {
               $0.source?.caseInsensitiveCompare(source) == .orderedSame
                   && $0.externalId?.caseInsensitiveCompare(externalId) == .orderedSame
           }),
           !matches.contains(where: { $0.id == external.id }) {
            matches.append(external)
        }
        return matches
    }

    private func goingProResolvedScorerTimelineSummary(
        for displayGame: SavedProGame,
        timelineEvents: [LiveTimelineEvent]
    ) -> LiveScoringTimelineSummary? {
        LiveScoringTimelineBuilder.resolvedGoalDisplaySummary(
            sportType: displayGame.liveSportVisualType,
            timelineEvents: timelineEvents,
            scoreAway: displayGame.scoreAway,
            scoreHome: displayGame.scoreHome,
            awayTeam: displayGame.awayTeam,
            homeTeam: displayGame.homeTeam,
            flagSource: "GoingPro"
        )
    }

    private func goingProResolvedLatestScoringEvent(
        for displayGame: SavedProGame,
        timelineEvents: [LiveTimelineEvent]
    ) -> LiveLatestScoringEvent? {
        if let latest = displayGame.latestScoringEvent {
            return latest
        }
        return LiveScoringEventResolver.resolve(
            sportType: displayGame.liveSportVisualType,
            timelineEvents: timelineEvents
        ).latestEvent
    }

    private func goingProResolvedFirstScoringEvent(
        for displayGame: SavedProGame,
        timelineEvents: [LiveTimelineEvent]
    ) -> LiveFirstScoringEvent? {
        LiveScoringTimelineBuilder.resolveFirstScoringEvent(
            sportType: displayGame.liveSportVisualType,
            timelineEvents: timelineEvents,
            homeTeam: displayGame.homeTeam,
            awayTeam: displayGame.awayTeam,
            scoreAway: displayGame.scoreAway,
            scoreHome: displayGame.scoreHome
        )
    }

    private func logGoingProScorerRenderDebug(
        displayGame: SavedProGame,
        mergedTimelineEvents: [LiveTimelineEvent],
        timelineSummary: LiveScoringTimelineSummary?,
        latestScoringEvent: LiveLatestScoringEvent?
    ) {
        let firstScoringEvent = goingProResolvedFirstScoringEvent(
            for: displayGame,
            timelineEvents: mergedTimelineEvents
        )
        let timelineSummaryEntriesCount = timelineSummary?.entries.count ?? 0
        let renderedGoalScorers = timelineSummaryEntriesCount > 0 || latestScoringEvent != nil
        let firstScoringEventText: String = {
            guard let firstScoringEvent else { return "nil" }
            let minute = firstScoringEvent.minuteText
                ?? firstScoringEvent.minute.map { "\($0)'" }
                ?? "nil"
            return "\(minute) \(firstScoringEvent.teamName)"
        }()
        let latestScoringEventText: String = {
            guard let latestScoringEvent else { return "nil" }
            let clock = latestScoringEvent.gameClock ?? "nil"
            let scorer = latestScoringEvent.scorer ?? "nil"
            return "\(clock) \(scorer)"
        }()
        print("[GoingProScorerRenderDebug] displayGame.id=\(displayGame.id)")
        print("[GoingProScorerRenderDebug] liveMatchId=\(displayGame.stableKey)")
        print("[GoingProScorerRenderDebug] timelineEventsRawCount=\(mergedTimelineEvents.count)")
        print("[GoingProScorerRenderDebug] timelineSummaryEntriesCount=\(timelineSummaryEntriesCount)")
        print("[GoingProScorerRenderDebug] firstScoringEvent=\(firstScoringEventText)")
        print("[GoingProScorerRenderDebug] latestScoringEvent=\(latestScoringEventText)")
        print("[GoingProScorerRenderDebug] renderedGoalScorers=\(renderedGoalScorers)")
    }

    private func savedProGameCardRefreshToken(_ displayGame: SavedProGame) -> String {
        let mergedTimelineEvents = goingProMergedTimelineEvents(for: displayGame)
        let renderedCount = goingProResolvedScorerTimelineSummary(
            for: displayGame,
            timelineEvents: mergedTimelineEvents
        )?.entries.count ?? 0
        let cardCount = LiveCardTimelineBuilder.cardEvents(
            sportType: displayGame.liveSportVisualType,
            timelineEvents: mergedTimelineEvents,
            homeTeam: displayGame.homeTeam,
            awayTeam: displayGame.awayTeam,
            gameId: displayGame.stableKey,
            provider: displayGame.source
        ).count
        return "\(displayGame.stableKey)|\(displayGame.matchStatus.rawValue)|\(displayGame.scoreAway)-\(displayGame.scoreHome)|\(displayGame.minute ?? -1)|\(mergedTimelineEvents.count)|\(renderedCount)|\(cardCount)"
    }

    private func savedProGameTeamBadgeURL(for game: SavedProGame, team: String) -> String? {
        if let match = viewModel.liveMatches.first(where: { SavedProGame.stableKey(for: $0) == game.stableKey }) {
            return match.badgeURL(forTeamName: team)
        }
        if let source = game.source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty,
           let externalId = game.externalId?.trimmingCharacters(in: .whitespacesAndNewlines), !externalId.isEmpty,
           let match = viewModel.liveMatches.first(where: {
               $0.source?.caseInsensitiveCompare(source) == .orderedSame
                   && $0.externalId?.caseInsensitiveCompare(externalId) == .orderedSame
           }) {
            return match.badgeURL(forTeamName: team)
        }
        return nil
    }

    private func statusTint(for game: SavedProGame, fallback: Color) -> Color {
        if game.matchStatus.isHappeningNow { return FGColor.dangerRed }
        if game.isFinal { return FGColor.mutedText(followingColorScheme) }
        return fallback
    }

    private var goingPlayUnifiedListContent: some View {
        let items = goingPlayVisibleItems
        let _: Void = logPickupPerfRender(mode: "Play", rowCount: items.count, renderPath: "LazyVStack+EquatableRenderCard")
        return LazyVStack(alignment: .leading, spacing: 10) {
            if viewModel.isPickupFollowingJoinListRefreshing && !items.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.9)
                    Text(L10n.t("Refreshing games...", languageCode: goingPlayLanguageCode))
                        .font(FGTypography.caption.weight(.medium))
                        .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                }
                .padding(.horizontal, 4)
            }

            Text(L10n.t("going_play_upcoming", languageCode: goingPlayLanguageCode))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(followingColorScheme))
                .accessibilityAddTraits(.isHeader)

            ForEach(items) { item in
                goingPlayFeedRow(item)
            }
        }
    }

    private var goingPlayHostingHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("History", languageCode: goingPlayLanguageCode))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(followingColorScheme))
                .accessibilityAddTraits(.isHeader)
            ForEach(viewModel.myRemovedPickupGamesForSettings) { row in
                SettingsPickupRemovedHistoryCard(
                    viewModel: viewModel,
                    row: row,
                    withdrawnJoinRows: viewModel.pickupOrganizerWithdrawnRequestsByGameId[row.id] ?? [],
                    now: followingMyPickupClockTick,
                    colorScheme: followingColorScheme,
                    useCompactCopy: true
                )
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func goingPlayFeedRow(_ item: GoingPlayFeedItem) -> some View {
        if item.source == .team {
            goingPlayTeamFeedCard(item)
                .id(item.pickupGameId)
        } else if let inviteId = item.inviteId,
                  let invite = viewModel.incomingPickupGameInvites.first(where: { $0.id == inviteId }) {
            EquatableRenderCard(token: pickupInviteRenderToken(for: invite)) {
                pickupGameInviteCard(invite)
            }
            .equatable()
            .id(invite.id)
        } else if let card = item.pickupCard {
            EquatableRenderCard(token: pickupPlayingCardRenderToken(for: card)) {
                pickupGameJoinCard(item, card: card)
            }
            .equatable()
            .id(card.pickupGameId)
            .overlay {
                if viewModel.pendingPickupPlayingHighlightGameID == card.pickupGameId {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(FGColor.accentGreen.opacity(0.95), lineWidth: 2.5)
                        .shadow(color: FGColor.accentGreen.opacity(0.35), radius: 8, y: 0)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(
                .easeInOut(duration: 0.25),
                value: viewModel.pendingPickupPlayingHighlightGameID == card.pickupGameId
            )
        } else if let rowId = item.hostedRowId,
                  let row = goingPickupHostingGamesForDisplay.first(where: { $0.id == rowId })
                    ?? viewModel.myPickupGamesForSettings.first(where: { $0.id == rowId }) {
            goingPlayHostedPickupRow(item, row: row)
        }
    }

    private func goingPlayTeamFeedCard(_ item: GoingPlayFeedItem) -> some View {
        let resolved = viewModel.resolvedPickupGameRow(for: item.pickupGameId)
        let dateTimeLine: String = {
            if let resolved, let line = resolved.pickupDateWithCompactTimeRange(languageCode: appLanguageRaw) {
                return line
            }
            if !item.dateTimeLine.isEmpty { return item.dateTimeLine }
            return item.startAt.formatted(
                Date.FormatStyle.dateTime.month(.abbreviated).day().year().hour().minute()
                    .locale(Locale(identifier: goingPlayLanguageCode.replacingOccurrences(of: "-", with: "_")))
            )
        }()
        let location = resolved.map(locationLineForGoingPlay) ?? item.locationLine
        let display = item.withPresentation(dateTimeLine: dateTimeLine, locationLine: location)
        return GoingPlayTeamCard(
            item: display,
            dateTimeLine: dateTimeLine,
            languageCode: goingPlayLanguageCode,
            colorScheme: followingColorScheme,
            onOpen: { openGoingPlayTeamEvent(item) },
            onViewEvent: { openGoingPlayTeamEvent(item) }
        ) {
            goingPlayTeamOverflowMenu(item, resolved: resolved)
        }
    }

    @ViewBuilder
    private func goingPlayTeamOverflowMenu(
        _ item: GoingPlayFeedItem,
        resolved: PickupGameRow?
    ) -> some View {
        Menu {
            if let card = item.pickupCard, card.pill == .approved {
                Button(role: .destructive) {
                    let rid = viewModel.pickupJoinRequestLatestByPickupGameIdForFan[card.pickupGameId]?.id ?? card.id
                    followingPickupWithdrawConfirm = PickupJoinWithdrawConfirmState(
                        requestId: rid,
                        pickupGameId: card.pickupGameId,
                        intent: .approved
                    )
                } label: {
                    Text(L10n.t("Can’t make it", languageCode: goingPlayLanguageCode))
                }
            }
            if item.hostedRowId != nil, let row = resolved {
                Button {
                    logFollowingMyPickupGames(action: "editTap", selectedGameId: row.id)
                    followingMyPickupFormMode = .edit(row)
                } label: {
                    Label(L10n.t("Edit", languageCode: goingPlayLanguageCode), systemImage: "pencil")
                }
                Button {
                    logFollowingMyPickupGames(action: "inviteTap", selectedGameId: row.id)
                    followingPickupInviteGame = row
                } label: {
                    Label(L10n.t("Invite", languageCode: goingPlayLanguageCode), systemImage: "envelope")
                }
                Button {
                    logFollowingMyPickupGames(action: "manageRequestsTap", selectedGameId: row.id)
                    followingMyPickupOrganizerRequestsGame = row
                } label: {
                    Label(L10n.t("Manage requests", languageCode: goingPlayLanguageCode), systemImage: "person.badge.plus")
                }
                Button(role: .destructive) {
                    logFollowingMyPickupGames(action: "cancelGameTap", selectedGameId: row.id)
                    followingMyPickupDeleteTarget = row
                } label: {
                    Label(L10n.t("Delete", languageCode: goingPlayLanguageCode), systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(L10n.t("More", languageCode: goingPlayLanguageCode))
    }

    private func openGoingPlayTeamEvent(_ item: GoingPlayFeedItem) {
        let teamId = item.teamIdentity?.teamId
        if let teamId {
            viewModel.openGoingPlayTeamEvent(teamId: teamId, pickupGameId: item.pickupGameId)
            return
        }
        pickupDetailNav = viewModel.pickupDetailNavigationToken(for: item.pickupGameId)
    }

    private func locationLineForGoingPlay(_ row: PickupGameRow) -> String {
        FanTeamScheduleLocationPresentation.displayLocation(
            venueName: nil,
            address: row.address,
            city: row.city,
            state: row.state
        )
    }

    private func goingPlayHostedPickupRow(_ item: GoingPlayFeedItem, row: PickupGameRow) -> some View {
        let pendingHere = viewModel.organizerPendingPickupJoinRequests(for: row.id)
        let withdrawnRows = viewModel.pickupOrganizerWithdrawnRequestsByGameId[row.id] ?? []
        let dateTimeLine = row.pickupDateWithCompactTimeRange(languageCode: appLanguageRaw) ?? item.dateTimeLine
        let location = locationLineForGoingPlay(row)
        let display = item.withPresentation(dateTimeLine: dateTimeLine, locationLine: location)
        let now = followingMyPickupClockTick
        let started = row.hasPickupGameStarted(now: now)
        return EquatableRenderCard(
            token: PickupHostedCardRenderToken(
                row: row,
                pendingJoinCount: pendingHere,
                withdrawnJoinRows: withdrawnRows,
                now: now,
                colorScheme: followingColorScheme
            )
        ) {
            GoingPlayPickupCard(
                item: display,
                dateTimeLine: dateTimeLine,
                locationLine: location,
                spotsLine: pickupLocalizedSpotsOpen(row.pickupOpenSlotsRemaining, languageCode: appLanguageRaw),
                organizerName: nil,
                showStarted: started,
                languageCode: goingPlayLanguageCode,
                colorScheme: followingColorScheme,
                onOpen: {
                    logFollowingMyPickupGames(action: "openDetailSheet", selectedGameId: row.id)
                    followingMyPickupDetailGame = row
                },
                onViewDetails: {
                    logFollowingMyPickupGames(action: "openDetailSheet", selectedGameId: row.id)
                    followingMyPickupDetailGame = row
                }
            ) {
                goingPlayTeamOverflowMenu(item, resolved: row)
            } extra: {
                EmptyView()
            }
        }
        .equatable()
        .id(row.id)
    }

    @ViewBuilder
    private var incomingPickupGameInvitesContent: some View {
        if !viewModel.incomingPickupGameInvites.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(goingPlayInviteItems) { item in
                    if let invite = viewModel.incomingPickupGameInvites.first(where: { $0.id == item.inviteId }) {
                        EquatableRenderCard(token: pickupInviteRenderToken(for: invite)) {
                            pickupGameInviteCard(invite)
                        }
                        .equatable()
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
            }
        }
    }

    private func pickupInviteRenderToken(for item: PickupGameInviteDisplay) -> PickupInviteRenderToken {
        PickupInviteRenderToken(
            id: item.id,
            game: item.game,
            inviterName: pickupInviteInviterName(item),
            inviterAvatarThumbnailURL: ImageDisplayURL.canonicalStorageURLString(item.inviterProfile?.avatar_thumbnail_url),
            inviterAvatarURL: ImageDisplayURL.canonicalStorageURLString(item.inviterProfile?.avatar_url),
            isBusy: pickupInviteResponseInFlightId == item.id,
            colorScheme: followingColorScheme
        )
    }

    private func pickupGameInviteCard(_ item: PickupGameInviteDisplay) -> some View {
        let game = item.game
        let inviterName = pickupInviteInviterName(item)
        let location = GoingPlayProjection.locationLine(for: game)
        let isBusy = pickupInviteResponseInFlightId == item.id

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                pickupInviteInviterAvatar(item, size: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(inviterName) invited you")
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                    HStack(alignment: .top, spacing: 8) {
                        SportArtworkIconView(sport: game.sport, diameter: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(game.title)
                                .font(FGTypography.cardTitle)
                                .foregroundStyle(FGColor.primaryText(followingColorScheme))
                                .lineLimit(2)
                            GameFormatBadgeView(format: game.gameFormat, colorScheme: followingColorScheme)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            if let dateLine = game.pickupDateWithCompactTimeRange(languageCode: appLanguageRaw) {
                Label(dateLine, systemImage: "calendar")
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(followingColorScheme))
            }
            if !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                    .lineLimit(2)
            }
            Label(spotsOpenLine(for: game), systemImage: "person.3")
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(followingColorScheme))

            Button {
                followingPickupInviteDetail = item
            } label: {
                HStack(spacing: 6) {
                    Text("View invite details")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.accentBlue)
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                pickupInviteResponseButton("Accept", tint: FGColor.accentGreen, disabled: isBusy) {
                    await respondToPickupInvite(item, status: "accepted")
                }
                pickupInviteResponseButton("Maybe", tint: Color.orange, disabled: isBusy) {
                    await respondToPickupInvite(item, status: "maybe")
                }
                pickupInviteResponseButton("Decline", tint: Color.red.opacity(0.9), disabled: isBusy) {
                    await respondToPickupInvite(item, status: "declined")
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.orange.opacity(followingColorScheme == .dark ? 0.38 : 0.24), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture {
            followingPickupInviteDetail = item
        }
    }

    private func pickupInviteResponseButton(
        _ title: String,
        tint: Color,
        disabled: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            if disabled {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                Text(title)
                    .font(FGTypography.metadata.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .disabled(disabled)
    }

    private func respondToPickupInvite(_ item: PickupGameInviteDisplay, status: String) async {
        pickupInviteResponseInFlightId = item.id
        let priorInvites = viewModel.incomingPickupGameInvites
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            viewModel.incomingPickupGameInvites.removeAll { $0.id == item.id }
        }
        if status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "accepted" {
            FGInteractionHaptics.success()
        } else {
            FGInteractionHaptics.selection()
        }
        defer {
            pickupInviteResponseInFlightId = nil
            if viewModel.incomingPickupGameInvites.isEmpty && priorInvites.count > 1 {
                Task { await viewModel.loadIncomingPickupGameInvites() }
            }
        }
        await viewModel.respondToPickupGameInvite(item.invite, status: status)
    }

    private func pickupInviteInviterAvatar(_ item: PickupGameInviteDisplay, size: CGFloat) -> some View {
        UserAvatarView(
            avatarThumbnailURL: ImageDisplayURL.canonicalStorageURLString(item.inviterProfile?.avatar_thumbnail_url),
            avatarURL: ImageDisplayURL.canonicalStorageURLString(item.inviterProfile?.avatar_url),
            avatarDisplayRefreshToken: UserAvatarView.stableRefreshToken(
                userId: item.invite.inviter_user_id,
                thumbnailURL: item.inviterProfile?.avatar_thumbnail_url,
                avatarURL: item.inviterProfile?.avatar_url
            ),
            displayName: pickupInviteInviterName(item),
            email: item.inviterProfile?.email ?? "",
            size: size,
            fallbackStyle: followingColorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome
        )
    }

    private func pickupInviteInviterName(_ item: PickupGameInviteDisplay) -> String {
        let display = item.inviterProfile?.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !display.isEmpty { return display }
        let username = item.inviterProfile?.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !username.isEmpty { return username }
        return "A friend"
    }

    private func spotsOpenLine(for game: PickupGameRow) -> String {
        let open = game.pickupOpenSlotsRemaining
        return pickupLocalizedSpotsOpen(open, languageCode: appLanguageRaw)
    }

    private var hostedGamesListContent: some View {
        let hostingRowCount = goingPickupHostingGamesForDisplay.count + viewModel.myRemovedPickupGamesForSettings.count
        let _: Void = logPickupPerfRender(mode: "Hosting", rowCount: hostingRowCount, renderPath: "LazyVStack+EquatableRenderCard")
        return LazyVStack(alignment: .leading, spacing: 12) {
            if goingPlayHostingItems.isEmpty, viewModel.myRemovedPickupGamesForSettings.isEmpty {
                hostingEmptyStateCard
            } else {
                ForEach(goingPlayHostingItems) { item in
                    goingPlayFeedRow(item)
                }

                if !viewModel.myRemovedPickupGamesForSettings.isEmpty {
                    Text("History")
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    ForEach(viewModel.myRemovedPickupGamesForSettings) { row in
                        SettingsPickupRemovedHistoryCard(
                            viewModel: viewModel,
                            row: row,
                            withdrawnJoinRows: viewModel.pickupOrganizerWithdrawnRequestsByGameId[row.id] ?? [],
                            now: followingMyPickupClockTick,
                            colorScheme: followingColorScheme,
                            useCompactCopy: true
                        )
                    }
                }
            }
        }
    }

    private func pickupPlayingCardRenderToken(for card: PickupGameJoinRequestCardDisplay) -> PickupPlayingCardRenderToken {
        let resolvedGame = viewModel.resolvedPickupGameRow(for: card.pickupGameId)
        return PickupPlayingCardRenderToken(
            card: card,
            resolvedGame: resolvedGame,
            organizerAvatarThumbnailURL: viewModel.pickupOrganizerAvatarThumbnailForDetail(userId: card.organizerUserId),
            organizerAvatarURL: viewModel.pickupOrganizerAvatarFullForDetail(userId: card.organizerUserId),
            organizerAvatarRefreshToken: viewModel.pickupOrganizerAvatarRefreshTokenForDetail(userId: card.organizerUserId),
            organizerEmail: viewModel.pickupOrganizerEmailForDetail(userId: card.organizerUserId),
            currentUserId: viewModel.currentUserAuthId,
            hasUnreadActivity: viewModel.pickupFollowingUnreadActivityGameIds.contains(card.pickupGameId),
            isRefreshSpinning: viewModel.pickupFollowingCardRefreshSpinGameId == card.pickupGameId,
            isWithdrawInFlight: followingPickupWithdrawInFlight,
            lastJoinStatusRefreshAt: viewModel.lastJoinStatusRefreshAt,
            isHighlightedFromRatingNotification: viewModel.pendingPickupPlayingHighlightGameID == card.pickupGameId,
            colorScheme: followingColorScheme
        )
    }

    /// Going → Play → Playing for a pickup rating notification tap; scrolls and briefly highlights the card.
    private func fulfillPickupCreatorRatingNotificationDeepLink(
        pickupGameId: UUID,
        scrollProxy: ScrollViewProxy
    ) {
        selectedGoingMode = .pickupGames
        selectedGoingPlayFilter = .all
        goingDayScope = .all
        sanitizeBusinessGoingModeIfNeeded()
        viewModel.pendingPickupPlayingHighlightGameID = pickupGameId
        viewModel.clearPendingPickupCreatorRatingNotificationDeepLink()

        Task { @MainActor in
            await viewModel.loadMyPickupGameJoinRequestsForFollowing(
                forceRefresh: false,
                reason: "pickupCreatorRatingDeepLink"
            )
            await viewModel.refreshMyPickupCreatorRatingsForPickupGames(pickupGameIds: [pickupGameId])
            // Yield so Playing list / rating prompt can mount before scroll.
            await Task.yield()
            try? await Task.sleep(nanoseconds: 180_000_000)
            withAnimation(.easeInOut(duration: 0.35)) {
                scrollProxy.scrollTo(pickupGameId, anchor: .center)
            }
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if viewModel.pendingPickupPlayingHighlightGameID == pickupGameId {
                viewModel.clearPendingPickupPlayingHighlightGameID()
            }
        }
    }

    private var hostingEmptyStateCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "sportscourt.fill")
                .font(.largeTitle)
                .foregroundStyle(FGColor.secondaryText(followingColorScheme))

            Text("No games you’re hosting yet.")
                .font(FGTypography.cardTitle)
                .foregroundStyle(FGColor.primaryText(followingColorScheme))

            Text("Create a game when you’re ready to play.")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                .multilineTextAlignment(.center)

            Button {
                openCreatePickupFromGoing()
            } label: {
                Text("Create Game")
                    .font(FGTypography.metadata.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(FGColor.intentPlay)
            .padding(.top, 2)
            .accessibilityLabel("Create Game")
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .modifier(FollowingCardChromeModifier(colorScheme: followingColorScheme, cornerRadius: 22))
    }

    // MARK: - Session / cache (Following tab only)

    private func clearFollowingUserSpecificState() {
        viewModel.clearFollowingTabCaches()
        viewModel.favoriteVenueIDs = []
        viewModel.venueEventInterestIDs = []
        viewModel.interestedVenueEventKeys = []
        viewModel.incomingPickupGameInvites = []
        viewModel.favoriteTeamProGames = []
        viewModel.clearBusinessFavoriteTeamState()
    }

    private func reloadFollowingDataForCurrentUser() async {
        if isBusinessProGamesOnly {
            await reloadBusinessProGamesData(reason: "authOrInitialReload")
            return
        }
        await viewModel.fetchSavedProGames(reason: "authOrInitialReload")
        await viewModel.refreshFollowingTabDataGloballyUnlessFresh()
        await viewModel.loadMyPickupGameJoinRequestsForFollowing(
            reason: "authOrInitialReload"
        )
        await viewModel.loadIncomingPickupGameInvites()
        await refreshFavoriteTeamProGames(reason: "authOrInitialReload")
    }

    private func reloadBusinessProGamesData(reason: String) async {
        sanitizeBusinessGoingModeIfNeeded()
        if reason == "pullToRefresh" {
            await viewModel.refreshGoingProGames(reason: reason)
        } else {
            await viewModel.fetchSavedProGames(reason: reason)
        }
        if let businessId = await MainActor.run(body: { viewModel.currentBusinessIdForAddLocation() }) {
            await viewModel.loadBusinessFavoriteTeams(businessId: businessId)
        }
        await refreshBusinessFavoriteTeamProGames(reason: reason, forceRefresh: reason == "pullToRefresh")
    }

#if DEBUG
    private func logFollowingMyPickupGames(action: String, selectedGameId: UUID? = nil) {
        let active = viewModel.myPickupGamesForSettings.count
        let hist = viewModel.myRemovedPickupGamesForSettings.count
        print("[FollowingMyPickupGames] loadedCount=\(active + hist)")
        print("[FollowingMyPickupGames] activeCount=\(active)")
        print("[FollowingMyPickupGames] historyCount=\(hist)")
        if let id = selectedGameId {
            print("[FollowingMyPickupGames] selectedGameId=\(id.uuidString.lowercased())")
        } else {
            print("[FollowingMyPickupGames] selectedGameId=")
        }
        print("[FollowingMyPickupGames] action=\(action)")
    }
#else
    private func logFollowingMyPickupGames(action: String, selectedGameId: UUID? = nil) {
        _ = action
        _ = selectedGameId
    }
#endif

    private func logPickupPerfRender(mode: String, rowCount: Int, renderPath: String) {
#if DEBUG
        print("[PickupPerf] screen=Going mode=\(mode) rowCount=\(rowCount) renderPath=\(renderPath) freshnessSkip=false forcedReload=false")
#else
        _ = mode
        _ = rowCount
        _ = renderPath
#endif
    }

    private func openCreatePickupFromGoing() {
        guard viewModel.canFanUsePickupGamesUI else { return }
        logGoingHubDebug(reason: "createPickupTapped", createPickupTapped: true)
        followingMyPickupFormMode = .add
    }

    private func openHostedPickupGameOnDiscoverMap(_ row: PickupGameRow) {
        logFollowingMyPickupGames(action: "openMap", selectedGameId: row.id)
        viewModel.requestDiscoverFocusForPickupGame(id: row.id, snapshot: row)
    }

    private func openPlayingPickupGameOnDiscoverMap(_ card: PickupGameJoinRequestCardDisplay) {
        logFollowingMyPickupGames(action: "openPlayingMap", selectedGameId: card.pickupGameId)
        viewModel.requestDiscoverFocusForPickupGame(
            id: card.pickupGameId,
            snapshot: viewModel.resolvedPickupGameRow(for: card.pickupGameId)
        )
    }

#if DEBUG
    private func logGoingHubDebug(reason: String, createPickupTapped: Bool = false) {
        print("[GoingStructureDebug] venueGamesGoingCount=\(goingVenueGameItems.count)")
        print("[GoingStructureDebug] favoriteVenuesCount=\(viewModel.followingTabSavedVenues.count)")
        print("[GoingStructureDebug] pickupPlayingCount=\(viewModel.myPickupGameJoinRequestCards.count)")
        print("[GoingStructureDebug] pickupHostingCount=\(viewModel.myPickupGamesForSettings.count)")
        print("[GoingStructureDebug] hostPickupTapped=\(createPickupTapped)")
        let emptySections = goingStructureEmptySections()
        if emptySections.isEmpty {
            print("[GoingStructureDebug] sectionEmptyState=none")
        } else {
            for section in emptySections {
                print("[GoingStructureDebug] sectionEmptyState=\(section)")
            }
        }
        print("[GoingStructureDebug] reason=\(reason)")
    }
#else
    private func logGoingHubDebug(reason: String, createPickupTapped: Bool = false) {
        _ = reason
        _ = createPickupTapped
    }
#endif

    private func goingStructureEmptySections() -> [String] {
        var sections: [String] = []
        if goingVenueGameItems.isEmpty { sections.append("I’m Going") }
        if viewModel.followingTabSavedVenues.isEmpty { sections.append("Saved") }
        if viewModel.myPickupGameJoinRequestCards.isEmpty { sections.append("Playing") }
        if viewModel.myPickupGamesForSettings.isEmpty { sections.append("Hosting") }
        return sections
    }

    private func runFollowingHostedPickupAutoClearIfNeeded(now: Date, reason: String) {
        let anyPast = viewModel.myPickupGamesForSettings.contains {
            PickupHostingAutoClear.isPastDeadline(row: $0, now: now)
        }
        guard anyPast else { return }
        Task {
            await viewModel.clearExpiredHostedPickupGamesIfNeeded(now: now, reason: reason)
            logFollowingMyPickupGames(action: "hostedAutoClearPass")
        }
    }

    private func performFollowingMyPickupDelete(_ row: PickupGameRow) async {
        do {
            try await viewModel.clearHostedPickupGame(id: row.id, reason: "followingManualClear")
            followingMyPickupBanner = nil
            await viewModel.loadMyPickupGamesForSettings(forceRefresh: true, reason: "followingDeleteSuccess")
            await viewModel.refreshPickupGamesForDiscoverMap(force: true)
            logFollowingMyPickupGames(action: "deleteGameSuccess", selectedGameId: row.id)
        } catch {
            followingMyPickupBanner = error.localizedDescription
            logFollowingMyPickupGames(action: "deleteGameFailed", selectedGameId: row.id)
        }
    }

    // MARK: - Attendance actions

    private func setInterestedOnlyLocally(_ venueEventID: UUID, _ add: Bool) {
        var set = decodeInterestedOnlyUUIDs(from: interestedOnlyEncoded)
        if add {
            set.insert(venueEventID)
        } else {
            set.remove(venueEventID)
        }
        interestedOnlyEncoded = encodeInterestedOnlyUUIDs(set)
    }

    @MainActor
    private func applyAttendance(_ item: FollowingGoingDisplayItem, target: FollowingAttendanceTarget) async {
        guard viewModel.isAuthenticatedForSocialFeatures else { return }

        let previousInterestedOnly = interestedOnlyEncoded
        let previousGoingItems = viewModel.followingTabGoingItems
        let previousCachedGoingItems = cachedGoingVenueGameItems
        let previousGoingInterestCounts = viewModel.followingTabGoingInterestCounts
        let previousServerGoingIDs = viewModel.followingTabUserVenueEventInterestIDs
        let oldStatus = item.goingTabStatusDebugValue
        let newStatus = target.goingTabStatusDebugValue
        var ok = true

#if DEBUG
        print("[FollowingState] attendance action event=\(item.id.uuidString) action=\(target)")
#endif

        switch target {
        case .going:
            if item.isServerGoing && !item.isInterestedOnlyLocal {
                logGoingTabStatusDebug(
                    eventID: item.id,
                    oldStatus: oldStatus,
                    newStatus: newStatus,
                    includedInGoingTab: true,
                    optimisticUpdate: false,
                    backendSaved: true
                )
                logGoingStatusOptimistic(
                    before: oldStatus,
                    after: newStatus,
                    eventID: item.id,
                    localUpdated: false,
                    backendSynced: true,
                    rollback: false
                )
                return
            }
            setInterestedOnlyLocally(item.id, false)
            applyOptimisticGoingTabAttendance(item, target: target)
            logGoingStatusOptimistic(
                before: oldStatus,
                after: newStatus,
                eventID: item.id,
                localUpdated: true,
                backendSynced: nil,
                rollback: false
            )
            logGoingTabStatusDebug(
                eventID: item.id,
                oldStatus: oldStatus,
                newStatus: newStatus,
                includedInGoingTab: true,
                optimisticUpdate: true,
                backendSaved: nil
            )
            ok = await syncGoingStatusToBackend(eventID: item.id, isGoing: true)
        case .interested:
            if !item.isServerGoing && item.isInterestedOnlyLocal {
                logGoingTabStatusDebug(
                    eventID: item.id,
                    oldStatus: oldStatus,
                    newStatus: newStatus,
                    includedInGoingTab: true,
                    optimisticUpdate: false,
                    backendSaved: true
                )
                logGoingStatusOptimistic(
                    before: oldStatus,
                    after: newStatus,
                    eventID: item.id,
                    localUpdated: false,
                    backendSynced: true,
                    rollback: false
                )
                return
            }
            setInterestedOnlyLocally(item.id, true)
            applyOptimisticGoingTabAttendance(item, target: target)
            logGoingStatusOptimistic(
                before: oldStatus,
                after: newStatus,
                eventID: item.id,
                localUpdated: true,
                backendSynced: nil,
                rollback: false
            )
            logGoingTabStatusDebug(
                eventID: item.id,
                oldStatus: oldStatus,
                newStatus: newStatus,
                includedInGoingTab: true,
                optimisticUpdate: true,
                backendSaved: nil
            )
            if item.isServerGoing {
                ok = await syncGoingStatusToBackend(eventID: item.id, isGoing: false)
            }
        case .notGoing:
            guard item.isActiveGoingTabPlan else {
                logGoingTabStatusDebug(
                    eventID: item.id,
                    oldStatus: oldStatus,
                    newStatus: newStatus,
                    includedInGoingTab: false,
                    optimisticUpdate: false,
                    backendSaved: true
                )
                logGoingStatusOptimistic(
                    before: oldStatus,
                    after: newStatus,
                    eventID: item.id,
                    localUpdated: false,
                    backendSynced: true,
                    rollback: false
                )
                return
            }
            setInterestedOnlyLocally(item.id, false)
            applyOptimisticGoingTabAttendance(item, target: target)
            logGoingStatusOptimistic(
                before: oldStatus,
                after: newStatus,
                eventID: item.id,
                localUpdated: true,
                backendSynced: nil,
                rollback: false
            )
            logGoingTabStatusDebug(
                eventID: item.id,
                oldStatus: oldStatus,
                newStatus: newStatus,
                includedInGoingTab: false,
                optimisticUpdate: true,
                backendSaved: nil
            )
            if item.isServerGoing {
                ok = await syncGoingStatusToBackend(eventID: item.id, isGoing: false)
            }
        }

        guard ok else {
#if DEBUG
            print("[FollowingState] attendance update failed event=\(item.id.uuidString) action=\(target)")
#endif
            interestedOnlyEncoded = previousInterestedOnly
            viewModel.followingTabGoingItems = previousGoingItems
            cachedGoingVenueGameItems = previousCachedGoingItems
            viewModel.followingTabGoingInterestCounts = previousGoingInterestCounts
            viewModel.followingTabUserVenueEventInterestIDs = previousServerGoingIDs
            viewModel.refreshFollowingInterestDerivedSnapshotsForUI()
            logGoingStatusOptimistic(
                before: oldStatus,
                after: newStatus,
                eventID: item.id,
                localUpdated: false,
                backendSynced: false,
                rollback: true
            )
            logGoingTabStatusDebug(
                eventID: item.id,
                oldStatus: oldStatus,
                newStatus: newStatus,
                includedInGoingTab: item.isActiveGoingTabPlan,
                optimisticUpdate: false,
                backendSaved: false
            )
            viewModel.showSocialActionToast("Couldn't update your game plan.")
            return
        }
        logGoingTabStatusDebug(
            eventID: item.id,
            oldStatus: oldStatus,
            newStatus: newStatus,
            includedInGoingTab: target.isIncludedInGoingTab,
            optimisticUpdate: false,
            backendSaved: true
        )
        logGoingStatusOptimistic(
            before: oldStatus,
            after: newStatus,
            eventID: item.id,
            localUpdated: true,
            backendSynced: true,
            rollback: false
        )
        if target == .going {
            // Optimistic Going path uses max(attendeeCount + 1, 1) when newly going,
            // so followingTabGoingInterestCounts already includes the current user.
            let total = viewModel.followingTabGoingInterestCounts[item.id]
                ?? viewModel.interestCountForVenueEvent(item.id)
            let includesSelf = viewModel.followingTabUserVenueEventInterestIDs.contains(item.id)
                || viewModel.isInterestedInVenueEvent(item.id)
            viewModel.presentGoingWowMoment(
                totalGoingCount: total,
                includesCurrentUser: includesSelf,
                venueEventID: item.id
            )
        }
#if DEBUG
        switch target {
        case .going:
            print("[FollowingState] marked going")
        case .interested:
            print("[FollowingState] marked interested")
        case .notGoing:
            print("[FollowingState] marked not going, removed from following")
        }
#endif
    }

    private func syncGoingStatusToBackend(eventID: UUID, isGoing: Bool) async -> Bool {
        await viewModel.setVenueEventInterest(
            venueEventID: eventID,
            isInterested: isGoing,
            refreshFollowing: false,
            applyOptimistic: false,
            manageWriteInFlight: true,
            schedulePostWriteRefreshes: false,
            applyLocalSuccessState: false
        )
    }

    @MainActor
    private func applyOptimisticGoingTabAttendance(_ item: FollowingGoingDisplayItem, target: FollowingAttendanceTarget) {
        let attendeeCount = optimisticAttendeeCount(for: item, target: target)
        switch target {
        case .going:
            viewModel.followingTabUserVenueEventInterestIDs.insert(item.id)
            upsertOptimisticGoingTabItem(
                item,
                attendeeCount: attendeeCount,
                isServerGoing: true,
                isInterestedOnlyLocal: false
            )
        case .interested:
            viewModel.followingTabUserVenueEventInterestIDs.remove(item.id)
            upsertOptimisticGoingTabItem(
                item,
                attendeeCount: attendeeCount,
                isServerGoing: false,
                isInterestedOnlyLocal: true
            )
        case .notGoing:
            viewModel.followingTabUserVenueEventInterestIDs.remove(item.id)
            viewModel.followingTabGoingItems.removeAll { $0.id == item.id }
            cachedGoingVenueGameItems.removeAll { $0.id == item.id }
        }
        applyOptimisticGoingTabInterestCount(eventID: item.id, attendeeCount: attendeeCount)
        viewModel.followingTabGoingItems = MapViewModel.sortFollowingGoingItemsChronologically(viewModel.followingTabGoingItems)
        cachedGoingVenueGameItems = MapViewModel.sortFollowingGoingItemsChronologically(cachedGoingVenueGameItems)
        viewModel.refreshFollowingInterestDerivedSnapshotsForUI()
    }

    @MainActor
    private func upsertOptimisticGoingTabItem(
        _ item: FollowingGoingDisplayItem,
        attendeeCount: Int,
        isServerGoing: Bool,
        isInterestedOnlyLocal: Bool
    ) {
        let updated = FollowingGoingDisplayItem(
            id: item.id,
            venueEvent: item.venueEvent,
            bar: item.bar,
            attendeeCount: attendeeCount,
            isServerGoing: isServerGoing,
            isInterestedOnlyLocal: isInterestedOnlyLocal
        )
        if let index = viewModel.followingTabGoingItems.firstIndex(where: { $0.id == item.id }) {
            viewModel.followingTabGoingItems[index] = updated
        } else {
            viewModel.followingTabGoingItems.append(updated)
        }
        if let index = cachedGoingVenueGameItems.firstIndex(where: { $0.id == item.id }) {
            cachedGoingVenueGameItems[index] = updated
        } else {
            cachedGoingVenueGameItems.append(updated)
        }
    }

    private func optimisticAttendeeCount(for item: FollowingGoingDisplayItem, target: FollowingAttendanceTarget) -> Int {
        switch target {
        case .going:
            return item.isServerGoing ? item.attendeeCount : max(item.attendeeCount + 1, 1)
        case .interested:
            return item.isServerGoing ? max(item.attendeeCount - 1, 0) : item.attendeeCount
        case .notGoing:
            return item.isServerGoing ? max(item.attendeeCount - 1, 0) : item.attendeeCount
        }
    }

    @MainActor
    private func applyOptimisticGoingTabInterestCount(eventID: UUID, attendeeCount: Int) {
        if attendeeCount > 0 {
            viewModel.followingTabGoingInterestCounts[eventID] = attendeeCount
        } else {
            viewModel.followingTabGoingInterestCounts.removeValue(forKey: eventID)
        }
    }

    private func logGoingTabStatusDebug(
        eventID: UUID,
        oldStatus: String,
        newStatus: String,
        includedInGoingTab: Bool,
        optimisticUpdate: Bool,
        backendSaved: Bool?
    ) {
#if DEBUG
        print("[GoingTabStatusDebug] eventID=\(eventID.uuidString.lowercased())")
        print("[GoingTabStatusDebug] oldStatus=\(oldStatus)")
        print("[GoingTabStatusDebug] newStatus=\(newStatus)")
        print("[GoingTabStatusDebug] includedInGoingTab=\(includedInGoingTab)")
        print("[GoingTabStatusDebug] optimisticUpdate=\(optimisticUpdate)")
        print("[GoingTabStatusDebug] backendSaved=\(backendSaved.map { String($0) } ?? "pending")")
#endif
    }

    private func logGoingStatusOptimistic(
        before: String,
        after: String,
        eventID: UUID,
        localUpdated: Bool,
        backendSynced: Bool?,
        rollback: Bool
    ) {
#if DEBUG
        print("[GoingStatusOptimistic] before=\(before) after=\(after) eventId=\(eventID.uuidString.lowercased()) localUpdated=\(localUpdated) backendSynced=\(backendSynced.map { String($0) } ?? "pending") rollback=\(rollback)")
#endif
    }

    // MARK: - Shared UI pieces

    private func pickupGameJoinCard(_ item: GoingPlayFeedItem, card: PickupGameJoinRequestCardDisplay) -> some View {
        let resolvedGame = viewModel.resolvedPickupGameRow(for: card.pickupGameId)
        let now = Date()
        let pickupStarted = resolvedGame?.hasPickupGameStarted(now: now)
            ?? PickupGameModels.parseSupabaseTimestamptz(card.game_start_at).map { now >= $0 }
            ?? false
        let isOrganizerCanceled = card.pill == .canceledByOrganizer
        let isRejected = card.pill == .declined
        let isApprovedCompleted = card.pill == .approved && (resolvedGame.map {
            GoingTabCompletedGameVisibility.isPickupGameCompleted($0, now: now)
        } ?? false)
        let showsCantMakeIt = card.pill == .approved && !isApprovedCompleted && !isOrganizerCanceled
        let shareGame: PickupGameRow? = {
            guard let game = resolvedGame, game.isEligibleForInAppShare() else { return nil }
            return game
        }()
        let dateTimeLine = resolvedGame?
            .pickupDateWithCompactTimeRange(languageCode: appLanguageRaw)
            ?? card.dateTimeLine
        let location = resolvedGame.map(locationLineForGoingPlay) ?? card.locationLine
        let spots: String? = {
            guard !isOrganizerCanceled else { return nil }
            if let resolvedGame {
                return pickupLocalizedSpotsOpen(resolvedGame.pickupOpenSlotsRemaining, languageCode: appLanguageRaw)
            }
            return card.spotsRemainingSummary
        }()
        var display = item.withPresentation(dateTimeLine: dateTimeLine, locationLine: location)
        if isApprovedCompleted {
            display = display.withParticipation(.completed)
        }
        let avatar = AnyView(
            PublicProfileAvatarTap(userId: card.organizerUserId, context: "following_pickup_organizer") {
                UserAvatarView(
                    avatarThumbnailURL: viewModel.pickupOrganizerAvatarThumbnailForDetail(userId: card.organizerUserId),
                    avatarURL: viewModel.pickupOrganizerAvatarFullForDetail(userId: card.organizerUserId),
                    avatarDisplayRefreshToken: viewModel.pickupOrganizerAvatarRefreshTokenForDetail(userId: card.organizerUserId),
                    displayName: card.organizerName,
                    email: viewModel.pickupOrganizerEmailForDetail(userId: card.organizerUserId),
                    size: 28,
                    fallbackStyle: followingColorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome
                )
            }
        )
        return GoingPlayPickupCard(
            item: display,
            dateTimeLine: dateTimeLine,
            locationLine: location,
            spotsLine: spots,
            organizerName: card.organizerName,
            showStarted: pickupStarted,
            languageCode: goingPlayLanguageCode,
            colorScheme: followingColorScheme,
            organizerAvatar: avatar,
            onOpen: { pickupDetailNav = viewModel.pickupDetailNavigationToken(for: card.pickupGameId) },
            onViewDetails: { pickupDetailNav = viewModel.pickupDetailNavigationToken(for: card.pickupGameId) }
        ) {
            Menu {
                if showsCantMakeIt {
                    Button(role: .destructive) {
                        let rid = viewModel.pickupJoinRequestLatestByPickupGameIdForFan[card.pickupGameId]?.id ?? card.id
                        followingPickupWithdrawConfirm = PickupJoinWithdrawConfirmState(
                            requestId: rid,
                            pickupGameId: card.pickupGameId,
                            intent: .approved
                        )
                    } label: {
                        Text(L10n.t("Can’t make it", languageCode: goingPlayLanguageCode))
                    }
                }
                if card.pill == .pending {
                    Button(role: .destructive) {
                        let rid = viewModel.pickupJoinRequestLatestByPickupGameIdForFan[card.pickupGameId]?.id ?? card.id
                        followingPickupWithdrawConfirm = PickupJoinWithdrawConfirmState(
                            requestId: rid,
                            pickupGameId: card.pickupGameId,
                            intent: .pending
                        )
                    } label: {
                        Text(L10n.t("Withdraw request", languageCode: goingPlayLanguageCode))
                    }
                    .disabled(followingPickupWithdrawInFlight)
                }
                if isApprovedCompleted {
                    let clearWarnUnrated = !(resolvedGame.map {
                        viewModel.hasSubmittedPickupCreatorRating(for: $0.id)
                    } ?? false)
                    Button {
                        followingPickupPlayingClearConfirm = PickupPlayingClearConfirmState(
                            pickupGameId: card.pickupGameId,
                            warnUnrated: clearWarnUnrated
                        )
                    } label: {
                        Text(L10n.t("pickup_playing_clear_from_going", languageCode: goingPlayLanguageCode))
                    }
                }
                if isRejected {
                    Button {
                        viewModel.markPickupFollowingRejectedRequestCleared(
                            requestId: card.id,
                            pickupGameId: card.pickupGameId
                        )
                    } label: {
                        Text(L10n.t("Clear", languageCode: goingPlayLanguageCode))
                    }
                }
                if isOrganizerCanceled {
                    Button {
                        viewModel.markPickupFollowingOrganizerCanceledCardUserCleared(pickupGameId: card.pickupGameId)
                    } label: {
                        Text(L10n.t("Clear now", languageCode: goingPlayLanguageCode))
                    }
                }
                Button {
                    Task { await viewModel.refreshPickupFollowingJoinCard(pickupGameId: card.pickupGameId) }
                } label: {
                    Label(L10n.t("Refresh pickup status", languageCode: goingPlayLanguageCode), systemImage: "arrow.clockwise")
                }
                if let shareGame {
                    PickupGameShareActionButton(game: shareGame, mapViewModel: viewModel) {
                        Label(L10n.t("Share", languageCode: goingPlayLanguageCode), systemImage: "square.and.arrow.up")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L10n.t("More", languageCode: goingPlayLanguageCode))
        } extra: {
            VStack(alignment: .leading, spacing: 4) {
                if isOrganizerCanceled {
                    Text(L10n.t("Canceled by organizer", languageCode: goingPlayLanguageCode))
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(Color.red.opacity(followingColorScheme == .dark ? 0.9 : 0.78))
                    Text(
                        viewModel.pickupHistoryAutoClearCaption(
                            forPickupGameId: card.pickupGameId,
                            languageCode: appLanguageRaw
                        )
                    )
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                } else if isRejected {
                    Text(L10n.t("going_play_declined_request_caption", languageCode: goingPlayLanguageCode))
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                }
                if let row = resolvedGame, card.pill == .approved, !isOrganizerCanceled {
                    followingPickupCreatorRatingSection(game: row, card: card)
                }
            }
        }
        .task(id: card.organizerUserId) {
            await viewModel.loadPickupCreatorDisplayNameIfNeeded(creatorUserId: card.organizerUserId)
        }
        .task(id: card.pickupGameId) {
            guard card.pill == .approved else { return }
            viewModel.ensurePickupCreatorRatingSessionScoped()
            await viewModel.refreshMyPickupCreatorRatingsForPickupGames(pickupGameIds: [card.pickupGameId])
            if let row = viewModel.resolvedPickupGameRow(for: card.pickupGameId) {
                await viewModel.refreshPickupCreatorRatingUIContext(
                    pickupGameId: row.id,
                    creatorUserId: row.creator_user_id
                )
            }
        }
        .onAppear {
            if let row = viewModel.resolvedPickupGameRow(for: card.pickupGameId) {
                PickupGameStartedStateDebug.log(
                    row: row,
                    now: Date(),
                    allowedActions: "following_join_card,view_detail"
                )
            }
        }
    }

    /// Compact top-trailing Share control for Going → Playing pickup cards (icon only).
    private func followingPickupPlayingShareIconControl(iconColor: Color) -> some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 38, height: 38)
                .overlay {
                    Circle()
                        .strokeBorder(
                            Color.primary.opacity(followingColorScheme == .dark ? 0.22 : 0.12),
                            lineWidth: 1
                        )
                }
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func followingPickupCreatorRatingSection(
        game: PickupGameRow,
        card: PickupGameJoinRequestCardDisplay
    ) -> some View {
        let joinStatus = viewModel.pickupJoinRequestLatestByPickupGameIdForFan[card.pickupGameId]?.status
            ?? "approved"
        let lang = L10n.normalizedLanguageCode(appLanguageRaw)
        if viewModel.pickupCreatorRatingPostSubmitPromptGameIds.contains(game.id) {
            followingPickupPostRatingClearChoices(game: game, languageCode: lang)
        } else if viewModel.hasSubmittedPickupCreatorRating(for: game.id) {
            VStack(alignment: .leading, spacing: FGSpacing.sm) {
                PickupCreatorRateOrganizerHistoryRow(
                    viewModel: viewModel,
                    game: game,
                    joinStatus: joinStatus
                )
                if let deadline = viewModel.pickupPlayingAutoClearDeadline(for: game.id),
                   GoingTabCompletedGameVisibility.isPickupGameCompleted(game, now: followingMyPickupClockTick) {
                    Text(
                        String(
                            format: L10n.t("pickup_playing_auto_clears_on_format", languageCode: lang),
                            locale: Locale(identifier: lang),
                            deadline.formatted(date: .abbreviated, time: .omitted)
                        )
                    )
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(
                        String(
                            format: L10n.t("pickup_playing_auto_clears_on_a11y_format", languageCode: lang),
                            locale: Locale(identifier: lang),
                            deadline.formatted(date: .abbreviated, time: .omitted)
                        )
                    )
                }
            }
        } else if viewModel.shouldShowPickupCreatorRateOrganizerAction(game: game, joinStatus: joinStatus) {
            // Rating action lives in Action Center; Going shows a compact status only.
            Button {
                viewModel.presentPickupCreatorRatingPrompt(pickupGameId: game.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "star.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.accentYellow)
                        .accessibilityHidden(true)
                    Text(L10n.t("pickup_rating_pending_status", languageCode: lang))
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("pickup_rating_pending_status", languageCode: lang))
            .accessibilityHint(L10n.t("action_center_cta_rate_now", languageCode: lang))
        }
    }

    @ViewBuilder
    private func followingPickupPostRatingClearChoices(game: PickupGameRow, languageCode: String) -> some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            HStack(alignment: .center, spacing: FGSpacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(FGColor.accentGreen)
                    .accessibilityHidden(true)
                Text(L10n.t("pickup_playing_thanks_for_rating", languageCode: languageCode))
                    .font(FGTypography.cardTitle.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(followingColorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.t("pickup_playing_thanks_for_rating", languageCode: languageCode))

            Text(L10n.t("pickup_playing_clear_confirm_rated_message", languageCode: languageCode))
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                .fixedSize(horizontal: false, vertical: true)

            if let deadline = viewModel.pickupPlayingAutoClearDeadline(for: game.id) {
                Text(
                    String(
                        format: L10n.t("pickup_playing_auto_clears_on_format", languageCode: languageCode),
                        locale: Locale(identifier: languageCode),
                        deadline.formatted(date: .abbreviated, time: .omitted)
                    )
                )
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(
                    String(
                        format: L10n.t("pickup_playing_auto_clears_on_a11y_format", languageCode: languageCode),
                        locale: Locale(identifier: languageCode),
                        deadline.formatted(date: .abbreviated, time: .omitted)
                    )
                )
            }

            HStack(spacing: FGSpacing.sm) {
                Button {
                    viewModel.markPickupFollowingPlayingCompletedUserCleared(pickupGameId: game.id)
                    rebuildFollowingDisplayCaches(reason: "playingClearNowAfterRating", prefetchAvatars: false)
                } label: {
                    Text(L10n.t("pickup_playing_clear_now", languageCode: languageCode))
                        .font(FGTypography.metadata.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(Color.red.opacity(0.88))
                .accessibilityLabel(L10n.t("pickup_playing_clear_now", languageCode: languageCode))
                .accessibilityHint(L10n.t("pickup_playing_clear_confirm_rated_message", languageCode: languageCode))

                Button {
                    viewModel.acknowledgePickupCreatorRatingPostSubmitPrompt(pickupGameId: game.id)
                    rebuildFollowingDisplayCaches(reason: "playingKeepForLater", prefetchAvatars: false)
                } label: {
                    Text(L10n.t("pickup_playing_keep_for_later", languageCode: languageCode))
                        .font(FGTypography.metadata.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(FGColor.accentBlue)
                .accessibilityLabel(L10n.t("pickup_playing_keep_for_later", languageCode: languageCode))
            }
        }
        .padding(FGSpacing.md)
        .background(FGColor.cardBackground(followingColorScheme))
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous)
                .strokeBorder(FGColor.divider(followingColorScheme), lineWidth: 1)
        }
    }

    private func pickupCardAccentBorder(_ card: PickupGameJoinRequestCardDisplay) -> Color? {
        switch card.pill {
        case .approved: return FGColor.accentGreen.opacity(0.38)
        case .declined: return FGColor.divider(followingColorScheme)
        case .canceledByOrganizer: return Color.red.opacity(followingColorScheme == .dark ? 0.42 : 0.32)
        default: return nil
        }
    }

    private func pickupJoinStatusPill(_ pill: PickupFollowingJoinRequestPillKind) -> some View {
        let colors = pickupJoinPillColors(pill)
        return Text(pill.title(languageCode: appLanguageRaw))
            .font(FGTypography.metadata)
            .fontWeight(.semibold)
            .foregroundStyle(colors.foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(colors.background)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(colors.stroke, lineWidth: 1))
    }

    private func pickupJoinPillColors(_ pill: PickupFollowingJoinRequestPillKind) -> (background: Color, foreground: Color, stroke: Color) {
        switch pill {
        case .pending:
            return (
                FGColor.accentYellow.opacity(followingColorScheme == .dark ? 0.22 : 0.18),
                followingColorScheme == .dark ? Color.white.opacity(0.92) : Color.orange.opacity(0.95),
                FGColor.accentYellow.opacity(0.55)
            )
        case .approved:
            return (
                FGColor.accentGreen.opacity(0.16),
                FGColor.accentGreen,
                FGColor.accentGreen.opacity(0.42)
            )
        case .declined:
            return (
                Color.gray.opacity(followingColorScheme == .dark ? 0.22 : 0.14),
                FGColor.secondaryText(followingColorScheme),
                FGColor.divider(followingColorScheme)
            )
        case .cancelled:
            return (
                Color.gray.opacity(0.12),
                FGColor.mutedText(followingColorScheme),
                FGColor.divider(followingColorScheme).opacity(0.75)
            )
        case .withdrawing:
            return (
                Color.orange.opacity(followingColorScheme == .dark ? 0.18 : 0.12),
                Color.orange.opacity(followingColorScheme == .dark ? 0.95 : 0.88),
                Color.orange.opacity(0.45)
            )
        case .canceledByOrganizer:
            return (
                Color.red.opacity(followingColorScheme == .dark ? 0.28 : 0.16),
                Color.red.opacity(followingColorScheme == .dark ? 0.95 : 0.88),
                Color.red.opacity(0.45)
            )
        }
    }

    private var hasCompletedPlayingPickupFetch: Bool {
        guard let uid = viewModel.currentUserAuthId else { return true }
        return viewModel.lastSuccessfulFollowingJoinRequestsRefreshUserId == uid
            && viewModel.lastSuccessfulFollowingJoinRequestsRefreshAt != nil
    }

    private var shouldShowPlayingPickupLoadingState: Bool {
        guard viewModel.canFanUsePickupGamesUI, goingPlayPlayingItems.isEmpty else { return false }
        if goingTabHasCachedContentForImmediatePaint() {
            return false
        }
        if viewModel.isPickupFollowingJoinListRefreshing { return true }
        if hasCompletedPlayingPickupFetch { return false }
        return goingTabPerf.backgroundRefreshInFlight || viewModel.isTabIntentPreloadInFlight("following")
    }

    private var shouldShowHostingPickupLoadingState: Bool {
        guard viewModel.canFanUsePickupGamesUI else { return false }
        guard viewModel.myPickupGamesForSettings.isEmpty,
              viewModel.myRemovedPickupGamesForSettings.isEmpty else { return false }
        return followingHostingPickupLoadInFlight || viewModel.myPickupGamesLightweightLoadTask != nil
    }

    private func openDiscoverFromGoing() {
#if DEBUG
        print("[AppleReviewFix] exploreDiscoverTapped")
#endif
        selectedTab = .discover
#if DEBUG
        print("[AppleReviewFix] selectedTab=\(MainTabView.AppTab.discover.rawValue)")
#endif
    }

    private func openDiscoverWatchSpotsFromGoing() {
        viewModel.prepareDiscoverFavoriteSpotBrowsingContext()
        selectedTab = .discover
    }

    private func openDiscoverForPickupGamesFromGoing() {
        if viewModel.discoverMapContentMode != .pickupGames {
            viewModel.clearDiscoverMapContentSelectionsWhenSwitching(to: .pickupGames)
            viewModel.discoverMapContentMode = .pickupGames
        }
        if viewModel.discoverPickupSubMode != .games {
            viewModel.discoverPickupSubMode = .games
        }
        selectedTab = .discover
    }

    private func openCalendarProGamesFromGoing() {
#if DEBUG
        print("[AppleReviewFix] browseProGamesTapped")
#endif
        viewModel.requestScheduleHubSurface(.pro)
        selectedTab = .calendar
#if DEBUG
        print("[AppleReviewFix] selectedTab=\(MainTabView.AppTab.calendar.rawValue)")
#endif
    }

    @ViewBuilder
    private func goingRichEmptyCard(
        title: String,
        description: String,
        buttonTitle: String? = nil,
        buttonAction: (() -> Void)? = nil,
        buttonAccent: Color = FGColor.intentWatch
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(FGTypography.cardTitle.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(followingColorScheme))
                    .fixedSize(horizontal: false, vertical: true)

                Text(description)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let buttonTitle, let buttonAction {
                Button {
                    buttonAction()
                } label: {
                    Text(buttonTitle)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            buttonAccent,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .modifier(FollowingCardChromeModifier(colorScheme: followingColorScheme, cornerRadius: 22))
    }

    private func pickupSubtabLoadingCard(message: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(FGTypography.caption.weight(.medium))
                .foregroundStyle(FGColor.secondaryText(followingColorScheme))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .modifier(FollowingCardChromeModifier(colorScheme: followingColorScheme, cornerRadius: 22))
    }

    private func emptyCard(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(FGColor.secondaryText(followingColorScheme))

            Text(title)
                .font(FGTypography.cardTitle)
                .foregroundStyle(FGColor.primaryText(followingColorScheme))

            Text(subtitle)
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .modifier(FollowingCardChromeModifier(colorScheme: followingColorScheme, cornerRadius: 22))
    }

    @ViewBuilder
    private func followingVenueLeadingVisual(bar: BarVenue, sportRaw: String) -> some View {
        let side: CGFloat = 72
        let raw = sportRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let sportKey = raw.isEmpty ? bar.primarySport : raw
        Group {
            if let urlString = ImageDisplayURL.forList(thumbnail: bar.coverPhotoThumbnailURL, full: bar.coverPhotoURL),
               let url = URL(string: urlString) {
                DiscoverCachedRemoteImage(url: url, contentMode: .fill) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.primary.opacity(followingColorScheme == .dark ? 0.22 : 0.08))
                }
                .frame(width: side, height: side)
                .clipped()
            } else {
                let vis = SportFilterCatalog.resolve(sportKey)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(vis.accent.opacity(followingColorScheme == .dark ? 0.24 : 0.15))
                    .frame(width: side, height: side)
                    .overlay {
                        Image(systemName: vis.systemImage)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(vis.accent)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHidden(true)
    }

    private func goingPlanCard(_ item: FollowingGoingDisplayItem, isCompleted: Bool) -> some View {
        let languageCode = goingWatchLanguageCode
        let title = GoingWatchProjection.gameTitle(for: item)
        let bar = item.bar
        let sportRaw = item.venueEvent.sport ?? bar.primarySport
        let dateTimeLine = GoingWatchProjection.statusTimeLine(
            for: item,
            languageCode: languageCode,
            timeZoneOption: viewModel.selectedTimeZone
        )
        let locationLine = GoingWatchProjection.locationLine(bar: bar, languageCode: languageCode)
        let primaryText = isCompleted ? FGColor.mutedText(followingColorScheme) : FGColor.primaryText(followingColorScheme)
        let secondaryText = isCompleted ? FGColor.mutedText(followingColorScheme) : FGColor.secondaryText(followingColorScheme)

        return HStack(alignment: .top, spacing: 12) {
            followingVenueLeadingVisual(bar: bar, sportRaw: sportRaw)
                .opacity(isCompleted ? 0.55 : 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(primaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)

                if !dateTimeLine.isEmpty {
                    Text(dateTimeLine)
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(secondaryText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }

                if !locationLine.isEmpty {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 11, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(locationLine)
                            .font(FGTypography.caption)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(secondaryText)
                }

                if isCompleted {
                    HStack(spacing: 8) {
                        watchingCompletedPill
                        Button {
                            Task { await clearWatchingVenueGame(item) }
                        } label: {
                            Text(L10n.t("Clear", languageCode: languageCode))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(FGColor.primaryText(followingColorScheme))
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    attendanceMenu(item: item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.systemBackground).opacity(followingColorScheme == .dark ? 0.55 : 1))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(FGColor.divider(followingColorScheme).opacity(0.55), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            guard !isCompleted else { return }
            viewModel.requestDiscoverFocusForSavedVenue(bar)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            [title, dateTimeLine, locationLine, item.isServerGoing
                ? L10n.t("Going", languageCode: languageCode)
                : L10n.t("Interested", languageCode: languageCode)]
                .filter { !$0.isEmpty }
                .joined(separator: ". ")
        )
        .opacity(isCompleted ? 0.88 : 1)
    }

    private var watchingCompletedPill: some View {
        Text("Ended")
            .font(.caption.weight(.bold))
            .foregroundStyle(FGColor.mutedText(followingColorScheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(followingColorScheme == .dark ? 0.16 : 0.08))
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(FGColor.divider(followingColorScheme), lineWidth: 1)
            }
            .accessibilityLabel("Game ended")
    }

    @MainActor
    private func clearWatchingVenueGame(_ item: FollowingGoingDisplayItem) async {
        guard viewModel.isAuthenticatedForSocialFeatures else { return }
#if DEBUG
        if WatchingExpiredVenueGameDiagnostics.enabled {
            print("[WatchingExpiredVenueGame] clear tapped event_id=\(item.id.uuidString.lowercased())")
        }
#endif
        setInterestedOnlyLocally(item.id, false)
        let ok = await viewModel.removeInterestInVenueEvent(venueEventID: item.id, refreshFollowing: true)
        if ok {
#if DEBUG
            if WatchingExpiredVenueGameDiagnostics.enabled {
                print("[WatchingExpiredVenueGame] clear success event_id=\(item.id.uuidString.lowercased())")
            }
#endif
            viewModel.showSocialActionToast("Removed from I’m Going.")
        } else {
#if DEBUG
            if WatchingExpiredVenueGameDiagnostics.enabled {
                print("[WatchingExpiredVenueGame] clear failed event_id=\(item.id.uuidString.lowercased()) error=removeInterestInVenueEvent")
            }
#endif
            viewModel.showSocialActionToast("Couldn't clear this game. Try again.")
        }
    }

    @ViewBuilder
    private func attendanceMenu(item: FollowingGoingDisplayItem) -> some View {
        if viewModel.isAuthenticatedForSocialFeatures {
            Menu {
                Button {
                    Task { await applyAttendance(item, target: .going) }
                } label: {
                    Label("Going ✅", systemImage: "checkmark.circle.fill")
                }

                Button {
                    Task { await applyAttendance(item, target: .interested) }
                } label: {
                    Label("Interested 👀", systemImage: "eye")
                }

                Button(role: .destructive) {
                    Task { await applyAttendance(item, target: .notGoing) }
                } label: {
                    Label("Not going ❌", systemImage: "xmark.circle")
                }
            } label: {
                attendancePill(item: item)
            }
            .buttonStyle(.plain)
        } else {
            attendancePill(item: item)
                .opacity(0.45)
        }
    }

    private func attendancePill(item: FollowingGoingDisplayItem) -> some View {
        GoingWatchStatusChip(
            isGoing: item.isServerGoing,
            languageCode: goingWatchLanguageCode
        )
    }

    private func venueCard(_ bar: BarVenue) -> some View {
        let languageCode = goingWatchLanguageCode
        let isFavorite = viewModel.favoriteVenueIDs.contains(bar.id)
        let sportRaw = bar.primarySport
        let locationLine = GoingWatchProjection.spotLocationLine(bar: bar, languageCode: languageCode)
        let tonight = GoingWatchProjection.tonightTitles(for: bar, games: goingVenueGameItems)

        return HStack(alignment: .top, spacing: 12) {
            followingVenueLeadingVisual(bar: bar, sportRaw: sportRaw)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 8) {
                    Text(bar.name)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(followingColorScheme))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button {
                        Task { await toggleSavedVenueHeart(bar: bar, currentlySaved: isFavorite) }
                    } label: {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isFavorite ? FGColor.intentWatch : FGColor.secondaryText(followingColorScheme))
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .fill(FGColor.intentWatch.opacity(followingColorScheme == .dark ? 0.18 : 0.10))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        isFavorite
                            ? String(
                                format: L10n.t("favorite_spot_remove_a11y_format", languageCode: languageCode),
                                locale: Locale(identifier: languageCode),
                                bar.name
                            )
                            : String(
                                format: L10n.t("favorite_spot_add_a11y_format", languageCode: languageCode),
                                locale: Locale(identifier: languageCode),
                                bar.name
                            )
                    )
                }

                GoingWatchFavoriteSpotBadge(languageCode: languageCode)

                if !tonight.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(L10n.t("going_watch_tonight", languageCode: languageCode)):")
                            .font(FGTypography.caption.weight(.semibold))
                            .foregroundStyle(FGColor.primaryText(followingColorScheme))
                        ForEach(tonight, id: \.self) { title in
                            Text("• \(title)")
                                .font(FGTypography.caption)
                                .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                        }
                    }
                } else if !locationLine.isEmpty {
                    Text(locationLine)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }

                Button {
                    viewModel.requestDiscoverFocusForSavedVenue(bar)
                } label: {
                    Text(L10n.t("view_spot", languageCode: languageCode))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.intentWatch)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(FGColor.intentWatch.opacity(0.85), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("view_spot", languageCode: languageCode))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.systemBackground).opacity(followingColorScheme == .dark ? 0.55 : 1))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(FGColor.divider(followingColorScheme).opacity(0.55), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            [
                bar.name,
                L10n.t("favorite_spot_card_subtitle", languageCode: languageCode),
                locationLine,
                tonight.isEmpty ? "" : "\(L10n.t("going_watch_tonight", languageCode: languageCode)): \(tonight.joined(separator: ", "))"
            ]
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
        )
    }

    // MARK: - Maps / Discover (Following tab)

    /// Opens Apple Maps directions: uses venue coordinates when they look valid; otherwise falls back to encoded address (`daddr`).
    private func openFollowingDirectionsToVenue(bar: BarVenue) {
#if DEBUG
        print("[FollowingDirections] venue=\(bar.name) address=\(bar.address)")
#endif
        let trimmedAddress = bar.address.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.followingDirectionsCoordinateLooksUsable(bar.coordinate) {
            let location = CLLocation(latitude: bar.coordinate.latitude, longitude: bar.coordinate.longitude)
            let mapItem = MKMapItem(location: location, address: nil)
            mapItem.name = bar.name
            mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
            return
        }
        guard !trimmedAddress.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.queryItems = [URLQueryItem(name: "daddr", value: trimmedAddress)]
        guard let url = components.url else { return }
        UIApplication.shared.open(url)
    }

    private static func followingDirectionsCoordinateLooksUsable(_ c: CLLocationCoordinate2D) -> Bool {
        guard CLLocationCoordinate2DIsValid(c) else { return false }
        if abs(c.latitude) < 1e-5 && abs(c.longitude) < 1e-5 { return false }
        return abs(c.latitude) <= 90 && abs(c.longitude) <= 180
    }

    private func toggleSavedVenueHeart(bar: BarVenue, currentlySaved: Bool) async {
        guard viewModel.isAuthenticatedForSocialFeatures else { return }
        let wantSave = !currentlySaved
        if !wantSave {
#if DEBUG
            print("[GoingVenueBadgeDebug] unsaveOptimistic venueId=\(bar.id.uuidString.lowercased())")
#endif
        }
        let ok = await viewModel.setVenueFavorite(bar: bar, isFavorite: wantSave)
        if !ok {
#if DEBUG
            if !wantSave {
                print("[GoingVenueBadgeDebug] unsaveRestore venueId=\(bar.id.uuidString.lowercased())")
            }
#endif
            await MainActor.run {
                favoriteActionBanner = "Couldn’t update saved venue. Try again."
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                    favoriteActionBanner = nil
                }
            }
        }
    }
}

/// Premium separation for Following list cards on `systemGroupedBackground` (stroke, soft lift, top-edge sheen).
private struct FollowingCardChromeModifier: ViewModifier {
    var colorScheme: ColorScheme
    var cornerRadius: CGFloat = 20
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    func body(content: Content) -> some View {
        let isLight = colorScheme == .light
        let shadowColor = Color.black.opacity(isLight ? 0.125 : 0.32)
        let shadowRadius: CGFloat = isLight ? 12 : 8
        let shadowY: CGFloat = isLight ? 3 : 2
        let outerStroke = FGColor.divider(colorScheme).opacity(isLight ? 0.92 : 0.88)
        let innerStroke = Color.white.opacity(isLight ? 0.10 : 0.04)
        let sheenTop = Color.white.opacity(isLight ? 0.16 : 0.04)

        content
            .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
            .overlay {
                ZStack {
                    shape
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: sheenTop, location: 0),
                                    .init(color: Color.clear, location: 0.2)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .blendMode(.overlay)
                    shape
                        .strokeBorder(innerStroke, lineWidth: 0.5)
                        .padding(1)
                    shape
                        .strokeBorder(outerStroke, lineWidth: 1.35)
                }
                .allowsHitTesting(false)
            }
    }
}

private enum FollowingAttendanceTarget {
    case going
    case interested
    case notGoing

    var goingTabStatusDebugValue: String {
        switch self {
        case .going:
            return "going"
        case .interested:
            return "interested"
        case .notGoing:
            return "not_going"
        }
    }

    var isIncludedInGoingTab: Bool {
        switch self {
        case .going, .interested:
            return true
        case .notGoing:
            return false
        }
    }
}

private enum GoingParticipationMode: Hashable {
    case venueGames
    case pickupGames
    case proGames

    var title: String {
        switch self {
        case .venueGames: return L10n.t("intent_watch")
        case .pickupGames: return L10n.t("intent_play")
        case .proGames: return L10n.t("pro_games")
        }
    }

    var systemImage: String {
        switch self {
        case .venueGames: return "sportscourt.fill"
        case .pickupGames: return "figure.run"
        case .proGames: return "trophy.fill"
        }
    }

    var tint: Color {
        switch self {
        case .venueGames: return FGColor.intentWatch
        case .pickupGames: return FGColor.intentPlay
        case .proGames: return FGColor.intentProGames
        }
    }
}

private enum BusinessProGameFilter: Hashable {
    case all
    case myTeams
}

private struct PickupGameInviteDetailSheet: View {
    let item: PickupGameInviteDisplay
    let isResponding: Bool
    let onRespond: (String) async -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var game: PickupGameRow { item.game }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FGSpacing.lg) {
                    hero
                    inviterLine
                    gameFacts
                    actionRow
                }
                .padding(FGSpacing.lg)
            }
            .scrollContentBackground(.hidden)
            .fanGeoScreenBackground()
            .navigationTitle("Invitation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [
                    FGColor.accentGreen.opacity(colorScheme == .dark ? 0.34 : 0.18),
                    FGColor.accentBlue.opacity(colorScheme == .dark ? 0.30 : 0.14),
                    Color.orange.opacity(colorScheme == .dark ? 0.22 : 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            SportArtworkIconView(sport: game.sport, diameter: 86)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 24)
                .opacity(0.92)

            VStack(alignment: .leading, spacing: 8) {
                GameFormatBadgeView(format: game.gameFormat, colorScheme: colorScheme)
                Text(game.title)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text(game.sportIdentityLabel())
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
            .padding(FGSpacing.lg)
        }
        .frame(minHeight: 168)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.26 : 0.08), radius: 14, y: 6)
    }

    private var inviterLine: some View {
        HStack(spacing: 10) {
            UserAvatarView(
                avatarThumbnailURL: ImageDisplayURL.canonicalStorageURLString(item.inviterProfile?.avatar_thumbnail_url),
                avatarURL: ImageDisplayURL.canonicalStorageURLString(item.inviterProfile?.avatar_url),
                avatarDisplayRefreshToken: UserAvatarView.stableRefreshToken(
                    userId: item.invite.inviter_user_id,
                    thumbnailURL: item.inviterProfile?.avatar_thumbnail_url,
                    avatarURL: item.inviterProfile?.avatar_url
                ),
                displayName: inviterName,
                email: item.inviterProfile?.email ?? "",
                size: 44,
                fallbackStyle: colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("\(inviterName) invited you to")
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                Text(game.title)
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
            }
        }
        .padding(FGSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
        )
    }

    private var gameFacts: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let dateLine = game.pickupDateWithCompactTimeRange(languageCode: appLanguageRaw) {
                factRow("calendar", dateLine)
            }
            if !locationLine.isEmpty {
                factRow("mappin.and.ellipse", locationLine)
            }
            factRow("person.3", spotsOpenLine)
            if let lat = game.latitude, let lon = game.longitude {
                Button {
                    if let url = URL(string: "http://maps.apple.com/?ll=\(lat),\(lon)&q=Pickup%20game") {
                        openURL(url)
                    }
                } label: {
                    Label("View on map", systemImage: "map")
                        .font(FGTypography.metadata.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(FGColor.accentBlue)
            }
        }
        .padding(FGSpacing.md)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
        )
    }

    private func factRow(_ systemImage: String, _ text: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(FGTypography.caption.weight(.semibold))
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            responseButton("Accept", status: "accepted", tint: FGColor.accentGreen)
            responseButton("Maybe", status: "maybe", tint: Color.orange)
            responseButton("Decline", status: "declined", tint: Color.red.opacity(0.9))
        }
    }

    private func responseButton(_ title: String, status: String, tint: Color) -> some View {
        Button {
            Task { await onRespond(status) }
        } label: {
            if isResponding {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            } else {
                Text(title)
                    .font(FGTypography.metadata.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .disabled(isResponding)
    }

    private var inviterName: String {
        let display = item.inviterProfile?.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !display.isEmpty { return display }
        let username = item.inviterProfile?.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !username.isEmpty { return username }
        return "A friend"
    }

    private var locationLine: String {
        [game.address, game.city, game.state]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private var spotsOpenLine: String {
        let open = game.pickupOpenSlotsRemaining
        return pickupLocalizedSpotsOpen(open, languageCode: appLanguageRaw)
    }
}

private func decodeInterestedOnlyUUIDs(from encoded: String) -> Set<UUID> {
    let parts = encoded.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    var out: Set<UUID> = []
    for p in parts {
        if let u = UUID(uuidString: p) {
            out.insert(u)
        }
    }
    return out
}

private struct EquatableRenderCard<Token: Equatable, Content: View>: View, Equatable {
    let token: Token
    let content: () -> Content

    static func == (lhs: EquatableRenderCard<Token, Content>, rhs: EquatableRenderCard<Token, Content>) -> Bool {
        lhs.token == rhs.token
    }

    var body: some View {
        content()
    }
}

private struct PickupInviteRenderToken: Equatable {
    let id: UUID
    let game: PickupGameRow
    let inviterName: String
    let inviterAvatarThumbnailURL: String
    let inviterAvatarURL: String
    let isBusy: Bool
    let colorScheme: ColorScheme
}

private struct PickupPlayingCardRenderToken: Equatable {
    let card: PickupGameJoinRequestCardDisplay
    let resolvedGame: PickupGameRow?
    let organizerAvatarThumbnailURL: String?
    let organizerAvatarURL: String?
    let organizerAvatarRefreshToken: UUID
    let organizerEmail: String
    let currentUserId: UUID?
    let hasUnreadActivity: Bool
    let isRefreshSpinning: Bool
    let isWithdrawInFlight: Bool
    let lastJoinStatusRefreshAt: Date?
    let isHighlightedFromRatingNotification: Bool
    let colorScheme: ColorScheme
}

private struct PickupHostedCardRenderToken: Equatable {
    let row: PickupGameRow
    let pendingJoinCount: Int
    let withdrawnJoinRows: [PickupGameRequestRow]
    let now: Date
    let colorScheme: ColorScheme
}

private func encodeInterestedOnlyUUIDs(_ set: Set<UUID>) -> String {
    set.map(\.uuidString).sorted().joined(separator: ",")
}

private struct FollowingMyPickupHostedGameDetailSheet: View {
    @ObservedObject var viewModel: MapViewModel
    @EnvironmentObject private var chatViewModel: ChatViewModel
    let game: PickupGameRow
    let now: Date
    let colorScheme: ColorScheme
    let onDone: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onManageRequests: () -> Void
    let onInvite: () -> Void

    private var shareIconColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.78) : Color.secondary
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                SettingsPickupMyGameListCard(
                    viewModel: viewModel,
                    row: game,
                    pendingJoinCount: viewModel.organizerPendingPickupJoinRequests(for: game.id),
                    withdrawnJoinRows: viewModel.pickupOrganizerWithdrawnRequestsByGameId[game.id] ?? [],
                    now: now,
                    colorScheme: colorScheme,
                    onEdit: onEdit,
                    onDelete: onDelete,
                    onManageRequests: onManageRequests,
                    displayStyle: .hostingDetail,
                    onInvite: onInvite
                )
                .environmentObject(chatViewModel)
                .padding(.vertical, 8)
            }
            .fanGeoScreenBackground()
            .navigationTitle("Pickup game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDone)
                }
                if game.isEligibleForInAppShare() {
                    ToolbarItem(placement: .topBarTrailing) {
                        PickupGameShareActionButton(game: game, mapViewModel: viewModel) {
                            hostedDetailShareIconControl
                        }
                        .environmentObject(chatViewModel)
                        .fixedSize()
                    }
                }
            }
        }
    }

    /// Compact Share control matching Discover / Going card trailing share (38pt material, 44pt hit).
    private var hostedDetailShareIconControl: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 38, height: 38)
                .overlay {
                    Circle()
                        .strokeBorder(
                            Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.12),
                            lineWidth: 1
                        )
                }
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(shareIconColor)
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
}
