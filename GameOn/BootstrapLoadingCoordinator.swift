import Combine
import Foundation
import SwiftUI

@MainActor
final class BootstrapLoadingCoordinator: ObservableObject {
    @Published private(set) var isBootstrapping = true
    @Published private(set) var bootstrapError: String?
    @Published private(set) var shouldUseMainTabFallbackBootstrap = false
    @Published private(set) var splashStatusMessage = FanGeoSplashBootstrapStage.preparing.message

    private var didStart = false
    private static let didExplicitlyLogoutDefaultsKey = "didExplicitlyLogout"
    private let minimumVisibleSeconds: TimeInterval = FanGeoSplashAnimation.minimumVisibleDuration
    private let maximumWaitSeconds: TimeInterval = 3.8
    private var lastSplashStageAppliedAt = Date.distantPast
    private var pendingSplashStage: FanGeoSplashBootstrapStage?
    private var splashStageDebounceTask: Task<Void, Never>?

    /// Status shown while age eligibility is resolving after splash release / mid-session login.
    static let ageEligibilitySplashMessage = FanGeoSplashBootstrapStage.checkingAgeEligibility.message

    func beginIfNeeded(
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel
    ) async {
        guard !didStart else { return }
        didStart = true

        setSplashStage(.preparing)

        let startedAt = Date()
        StartupPerf.phase("processBootstrapStart")
        let bootstrapTask = Self.criticalBootstrapTask(
            viewModel: viewModel,
            chatViewModel: chatViewModel,
            owner: "splashCoordinator",
            onStage: { [weak self] stage in
                self?.setSplashStage(stage)
            }
        )

        let completedInTime = await waitForCompletion(
            bootstrapTask,
            timeoutSeconds: maximumWaitSeconds
        )
        if !completedInTime {
            StartupPerf.phase("bootstrapTimeoutFired", ms: Int(maximumWaitSeconds * 1000))
#if DEBUG
            print(
                "[StartupTimeout] generation=\(LaunchBootstrapState.criticalBootstrapGeneration) "
                + "gateReleased=true authCancelled=\(bootstrapTask.isCancelled)"
            )
#endif
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        let criticalReadyMs = Int(elapsed * 1000)
        StartupPerf.phase("criticalReadyGateSatisfied", ms: criticalReadyMs, details: "completedInTime=\(completedInTime)")

        if elapsed < minimumVisibleSeconds {
            let remaining = minimumVisibleSeconds - elapsed
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            StartupPerf.phase(
                "minimumSplashGateSatisfied",
                ms: Int(minimumVisibleSeconds * 1000),
                details: "waitedMs=\(Int(remaining * 1000)) criticalReadyMs=\(criticalReadyMs)"
            )
        } else {
            StartupPerf.phase(
                "minimumSplashGateSatisfied",
                ms: criticalReadyMs,
                details: "noWait criticalReadyMs=\(criticalReadyMs)"
            )
        }

        if completedInTime {
            shouldUseMainTabFallbackBootstrap = false
            LaunchBootstrapState.markCriticalBootstrapCompleted()
        } else {
            bootstrapError = "Opening FanGeo while the rest finishes loading."
            print("[BusinessLogoutTrace] bootstrapTimeoutAuthRestoreContinues=true")
            shouldUseMainTabFallbackBootstrap = true
            // Bootstrap task continues independently; schedule warm preload when it finishes.
            Task { [weak self, weak viewModel, weak chatViewModel] in
                let waitStart = Date()
                await bootstrapTask.value
#if DEBUG
                print(
                    "[StartupTimeout] generation=\(LaunchBootstrapState.criticalBootstrapGeneration) "
                    + "authCompletedAfterTimeout=true extraMs=\(Int(Date().timeIntervalSince(waitStart) * 1000)) "
                    + "authCancelled=\(bootstrapTask.isCancelled)"
                )
#endif
                guard let self, let viewModel, let chatViewModel else { return }
                await MainActor.run {
                    self.scheduleWarmPreload(viewModel: viewModel, chatViewModel: chatViewModel)
                }
            }
        }

        #if DEBUG
        print("[FanGeoLoadingDebug] appReady")
        print("[StartupPrefetchDebug] firstUsableScreenMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
        MemoryAuditProbe.log("appReady")
        #endif

        await holdSplashForPendingAgeEligibilityIfNeeded(viewModel: viewModel)

        let firstUsableMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        StartupPerf.phase("appReady", ms: firstUsableMs, details: "completedInTime=\(completedInTime)")
        StartupPerf.phase("splashDismissed", ms: firstUsableMs)
        LaunchBootstrapState.markAppReady()
        viewModel.scheduleDeferredProGamesAppleCalendarReconcileAfterAppReady(reason: "appReady")
        isBootstrapping = false
        print("[BusinessLaunchPerf] splashNoLongerBlockedByBusinessRefresh=true")
        if completedInTime {
            scheduleWarmPreload(viewModel: viewModel, chatViewModel: chatViewModel)
        }
    }

    /// Extends the branded splash while age is still resolving after critical bootstrap/timeout,
    /// so ContentView never flashes a blank age-check screen. Proceeds immediately when allowed
    /// or when an actionable age presentation is ready.
    private func holdSplashForPendingAgeEligibilityIfNeeded(viewModel: MapViewModel) async {
        let isAuthenticated = viewModel.isLoggedIn
            || viewModel.isVenueOwnerLoggedIn
            || viewModel.hasAuthenticatedVenueOwnerSession
        guard isAuthenticated else { return }
        guard let userId = viewModel.currentUserAuthId else { return }

        if AgeAccessGateService.shared.isSocialShellAllowed(for: userId) { return }
        if AgeAccessGateService.shared.presentation != nil { return }

        setSplashStage(.checkingAgeEligibility)
        let holdStart = Date()
        StartupPerf.phase("ageSplashHoldStart")
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if AgeAccessGateService.shared.isSocialShellAllowed(for: userId) { break }
            if AgeAccessGateService.shared.presentation != nil { break }
            if !AgeAccessGateService.shared.isResolvingSocialSession,
               AgeAccessGateService.shared.blocksSocialSession {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let holdMs = Int(Date().timeIntervalSince(holdStart) * 1000)
        StartupPerf.phase(
            "ageSplashHoldEnd",
            ms: holdMs,
            details: "allowed=\(AgeAccessGateService.shared.isSocialShellAllowed(for: userId))"
        )
#if DEBUG
        print("[AgeStartupDebug] splashHoldMs=\(holdMs)")
#endif
    }

    // MARK: - Single critical bootstrap owner

    /// The one critical bootstrap task for this process launch.
    ///
    /// It is deliberately unstructured and stored statically so that no caller owns its lifetime:
    /// a SwiftUI `.task` that is torn down (for example when the root view swaps branches while
    /// auth restore mutates session state) can neither cancel auth/session restoration nor start a
    /// competing bootstrap. Later callers observe this same task.
    private static var criticalBootstrapOwnerTask: Task<Void, Never>?

    /// Returns the launch-owned critical bootstrap task, starting it on the first request.
    static func criticalBootstrapTask(
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel,
        owner: String,
        onStage: (@MainActor (FanGeoSplashBootstrapStage) -> Void)? = nil
    ) -> Task<Void, Never> {
        if let existing = criticalBootstrapOwnerTask {
            let generation = LaunchBootstrapState.criticalBootstrapGeneration
            if LaunchBootstrapState.didCompleteCriticalBootstrap {
#if DEBUG
                print("[StartupOwnership] generation=\(generation) criticalBootstrapDuplicateSkipped owner=\(owner)")
#endif
                StartupPerf.duplicateSkipped(reason: "criticalBootstrapAlreadyCompleted")
            } else {
#if DEBUG
                print("[StartupOwnership] generation=\(generation) criticalBootstrapJoined owner=\(owner)")
#endif
                StartupPerf.taskCoalesced(name: "criticalBootstrap")
            }
            return existing
        }

        let generation = LaunchBootstrapState.beginCriticalBootstrapGeneration()
#if DEBUG
        print("[StartupOwnership] generation=\(generation) criticalBootstrapStarted owner=\(owner)")
#endif
        let task = Task {
            await performCriticalBootstrap(
                viewModel: viewModel,
                chatViewModel: chatViewModel,
                generation: generation,
                onStage: onStage
            )
        }
        criticalBootstrapOwnerTask = task
        return task
    }

    /// Awaits the launch-owned critical bootstrap without being able to cancel or duplicate it.
    static func joinCriticalBootstrap(
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel,
        owner: String
    ) async {
        await criticalBootstrapTask(
            viewModel: viewModel,
            chatViewModel: chatViewModel,
            owner: owner
        ).value
    }

    /// Critical launch path only — must stay fast enough for splash dismiss.
    ///
    /// Blocking work (A): decode Discover disk snapshot (no geo paint yet) + auth session bootstrap
    /// + age eligibility.
    ///
    /// Non-blocking (B): GPS/region prepare, geo-gated cache apply, Discover venue refresh,
    /// unread DM badge — never required before MainTab is interactive.
    private static func performCriticalBootstrap(
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel,
        generation: Int,
        onStage: (@MainActor (FanGeoSplashBootstrapStage) -> Void)? = nil
    ) async {
        let criticalStart = Date()
        print("[LaunchPerf] criticalStart")
        StartupPerf.phase("criticalStart")
        StartupTaskTracker.enter("criticalBootstrap")

        await MainActor.run {
            onStage?(.preparing)
        }

        // Start location early so it overlaps cache decode + auth; never await on critical path.
        let locationTask = Task { @MainActor in
            StartupPerf.phase("locationRequestStart")
            let regionStart = Date()
            await viewModel.prepareInitialDiscoverRegionAndPreload()
            let ms = Int(Date().timeIntervalSince(regionStart) * 1000)
            StartupPerf.phase("locationRequestEnd", ms: ms)
            StartupPerf.phase("discoverRegionPrepared", ms: ms)
        }

        let cacheStart = Date()
        StartupPerf.phase("cachedDiscoverRestoreStart")
        await viewModel.renderCachedDiscoverCore()
        let cacheMs = Int(Date().timeIntervalSince(cacheStart) * 1000)
        // Geographic pins are applied only after region prepare (post-critical).
        StartupPerf.phase(
            "cachedDiscoverRendered",
            ms: cacheMs,
            details: "usable=false pendingGeoValidation=true"
        )
        StartupPerf.phase(
            "locationDeferredOffCriticalPath",
            details: "venueFetchDeferred=true"
        )

        await MainActor.run {
            onStage?(.findingNearbyVenues)
        }

        if shouldShowLoadingFavoritesSplashStage {
            await MainActor.run {
                onStage?(.loadingFavorites)
            }
        }
        // Auth overlaps in-flight location when present; session gates must finish before interactive UI.
        let authStart = Date()
        StartupPerf.phase("authBootstrapStart")
        await MainActor.run {
            onStage?(.signingYouIn)
        }
        await viewModel.bootstrapAuthSessionOnly()
        let authMs = Int(Date().timeIntervalSince(authStart) * 1000)
        StartupPerf.phase("authBootstrapEnd", ms: authMs)
        StartupPerf.phase("authSessionBootstrapped", ms: authMs)

        // Age eligibility is part of authenticated startup — branded splash status, not a second screen.
        await resolveAgeEligibilityDuringBootstrap(viewModel: viewModel, onStage: onStage)

        let shouldRefreshDiscoverCore = await MainActor.run {
            LaunchBootstrapState.markLaunchDiscoverCoreRefreshStarted()
        }

        // Always refine location + Discover off the splash critical path.
        schedulePostCriticalDiscoverPipeline(
            viewModel: viewModel,
            locationTask: locationTask,
            shouldRefreshDiscoverCore: shouldRefreshDiscoverCore,
            generation: generation,
            onStage: onStage
        )

        await MainActor.run {
            onStage?(.gettingFanGeoReady)
        }

        // Unread badge must still refresh at startup, but never gates Discover interactivity.
        schedulePostCriticalUnreadBadgeRefresh(
            viewModel: viewModel,
            chatViewModel: chatViewModel,
            generation: generation
        )

        LaunchBootstrapState.markCriticalBootstrapCompleted()

        let criticalMs = Int(Date().timeIntervalSince(criticalStart) * 1000)
        print("[LaunchPerf] criticalEnd ms=\(criticalMs)")
        StartupPerf.phase(
            "criticalEnd",
            ms: criticalMs,
            details: "usableCachedDiscover=deferredGeoValidation"
        )
        StartupTaskTracker.exit("criticalBootstrap")
    }

    /// Hydrates authoritative age-access for the restored session while splash remains visible.
    /// Does not flash the age status if resolution finishes before the reveal delay.
    private static func resolveAgeEligibilityDuringBootstrap(
        viewModel: MapViewModel,
        onStage: (@MainActor (FanGeoSplashBootstrapStage) -> Void)?
    ) async {
        let isAuthenticated = await MainActor.run {
            viewModel.isLoggedIn
                || viewModel.isVenueOwnerLoggedIn
                || viewModel.hasAuthenticatedVenueOwnerSession
        }
        guard isAuthenticated else { return }

        let userId = await MainActor.run { viewModel.currentUserAuthId }
        guard let userId else {
            await MainActor.run {
                AgeAccessGateService.shared.failClosedPendingAuthenticatedResolution()
            }
            return
        }

        if AgeAccessGateService.shared.isSocialShellAllowed(for: userId) {
#if DEBUG
            print("[AgeStartupDebug] bootstrapAgeSkipped reason=already_server_confirmed")
#endif
            return
        }

        await MainActor.run {
            AgeAccessGateService.shared.bindAuthenticatedUser(userId, reason: .launch)
        }

        let ageStart = Date()
        StartupPerf.phase("ageEligibilityStart", details: "owner=bootstrap")

        let revealDelayNs = UInt64(FanGeoSplashStatusPresentation.ageStatusRevealDelayMs) * 1_000_000
        let revealTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: revealDelayNs)
            guard !Task.isCancelled else { return }
            guard AgeAccessGateService.shared.isResolvingSocialSession
                || !AgeAccessGateService.shared.isSocialShellAllowed(for: userId) else { return }
            onStage?(.checkingAgeEligibility)
        }

        await viewModel.evaluateAgeAccessForExistingAuthenticatedSessionIfNeeded(reason: .launch)
        revealTask.cancel()

        let ageMs = Int(Date().timeIntervalSince(ageStart) * 1000)
        let allowed = AgeAccessGateService.shared.isSocialShellAllowed(for: userId)
        StartupPerf.phase(
            "ageEligibilityEnd",
            ms: ageMs,
            details: "allowed=\(allowed) presentation=\(String(describing: AgeAccessGateService.shared.presentation))"
        )
#if DEBUG
        print("[AgeStartupDebug] bootstrapAgeMs=\(ageMs) allowed=\(allowed)")
#endif
    }

    /// Location refine → geo-gated cache apply → Discover network refresh (skipped when viewport too broad).
    /// Does not block splash.
    private static func schedulePostCriticalDiscoverPipeline(
        viewModel: MapViewModel,
        locationTask: Task<Void, Never>,
        shouldRefreshDiscoverCore: Bool,
        generation: Int,
        onStage: (@MainActor (FanGeoSplashBootstrapStage) -> Void)?
    ) {
        Task { @MainActor in
            StartupTaskTracker.enter("postCriticalDiscoverPipeline")
            defer { StartupTaskTracker.exit("postCriticalDiscoverPipeline") }

            await locationTask.value

            guard LaunchBootstrapState.isCurrentCriticalBootstrapGeneration(generation) else {
                StartupPerf.staleRejected(name: "postCriticalDiscoverPipeline")
#if DEBUG
                print("[StartupOwnership] generation=\(generation) staleResultDiscarded=postCriticalDiscoverPipeline")
#endif
                return
            }

            let appliedCache = viewModel.applyPendingDiscoverCoreSnapshotIfGeographicallyRelevant()
#if DEBUG
            print("[StartupDiscover] postCriticalCacheApplied=\(appliedCache) basis=\(viewModel.discoverStartupCameraBasis.rawValue)")
#endif

            guard shouldRefreshDiscoverCore else {
                print("[LaunchPerf] duplicateSkipped reason=launchDiscoverCoreRefresh")
                StartupPerf.duplicateSkipped(reason: "launchDiscoverCoreRefresh")
                return
            }

            onStage?(.checkingLiveGames)
            let discoverStart = Date()
            let fetchAllowed = viewModel.discoverGeographicNetworkFetchAllowed()
            StartupPerf.phase(
                "freshDiscoverRefreshStart",
                details: "blocksSplash=false fetchAllowed=\(fetchAllowed) basis=\(viewModel.discoverStartupCameraBasis.rawValue)"
            )
            await viewModel.refreshDiscoverCoreInBackground()
            let discoverMs = Int(Date().timeIntervalSince(discoverStart) * 1000)
            StartupPerf.phase("freshDiscoverRefreshEnd", ms: discoverMs)
            StartupPerf.phase("discoverCoreRefreshed", ms: discoverMs)
        }
    }

    private static func schedulePostCriticalUnreadBadgeRefresh(
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel,
        generation: Int
    ) {
        // The signed-out branch below is destructive, so it may only run for the exact session this
        // task was scheduled under. A session that changed in the meantime owns its own refresh.
        let scheduledAuthId = viewModel.currentUserAuthId
        Task { @MainActor in
            StartupTaskTracker.enter("postCriticalUnreadBadge")
            defer { StartupTaskTracker.exit("postCriticalUnreadBadge") }

            guard LaunchBootstrapState.isCurrentCriticalBootstrapGeneration(generation),
                  viewModel.currentUserAuthId == scheduledAuthId else {
                StartupPerf.staleRejected(name: "postCriticalUnreadBadge")
#if DEBUG
                print("[StartupOwnership] generation=\(generation) staleResultDiscarded=postCriticalUnreadBadge")
#endif
                return
            }

            let shouldLoadChatBadge = viewModel.isAuthenticatedForSocialFeatures
                && AgeAccessGateService.shared.allowsSocialSubsystemsForActiveUser()
            if shouldLoadChatBadge {
                let unreadStart = Date()
                StartupPerf.phase("unreadCountStart", details: "blocksSplash=false")
                await chatViewModel.refreshUnreadDirectMessageCount()
                let unreadMs = Int(Date().timeIntervalSince(unreadStart) * 1000)
                StartupPerf.phase("unreadCountEnd", ms: unreadMs)
                StartupPerf.phase("unreadBadgeDeferred", ms: unreadMs)
            } else {
                chatViewModel.clearForSignOut()
                StartupPerf.phase("unreadCountSkipped", details: "reason=unauthenticated")
            }
        }
    }

    private static var shouldShowLoadingFavoritesSplashStage: Bool {
        !UserDefaults.standard.bool(forKey: didExplicitlyLogoutDefaultsKey)
    }

    private func setSplashStage(_ stage: FanGeoSplashBootstrapStage) {
        let now = Date()
        let elapsedMs = Int(now.timeIntervalSince(lastSplashStageAppliedAt) * 1000)
        if splashStatusMessage == FanGeoSplashBootstrapStage.preparing.message
            || elapsedMs >= FanGeoSplashStatusPresentation.minimumVisibleMs
            || lastSplashStageAppliedAt == Date.distantPast {
            applySplashStageImmediately(stage)
            return
        }

        pendingSplashStage = stage
        splashStageDebounceTask?.cancel()
        let remainingMs = FanGeoSplashStatusPresentation.minimumVisibleMs - elapsedMs
        splashStageDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, remainingMs)) * 1_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, let pending = self.pendingSplashStage else { return }
                self.applySplashStageImmediately(pending)
            }
        }
    }

    private func applySplashStageImmediately(_ stage: FanGeoSplashBootstrapStage) {
        pendingSplashStage = nil
        splashStatusMessage = stage.message
        lastSplashStageAppliedAt = Date()
#if DEBUG
        print("[FanGeoLoadingDebug] loadingStatus=\(stage.message)")
#endif
    }

    private func scheduleWarmPreload(
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel
    ) {
        LaunchBootstrapState.markBootstrapWarmPreloadScheduled()
        StartupPerf.phase("warmPreloadScheduled")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            LaunchWarmPreloadCoordinator.shared.beginIfNeeded(
                viewModel: viewModel,
                chatViewModel: chatViewModel,
                accountTabVisible: false
            )
            UserPreferencesWarmCacheCoordinator.shared.beginIfNeeded(
                viewModel: viewModel,
                delayMs: 1_400
            )
        }
    }

    /// True race: timeout can release the splash gate without waiting for the bootstrap task
    /// to cooperatively finish. `withTaskGroup` previously still drained `await task.value`
    /// on exit even after `cancelAll()`, which defeated the deadline.
    ///
    /// The deadline only stops *waiting*. `task` is never cancelled here, so auth/session
    /// restoration always runs to completion even when the splash is released first.
    private func waitForCompletion(
        _ task: Task<Void, Never>,
        timeoutSeconds: TimeInterval
    ) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let lock = NSLock()
            var didResume = false
            func resumeOnce(_ completedInTime: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: completedInTime)
            }

            Task {
                await task.value
                resumeOnce(true)
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                resumeOnce(false)
            }
        }
    }
}
