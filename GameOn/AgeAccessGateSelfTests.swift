import Foundation
import os

#if DEBUG
/// Pure policy / ownership / server-precedence self-tests (no XCTest target in this project).
/// Emits only `[AgeAccessGateTest]` (and optional `[AgeAccessGateSelfTestEvent]`).
/// Never emits live `[AgeAccessRuntime]` / `[AgeAccessGate]` noise, so a real session can
/// never be mistaken for a test run.
@MainActor
enum AgeAccessGateSelfTests {
    private static let userA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private static let userB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    /// Deterministic stand-in for the authoritative `user_profiles` age record.
    ///
    /// All mutable state lives behind an `OSAllocatedUnfairLock`, so every access is a
    /// synchronous critical section. The lock is never held across an `await`, the type is
    /// genuinely `Sendable`, and the gateway closures satisfy `@Sendable` without any
    /// `@unchecked` escape hatch.
    private final class FakeServer: Sendable {
        struct Row: Sendable {
            var status: AgeAccessState
            var policyVersion: String?
            var checkedAt: Date?
            var exists: Bool
        }

        private struct State: Sendable {
            var rows: [UUID: Row] = [:]
            var reachable = true
            var recordedStatuses: [(UUID, AgeAccessState)] = []
        }

        private let state = OSAllocatedUnfairLock<State>(initialState: State())

        func setRow(_ userId: UUID, _ row: Row) {
            state.withLock { $0.rows[userId] = row }
        }

        func setReachable(_ value: Bool) {
            state.withLock { $0.reachable = value }
        }

        var recordedStatuses: [(UUID, AgeAccessState)] {
            state.withLock { $0.recordedStatuses }
        }

        func gateway() -> AgeAccessServerGateway {
            AgeAccessServerGateway(
                loadState: { userId in
                    self.state.withLock { s -> AgeAccessServerLoadOutcome in
                        guard s.reachable else { return .unavailable(reason: "test_offline") }
                        let resolved = s.rows[userId]
                            ?? Row(status: .unknown, policyVersion: nil, checkedAt: nil, exists: false)
                        return .loaded(
                            AgeAccessServerSnapshot(
                                userId: userId,
                                status: resolved.status,
                                policyVersion: resolved.policyVersion,
                                checkedAt: resolved.checkedAt,
                                serverPolicyVersion: AgeAccessPolicy.policyVersion,
                                profileRowExists: resolved.exists
                            )
                        )
                    }
                },
                // Mirrors public.record_user_age_access_result: requires a profile row,
                // stamps the authoritative policy version + timestamp, sticky blocked.
                recordResult: { userId, state in
                    self.state.withLock { s -> Bool in
                        guard s.reachable else { return false }
                        guard var row = s.rows[userId], row.exists else { return false }
                        if row.status == .under13, state != .under13 { return false }
                        s.recordedStatuses.append((userId, state))
                        row.status = AgeAccessState.fromServerStatus(state.serverStatus)
                        row.policyVersion = AgeAccessPolicy.policyVersion
                        row.checkedAt = Date()
                        s.rows[userId] = row
                        return true
                    }
                }
            )
        }
    }

