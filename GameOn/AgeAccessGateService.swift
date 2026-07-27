import Combine
import DeclaredAgeRange
import Foundation
import UIKit

/// Result of asking the shared age gate to allow account creation.
enum AgeAccessSignUpDecision: Equatable, Sendable {
    case allow
    case blockedUnder13
    case needsConfirmation
    case cancelled
}

/// Result for existing authenticated sessions before mounting social surfaces.
enum AgeAccessSocialSessionDecision: Equatable, Sendable {
    case allow
    case blockedUnder13
    case needsConfirmation
}

/// Which kind of authenticated shell is being evaluated.
///
/// Business-owner sessions deliberately have no `public.user_profiles` row (see
/// `MapViewModel.ensureUserProfileExists`), so a missing row is expected there and
/// must not lock the owner out of venue management. For fan sessions a missing row
/// is unresolved and fails closed.
enum AgeAccessSessionKind: String, Sendable {
    case fan
    case businessOwner = "business_owner"
}

/// Single shared Declared Age Range gate for all FanGeo registration + social entry paths.
///
/// Precedence rules (single source of truth):
///  1. The authoritative record is `user_profiles.age_access_status` /
///     `age_policy_version` / `age_checked_at` for the exact authenticated UUID.
///  2. Social access requires `status = eligible` AND `policy_version = server current`
///     AND `checked_at` present. `unknown`, missing policy version, missing timestamp,
///     stale policy version and missing profile row all fail closed.
///  3. A local `UserDefaults` cache can only be used after the server confirmed the
///     same UUID in this process session (rendering optimization), or as a bounded
///     offline grace when the server was unreachable — never when the server answered.
///  4. Device-level / cross-account state can never authorize a UUID. A pre-auth
///     sign-up result is a single-use ``AgeAccessSignUpOwnership`` grant that is
///     consumed by the sign-up transaction that produced it and recorded server-side.
@MainActor
final class AgeAccessGateService: ObservableObject {
    static let shared = AgeAccessGateService()

    enum Presentation: Equatable, Identifiable {
        case under13
        case needsConfirmation

        var id: String {
            switch self {
            case .under13: return "under13"
            case .needsConfirmation: return "needsConfirmation"
            }
        }
    }

    enum EvaluationReason: String, Sendable {
        case launch
        case login
        case accountSwitch = "account_switch"
        case retry
        case signUp = "sign_up"
    }

    /// Bounded reuse window for a same-UUID server-confirmed cache when the server is
    /// unreachable. Never applies when the server answered with an unresolved record.
    static let offlineGracePeriod: TimeInterval = 7 * 24 * 60 * 60

    @Published private(set) var latestState: AgeAccessState = .unknown
    @Published var presentation: Presentation?
    @Published private(set) var isRequestInFlight = false

    /// When true, authenticated social tabs must not mount until eligibility resolves to eligible for the active UUID.
    @Published private(set) var blocksSocialSession = false

    /// True while the authoritative record for the active UUID is still being resolved.
    /// The shell stays blocked, but the UI shows progress instead of a retry prompt.
    @Published private(set) var isResolvingSocialSession = false

    /// Active authenticated identity this gate is evaluating. Nil when logged out / guest.
    @Published private(set) var activeUserId: UUID?

    /// UUIDs whose authoritative server record was confirmed eligible in this process
    /// session. Cleared on logout / account switch so every session re-hydrates.
    private var serverConfirmedUserIds: Set<UUID> = []

    /// Business-owner UUIDs with no fan profile row: no fan social surface exists for
    /// them, so venue management stays reachable. Never used for fan sessions.
    private var businessOwnerExemptUserIds: Set<UUID> = []

    private var serverGateway: AgeAccessServerGateway = .live

    private var inFlightTask: Task<AgeAccessState, Never>?
    private var inFlightUserId: UUID?
    private var inFlightGeneration: UInt64 = 0
    private var sessionGeneration: UInt64 = 0
    /// Suppresses runtime `[AgeAccessRuntime]` / `[AgeAccessGate]` event noise during DEBUG self-tests.
    private(set) var suppressRuntimeEventLogging = false

