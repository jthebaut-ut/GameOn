import Foundation

/// Per-user Recent Chats hide state (swipe delete). Does not delete messages for the other participant.
enum DmInboxHiddenConversationsStore {
    private static let keyPrefix = "dm.inbox.hiddenPeerUserIds."

    static func hiddenPeerUserIds(authId: UUID) -> Set<UUID> {
        let key = storageKey(authId: authId)
        let raw = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    static func hide(peerUserId: UUID, authId: UUID) {
        var hidden = hiddenPeerUserIds(authId: authId)
        guard hidden.insert(peerUserId).inserted else { return }
        persist(hidden, authId: authId)
    }

    static func unhide(peerUserId: UUID, authId: UUID) {
        var hidden = hiddenPeerUserIds(authId: authId)
        guard hidden.remove(peerUserId) != nil else { return }
        persist(hidden, authId: authId)
    }

    private static func storageKey(authId: UUID) -> String {
        keyPrefix + authId.uuidString.lowercased()
    }

    private static func persist(_ hidden: Set<UUID>, authId: UUID) {
        let key = storageKey(authId: authId)
        if hidden.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(hidden.map { $0.uuidString.lowercased() }.sorted(), forKey: key)
        }
    }
}
