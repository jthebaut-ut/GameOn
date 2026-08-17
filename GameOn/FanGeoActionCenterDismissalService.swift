import Foundation
import Supabase

/// Per-user Action Center hide ledger (`action_center_dismissals`).
///
/// Dismissing never deletes the underlying game / invite / rating / notification.
/// Server persistence is preferred; local UserDefaults is a cache + pre-migration fallback.
enum FanGeoActionCenterDismissalService {
    private static let table = "action_center_dismissals"

    struct DismissalRow: Codable, Sendable {
        var user_id: UUID
        var action_key: String
    }

    static func fetchKeys(userId: UUID) async throws -> Set<String> {
        let rows: [DismissalRow] = try await supabase
            .from(table)
            .select("user_id,action_key")
            .eq("user_id", value: userId.uuidString.lowercased())
            .execute()
            .value
        return Set(rows.map(\.action_key).filter { !$0.isEmpty })
    }

    static func upsert(userId: UUID, actionKeys: [String]) async throws {
        let keys = FanGeoActionCenterActionKey.sanitizedUnique(actionKeys)
        guard !keys.isEmpty else { return }
        let rows = keys.map {
            DismissalRow(user_id: userId, action_key: $0)
        }
        try await supabase
            .from(table)
            .upsert(rows, onConflict: "user_id,action_key")
            .execute()
    }

    static func delete(userId: UUID, actionKeys: [String]) async throws {
        let keys = FanGeoActionCenterActionKey.sanitizedUnique(actionKeys)
        guard !keys.isEmpty else { return }
        try await supabase
            .from(table)
            .delete()
            .eq("user_id", value: userId.uuidString.lowercased())
            .in("action_key", values: keys)
            .execute()
    }
}

/// Stable Action Center item keys. Do not use title/date strings as identity.
enum FanGeoActionCenterActionKey {
    static func teamInvite(_ invitationId: UUID) -> String {
        "team_invite:\(invitationId.uuidString.lowercased())"
    }

    static func pickupInvite(_ inviteId: UUID) -> String {
        "pickup_invite:\(inviteId.uuidString.lowercased())"
    }

    static func friendRequest(_ friendshipId: UUID) -> String {
        "friend_request:\(friendshipId.uuidString.lowercased())"
    }

    static func joinApproval(_ requestId: UUID) -> String {
        "join_approval:\(requestId.uuidString.lowercased())"
    }

    static func rateGame(_ pickupGameId: UUID) -> String {
        "rate_game:\(pickupGameId.uuidString.lowercased())"
    }

    static func pickupUpdate(gameId: UUID, instanceKey: String) -> String {
        "pickup_update:\(gameId.uuidString.lowercased()):\(sanitizedInstance(instanceKey))"
    }

    static func pickupCancel(gameId: UUID, instanceKey: String) -> String {
        "pickup_cancel:\(gameId.uuidString.lowercased()):\(sanitizedInstance(instanceKey))"
    }

    static func poke(_ pokeId: UUID) -> String {
        "poke:\(pokeId.uuidString.lowercased())"
    }

    static let businessClaim = "business_claim"
    static let teamInvitesAggregate = "team_invites"
    static let friendRequestsAggregate = "friend_requests"
    static let joinApprovalsAggregate = "join_approvals"
    static let scheduleActivityAggregate = "schedule_activity"
    static let pokesAggregate = "pokes"