    private init() {
        // Fail closed until an authenticated user is bound and server-resolved.
        latestState = .unknown
        blocksSocialSession = false
        activeUserId = nil
        // One-way migration: legacy device-scoped / unscoped eligibility can never
        // authorize any account again.
        AgeAccessLocalStore.purgeDeviceLevelEligibility()
    }

    // MARK: - Session binding

    /// Binds the gate to the current Supabase auth UUID. Cancels prior evaluation ownership on change.
    /// Never grants access from a local cache that the server has not confirmed this session.
    func bindAuthenticatedUser(_ userId: UUID?, reason: EvaluationReason = .login) {
        let normalized = userId
        if activeUserId != normalized {
            let previous = activeUserId
            cancelInFlightEvaluation(reason: "bind_user_changed")
            if let previous {
                AgeAccessRuntimeLog.sessionCleared(previousUserId: previous)
            }
            sessionGeneration &+= 1
            presentation = nil
            isRequestInFlight = false
            activeUserId = normalized
            // A new identity must never inherit another identity's confirmation.
            serverConfirmedUserIds = serverConfirmedUserIds.filter { $0 == normalized }
            businessOwnerExemptUserIds = businessOwnerExemptUserIds.filter { $0 == normalized }
        } else {
            activeUserId = normalized
        }

        guard let normalized else {
            latestState = .unknown
            blocksSocialSession = false
            isResolvingSocialSession = false
            return
        }

        let persisted = AgeAccessLocalStore.loadPersistedState(userId: normalized)
        AgeAccessRuntimeLog.localState(
            userId: normalized,
            state: persisted.state,
            policyVersion: persisted.policyVersion
        )

        if AgeAccessLocalStore.cachedUnder13ForCurrentPolicy(userId: normalized) {
            latestState = .under13
            blocksSocialSession = true
            isResolvingSocialSession = false
            presentation = .under13
            AgeAccessRuntimeLog.socialShellBlocked(userId: normalized, state: .under13)
            return
        }

        if serverConfirmedUserIds.contains(normalized),
           AgeAccessLocalStore.serverConfirmedEligible(userId: normalized) {
            latestState = .eligible13Plus
            blocksSocialSession = false
            isResolvingSocialSession = false
            presentation = nil
            AgeAccessRuntimeLog.localCacheFound(userId: normalized, reason: "session_server_confirmed")
            return
        }

        if businessOwnerExemptUserIds.contains(normalized) {
            blocksSocialSession = false
            isResolvingSocialSession = false
            presentation = nil
            return
        }

        if persisted.state == .eligible13Plus {
            AgeAccessRuntimeLog.localCacheRejected(
                userId: normalized,
                reason: AgeAccessLocalStore.serverConfirmedEligible(userId: normalized)
                    ? "server_revalidation_required"
                    : "never_server_confirmed"
            )
        }

        latestState = .unknown
        blocksSocialSession = true
        // Pending, not refused: show progress rather than a retry prompt.
        isResolvingSocialSession = true
        presentation = nil
        AgeAccessRuntimeLog.socialShellBlocked(userId: normalized, state: .unknown)
    }

    /// True only when this exact UUID is server-confirmed eligible for the current
    /// policy in this session. The social shell must consult this and nothing else.
    func isSocialShellAllowed(for userId: UUID) -> Bool {
        guard activeUserId == userId else { return false }
        guard !blocksSocialSession else { return false }
        if businessOwnerExemptUserIds.contains(userId) { return true }
        guard latestState == .eligible13Plus else { return false }
        guard serverConfirmedUserIds.contains(userId) else { return false }
        return AgeAccessLocalStore.serverConfirmedEligible(userId: userId)
    }

    /// Social subsystems (presence heartbeat, DM inbox, friendship realtime, suggested
    /// fans, social badges) must consult this before starting any work.
    func allowsSocialSubsystemsForActiveUser() -> Bool {
        guard let activeUserId else { return false }
        return isSocialShellAllowed(for: activeUserId)
    }