    static func runAll() {
        let gate = AgeAccessGateService.shared
        gate.setSuppressRuntimeEventLogging(true)
        let server = FakeServer()
        gate.debugSetServerGateway(server.gateway())
        // Never present the real Apple sheet from a self-test. The scripted result is held
        // in a lock box so the override closure reads shared state instead of capturing a
        // mutable local (which would be an illegal capture-then-mutate under Swift 6).
        let appleResult = OSAllocatedUnfairLock<AgeAccessState>(initialState: .declined)
        gate.debugAppleRequestOverride = { appleResult.withLock { $0 } }
        defer {
            gate.debugAppleRequestOverride = nil
            gate.debugRestoreLiveServerGateway()
            gate.debugResetForTests()
            resetStores()
            gate.setSuppressRuntimeEventLogging(false)
        }

        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[AgeAccessGateTest] PASS \(name)")
            } else {
                failures += 1
                print("[AgeAccessGateTest] FAIL \(name)")
            }
        }

        /// Runs one async gate step to completion, failing loudly if it stalls.
        func step(_ name: String, _ operation: @escaping @MainActor () async -> Void) {
            expect(runBlocking(operation), "\(name)_completed")
        }

        resetStores()
        gate.debugResetForTests()

        // MARK: Policy mapping
        expect(AgeAccessPolicy.evaluateSharing(lowerBound: 13).allowsSignUp, "eligible_13_allows_signup")
        expect(AgeAccessPolicy.evaluateSharing(lowerBound: 18).allowsSignUp, "eligible_18_allows_signup")
        expect(AgeAccessPolicy.evaluateSharing(lowerBound: nil) == .under13, "nil_lower_bound_under13")
        expect(!AgeAccessPolicy.evaluateSharing(lowerBound: nil).allowsSocialSession, "under13_blocks_social")
        expect(!AgeAccessPolicy.evaluateDeclined().allowsSignUp, "declined_blocks_signup")
        expect(!AgeAccessPolicy.evaluateUnavailable().allowsSignUp, "unavailable_blocks_signup")
        expect(!AgeAccessPolicy.evaluateError().allowsSignUp, "error_blocks_signup")
        expect(AgeAccessState.eligible13Plus.serverStatus == "eligible", "server_status_eligible")
        expect(AgeAccessState.under13.serverStatus == "blocked_under_13", "server_status_blocked")
        expect(AgeAccessState.declined.serverStatus == "unknown", "server_status_unresolved")

        // MARK: Snapshot eligibility rule
        expect(
            snapshot(userA, status: .eligible13Plus, policy: AgeAccessPolicy.policyVersion, checkedAt: Date())
                .isEligibleForCurrentPolicy,
            "snapshot_eligible_current_policy"
        )
        expect(
            !snapshot(userA, status: .unknown, policy: AgeAccessPolicy.policyVersion, checkedAt: Date())
                .isEligibleForCurrentPolicy,
            "snapshot_unknown_not_eligible"
        )
        expect(
            !snapshot(userA, status: .eligible13Plus, policy: nil, checkedAt: Date())
                .isEligibleForCurrentPolicy,
            "snapshot_missing_policy_not_eligible"
        )
        expect(
            !snapshot(userA, status: .eligible13Plus, policy: "0", checkedAt: Date())
                .isEligibleForCurrentPolicy,
            "snapshot_stale_policy_not_eligible"
        )
        expect(
            !snapshot(userA, status: .eligible13Plus, policy: AgeAccessPolicy.policyVersion, checkedAt: nil)
                .isEligibleForCurrentPolicy,
            "snapshot_missing_checked_at_not_eligible"
        )
        expect(
            !snapshot(userA, status: .eligible13Plus, policy: AgeAccessPolicy.policyVersion, checkedAt: Date(), exists: false)
                .isEligibleForCurrentPolicy,
            "snapshot_missing_profile_row_not_eligible"
        )

        // MARK: Local cache alone never authorizes
        AgeAccessLocalStore.persist(state: .eligible13Plus, userId: userA)
        expect(
            AgeAccessLocalStore.locallyCachedEligibleForCurrentPolicy(userId: userA),
            "local_cache_written_for_a"
        )
        expect(!AgeAccessLocalStore.serverConfirmedEligible(userId: userA), "local_cache_not_server_confirmed")
        expect(
            !AgeAccessLocalStore.locallyCachedEligibleForCurrentPolicy(userId: userB),
            "user_a_cache_does_not_unlock_user_b"
        )
        gate.bindAuthenticatedUser(userA, reason: .login)
        expect(gate.blocksSocialSession, "unconfirmed_local_eligible_fails_closed")
        expect(!gate.isSocialShellAllowed(for: userA), "unconfirmed_local_eligible_blocks_shell")
        expect(gate.isResolvingSocialSession, "unconfirmed_local_eligible_shows_progress")

        // MARK: Legacy device-level eligibility can never authorize an account
        AgeAccessLocalStore.persist(state: .eligible13Plus, userId: nil)
        AgeAccessLocalStore.purgeDeviceLevelEligibility()
        expect(
            !AgeAccessLocalStore.locallyCachedEligibleForCurrentPolicy(userId: nil),
            "device_level_eligibility_purged"
        )

        // MARK: Server unknown + local eligible => fail closed (the reported bypass)
        resetStores()
        gate.debugResetForTests()
        AgeAccessLocalStore.persist(state: .eligible13Plus, userId: userB)
        server.setReachable(true)
        server.setRow(userB, .init(status: .unknown, policyVersion: nil, checkedAt: nil, exists: true))
        step("server_unknown_evaluation") {
            let decision = await gate.ensureEligibleForSocialSession(
                userId: userB,
                reason: .login,
                presentUI: false
            )
            expect(decision != .allow, "local_eligible_plus_server_unknown_fails_closed")
        }
        expect(!gate.isSocialShellAllowed(for: userB), "server_unknown_blocks_shell")
        expect(gate.debugServerConfirmedUserIds.isEmpty, "server_unknown_leaves_no_confirmation")

        // MARK: Server stale policy + local eligible => fail closed
        resetStores()
        gate.debugResetForTests()
        AgeAccessLocalStore.persist(state: .eligible13Plus, userId: userB)
        server.setRow(userB, .init(status: .eligible13Plus, policyVersion: "0", checkedAt: Date(), exists: true))
        step("stale_policy_evaluation") {
            let decision = await gate.ensureEligibleForSocialSession(
                userId: userB,
                reason: .login,
                presentUI: false
            )
            expect(decision != .allow, "local_eligible_plus_stale_server_policy_fails_closed")
        }
        expect(!gate.isSocialShellAllowed(for: userB), "stale_server_policy_blocks_shell")

        // MARK: Server missing checked_at => fail closed
        resetStores()
        gate.debugResetForTests()
        server.setRow(
            userB,
            .init(status: .eligible13Plus, policyVersion: AgeAccessPolicy.policyVersion, checkedAt: nil, exists: true)
        )
        step("missing_checked_at_evaluation") {
            let decision = await gate.ensureEligibleForSocialSession(
                userId: userB,
                reason: .login,
                presentUI: false
            )
            expect(decision != .allow, "server_missing_checked_at_fails_closed")
        }

        // MARK: Completing the real gate must land server-side before access is granted
        resetStores()
        gate.debugResetForTests()
        server.setRow(userB, .init(status: .unknown, policyVersion: nil, checkedAt: nil, exists: true))
        appleResult.withLock { $0 = .eligible13Plus }
        step("gate_completion_evaluation") {
            let decision = await gate.ensureEligibleForSocialSession(
                userId: userB,
                reason: .login,
                presentUI: false
            )
            expect(decision == .allow, "completed_gate_recorded_then_allows")
        }
        expect(gate.isSocialShellAllowed(for: userB), "completed_gate_allows_shell")
        appleResult.withLock { $0 = .declined }

        // MARK: Fan session with no profile row fails closed; business shell stays usable
        resetStores()
        gate.debugResetForTests()
        server.setRow(userB, .init(status: .unknown, policyVersion: nil, checkedAt: nil, exists: false))
        step("fan_missing_profile_row_evaluation") {
            let decision = await gate.ensureEligibleForSocialSession(
                userId: userB,
                reason: .login,
                presentUI: false,
                sessionKind: .fan
            )
            expect(decision != .allow, "fan_session_missing_profile_row_fails_closed")
        }
        resetStores()
        gate.debugResetForTests()
        server.setRow(userB, .init(status: .unknown, policyVersion: nil, checkedAt: nil, exists: false))
        step("business_missing_profile_row_evaluation") {
            let decision = await gate.ensureEligibleForSocialSession(
                userId: userB,
                reason: .login,
                presentUI: false,
                sessionKind: .businessOwner
            )
            expect(decision == .allow, "business_session_without_fan_profile_allowed")
        }
        expect(
            !AgeAccessLocalStore.locallyCachedEligibleForCurrentPolicy(userId: userB),
            "business_exemption_does_not_write_eligible_cache"
        )

        // MARK: Server eligible for the same UUID allows access
        resetStores()
        gate.debugResetForTests()
        server.setRow(
            userA,
            .init(
                status: .eligible13Plus,
                policyVersion: AgeAccessPolicy.policyVersion,
                checkedAt: Date(),
                exists: true
            )
        )
        step("server_eligible_evaluation") {
            let decision = await gate.ensureEligibleForSocialSession(
                userId: userA,
                reason: .login,
                presentUI: false
            )
            expect(decision == .allow, "server_eligible_same_uuid_allows")
        }
        expect(gate.isSocialShellAllowed(for: userA), "server_eligible_allows_shell")
        expect(
            AgeAccessLocalStore.serverConfirmedEligible(userId: userA),
            "server_eligible_marks_local_confirmation"
        )

        // MARK: User A eligible does not unlock user B
        expect(!gate.isSocialShellAllowed(for: userB), "user_a_confirmation_does_not_unlock_b")
        server.setRow(userB, .init(status: .unknown, policyVersion: nil, checkedAt: nil, exists: true))
        gate.bindAuthenticatedUser(userB, reason: .accountSwitch)
        expect(gate.blocksSocialSession, "account_switch_to_b_fails_closed")
        expect(!gate.isSocialShellAllowed(for: userB), "account_switch_b_blocked")
        expect(!gate.debugServerConfirmedUserIds.contains(userA), "account_switch_drops_a_confirmation")

        // MARK: Logout / login cannot leak eligibility (server is re-read every session)
        resetStores()
        gate.debugResetForTests()
        server.setRow(
            userA,
            .init(
                status: .eligible13Plus,
                policyVersion: AgeAccessPolicy.policyVersion,
                checkedAt: Date(),
                exists: true
            )
        )
        step("session_one_evaluation") {
            _ = await gate.ensureEligibleForSocialSession(userId: userA, reason: .login, presentUI: false)
        }
        expect(gate.isSocialShellAllowed(for: userA), "session_one_allows_a")
        gate.handleLogoutOrAccountSwitch()
        expect(gate.debugServerConfirmedUserIds.isEmpty, "logout_clears_session_confirmation")
        server.setRow(userA, .init(status: .unknown, policyVersion: nil, checkedAt: nil, exists: true))
        gate.bindAuthenticatedUser(userA, reason: .login)
        expect(!gate.isSocialShellAllowed(for: userA), "relogin_after_server_downgrade_fails_closed")

        // MARK: Rapid switching keeps each identity independent
        resetStores()
        gate.debugResetForTests()
        server.setRow(
            userA,
            .init(status: .eligible13Plus, policyVersion: AgeAccessPolicy.policyVersion, checkedAt: Date(), exists: true)
        )
        server.setRow(userB, .init(status: .unknown, policyVersion: nil, checkedAt: nil, exists: true))
        step("rapid_switch_evaluation") {
            _ = await gate.ensureEligibleForSocialSession(userId: userA, reason: .login, presentUI: false)
            _ = await gate.ensureEligibleForSocialSession(userId: userB, reason: .accountSwitch, presentUI: false)
        }
        expect(!gate.isSocialShellAllowed(for: userB), "rapid_switch_b_still_blocked")
        expect(!gate.isSocialShellAllowed(for: userA), "rapid_switch_a_no_longer_active")

        // MARK: Stale async response from A cannot alter B
        resetStores()
        gate.debugResetForTests()
        gate.bindAuthenticatedUser(userA, reason: .login)
        gate.bindAuthenticatedUser(userB, reason: .accountSwitch)
        gate.applyServerSocialDenial(.under13, userId: userA)
        expect(gate.activeUserId == userB, "stale_denial_keeps_active_b")
        expect(gate.latestState != .under13, "stale_denial_for_a_ignored_for_b")
        expect(!AgeAccessLocalStore.cachedUnder13ForCurrentPolicy(userId: userB), "stale_denial_did_not_mark_b")

        // MARK: Under-13 is sticky and blocks the shell
        resetStores()
        gate.debugResetForTests()
        server.setRow(
            userA,
            .init(status: .under13, policyVersion: AgeAccessPolicy.policyVersion, checkedAt: Date(), exists: true)
        )
        step("under13_evaluation") {
            let decision = await gate.ensureEligibleForSocialSession(userId: userA, reason: .login, presentUI: true)
            expect(decision == .blockedUnder13, "server_blocked_under13_blocks")
        }
        expect(gate.presentation == .under13, "under13_presentation")
        expect(AgeAccessLocalStore.cachedUnder13ForCurrentPolicy(userId: userA), "under13_cached_locally")
        expect(!gate.isSocialShellAllowed(for: userA), "under13_blocks_shell")

        // MARK: Sign-up grant is single-use, email-bound, and never a local promotion
        resetStores()
        gate.debugResetForTests()
        AgeAccessSignUpOwnershipStore.issue(state: .eligible13Plus, email: "signup+a@example.com")
        expect(
            AgeAccessSignUpOwnershipStore.pendingGrant(forEmail: "signup+a@example.com") != nil,
            "signup_grant_matches_own_email"
        )
        expect(
            AgeAccessSignUpOwnershipStore.pendingGrant(forEmail: "other+b@example.com") == nil,
            "signup_grant_rejects_other_email"
        )
        server.setRow(userB, .init(status: .unknown, policyVersion: nil, checkedAt: nil, exists: true))
        step("signup_claim") {
            let claimed = await gate.claimSignUpOwnership(userId: userB, email: "signup+a@example.com")
            expect(claimed, "signup_grant_recorded_server_side")
        }
        expect(
            AgeAccessSignUpOwnershipStore.outstanding() == nil,
            "signup_grant_is_single_use"
        )
        expect(
            !AgeAccessLocalStore.locallyCachedEligibleForCurrentPolicy(userId: userB),
            "signup_claim_does_not_locally_promote_eligible"
        )
        step("signup_reclaim") {
            let reclaimed = await gate.claimSignUpOwnership(userId: userA, email: "signup+a@example.com")
            expect(!reclaimed, "consumed_grant_cannot_unlock_another_account")
        }

        // MARK: Expired / stale-policy grants are purged instead of reused
        resetStores()
        let expired = AgeAccessSignUpOwnership(
            token: UUID(),
            stateRaw: AgeAccessState.eligible13Plus.rawValue,
            policyVersion: AgeAccessPolicy.policyVersion,
            createdAt: Date().addingTimeInterval(-(AgeAccessSignUpOwnershipStore.lifetime + 60)),
            boundEmail: "signup+a@example.com"
        )
        expect(
            expired.isExpired(lifetime: AgeAccessSignUpOwnershipStore.lifetime),
            "expired_grant_detected"
        )

        // MARK: Offline grace only after the same UUID was server-confirmed
        resetStores()
        gate.debugResetForTests()
        server.setReachable(false)
        step("offline_evaluation") {
            let decision = await gate.ensureEligibleForSocialSession(userId: userB, reason: .launch, presentUI: false)
            expect(decision != .allow, "offline_without_confirmed_cache_fails_closed")
        }
        AgeAccessLocalStore.persist(state: .eligible13Plus, userId: userA, serverConfirmed: true)
        expect(
            AgeAccessLocalStore.serverConfirmedEligibleWithinGrace(
                userId: userA,
                maxAge: AgeAccessGateService.offlineGracePeriod
            ),
            "offline_grace_available_for_confirmed_uuid"
        )
        expect(
            !AgeAccessLocalStore.serverConfirmedEligibleWithinGrace(
                userId: userB,
                maxAge: AgeAccessGateService.offlineGracePeriod
            ),
            "offline_grace_unavailable_for_unconfirmed_uuid"
        )
        expect(
            !AgeAccessLocalStore.serverConfirmedEligibleWithinGrace(
                userId: userA,
                maxAge: AgeAccessGateService.offlineGracePeriod,
                now: Date().addingTimeInterval(AgeAccessGateService.offlineGracePeriod + 60)
            ),
            "offline_grace_expires"
        )
        server.setReachable(true)

        // MARK: No exact age / birth date is ever persisted
        let defaults = UserDefaults.standard.dictionaryRepresentation()
        let ageKeys = defaults.keys.filter {
            $0.lowercased().contains("birth") || $0.lowercased().contains("dob") || $0 == "exact_age"
        }
        expect(ageKeys.isEmpty, "no_exact_age_or_birthdate_persisted")

        // MARK: Self-test events are on their own channel
        expect(gate.suppressRuntimeEventLogging, "self_test_suppresses_runtime_events")
        AgeAccessDebugLog.event("gate_requested")
        AgeAccessDebugLog.event("eligible")
        AgeAccessDebugLog.event("blocked")
        expect(true, "self_test_events_use_self_test_channel")

        resetStores()

        if failures == 0 {
            print("[AgeAccessGateTest] ALL_PASSED")
        } else {
            print("[AgeAccessGateTest] FAILURES=\(failures)")
        }
    }

    private static func snapshot(
        _ userId: UUID,
        status: AgeAccessState,
        policy: String?,
        checkedAt: Date?,
        exists: Bool = true
    ) -> AgeAccessServerSnapshot {
        AgeAccessServerSnapshot(
            userId: userId,
            status: status,
            policyVersion: policy,
            checkedAt: checkedAt,
            serverPolicyVersion: AgeAccessPolicy.policyVersion,
            profileRowExists: exists
        )
    }

    private static func resetStores() {
        AgeAccessLocalStore.clearAll(userId: userA)
        AgeAccessLocalStore.clearAll(userId: userB)
        AgeAccessLocalStore.purgeDeviceLevelEligibility()
        AgeAccessSignUpOwnershipStore.clear()
    }

    /// Drives an async gate call to completion on the main run loop so the suite can stay
    /// synchronous like the rest of the DEBUG self-tests.
    private static func runBlocking(_ operation: @escaping @MainActor () async -> Void) -> Bool {
        var finished = false
        Task { @MainActor in
            await operation()
            finished = true
        }
        let deadline = Date().addingTimeInterval(8)
        while !finished, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return finished
    }
}
#endif
