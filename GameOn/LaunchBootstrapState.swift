import Foundation

/// Process-wide launch flags so splash bootstrap, timeout fallback, and warm preload do not duplicate work.
@MainActor
enum LaunchBootstrapState {
    private(set) static var didCompleteCriticalBootstrap = false
    private(set) static var didRunLaunchDiscoverCoreRefresh = false
    private(set) static var didStartWarmPreload = false
    private(set) static var didBootstrapScheduleWarmPreload = false
    private(set) static var didBecomeAppReady = false
    /// Monotonic-ish marker for the first usable screen, used only for DEBUG perf instrumentation.
    private(set) static var appReadyAt: Date?
    /// Identifies the single critical bootstrap lifecycle owned by this process launch.
    /// Post-critical work carries the generation it was scheduled under so a late task from a
    /// superseded lifecycle can be discarded instead of publishing over current state.
    private(set) static var criticalBootstrapGeneration = 0

    static func beginCriticalBootstrapGeneration() -> Int {
        criticalBootstrapGeneration += 1
        return criticalBootstrapGeneration
    }

    static func isCurrentCriticalBootstrapGeneration(_ generation: Int) -> Bool {
        criticalBootstrapGeneration == generation
    }

    static func markCriticalBootstrapCompleted() {
        didCompleteCriticalBootstrap = true
    }

    static func markAppReady() {
        didBecomeAppReady = true
        if appReadyAt == nil {
            appReadyAt = Date()
            StartupPerf.phase("firstUsableScreen")
        }
    }

    /// Milliseconds elapsed since the first usable screen, or `nil` before appReady.
    static func msSinceFirstUsableScreen() -> Int? {
        guard let appReadyAt else { return nil }
        return Int(Date().timeIntervalSince(appReadyAt) * 1000)
    }

    @discardableResult
    static func markLaunchDiscoverCoreRefreshStarted() -> Bool {
        guard !didRunLaunchDiscoverCoreRefresh else { return false }
        didRunLaunchDiscoverCoreRefresh = true
        return true
    }

    @discardableResult
    static func markWarmPreloadStarted() -> Bool {
        guard !didStartWarmPreload else { return false }
        didStartWarmPreload = true
        return true
    }

    static func markBootstrapWarmPreloadScheduled() {
        didBootstrapScheduleWarmPreload = true
    }

#if DEBUG
    static func resetForTesting() {
        didCompleteCriticalBootstrap = false
        didRunLaunchDiscoverCoreRefresh = false
        didStartWarmPreload = false
        didBootstrapScheduleWarmPreload = false
        didBecomeAppReady = false
        appReadyAt = nil
        criticalBootstrapGeneration = 0
    }
#endif
}