    /// Clears in-memory presentation / in-flight work. Does not erase durable per-user cache unless `clearPersisted`.
    func clearTransientGateState(clearPersisted: Bool = false) {
        cancelInFlightEvaluation(reason: "clear_transient")
        presentation = nil
        isRequestInFlight = false
        if clearPersisted {
            AgeAccessLocalStore.clearAll(userId: activeUserId)
            latestState = .unknown
        }
        let previous = activeUserId
        activeUserId = nil
        blocksSocialSession = false
        isResolvingSocialSession = false
        serverConfirmedUserIds.removeAll()
        businessOwnerExemptUserIds.removeAll()
        sessionGeneration &+= 1
        if let previous {
            AgeAccessRuntimeLog.sessionCleared(previousUserId: previous)
        }
    }

    /// Call from logout / account switch — clears transient UI ownership only (per-user disk cache retained).
    func handleLogoutOrAccountSwitch() {
        let previous = activeUserId
        cancelInFlightEvaluation(reason: "logout_or_account_switch")
        presentation = nil
        isRequestInFlight = false
        activeUserId = nil
        blocksSocialSession = false
        isResolvingSocialSession = false
        latestState = .unknown
        // Every new session must re-hydrate the authoritative record.
        serverConfirmedUserIds.removeAll()
        businessOwnerExemptUserIds.removeAll()
        sessionGeneration &+= 1
        if let previous {
            AgeAccessRuntimeLog.sessionCleared(previousUserId: previous)
        }
    }

    // MARK: - Sign-up path

    /// Shared entry used by every create-account path. Never silently treats unresolved as eligible.
    /// - Parameter email: sign-up email, used to bind the resulting single-use grant.
    func ensureEligibleForSignUp(presentUI: Bool = true, email: String? = nil) async -> AgeAccessSignUpDecision {
        // Reuse the grant issued earlier in this same sign-up transaction so the user is
        // prompted once. The grant never authorizes social access on its own — it is
        // recorded server-side by ``claimSignUpOwnership`` and the shell still requires
        // the authoritative record.
        if let grant = AgeAccessSignUpOwnershipStore.pendingGrant(forEmail: email) {
            if let email { AgeAccessSignUpOwnershipStore.bindEmailIfUnbound(email) }
            switch grant.state {
            case .eligible13Plus:
                latestState = .eligible13Plus
                AgeAccessRuntimeLog.localCacheFound(userId: activeUserId, reason: "signup_grant_reused")
                return .allow
            case .under13:
                latestState = .under13
                if presentUI { presentation = .under13 }
                AgeAccessRuntimeLog.result(userId: activeUserId, state: .under13)
                return .blockedUnder13
            case .unknown, .unavailable, .declined, .error:
                break
            }
        }

        // Authenticated continuation without a grant: the authoritative server record
        // governs, exactly like any other social session.
        if let activeUserId {
            switch await ensureEligibleForSocialSession(
                userId: activeUserId,
                reason: .signUp,
                presentUI: presentUI
            ) {
            case .allow: return .allow
            case .blockedUnder13: return .blockedUnder13
            case .needsConfirmation: return .needsConfirmation
            }
        }

        let generation = sessionGeneration
        AgeAccessRuntimeLog.evaluationStarted(userId: nil, reason: .signUp)
        AgeAccessRuntimeLog.gateRequested(userId: nil, reason: .signUp)
        let state = await requestAgeRangeExclusive(for: nil, generation: generation, reason: .signUp)
        guard generation == sessionGeneration, activeUserId == nil else {
            AgeAccessRuntimeLog.staleResultIgnored(requestedUserId: nil, currentUserId: activeUserId)
            return .needsConfirmation
        }

        latestState = state
        AgeAccessRuntimeLog.gateResult(userId: nil, state: state)
        AgeAccessSignUpOwnershipStore.issue(state: state, email: email)

        switch state {
        case .eligible13Plus:
            presentation = nil
            AgeAccessRuntimeLog.result(userId: nil, state: state)
            return .allow
        case .under13:
            if presentUI { presentation = .under13 }
            AgeAccessRuntimeLog.result(userId: nil, state: state)
            return .blockedUnder13
        case .unknown, .unavailable, .declined, .error:
            if presentUI { presentation = .needsConfirmation }
            AgeAccessRuntimeLog.result(userId: nil, state: state)
            return .needsConfirmation
        }
    }

