import Foundation

extension AgeAccessLocalStore {
    private static func statusKey(userId: UUID?) -> String {
        if let userId {
            return "fangeo.age_access.status.v1.\(userId.uuidString.lowercased())"
        }
        return "fangeo.age_access.status.v1.device"
    }

    private static func policyKey(userId: UUID?) -> String {
        if let userId {
            return "fangeo.age_access.policy_version.v1.\(userId.uuidString.lowercased())"
        }
        return "fangeo.age_access.policy_version.v1.device"
    }

    private static func checkedAtKey(userId: UUID?) -> String {
        if let userId {
            return "fangeo.age_access.checked_at.v1.\(userId.uuidString.lowercased())"
        }
        return "fangeo.age_access.checked_at.v1.device"
    }

    /// Marks that this UUID's cached status was confirmed against the authoritative
    /// server record. Without it a cached `eligible` is never usable for access.
    private static func serverConfirmedKey(userId: UUID?) -> String {
        if let userId {
            return "fangeo.age_access.server_confirmed.v1.\(userId.uuidString.lowercased())"
        }
        return "fangeo.age_access.server_confirmed.v1.device"
    }

    // Legacy unscoped keys from the initial model — purged, never migrated forward.
    private static let legacyStatusKey = "fangeo.age_access.status.v1"
    private static let legacyPolicyKey = "fangeo.age_access.policy_version.v1"
    private static let legacyCheckedAtKey = "fangeo.age_access.checked_at.v1"

    static func loadPersistedState(userId: UUID?) -> (state: AgeAccessState, policyVersion: String?, checkedAt: Date?) {
        let raw = UserDefaults.standard.string(forKey: statusKey(userId: userId)) ?? ""
        let state = AgeAccessState(rawValue: raw) ?? .unknown
        let policy = UserDefaults.standard.string(forKey: policyKey(userId: userId))
        let checkedAt: Date? = {
            guard let iso = UserDefaults.standard.string(forKey: checkedAtKey(userId: userId)), !iso.isEmpty else { return nil }
            return ISO8601DateFormatter().date(from: iso)
        }()
        return (state, policy, checkedAt)
    }

    static func persist(
        state: AgeAccessState,
        policyVersion: String = AgeAccessPolicy.policyVersion,
        userId: UUID?,
        serverConfirmed: Bool = false
    ) {
        // Never persist exact age, birthdate, or Apple payload — coarse status only.
        UserDefaults.standard.set(state.rawValue, forKey: statusKey(userId: userId))
        UserDefaults.standard.set(policyVersion, forKey: policyKey(userId: userId))
        UserDefaults.standard.set(ISO8601DateFormatter().string(from: Date()), forKey: checkedAtKey(userId: userId))
        if serverConfirmed {
            UserDefaults.standard.set(true, forKey: serverConfirmedKey(userId: userId))
        } else {
            UserDefaults.standard.removeObject(forKey: serverConfirmedKey(userId: userId))
        }
    }

    static func clearAll(userId: UUID?) {
        UserDefaults.standard.removeObject(forKey: statusKey(userId: userId))
        UserDefaults.standard.removeObject(forKey: policyKey(userId: userId))
        UserDefaults.standard.removeObject(forKey: checkedAtKey(userId: userId))
        UserDefaults.standard.removeObject(forKey: serverConfirmedKey(userId: userId))
    }

    /// Drops the server-confirmation marker while keeping the coarse status, so the
    /// next session must re-hydrate from the server before allowing social access.
    static func invalidateServerConfirmation(userId: UUID?) {
        UserDefaults.standard.removeObject(forKey: serverConfirmedKey(userId: userId))
    }

    /// Removes every device-scoped / legacy-unscoped eligibility artifact. Device-level
    /// eligibility is no longer a thing that can authorize any UUID; sign-up grants are
    /// tracked by ``AgeAccessSignUpOwnershipStore`` instead.
    static func purgeDeviceLevelEligibility() {
        clearAll(userId: nil)
        UserDefaults.standard.removeObject(forKey: legacyStatusKey)
        UserDefaults.standard.removeObject(forKey: legacyPolicyKey)
        UserDefaults.standard.removeObject(forKey: legacyCheckedAtKey)
    }

    /// Local-only view of the cache. NEVER sufficient to authorize social access —
    /// use ``serverConfirmedEligible(userId:)`` for that.
    static func locallyCachedEligibleForCurrentPolicy(userId: UUID?) -> Bool {
        let persisted = loadPersistedState(userId: userId)
        return persisted.state == .eligible13Plus
            && persisted.policyVersion == AgeAccessPolicy.policyVersion
    }

    static func cachedUnder13ForCurrentPolicy(userId: UUID?) -> Bool {
        let persisted = loadPersistedState(userId: userId)
        return persisted.state == .under13
            && persisted.policyVersion == AgeAccessPolicy.policyVersion
    }

    /// True only when this exact UUID's cached `eligible` was written after the
    /// authoritative server record confirmed eligibility for the current policy.
    static func serverConfirmedEligible(userId: UUID) -> Bool {
        guard UserDefaults.standard.bool(forKey: serverConfirmedKey(userId: userId)) else { return false }
        let persisted = loadPersistedState(userId: userId)
        return persisted.state == .eligible13Plus
            && persisted.policyVersion == AgeAccessPolicy.policyVersion
            && persisted.checkedAt != nil
    }

    /// Same-UUID server-confirmed cache that is still recent enough to cover a
    /// transport failure (offline launch). Not usable when the server actually
    /// answered with unknown / stale / missing timestamp.
    static func serverConfirmedEligibleWithinGrace(
        userId: UUID,
        maxAge: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        guard serverConfirmedEligible(userId: userId) else { return false }
        guard let checkedAt = loadPersistedState(userId: userId).checkedAt else { return false }
        let age = now.timeIntervalSince(checkedAt)
        return age >= 0 && age <= maxAge
    }
}
