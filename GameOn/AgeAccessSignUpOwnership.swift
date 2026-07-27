import Foundation

/// A single-use grant proving that one specific sign-up transaction completed a real
/// Apple Declared Age Range request before an auth UUID existed.
///
/// Replaces the old globally reusable device-level eligibility flag: a grant is bound
/// to the sign-up email that produced it, expires, and is destroyed the moment it is
/// consumed by the UUID that finished that same sign-up.
struct AgeAccessSignUpOwnership: Codable, Equatable, Sendable {
    let token: UUID
    let stateRaw: String
    let policyVersion: String
    let createdAt: Date
    /// Normalized sign-up email when known. `nil` for pre-email pathways (Apple).
    let boundEmail: String?

    var state: AgeAccessState { AgeAccessState(rawValue: stateRaw) ?? .unknown }

    var isCurrentPolicy: Bool { policyVersion == AgeAccessPolicy.policyVersion }

    func isExpired(now: Date = Date(), lifetime: TimeInterval) -> Bool {
        now.timeIntervalSince(createdAt) > lifetime || now < createdAt
    }

    func matches(email: String?) -> Bool {
        guard let boundEmail, !boundEmail.isEmpty else { return true }
        guard let email else { return false }
        return boundEmail == AgeAccessSignUpOwnershipStore.normalize(email)
    }
}

/// Durable store for the outstanding sign-up grant. At most one grant exists at a time.
enum AgeAccessSignUpOwnershipStore {
    private static let storageKey = "fangeo.age_access.signup_ownership.v1"

    /// Long enough to survive an email-confirmation round trip, short enough that an
    /// abandoned sign-up cannot be harvested by an unrelated account later.
    static let lifetime: TimeInterval = 24 * 60 * 60

    nonisolated static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    @discardableResult
    static func issue(
        state: AgeAccessState,
        email: String?,
        now: Date = Date()
    ) -> AgeAccessSignUpOwnership? {
        guard state == .eligible13Plus || state == .under13 else {
            clear()
            return nil
        }
        let ownership = AgeAccessSignUpOwnership(
            token: UUID(),
            stateRaw: state.rawValue,
            policyVersion: AgeAccessPolicy.policyVersion,
            createdAt: now,
            boundEmail: email.map(normalize)
        )
        guard let data = try? JSONEncoder().encode(ownership) else { return nil }
        UserDefaults.standard.set(data, forKey: storageKey)
        return ownership
    }

    /// Rebinds the outstanding grant to the email that the user finally submitted.
    /// Only allowed while the grant is still unbound.
    static func bindEmailIfUnbound(_ email: String) {
        guard let ownership = outstanding(),
              ownership.boundEmail == nil else { return }
        let rebound = AgeAccessSignUpOwnership(
            token: ownership.token,
            stateRaw: ownership.stateRaw,
            policyVersion: ownership.policyVersion,
            createdAt: ownership.createdAt,
            boundEmail: normalize(email)
        )
        guard let data = try? JSONEncoder().encode(rebound) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// The outstanding grant, or `nil` when absent / expired / stale policy.
    /// Expired or stale grants are purged on read so they can never be reused.
    static func outstanding(now: Date = Date()) -> AgeAccessSignUpOwnership? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let ownership = try? JSONDecoder().decode(AgeAccessSignUpOwnership.self, from: data) else {
            return nil
        }
        guard ownership.isCurrentPolicy,
              !ownership.isExpired(now: now, lifetime: lifetime) else {
            clear()
            return nil
        }
        return ownership
    }

    /// Single-use consumption. The grant is destroyed whether or not the caller accepts it.
    static func consume(token: UUID, now: Date = Date()) -> AgeAccessSignUpOwnership? {
        guard let ownership = outstanding(now: now) else { return nil }
        clear()
        return ownership.token == token ? ownership : nil
    }

    /// Resolves the grant that a finishing sign-up transaction is allowed to consume.
    static func pendingGrant(forEmail email: String?, now: Date = Date()) -> AgeAccessSignUpOwnership? {
        guard let ownership = outstanding(now: now) else { return nil }
        return ownership.matches(email: email) ? ownership : nil
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