    /// Consumes the single-use sign-up grant for the UUID that finished that sign-up and
    /// records the coarse result server-side. Must be called only after the profile row
    /// exists. Never writes a local `eligible` — the following social-session hydration
    /// decides access from the authoritative record.
    @discardableResult
    func claimSignUpOwnership(userId: UUID, email: String?) async -> Bool {
        AgeAccessLocalStore.purgeDeviceLevelEligibility()

        guard let grant = AgeAccessSignUpOwnershipStore.pendingGrant(forEmail: email),
              let consumed = AgeAccessSignUpOwnershipStore.consume(token: grant.token) else {
            AgeAccessRuntimeLog.signUpGrantRejected(userId: userId, reason: "no_matching_grant")
            return false
        }

        AgeAccessRuntimeLog.signUpGrantConsumed(userId: userId, state: consumed.state)
        // The profile row may still be landing right after activation; the RPC rejects a
        // missing row, so retry briefly before giving up and re-prompting later.
        var recorded = false
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
            }
            recorded = await serverGateway.recordResult(userId, consumed.state)
            if recorded { break }
        }
        AgeAccessRuntimeLog.serverResultRecorded(userId: userId, state: consumed.state, success: recorded)

        if consumed.state == .under13 {
            AgeAccessLocalStore.persist(state: .under13, userId: userId, serverConfirmed: recorded)
            if activeUserId == userId {
                _ = applyBlockedUnder13(userId: userId, presentUI: true)
            }
        }
        return recorded
    }

    // MARK: - Existing authenticated social session

    /// Existing authenticated users: mandatory fail-closed check before social features.
    /// Hydrates the authoritative server record for THIS UUID on every session.
    func ensureEligibleForSocialSession(
        userId: UUID,
        reason: EvaluationReason,
        presentUI: Bool = true,
        sessionKind: AgeAccessSessionKind = .fan
    ) async -> AgeAccessSocialSessionDecision {
        bindAuthenticatedUser(userId, reason: reason)
        AgeAccessRuntimeLog.evaluationStarted(userId: userId, reason: reason)

        if AgeAccessLocalStore.cachedUnder13ForCurrentPolicy(userId: userId) {
            return applyBlockedUnder13(userId: userId, presentUI: presentUI)
        }

        if serverConfirmedUserIds.contains(userId),
           AgeAccessLocalStore.serverConfirmedEligible(userId: userId) {
            AgeAccessRuntimeLog.localCacheFound(userId: userId, reason: "session_server_confirmed")
            return allowEligible(userId: userId)
        }

        // Fail closed while resolution is pending.
        blocksSocialSession = true
        latestState = .unknown
        let generation = sessionGeneration

        let outcome = await serverGateway.loadState(userId)
        guard generation == sessionGeneration, activeUserId == userId else {
            AgeAccessRuntimeLog.staleResultIgnored(requestedUserId: userId, currentUserId: activeUserId)
            return .needsConfirmation
        }

        switch outcome {
        case .loaded(let snapshot):
            AgeAccessRuntimeLog.serverStatusLoaded(snapshot)

            if snapshot.isBlockedUnder13 {
                AgeAccessLocalStore.persist(state: .under13, userId: userId, serverConfirmed: true)
                return applyBlockedUnder13(userId: userId, presentUI: presentUI)
            }

            if snapshot.isEligibleForCurrentPolicy {
                markServerConfirmedEligible(userId)
                return allowEligible(userId: userId)
            }

            if sessionKind == .businessOwner, !snapshot.profileRowExists {
                // Venue-management-only session: there is no fan social surface to gate.
                businessOwnerExemptUserIds.insert(userId)
                blocksSocialSession = false
                isResolvingSocialSession = false
                presentation = nil
                AgeAccessRuntimeLog.socialSubsystemAllowed(
                    userId: userId,
                    subsystem: "business_owner_shell_without_fan_profile"
                )
                return .allow
            }

            // Server answered "not eligible under the current policy": a local eligible
            // cache is worthless here, no matter which account or device produced it.
            AgeAccessRuntimeLog.localCacheRejected(userId: userId, reason: snapshot.resolutionReason)
            revokeServerConfirmation(userId: userId)
            return await runGateAndRecord(
                userId: userId,
                generation: generation,
                reason: reason,
                presentUI: presentUI
            )

        case .unavailable(let failureReason):
            AgeAccessRuntimeLog.serverStatusUnavailable(userId: userId, reason: failureReason)
            if AgeAccessLocalStore.serverConfirmedEligibleWithinGrace(
                userId: userId,
                maxAge: Self.offlineGracePeriod
            ) {
                AgeAccessRuntimeLog.localCacheFound(userId: userId, reason: "offline_grace_server_unreachable")
                serverConfirmedUserIds.insert(userId)
                return allowEligible(userId: userId)
            }
            AgeAccessRuntimeLog.localCacheRejected(userId: userId, reason: "server_unreachable_without_confirmed_cache")
            latestState = .unknown
            blocksSocialSession = true
            isResolvingSocialSession = false
            if presentUI { presentation = .needsConfirmation }
            AgeAccessRuntimeLog.result(userId: userId, state: .unknown)
            AgeAccessRuntimeLog.socialShellBlocked(userId: userId, state: .unknown)
            return .needsConfirmation
        }
    }

    private func applyBlockedUnder13(userId: UUID, presentUI: Bool) -> AgeAccessSocialSessionDecision {
        businessOwnerExemptUserIds.remove(userId)
        latestState = .under13
        blocksSocialSession = true
        isResolvingSocialSession = false
        if presentUI { presentation = .under13 }
        AgeAccessRuntimeLog.result(userId: userId, state: .under13)
        AgeAccessRuntimeLog.socialShellBlocked(userId: userId, state: .under13)
        return .blockedUnder13
    }

    func retryConfirmation() async {
        presentation = nil
        if let activeUserId {
            _ = await ensureEligibleForSocialSession(userId: activeUserId, reason: .retry, presentUI: true)
        } else {
            _ = await ensureEligibleForSignUp(presentUI: true)
        }
    }

    func dismissNeedsConfirmation() {
        presentation = nil
    }

    func dismissUnder13() {
        presentation = nil
    }

    /// Fail-closed while an authenticated session exists but UUID/resolution is not ready.
    func failClosedPendingAuthenticatedResolution(presentNeedsConfirmation: Bool = true) {
        blocksSocialSession = true
        isResolvingSocialSession = false
        if presentNeedsConfirmation, presentation != .under13 {
            presentation = .needsConfirmation
        }
        latestState = latestState == .under13 ? .under13 : .unknown
    }

    /// Backend RPC/trigger denied a social write for this UUID. Applies the same
    /// blocking experience as a local under-13 result (single gate system).
    func applyServerSocialDenial(_ state: AgeAccessState, userId: UUID) {
        guard activeUserId == userId else {
            AgeAccessRuntimeLog.staleResultIgnored(requestedUserId: userId, currentUserId: activeUserId)
            return
        }
        latestState = state
        blocksSocialSession = true
        isResolvingSocialSession = false
        revokeServerConfirmation(userId: userId)
        if state == .under13 {
            AgeAccessLocalStore.persist(state: .under13, userId: userId, serverConfirmed: true)
            presentation = .under13
        } else if presentation != .under13 {
            presentation = .needsConfirmation
        }
        AgeAccessRuntimeLog.result(userId: userId, state: state)
        AgeAccessRuntimeLog.socialShellBlocked(userId: userId, state: state)
    }

