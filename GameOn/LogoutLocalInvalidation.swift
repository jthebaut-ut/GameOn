import Foundation

/// Testable, network-independent core of explicit-logout local session invalidation.
///
/// Injecting the effects (plus clock/sleep) lets regression tests drive the exact bounding
/// contract without a real Supabase client, network, or wall-clock waiting: a suspended or
/// non-cancellable remote sign-out can never delay ``run()``, because the remote call is only
/// ever dispatched (fire-and-forget) and never awaited here.
struct ExplicitLogoutLocalInvalidator {
    /// Stops background token refresh so it cannot re-persist a session mid-logout.
    /// Async because the SDK's `stopAutoRefresh()` is actor-isolated.
    var stopAutoRefresh: () async -> Void
    /// True while a reusable local session still exists.
    var hasLocalSession: () -> Bool
    /// Dispatches remote revocation as best effort. MUST return immediately (fire-and-forget).
    var dispatchRemoteBestEffort: () -> Void
    /// Truly-local, synchronous session purge. Returns `true` when no reusable session remains.
    var directLocalPurge: () -> Bool
    /// Injected clock. Defaults to the wall clock.
    var now: () -> Date = { Date() }
    /// Injected sleep. Defaults to a real sleep; tests pass a no-op (advancing ``now``) so the
    /// bounded confirmation loop cannot busy-wait or block.
    var sleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }

    /// Bounded confirmation window for the SDK's own local removal before falling back.
    var confirmationWindow: TimeInterval = 0.8
    /// Poll interval while awaiting the SDK's local removal.
    var pollIntervalNanos: UInt64 = 40_000_000

    func run() async -> MapViewModel.LocalLogoutResult {
        // (1) Never let auto-refresh re-persist a session after we invalidate it.
        await stopAutoRefresh()

        guard hasLocalSession() else { return .noSessionPresent }

        // (2) Remote revocation runs independently and is never awaited.
        dispatchRemoteBestEffort()

        // (3) Bounded, wall-clock confirmation. The SDK removes the local session before its
        // network call, so this normally succeeds within a tick and is network-independent.
        let deadline = now().addingTimeInterval(confirmationWindow)
        while now() < deadline {
            if !hasLocalSession() { return .clearedBySDK }
            await sleep(pollIntervalNanos)
        }

        // (4) SDK local removal stalled (e.g. the session actor is blocked by a hung refresh):
        // invalidate the persisted session directly (synchronous, local, no network).
        return directLocalPurge() ? .clearedByLocalFallback : .failed
    }
}
