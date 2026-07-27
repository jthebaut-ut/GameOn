import Foundation
import Supabase

extension MapViewModel {
    /// Account-appear / startup preferences hydration. Freshness window + in-flight dedup keep
    /// repeated Account visits from re-hitting `user_profiles`. Local edits publish immediately via
    /// ``saveFanIdentityPreferences``, and account changes rekey the freshness owner, so a stale
    /// window can never hide a legitimate change.
    private static let fanIdentityPreferencesFreshnessInterval: TimeInterval = 5 * 60

    @MainActor
    func loadFanIdentityPreferencesFromProfile(forceRefresh: Bool = false) async {
        guard let authId = currentUserAuthId else { return }

        if !forceRefresh, let inFlight = fanIdentityPreferencesLoadTask {
            AccountActivationPerf.refreshDeduplicated(name: "fanIdentityPreferences")
            await inFlight.value
            return
        }

        if !forceRefresh,
           lastFanIdentityPreferencesLoadUserId == authId,
           let last = lastFanIdentityPreferencesLoadAt {
            let age = Date().timeIntervalSince(last)
            if age < Self.fanIdentityPreferencesFreshnessInterval {
                AccountActivationPerf.refreshSkippedFresh(
                    name: "fanIdentityPreferences",
                    ageMs: Int(age * 1000)
                )
                return
            }
        }

        let task = Task<Void, Never> { [weak self] in
            await self?.loadFanIdentityPreferencesFromProfileNow(authId: authId)
        }
        fanIdentityPreferencesLoadTask = task
        await task.value
        fanIdentityPreferencesLoadTask = nil
    }

    @MainActor
    private func loadFanIdentityPreferencesFromProfileNow(authId: UUID) async {
        struct Row: Decodable {
            let fan_identity_preferences: FanIdentityPreferences?
        }
        do {
            let rows: [Row] = try await supabase
                .from("user_profiles")
                .select("fan_identity_preferences")
                .eq("id", value: authId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value
            guard currentUserAuthId == authId else {
                AccountActivationPerf.log("staleResultIgnored context=fanIdentityPreferences")
                return
            }
            currentUserFanIdentityPreferences = rows.first?.fan_identity_preferences ?? .empty
            lastFanIdentityPreferencesLoadAt = Date()
            lastFanIdentityPreferencesLoadUserId = authId
        } catch {
#if DEBUG
            print("[FanIdentityPrefs] load_failed error=\(error.localizedDescription)")
#endif
        }
    }

    /// Persists JSONB preferences for the signed-in fan.
    @discardableResult
    func saveFanIdentityPreferences(_ preferences: FanIdentityPreferences) async -> String? {
        guard let authId = currentUserAuthId else {
            return "Sign in to save your fan identity."
        }

        struct Patch: Encodable {
            let fan_identity_preferences: FanIdentityPreferences
        }

        let payloadIDs = FanOpenToCatalog.canonicalizeItemIDs(preferences.openToItems)
        if let payloadData = try? JSONEncoder().encode(
            ["open_to_items": payloadIDs]
        ),
           let payloadJSON = String(data: payloadData, encoding: .utf8) {
            print("[OpenToDebug] savePayload= \(payloadJSON)")
        }

        do {
            try await supabase
                .from("user_profiles")
                .update(Patch(fan_identity_preferences: preferences))
                .eq("id", value: authId.uuidString.lowercased())
                .execute()
            await MainActor.run {
                currentUserFanIdentityPreferences = preferences
                publicProfileOpenToRevision &+= 1
            }
            print("[OpenToDebug] savedPreferences= ids=\(preferences.resolvedOpenToItemIDs)")
            return nil
        } catch {
#if DEBUG
            print("[FanIdentityPrefs] save_failed error=\(error.localizedDescription)")
#endif
            return "Couldn't save fan identity. Please try again."
        }
    }
}