#if DEBUG
    /// Test-only: replaces the Apple Declared Age Range request so self-tests never
    /// present real system UI (which would hang waiting for a human).
    var debugAppleRequestOverride: (@MainActor () async -> AgeAccessState)?

    func setSuppressRuntimeEventLogging(_ suppress: Bool) {
        suppressRuntimeEventLogging = suppress
    }

    /// Test-only: swap the authoritative server record source.
    func debugSetServerGateway(_ gateway: AgeAccessServerGateway) {
        serverGateway = gateway
    }

    func debugRestoreLiveServerGateway() {
        serverGateway = .live
    }

    var debugServerConfirmedUserIds: Set<UUID> { serverConfirmedUserIds }

    /// Test-only: reset shared singleton between deterministic cases.
    func debugResetForTests() {
        cancelInFlightEvaluation(reason: "debug_reset")
        presentation = nil
        isRequestInFlight = false
        activeUserId = nil
        latestState = .unknown
        blocksSocialSession = false
        isResolvingSocialSession = false
        serverConfirmedUserIds.removeAll()
        businessOwnerExemptUserIds.removeAll()
        sessionGeneration &+= 1
    }
#endif

    // MARK: - Apple Declared Age Range

    /// Runs the real Apple flow for an unresolved UUID, records the coarse result, then
    /// re-reads the authoritative record before granting anything.
    private func runGateAndRecord(
        userId: UUID,
        generation: UInt64,
        reason: EvaluationReason,
        presentUI: Bool
    ) async -> AgeAccessSocialSessionDecision {
        AgeAccessRuntimeLog.gateRequested(userId: userId, reason: reason)
        let state = await requestAgeRangeExclusive(for: userId, generation: generation, reason: reason)
        guard generation == sessionGeneration, activeUserId == userId else {
            AgeAccessRuntimeLog.staleResultIgnored(requestedUserId: userId, currentUserId: activeUserId)
            return .needsConfirmation
        }
        AgeAccessRuntimeLog.gateResult(userId: userId, state: state)

        let recorded = await serverGateway.recordResult(userId, state)
        guard generation == sessionGeneration, activeUserId == userId else {
            AgeAccessRuntimeLog.staleResultIgnored(requestedUserId: userId, currentUserId: activeUserId)
            return .needsConfirmation
        }
        AgeAccessRuntimeLog.serverResultRecorded(userId: userId, state: state, success: recorded)

        switch state {
        case .under13:
            AgeAccessLocalStore.persist(state: .under13, userId: userId, serverConfirmed: recorded)
            return applyBlockedUnder13(userId: userId, presentUI: presentUI)

        case .eligible13Plus:
            guard recorded else {
                return failClosedAfterUnresolvedGate(
                    userId: userId,
                    reason: "server_record_failed",
                    presentUI: presentUI
                )
            }
            let verification = await serverGateway.loadState(userId)
            guard generation == sessionGeneration, activeUserId == userId else {
                AgeAccessRuntimeLog.staleResultIgnored(requestedUserId: userId, currentUserId: activeUserId)
                return .needsConfirmation
            }
            if case .loaded(let snapshot) = verification {
                AgeAccessRuntimeLog.serverStatusLoaded(snapshot)
                if snapshot.isEligibleForCurrentPolicy {
                    markServerConfirmedEligible(userId)
                    return allowEligible(userId: userId)
                }
                return failClosedAfterUnresolvedGate(
                    userId: userId,
                    reason: snapshot.resolutionReason,
                    presentUI: presentUI
                )
            }
            if case .unavailable(let failureReason) = verification {
                AgeAccessRuntimeLog.serverStatusUnavailable(userId: userId, reason: failureReason)
            }
            return failClosedAfterUnresolvedGate(
                userId: userId,
                reason: "verification_unavailable",
                presentUI: presentUI
            )

        case .unknown, .unavailable, .declined, .error:
            return failClosedAfterUnresolvedGate(
                userId: userId,
                reason: "gate_\(state.rawValue)",
                presentUI: presentUI
            )
        }
    }

    private func failClosedAfterUnresolvedGate(
        userId: UUID,
        reason: String,
        presentUI: Bool
    ) -> AgeAccessSocialSessionDecision {
        AgeAccessLocalStore.persist(state: .unknown, userId: userId)
        revokeServerConfirmation(userId: userId)
        latestState = .unknown
        blocksSocialSession = true
        isResolvingSocialSession = false
        if presentUI { presentation = .needsConfirmation }
        AgeAccessRuntimeLog.localCacheRejected(userId: userId, reason: reason)
        AgeAccessRuntimeLog.result(userId: userId, state: .unknown)
        AgeAccessRuntimeLog.socialShellBlocked(userId: userId, state: .unknown)
        return .needsConfirmation
    }

    private func allowEligible(userId: UUID) -> AgeAccessSocialSessionDecision {
        latestState = .eligible13Plus
        blocksSocialSession = false
        isResolvingSocialSession = false
        presentation = nil
        AgeAccessRuntimeLog.result(userId: userId, state: .eligible13Plus)
        return .allow
    }

    private func markServerConfirmedEligible(_ userId: UUID) {
        serverConfirmedUserIds.insert(userId)
        AgeAccessLocalStore.persist(state: .eligible13Plus, userId: userId, serverConfirmed: true)
    }

    private func revokeServerConfirmation(userId: UUID) {
        serverConfirmedUserIds.remove(userId)
        businessOwnerExemptUserIds.remove(userId)
        AgeAccessLocalStore.invalidateServerConfirmation(userId: userId)
    }

    private func requestAgeRangeExclusive(
        for userId: UUID?,
        generation: UInt64,
        reason: EvaluationReason
    ) async -> AgeAccessState {
        if let inFlightTask,
           inFlightUserId == userId,
           inFlightGeneration == generation {
            return await inFlightTask.value
        }

        cancelInFlightEvaluation(reason: "replace_in_flight")
        AgeAccessRuntimeLog.requestStarted(userId: userId)

        let task = Task<AgeAccessState, Never> { @MainActor in
            defer {
                if self.inFlightGeneration == generation {
                    self.isRequestInFlight = false
                    self.inFlightTask = nil
                    self.inFlightUserId = nil
                }
            }
            self.isRequestInFlight = true
            return await self.performAppleAgeRangeRequest()
        }
        inFlightTask = task
        inFlightUserId = userId
        inFlightGeneration = generation
        let state = await task.value
        guard generation == sessionGeneration, activeUserId == userId else {
            AgeAccessRuntimeLog.staleResultIgnored(requestedUserId: userId, currentUserId: activeUserId)
            return .error
        }
        _ = reason
        return state
    }

    private func performAppleAgeRangeRequest() async -> AgeAccessState {
#if DEBUG
        if let debugAppleRequestOverride {
            return await debugAppleRequestOverride()
        }
#endif
        guard #available(iOS 26.0, *) else {
            return AgeAccessPolicy.evaluateUnavailable()
        }

        guard let viewController = AdMobRootViewController.topViewController() else {
            return AgeAccessPolicy.evaluateError()
        }

        do {
            let response = try await AgeRangeService.shared.requestAgeRange(
                ageGates: AgeAccessPolicy.minimumAgeYears,
                in: viewController
            )
            switch response {
            case .declinedSharing:
                return AgeAccessPolicy.evaluateDeclined()
            case .sharing(let range):
                // Do not log lowerBound/upperBound.
                return AgeAccessPolicy.evaluateSharing(lowerBound: range.lowerBound)
            @unknown default:
                return AgeAccessPolicy.evaluateError()
            }
        } catch let error as AgeRangeService.Error {
            switch error {
            case .notAvailable:
                return AgeAccessPolicy.evaluateUnavailable()
            case .invalidRequest:
                return AgeAccessPolicy.evaluateError()
            @unknown default:
                return AgeAccessPolicy.evaluateError()
            }
        } catch {
            return AgeAccessPolicy.evaluateError()
        }
    }

    private func cancelInFlightEvaluation(reason: String) {
        inFlightTask?.cancel()
        inFlightTask = nil
        inFlightUserId = nil
        inFlightGeneration = 0
        isRequestInFlight = false
        _ = reason
    }
}