    /// Deterministic short fingerprint of a game-state signature (stable across launches).
    static func instanceKey(fromSignature signature: String) -> String {
        let trimmed = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "current" }
        return fnv1a64Hex(trimmed)
    }

    private static let pendingRequestPrefixes = [
        "team_invite:",
        "pickup_invite:",
        "friend_request:",
        "join_approval:"
    ]

    private static let pendingRequestExactKeys: Set<String> = [
        teamInvitesAggregate,
        friendRequestsAggregate,
        joinApprovalsAggregate
    ]

    /// Pending accept/decline keys must not live in `action_center_dismissals`.
    static func isPendingRequestKey(_ raw: String) -> Bool {
        let key = sanitize(raw)
        if pendingRequestExactKeys.contains(key) { return true }
        return pendingRequestPrefixes.contains { key.hasPrefix($0) }
    }

    /// Count-fallback Action Needed rows (`team_invites`, `friend_requests`, `join_approvals`)
    /// share this family with per-item snooze keys so cold launch cannot flash an aggregate
    /// while detailed rows are still loading.
    static func aggregateKey(coveringPendingKey raw: String) -> String? {
        let key = sanitize(raw)
        if key == teamInvitesAggregate || key.hasPrefix("team_invite:") {
            return teamInvitesAggregate
        }
        if key == friendRequestsAggregate || key.hasPrefix("friend_request:") {
            return friendRequestsAggregate
        }
        if key == joinApprovalsAggregate || key.hasPrefix("join_approval:") {
            return joinApprovalsAggregate
        }
        return nil
    }

    static func isHiddenByPendingSnooze(_ raw: String, snoozed: Set<String>) -> Bool {
        let key = sanitize(raw)
        if snoozed.contains(key) { return true }
        guard let family = aggregateKey(coveringPendingKey: key), key == family else { return false }
        return snoozed.contains { aggregateKey(coveringPendingKey: $0) == family }
    }

    static func isDetailedPendingKey(_ raw: String) -> Bool {
        let key = sanitize(raw)
        guard isPendingRequestKey(key) else { return false }
        return aggregateKey(coveringPendingKey: key) != key
    }

    static func retainingPermanentKeys(in keys: Set<String>) -> Set<String> {
        Set(keys.filter { !isPendingRequestKey($0) })
    }

    static func sanitizedUnique(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in keys {
            let key = sanitize(raw)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(key)
        }
        return result
    }

    static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = trimmed.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "-_:.".contains($0)) }
        guard filtered.count <= 180 else { return String(filtered.prefix(180)) }
        return filtered
    }

    private static func sanitizedInstance(_ raw: String) -> String {
        let value = sanitize(raw)
        return value.isEmpty ? "current" : value
    }

    private static func fnv1a64Hex(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

enum ActionCenterDismissDebug {
    static func log(_ message: String) {
#if DEBUG
        print("[ActionCenterDismissDebug] \(message)")
#endif
    }
}

/// Local Action Needed hide ledger used on cold launch **before** remote reconcile.
///
/// Permanent keys stay in `action_center_dismissals` / UserDefaults.
/// Pending-request X is a local TTL snooze — not a server permanent dismissal.
enum FanGeoActionCenterLocalVisibility {
    static let pendingSnoozeTTL: TimeInterval = 60 * 60

    static func dismissalDefaultsKey(userId: UUID) -> String {
        "fangeo.actionCenter.dismissedKeys.\(userId.uuidString.lowercased())"
    }

    static func pendingSnoozeDefaultsKey(userId: UUID) -> String {
        "fangeo.actionCenter.pendingSnooze.v1.\(userId.uuidString.lowercased())"
    }

    private static let lastUserDefaultsKey = "fangeo.actionCenter.lastUserId.v1"

    static func lastKnownUserId() -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: lastUserDefaultsKey) else { return nil }
        return UUID(uuidString: raw)
    }

    static func rememberUserId(_ userId: UUID) {
        let value = userId.uuidString.lowercased()
        guard UserDefaults.standard.string(forKey: lastUserDefaultsKey) != value else { return }
        UserDefaults.standard.set(value, forKey: lastUserDefaultsKey)
        flush()
    }

    static func resolvedUserId(_ inMemory: UUID?) -> UUID? {
        if let inMemory {
            rememberUserId(inMemory)
            return inMemory
        }
        return lastKnownUserId()
    }

    private static func flush() {
        UserDefaults.standard.synchronize()
    }

    static func loadPermanentDismissedKeys(userId: UUID) -> Set<String> {
        let raw = UserDefaults.standard.stringArray(
            forKey: dismissalDefaultsKey(userId: userId)
        ) ?? []
        return FanGeoActionCenterActionKey.retainingPermanentKeys(
            in: Set(FanGeoActionCenterActionKey.sanitizedUnique(raw))
        )
    }

    static func savePermanentDismissedKeys(_ keys: Set<String>, userId: UUID) {
        let permanent = FanGeoActionCenterActionKey.retainingPermanentKeys(in: keys)
        let defaultsKey = dismissalDefaultsKey(userId: userId)
        if permanent.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            flush()
            return
        }
        UserDefaults.standard.set(Array(permanent).sorted(), forKey: defaultsKey)
        flush()
    }

    static func loadPendingSnooze(userId: UUID, now: Date = Date()) -> [String: Date] {
        let raw = UserDefaults.standard.dictionary(
            forKey: pendingSnoozeDefaultsKey(userId: userId)
        ) as? [String: Double] ?? [:]
        var map: [String: Date] = [:]
        for (key, interval) in raw {
            map[key] = Date(timeIntervalSince1970: interval)
        }
        let prunedMap = prunedPendingSnooze(map, now: now)
        if prunedMap.count != map.count {
            savePendingSnooze(prunedMap, userId: userId, now: now)
        }
        return prunedMap
    }

    static func savePendingSnooze(_ map: [String: Date], userId: UUID, now: Date = Date()) {
        let prunedMap = prunedPendingSnooze(map, now: now)
        let defaultsKey = pendingSnoozeDefaultsKey(userId: userId)
        if prunedMap.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            flush()
            return
        }
        var payload: [String: Double] = [:]
        payload.reserveCapacity(prunedMap.count)
        for (key, date) in prunedMap {
            payload[key] = date.timeIntervalSince1970
        }
        UserDefaults.standard.set(payload, forKey: defaultsKey)
        flush()
    }

    static func clearPendingSnooze(userId: UUID) {
        UserDefaults.standard.removeObject(forKey: pendingSnoozeDefaultsKey(userId: userId))
        flush()
    }

    static func applyingPendingSnooze(
        keys: [String],
        to map: [String: Date],
        now: Date = Date()
    ) -> [String: Date] {
        var next = map
        for key in FanGeoActionCenterActionKey.sanitizedUnique(keys)
        where FanGeoActionCenterActionKey.isPendingRequestKey(key) {
            next[key] = now
            if let aggregate = FanGeoActionCenterActionKey.aggregateKey(coveringPendingKey: key) {
                next[aggregate] = now
            }
        }
        return prunedPendingSnooze(next, now: now)
    }

    static func removingPendingSnooze(
        keys: [String],
        from map: [String: Date],
        now: Date = Date()
    ) -> [String: Date] {
        var next = map
        for key in FanGeoActionCenterActionKey.sanitizedUnique(keys) {
            next.removeValue(forKey: key)
        }
        return prunedPendingSnooze(next, now: now)
    }

    static func activePendingSnoozeKeys(in map: [String: Date], now: Date = Date()) -> Set<String> {
        let cutoff = now.addingTimeInterval(-pendingSnoozeTTL)
        var keys: Set<String> = []
        for (raw, hiddenAt) in map {
            let key = FanGeoActionCenterActionKey.sanitize(raw)
            guard FanGeoActionCenterActionKey.isPendingRequestKey(key), hiddenAt >= cutoff else { continue }
            keys.insert(key)
        }
        return keys
    }

    /// First Inbox paint must apply locally-known hides even if in-memory hydrate has not run.
    static func dismissedKeysForProjection(inMemory: Set<String>, userId: UUID?) -> Set<String> {
        if inMemory.isEmpty, let userId {
            return loadPermanentDismissedKeys(userId: userId)
        }
        return FanGeoActionCenterActionKey.retainingPermanentKeys(in: inMemory)
    }

    static func pendingSnoozeKeysForProjection(
        inMemory: [String: Date],
        userId: UUID?,
        now: Date = Date()
    ) -> Set<String> {
        let map: [String: Date]
        if inMemory.isEmpty, let userId {
            map = loadPendingSnooze(userId: userId, now: now)
        } else {
            map = inMemory
        }
        return activePendingSnoozeKeys(in: map, now: now)
    }

    static func clearAllHiddenDefaultsKey(userId: UUID) -> String {
        "fangeo.actionCenter.clearAllHidden.v1.\(userId.uuidString.lowercased())"
    }

    static func lastKnownPendingDefaultsKey(userId: UUID) -> String {
        "fangeo.actionCenter.lastKnownPending.v1.\(userId.uuidString.lowercased())"
    }

    static func loadClearAllHiddenKeys(userId: UUID) -> Set<String> {
        let raw = UserDefaults.standard.stringArray(
            forKey: clearAllHiddenDefaultsKey(userId: userId)
        ) ?? []
        return Set(
            FanGeoActionCenterActionKey.sanitizedUnique(raw).filter {
                FanGeoActionCenterActionKey.isDetailedPendingKey($0)
            }
        )
    }

    static func saveClearAllHiddenKeys(_ keys: Set<String>, userId: UUID) {
        let detailed = Set(
            FanGeoActionCenterActionKey.sanitizedUnique(Array(keys)).filter {
                FanGeoActionCenterActionKey.isDetailedPendingKey($0)
            }
        )
        let defaultsKey = clearAllHiddenDefaultsKey(userId: userId)
        if detailed.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            flush()
            return
        }
        UserDefaults.standard.set(Array(detailed).sorted(), forKey: defaultsKey)
        flush()
    }

    static func loadLastKnownPendingKeys(userId: UUID) -> Set<String> {
        let raw = UserDefaults.standard.stringArray(
            forKey: lastKnownPendingDefaultsKey(userId: userId)
        ) ?? []
        return Set(
            FanGeoActionCenterActionKey.sanitizedUnique(raw).filter {
                FanGeoActionCenterActionKey.isDetailedPendingKey($0)
            }
        )
    }

    static func saveLastKnownPendingKeys(_ keys: Set<String>, userId: UUID) {
        let detailed = Set(
            FanGeoActionCenterActionKey.sanitizedUnique(Array(keys)).filter {
                FanGeoActionCenterActionKey.isDetailedPendingKey($0)
            }
        )
        let defaultsKey = lastKnownPendingDefaultsKey(userId: userId)
        if detailed.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            flush()
            return
        }
        UserDefaults.standard.set(Array(detailed).sorted(), forKey: defaultsKey)
        flush()
    }

    static func mergingLastKnownPendingKeys(_ incoming: [String], into existing: Set<String>) -> Set<String> {
        var next = existing
        for key in FanGeoActionCenterActionKey.sanitizedUnique(incoming)
        where FanGeoActionCenterActionKey.isDetailedPendingKey(key) {
            next.insert(key)
        }
        return next
    }

    static func applyingClearAllHidden(
        visibleIds: [String],
        lastKnownPendingKeys: Set<String>,
        to hidden: Set<String>
    ) -> Set<String> {
        var next = hidden
        for id in FanGeoActionCenterActionKey.sanitizedUnique(visibleIds) {
            if FanGeoActionCenterActionKey.isDetailedPendingKey(id) {
                next.insert(id)
                continue
            }
            guard let family = FanGeoActionCenterActionKey.aggregateKey(coveringPendingKey: id),
                  family == FanGeoActionCenterActionKey.sanitize(id) else { continue }
            for known in lastKnownPendingKeys
            where FanGeoActionCenterActionKey.aggregateKey(coveringPendingKey: known) == family {
                next.insert(known)
            }
        }
        return next
    }

    static func clearAllHiddenKeysForProjection(inMemory: Set<String>, userId: UUID?) -> Set<String> {
        if inMemory.isEmpty, let userId {
            return loadClearAllHiddenKeys(userId: userId)
        }
        return Set(
            FanGeoActionCenterActionKey.sanitizedUnique(Array(inMemory)).filter {
                FanGeoActionCenterActionKey.isDetailedPendingKey($0)
            }
        )
    }

    static func lastKnownPendingKeysForProjection(inMemory: Set<String>, userId: UUID?) -> Set<String> {
        var keys = inMemory
        if let userId {
            keys.formUnion(loadLastKnownPendingKeys(userId: userId))
        }
        return Set(
            FanGeoActionCenterActionKey.sanitizedUnique(Array(keys)).filter {
                FanGeoActionCenterActionKey.isDetailedPendingKey($0)
            }
        )
    }

    /// Count-fallback aggregates hide only when this family already has Clear-All'd detailed IDs.
    /// New detailed IDs are not stored as a family ban and still appear when their rows load.
    static func isHiddenByClearAll(
        _ raw: String,
        hidden: Set<String>,
        lastKnownPendingKeys: Set<String>
    ) -> Bool {
        let key = FanGeoActionCenterActionKey.sanitize(raw)
        if hidden.contains(key) { return true }
        guard let family = FanGeoActionCenterActionKey.aggregateKey(coveringPendingKey: key),
              key == family else { return false }
        return lastKnownPendingKeys.contains {
            FanGeoActionCenterActionKey.aggregateKey(coveringPendingKey: $0) == family
                && hidden.contains($0)
        }
    }

    static func clearClearAllHidden(userId: UUID) {
        UserDefaults.standard.removeObject(forKey: clearAllHiddenDefaultsKey(userId: userId))
        UserDefaults.standard.removeObject(forKey: lastKnownPendingDefaultsKey(userId: userId))
        flush()
    }

    private static func prunedPendingSnooze(_ map: [String: Date], now: Date) -> [String: Date] {
        let cutoff = now.addingTimeInterval(-pendingSnoozeTTL)
        var next: [String: Date] = [:]
        for (raw, date) in map {
            let key = FanGeoActionCenterActionKey.sanitize(raw)
            guard FanGeoActionCenterActionKey.isPendingRequestKey(key), date >= cutoff else { continue }
            next[key] = date
        }
        return next
    }
}
