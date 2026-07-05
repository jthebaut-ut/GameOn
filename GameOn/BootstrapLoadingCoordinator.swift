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

    func beginIfNeeded(
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel
    ) async {
        guard !didStart else { return }
        didStart = true

        setSplashStage(.preparing)

        let startedAt = Date()
        let bootstrapTask = Task {
            await Self.performCriticalBootstrap(
                viewModel: viewModel,
                chatViewModel: chatViewModel,
                onStage: { [weak self] stage in
                    self?.setSplashStage(stage)
                }
            )
        }

        let completedInTime = await waitForCompletion(
            bootstrapTask,
            timeoutSeconds: maximumWaitSeconds
        )

        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed < minimumVisibleSeconds {
            let remaining = minimumVisibleSeconds - elapsed
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }

        if completedInTime {
            shouldUseMainTabFallbackBootstrap = false
            LaunchBootstrapState.markCriticalBootstrapCompleted()
        } else {
            bootstrapError = "Opening FanGeo while the rest finishes loading."
            print("[BusinessLogoutTrace] bootstrapTimeoutAuthRestoreContinues=true")
            shouldUseMainTabFallbackBootstrap = true
            Task { [weak self, weak viewModel, weak chatViewModel] in
                await bootstrapTask.value
                guard let self, let viewModel, let chatViewModel else { return }
                await MainActor.run {
                    self.scheduleWarmPreload(viewModel: viewModel, chatViewModel: chatViewModel)
                }
            }
        }

        #if DEBUG
        print("[FanGeoLoadingDebug] appReady")
        print("[StartupPrefetchDebug] firstUsableScreenMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
        #endif
        LaunchBootstrapState.markAppReady()
        viewModel.scheduleDeferredProGamesAppleCalendarReconcileAfterAppReady(reason: "appReady")
        isBootstrapping = false
        print("[BusinessLaunchPerf] splashNoLongerBlockedByBusinessRefresh=true")
        if completedInTime {
            scheduleWarmPreload(viewModel: viewModel, chatViewModel: chatViewModel)
        }
    }

    /// Critical launch path only — must stay fast enough for splash dismiss.
    static func performCriticalBootstrap(
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel,
        onStage: (@MainActor (FanGeoSplashBootstrapStage) -> Void)? = nil
    ) async {
        let criticalStart = Date()
        print("[LaunchPerf] criticalStart")

        await MainActor.run {
            onStage?(.preparing)
        }
        await viewModel.renderCachedDiscoverCore()

        await MainActor.run {
            onStage?(.findingNearbyVenues)
        }
        await viewModel.prepareInitialDiscoverRegionAndPreload()

        if shouldShowLoadingFavoritesSplashStage {
            await MainActor.run {
                onStage?(.loadingFavorites)
            }
        }
        await viewModel.bootstrapAuthSessionOnly()

        let shouldRefreshDiscoverCore = await MainActor.run {
            LaunchBootstrapState.markLaunchDiscoverCoreRefreshStarted()
        }
        if shouldRefreshDiscoverCore {
            await MainActor.run {
                onStage?(.checkingLiveGames)
            }
            await viewModel.refreshDiscoverCoreInBackground()
        } else {
            print("[LaunchPerf] duplicateSkipped reason=launchDiscoverCoreRefresh")
        }

        await MainActor.run {
            onStage?(.almostReady)
        }
        let shouldLoadChatBadge = await MainActor.run {
            viewModel.isAuthenticatedForSocialFeatures
        }
        if shouldLoadChatBadge {
            await chatViewModel.refreshUnreadDirectMessageCount()
        } else {
            await MainActor.run {
                chatViewModel.clearForSignOut()
            }
        }

        LaunchBootstrapState.markCriticalBootstrapCompleted()

        let criticalMs = Int(Date().timeIntervalSince(criticalStart) * 1000)
        print("[LaunchPerf] criticalEnd ms=\(criticalMs)")
    }

    private static var shouldShowLoadingFavoritesSplashStage: Bool {
        !UserDefaults.standard.bool(forKey: didExplicitlyLogoutDefaultsKey)
    }

    private func setSplashStage(_ stage: FanGeoSplashBootstrapStage) {
        splashStatusMessage = stage.message
    }

    private func scheduleWarmPreload(
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel
    ) {
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

    private func waitForCompletion(
        _ task: Task<Void, Never>,
        timeoutSeconds: TimeInterval
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return false
            }

            let finished = await group.next() ?? true
            group.cancelAll()
            return finished
        }
    }
}