// MARK: - Runtime logging (never used for self-test noise)

/// All events are prefixed `runtime_` so a real session can never be confused with the
/// DEBUG self-test suite, which emits `[AgeAccessGateTest]` / `[AgeAccessGateSelfTestEvent]`.
enum AgeAccessRuntimeLog {
    static func evaluationStarted(userId: UUID?, reason: AgeAccessGateService.EvaluationReason) {
        emit("runtime_evaluation_started userId=\(logUserId(userId)) reason=\(reason.rawValue)")
    }

    static func localState(userId: UUID?, state: AgeAccessState, policyVersion: String?) {
        emit("runtime_local_state userId=\(logUserId(userId)) state=\(runtimeStateName(state)) policyVersion=\(policyVersion ?? "nil")")
    }

    static func localCacheFound(userId: UUID?, reason: String) {
        emit("runtime_local_cache_found userId=\(logUserId(userId)) reason=\(reason)")
    }

    static func localCacheRejected(userId: UUID?, reason: String) {
        emit("runtime_local_cache_rejected userId=\(logUserId(userId)) reason=\(reason)")
    }

    static func serverStatusLoaded(_ snapshot: AgeAccessServerSnapshot) {
        emit(
            "runtime_server_status_loaded userId=\(logUserId(snapshot.userId))"
                + " status=\(runtimeStateName(snapshot.status))"
                + " policyVersion=\(snapshot.policyVersion ?? "nil")"
                + " serverPolicyVersion=\(snapshot.serverPolicyVersion)"
                + " checkedAt=\(snapshot.checkedAt == nil ? "nil" : "set")"
                + " profileRow=\(snapshot.profileRowExists ? "present" : "missing")"
                + " eligible=\(snapshot.isEligibleForCurrentPolicy)"
                + " reason=\(snapshot.resolutionReason)"
        )
    }

