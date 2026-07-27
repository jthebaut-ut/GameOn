import Foundation

/// Lets post-launch warm work step aside for a moment when the user touches a tab.
///
/// Warm preload runs on the MainActor (publishing into `MapViewModel` / `ChatViewModel`), so a
/// tier that starts in the same runloop turn as a tab tap competes with the tab's first frame.
/// Nothing here cancels or skips work — a warm task only waits out a short quiet window, and the
/// wait is capped so background functionality always completes.
@MainActor
enum UserInteractionPriorityGate {
    /// How long after a tab tap warm work should stay out of the way.
    static let quietWindow: TimeInterval = 0.28
    /// Upper bound on deferral for a single warm task, so repeated tapping cannot starve it.
    private static let maxDeferral: TimeInterval = 0.9
    private static let pollInterval: UInt64 = 60_000_000

    private static var lastInteractionAt: Date?
    private static var activeWarmTaskNames: Set<String> = []

    /// Called from the tab button action path.
    static func noteUserTabInteraction(_ tab: String) {
        lastInteractionAt = Date()
#if DEBUG
        if !activeWarmTaskNames.isEmpty {
            TabTapPerf.activeWarmTasks(Array(activeWarmTaskNames))
        }
        StartupPerf.phase("userTabInteraction", details: "tab=\(tab)")
#endif
    }

    static var activeWarmTasks: [String] {
        Array(activeWarmTaskNames)
    }

    static func noteWarmTaskStarted(_ name: String) {
        activeWarmTaskNames.insert(name)
    }

    static func noteWarmTaskFinished(_ name: String) {
        activeWarmTaskNames.remove(name)
    }

    /// Suspends until the user has been idle for ``quietWindow``, or until ``maxDeferral`` elapses.
    /// Returns the number of milliseconds spent waiting (0 when no tap was in flight).
    @discardableResult
    static func awaitInteractionQuietWindow(stage: String) async -> Int {
        guard let last = lastInteractionAt,
              Date().timeIntervalSince(last) < quietWindow else {
            return 0
        }
        let deferralStartedAt = Date()
        while let interaction = lastInteractionAt,
              Date().timeIntervalSince(interaction) < quietWindow,
              Date().timeIntervalSince(deferralStartedAt) < maxDeferral {
            do {
                try await Task.sleep(nanoseconds: pollInterval)
            } catch {
                break
            }
        }
        let ms = Int(Date().timeIntervalSince(deferralStartedAt) * 1000)
        StartupPerf.phase("warmTaskDeferredForUserInteraction", ms: ms, details: "stage=\(stage)")
        return ms
    }

    /// Test hook: resets process state between validation runs.
    static func resetForTesting() {
        lastInteractionAt = nil
        activeWarmTaskNames.removeAll()
    }
}
