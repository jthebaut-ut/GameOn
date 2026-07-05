import Foundation

/// Post-launch background cache warmer for Going / Schedule user-specific datasets (non-blocking).
@MainActor
final class UserPreferencesWarmCacheCoordinator {
    static let shared = UserPreferencesWarmCacheCoordinator()

    private var warmTask: Task<Void, Never>?
    private var lastCompletedUserId: UUID?

    private init() {}

    func beginIfNeeded(
        viewModel: MapViewModel,
        delayMs: UInt64 = 1_400,
        forceRefresh: Bool = false
    ) {
        guard LaunchBootstrapState.didBecomeAppReady else { return }
        guard viewModel.isAuthenticatedForSocialFeatures else { return }

        if forceRefresh {
            lastCompletedUserId = nil
        } else if let userId = viewModel.currentUserAuthId, lastCompletedUserId == userId {
            return
        }

        warmTask?.cancel()
        warmTask = Task(priority: .utility) { [weak viewModel] in
            if delayMs > 0 {
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            }
            guard !Task.isCancelled else { return }
            guard let viewModel else { return }
            await viewModel.runUserPreferencesWarmCacheIfNeeded(forceRefresh: forceRefresh)
            await MainActor.run {
                self.lastCompletedUserId = viewModel.currentUserAuthId
            }
        }
    }

    func cancel() {
        warmTask?.cancel()
        warmTask = nil
        lastCompletedUserId = nil
    }
}
