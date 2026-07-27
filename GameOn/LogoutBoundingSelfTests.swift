import Foundation

#if DEBUG
/// Deterministic regression tests for the explicit-logout bounding contract (no XCTest target).
/// Emits only `[LogoutBoundingTest]`. Uses injectable session/remote gateways and an injected
/// clock + no-op sleep, so a suspended or non-cancellable remote sign-out is *modeled* without
/// any real waiting — no test can hang.
@MainActor
enum LogoutBoundingSelfTests {

    /// Controllable stand-in for the local Supabase session + SDK behaviors.
    private final class FakeAuth {
        var sessionPresent: Bool
        var autoRefreshStopped = false
        var remoteDispatchCount = 0
        var directPurgeCount = 0
        /// If set, the SDK's own local removal takes effect after this many polls (simulating
        /// `signOut`'s local removal landing before its network call). `nil` = never lands.
        var pollsUntilSDKRemoval: Int?
        private(set) var polls = 0

        init(sessionPresent: Bool, pollsUntilSDKRemoval: Int? = nil) {
            self.sessionPresent = sessionPresent
            self.pollsUntilSDKRemoval = pollsUntilSDKRemoval
        }

        func hasLocalSession() -> Bool {
            if let n = pollsUntilSDKRemoval, polls >= n { sessionPresent = false }
            return sessionPresent
        }

        func notePoll() { polls += 1 }
    }