    static func serverStatusUnavailable(userId: UUID, reason: String) {
        emit("runtime_server_status_unavailable userId=\(logUserId(userId)) reason=\(reason)")
    }

    static func gateRequested(userId: UUID?, reason: AgeAccessGateService.EvaluationReason) {
        emit("runtime_gate_requested userId=\(logUserId(userId)) reason=\(reason.rawValue)")
    }

    static func gateResult(userId: UUID?, state: AgeAccessState) {
        emit("runtime_gate_result userId=\(logUserId(userId)) state=\(runtimeStateName(state))")
    }

    static func serverResultRecorded(userId: UUID, state: AgeAccessState, success: Bool) {
        emit("runtime_server_result_recorded userId=\(logUserId(userId)) status=\(state.serverStatus) success=\(success)")
    }

    static func signUpGrantConsumed(userId: UUID, state: AgeAccessState) {
        emit("runtime_signup_grant_consumed userId=\(logUserId(userId)) state=\(runtimeStateName(state))")
    }

    static func signUpGrantRejected(userId: UUID, reason: String) {
        emit("runtime_signup_grant_rejected userId=\(logUserId(userId)) reason=\(reason)")
    }

    static func requestStarted(userId: UUID?) {
        emit("runtime_request_started userId=\(logUserId(userId))")
    }

