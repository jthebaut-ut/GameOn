import Foundation

/// Per-user DM history clear watermarks (`cleared_at` by conversation).
/// Keys include auth user id so account switches never leak User A's clear onto User B.
enum DmConversationClearStore {
    private static let keyPrefix = "dm.conversation.clearedAt.v2."
    /// Legacy dictionary storage (broken `as? [String: String]` cast on read-back).
    private static let legacyKeyPrefix = "dm.conversation.clearedAt."

    static func clearedAt(conversationId: UUID, authId: UUID) -> Date? {
        migrateLegacyIfNeeded(authId: authId)
        let map = loadMap(authId: authId)
        guard let raw = map[conversationId.uuidString.lowercased()] else { return nil }
        return parse(raw)
    }

    static func setClearedAt(_ date: Date, conversationId: UUID, authId: UUID) {
        migrateLegacyIfNeeded(authId: authId)
        var map = loadMap(authId: authId)
        map[conversationId.uuidString.lowercased()] = isoString(date)
        persist(map, authId: authId)
    }

    static func clearAll(authId: UUID) {
        UserDefaults.standard.removeObject(forKey: storageKey(authId: authId))
        UserDefaults.standard.removeObject(forKey: legacyStorageKey(authId: authId))
    }

    /// Replace local cache from server rows for this auth user.
    static func replaceAll(clearedAtByConversationId: [UUID: Date], authId: UUID) {
        var map: [String: String] = [:]
        for (id, date) in clearedAtByConversationId {
            map[id.uuidString.lowercased()] = isoString(date)
        }
        persist(map, authId: authId)
        UserDefaults.standard.removeObject(forKey: legacyStorageKey(authId: authId))
    }

    private static func storageKey(authId: UUID) -> String {
        keyPrefix + authId.uuidString.lowercased()
    }

    private static func legacyStorageKey(authId: UUID) -> String {
        legacyKeyPrefix + authId.uuidString.lowercased()
    }

    private static func loadMap(authId: UUID) -> [String: String] {
        let key = storageKey(authId: authId)
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            return decoded
        }
        return [:]
    }

    private static func persist(_ map: [String: String], authId: UUID) {
        let key = storageKey(authId: authId)
        if map.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Recover watermarks written with the v1 dictionary API (cast often failed on read).
    private static func migrateLegacyIfNeeded(authId: UUID) {
        let legacyKey = legacyStorageKey(authId: authId)
        guard let legacyAny = UserDefaults.standard.dictionary(forKey: legacyKey), !legacyAny.isEmpty else {
            return
        }
        var recovered: [String: String] = loadMap(authId: authId)
        for (k, v) in legacyAny {
            if let s = v as? String {
                recovered[k.lowercased()] = s
            }
        }
        persist(recovered, authId: authId)
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    private static func isoString(_ date: Date) -> String {
        SupabaseTimestampParsing.encodeTimestamptz(date)
    }

    private static func parse(_ raw: String) -> Date? {
        SupabaseTimestampParsing.parseTimestamptz(raw)
    }
}