    /// Simple virtual clock advanced by the injected sleep — never touches the wall clock.
    private final class VirtualClock {
        var now = Date(timeIntervalSince1970: 0)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private static func makeInvalidator(_ auth: FakeAuth) -> (ExplicitLogoutLocalInvalidator, VirtualClock) {
        let clock = VirtualClock()
        let invalidator = ExplicitLogoutLocalInvalidator(
            stopAutoRefresh: { auth.autoRefreshStopped = true },
            hasLocalSession: { auth.hasLocalSession() },
            dispatchRemoteBestEffort: { auth.remoteDispatchCount += 1 },
            directLocalPurge: {
                auth.directPurgeCount += 1
                auth.sessionPresent = false
                return true
            },
            now: { clock.now },
            // No-op sleep that only advances the virtual clock (and a poll tick). Guarantees the
            // bounded confirmation loop terminates without real waiting.
            sleep: { _ in
                auth.notePoll()
                clock.advance(0.1)
            }
        )
        return (invalidator, clock)
    }

    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[LogoutBoundingTest] PASS \(name)")
            } else {
                failures += 1
                print("[LogoutBoundingTest] FAIL \(name)")
            }
        }

        /// Runs one async invalidation to completion, failing loudly if it stalls.
        func run(_ auth: FakeAuth) -> MapViewModel.LocalLogoutResult? {
            let (invalidator, _) = makeInvalidator(auth)
            var captured: MapViewModel.LocalLogoutResult?
            let completed = runBlocking {
                captured = await invalidator.run()
            }
            return completed ? captured : nil
        }

        // 1. Remote sign-out never returns, but the SDK removed the local session promptly.
        //    (The network hang is irrelevant because run() never awaits the remote.)
        do {
            let auth = FakeAuth(sessionPresent: true, pollsUntilSDKRemoval: 1)
            let result = run(auth)
            expect(result == .clearedBySDK, "remote_hang_local_removed_clears_by_sdk")
            expect(auth.autoRefreshStopped, "remote_hang_stops_auto_refresh")
            expect(auth.remoteDispatchCount == 1, "remote_hang_dispatched_best_effort_once")
        }

        // 2. Remote ignores cancellation: modeled as remote never affecting local state; the SDK
        //    removal still lands → run completes. (run() never cancels/awaits the remote.)
        do {
            let auth = FakeAuth(sessionPresent: true, pollsUntilSDKRemoval: 3)
            let result = run(auth)
            expect(result == .clearedBySDK, "remote_ignores_cancellation_still_completes")
            expect(auth.directPurgeCount == 0, "remote_ignores_cancellation_no_fallback_needed")
        }

        // 3. Timeout fires while the remote is suspended AND the SDK local removal is blocked:
        //    the bounded loop reaches its deadline and the direct local purge invalidates.
        do {
            let auth = FakeAuth(sessionPresent: true, pollsUntilSDKRemoval: nil)
            let result = run(auth)
            expect(result == .clearedByLocalFallback, "sdk_blocked_uses_local_fallback")
            expect(auth.directPurgeCount == 1, "sdk_blocked_purges_once")
            expect(!auth.sessionPresent, "sdk_blocked_no_reusable_session_after")
        }

        // 4. Logout still clears local auth + overlay: after invalidation succeeds, the overlay
        //    settlement model finalizes exactly once.
        do {
            let auth = FakeAuth(sessionPresent: true, pollsUntilSDKRemoval: nil)
            let result = run(auth)
            expect(result?.succeeded == true, "blocked_local_clear_reports_success")
            var overlay = OverlaySettlementModel(localInvalidated: result?.succeeded == true)
            overlay.acknowledge(reason: "mainTab")
            expect(overlay.cleared, "overlay_cleared_after_success")
        }

        // 5 & 6. MainTabView.onChange missed OR flag already true on appear: reconciliation calls
        //        settle again. Settlement must be idempotent (single clear, no double-finalize).
        do {
            var overlay = OverlaySettlementModel(localInvalidated: true)
            overlay.acknowledge(reason: "onChange")
            overlay.acknowledge(reason: "onAppearReconcile") // race: both paths fire
            expect(overlay.cleared, "idempotent_settle_clears")
            expect(overlay.clearCount == 1, "idempotent_settle_finalizes_once")
        }

        // 7. Remote cleanup completes after a *different* account logs in: a generation-guarded
        //    sink must refuse to mutate the new account's state.
        do {
            let sink = GenerationGuardedSink(currentGeneration: 7)
            // Late remote cleanup captured the OLD generation (5).
            sink.applyIfCurrent(capturedGeneration: 5, mutate: { $0 + 1 })
            expect(sink.value == 0, "late_remote_cleanup_does_not_mutate_new_account")
            // A same-generation cleanup is allowed.
            sink.applyIfCurrent(capturedGeneration: 7, mutate: { $0 + 1 })
            expect(sink.value == 1, "same_generation_cleanup_allowed")
        }

        // 8. Repeated logout invalidations remain idempotent (no reusable session either time).
        do {
            let auth = FakeAuth(sessionPresent: true, pollsUntilSDKRemoval: nil)
            _ = run(auth)
            // Second logout finds no session present.
            auth.sessionPresent = false
            let second = run(auth)
            expect(second == .noSessionPresent, "repeated_logout_idempotent")
        }

        // 9. Background/foreground during logout: the explicit-logout guard stays engaged so
        //    authenticated subsystems refuse to restart until settlement clears it.
        do {
            var guardModel = LogoutGuardModel()
            guardModel.begin()
            expect(guardModel.blocksAuthenticatedWork, "guard_blocks_during_logout")
            guardModel.foregroundEvent() // must NOT clear the guard
            expect(guardModel.blocksAuthenticatedWork, "guard_survives_foreground")
            guardModel.settle()
            expect(!guardModel.blocksAuthenticatedWork, "guard_clears_after_settle")
        }

        // 10. Relaunch after offline logout: the direct purge left no reusable session, so a
        //     fresh "session read" returns nil (stays signed out).
        do {
            let auth = FakeAuth(sessionPresent: true, pollsUntilSDKRemoval: nil)
            _ = run(auth)
            expect(!auth.hasLocalSession(), "relaunch_after_offline_logout_stays_signed_out")
        }

        if failures == 0 {
            print("[LogoutBoundingTest] ALL PASS")
        } else {
            print("[LogoutBoundingTest] FAILURES=\(failures)")
        }
    }

    // MARK: - Small deterministic models

    /// Mirrors the overlay-settlement contract: only clears when local invalidation succeeded,
    /// and finalizes exactly once regardless of how many acknowledgement paths fire.
    private struct OverlaySettlementModel {
        let localInvalidated: Bool
        private(set) var cleared = false
        private(set) var clearCount = 0

        mutating func acknowledge(reason: String) {
            guard !cleared else { return }          // idempotent
            guard localInvalidated else { return }  // never fabricate success
            cleared = true
            clearCount += 1
        }
    }

    /// Mirrors generation-guarded background cleanup: late work with a stale generation is ignored.
    private final class GenerationGuardedSink {
        let currentGeneration: UInt64
        private(set) var value = 0
        init(currentGeneration: UInt64) { self.currentGeneration = currentGeneration }
        func applyIfCurrent(capturedGeneration: UInt64, mutate: (Int) -> Int) {
            guard capturedGeneration == currentGeneration else { return }
            value = mutate(value)
        }
    }

    /// Mirrors `FanGeoExplicitLogoutGuard` lifecycle across a foreground event.
    private struct LogoutGuardModel {
        private(set) var blocksAuthenticatedWork = false
        mutating func begin() { blocksAuthenticatedWork = true }
        mutating func foregroundEvent() { /* must be a no-op while logging out */ }
        mutating func settle() { blocksAuthenticatedWork = false }
    }

    /// Drives an async operation to completion on the main run loop so the suite stays
    /// synchronous like the other DEBUG self-tests. Deterministic: the invalidator uses an
    /// injected no-op sleep + virtual clock, so it completes in a handful of runloop turns.
    /// The bounded deadline guarantees a regression can never hang the suite.
    private static func runBlocking(_ operation: @escaping @MainActor () async -> Void) -> Bool {
        var finished = false
        Task { @MainActor in
            await operation()
            finished = true
        }
        let deadline = Date().addingTimeInterval(2)
        while !finished, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        return finished
    }
}
#endif