    static func result(userId: UUID?, state: AgeAccessState) {
        emit("runtime_result userId=\(logUserId(userId)) state=\(runtimeStateName(state))")
    }

    static func staleResultIgnored(requestedUserId: UUID?, currentUserId: UUID?) {
        emit("runtime_stale_result_ignored requestedUserId=\(logUserId(requestedUserId)) currentUserId=\(logUserId(currentUserId))")
    }

    static func socialShellMounted(userId: UUID) {
        emit("runtime_social_shell_mounted userId=\(logUserId(userId)) state=eligible")
    }

    static func socialShellBlocked(userId: UUID, state: AgeAccessState) {
        emit("runtime_social_shell_blocked userId=\(logUserId(userId)) state=\(runtimeStateName(state))")
    }

    static func socialSubsystemBlocked(userId: UUID?, subsystem: String) {
        emit("runtime_social_shell_blocked userId=\(logUserId(userId)) subsystem=\(subsystem)")
    }

    static func socialSubsystemAllowed(userId: UUID?, subsystem: String) {
        emit("runtime_social_shell_mounted userId=\(logUserId(userId)) subsystem=\(subsystem)")
    }

    static func sessionCleared(previousUserId: UUID) {
        emit("runtime_session_cleared previousUserId=\(logUserId(previousUserId))")
    }

    /// Coarse runtime state name for ContentView mount/block logs (never age/DOB).
    static func publicStateName(_ state: AgeAccessState) -> String {
        runtimeStateName(state)
    }

    private static func emit(_ message: String) {
#if DEBUG
        guard !AgeAccessGateService.shared.suppressRuntimeEventLogging else { return }
        print("[AgeAccessRuntime] \(message)")
#endif
    }

    private static func logUserId(_ userId: UUID?) -> String {
        userId?.uuidString.lowercased() ?? "nil"
    }

    private static func runtimeStateName(_ state: AgeAccessState) -> String {
        switch state {
        case .eligible13Plus: return "eligible"
        case .under13: return "blocked_under_13"
        case .declined: return "declined"
        case .unavailable: return "unavailable"
        case .error: return "error"
        case .unknown: return "unknown"
        }
    }
}
