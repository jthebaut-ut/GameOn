import Foundation

/// Per-user Recent Chats hide state (swipe delete). Does not delete messages for the other participant.
enum DmInboxHiddenConversationsStore {
    private static let peerKeyPrefix = "dm.inbox.hiddenPeerUserIds."
    private static let conversationKeyPrefix = "dm.inbox.hiddenConversationIds."

    static func hiddenPeerUserIds(authId: UUID) -> Set<UUID> {
        let key = peerStorageKey(authId: authId)
        let raw = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    static func hiddenConversationIds(authId: UUID) -> Set<UUID> {
        let key = conversationStorageKey(authId: authId)
        let raw = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    static func hide(peerUserId: UUID, authId: UUID) {
        var hidden = hiddenPeerUserIds(authId: authId)
        guard hidden.insert(peerUserId).inserted else { return }
        persistPeer(hidden, authId: authId)
    }

    static func hide(conversationId: UUID, authId: UUID) {
        var hidden = hiddenConversationIds(authId: authId)
        guard hidden.insert(conversationId).inserted else { return }
        persistConversation(hidden, authId: authId)
    }

    static func unhide(peerUserId: UUID, authId: UUID) {
        var hidden = hiddenPeerUserIds(authId: authId)
        guard hidden.remove(peerUserId) != nil else { return }
        persistPeer(hidden, authId: authId)
    }

    static func unhide(conversationId: UUID, authId: UUID) {
        var hidden = hiddenConversationIds(authId: authId)
        guard hidden.remove(conversationId) != nil else { return }
        persistConversation(hidden, authId: authId)
    }

    private static func peerStorageKey(authId: UUID) -> String {
        peerKeyPrefix + authId.uuidString.lowercased()
    }

    private static func conversationStorageKey(authId: UUID) -> String {
        conversationKeyPrefix + authId.uuidString.lowercased()
    }

    private static func persistPeer(_ hidden: Set<UUID>, authId: UUID) {
        let key = peerStorageKey(authId: authId)
        if hidden.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(hidden.map { $0.uuidString.lowercased() }.sorted(), forKey: key)
        }
    }

    private static func persistConversation(_ hidden: Set<UUID>, authId: UUID) {
        let key = conversationStorageKey(authId: authId)
        if hidden.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(hidden.map { $0.uuidString.lowercased() }.sorted(), forKey: key)
        }
    }
}
