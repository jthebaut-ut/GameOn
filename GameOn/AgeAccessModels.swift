import Foundation

/// Coarse FanGeo age-access eligibility. Never stores exact age or birthdate.
///
/// Pure value logic with no shared mutable state, so it stays `nonisolated` even under
/// the module's `MainActor` default isolation and can be evaluated from any context.
nonisolated enum AgeAccessState: String, Codable, Equatable, Sendable {
    case unknown
    case eligible13Plus
    case under13
    case unavailable
    case declined
    case error

    /// Server-side coarse status values (migration `age_access_status`).
    var serverStatus: String {
        switch self {
        case .eligible13Plus: return "eligible"
        case .under13: return "blocked_under_13"
        case .unknown, .unavailable, .declined, .error: return "unknown"
        }
    }

    static func fromServerStatus(_ raw: String?) -> AgeAccessState {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "eligible": return .eligible13Plus
        case "blocked_under_13": return .under13
        default: return .unknown
        }
    }

    var allowsSignUp: Bool { self == .eligible13Plus }
    var allowsSocialSession: Bool { self == .eligible13Plus }
    var isBlockingUnder13: Bool { self == .under13 }
    var needsRetryConfirmation: Bool {
        switch self {
        case .unknown, .unavailable, .declined, .error: return true
        case .eligible13Plus, .under13: return false
        }
    }
}

/// Pure policy evaluation with immutable constants; safe to read from any isolation.
nonisolated enum AgeAccessPolicy {
    /// Declared Age Range gate threshold (years).
    static let minimumAgeYears = 13
    /// Bump when eligibility rules change to force re-check without storing ages.
    static let policyVersion = "1"

    /// Maps Apple Declared Age Range sharing result into FanGeo policy.
    /// - Parameter lowerBound: `nil` means below the first age gate (under 13 when gate is 13).
    static func evaluateSharing(lowerBound: Int?) -> AgeAccessState {
        guard let lowerBound else { return .under13 }
        return lowerBound >= minimumAgeYears ? .eligible13Plus : .under13
    }

    static func evaluateDeclined() -> AgeAccessState { .declined }

    static func evaluateUnavailable() -> AgeAccessState { .unavailable }

    static func evaluateError() -> AgeAccessState { .error }
}

enum AgeAccessLocalStore {}

/// Detects the backend age-denial sentinel raised by
/// `public.assert_age_access_allows_social()` / social-write triggers and routes it
/// into the one existing age gate (never a second gate system).
enum AgeAccessBackendDenial {
    /// Server sentinel messages (ERRCODE 42501). Keep in sync with migrations.
    static let under13Sentinel = "age_access_blocked_under_13"
    static let unresolvedSentinel = "age_access_unresolved"

    static func matches(_ error: Error) -> Bool {
        deniedState(for: error) != nil
    }

    static func deniedState(for error: Error) -> AgeAccessState? {
        let raw = String(describing: error).lowercased()
        if raw.contains(under13Sentinel) { return .under13 }
        if raw.contains(unresolvedSentinel) { return .unknown }
        return nil
    }

    /// Call from social-mutation catch blocks. Returns true when the error was an
    /// age denial and the blocking UI has been triggered (or the response was stale).
    /// - Parameter requestUserId: auth UUID captured when the request started, so
    ///   responses arriving after logout/account switch are ignored.
    @MainActor
    @discardableResult
    static func handle(_ error: Error, requestUserId: UUID?) -> Bool {
        guard let state = deniedState(for: error) else { return false }
        let gate = AgeAccessGateService.shared
        guard let activeUserId = gate.activeUserId else {
            // Logged out before the response arrived — consume silently.
            return true
        }
        if let requestUserId, requestUserId != activeUserId {
            // Stale response from a previous account — never mutate the current gate.
            return true
        }
        gate.applyServerSocialDenial(state, userId: activeUserId)
        return true
    }
}

enum AgeAccessDebugLog {
    static func event(_ name: String) {
#if DEBUG
        // Never log age, range, birthdate, or Apple payloads.
        // Runtime outcomes use AgeAccessRuntimeLog (`[AgeAccessRuntime]`).
        // Self-tests must call setSuppressRuntimeEventLogging(true) first.
        if AgeAccessGateService.shared.suppressRuntimeEventLogging {
            print("[AgeAccessGateSelfTestEvent] \(name)")
            return
        }
        print("[AgeAccessGate] \(name)")
#endif
    }
}
