import Foundation

/// In-feed native ad slot for the Chat → Chats inbox list (not DM threads).
enum ChatInboxListItem: Identifiable {
    case conversation(ChatViewModel.FriendDisplay)
    case nativeAd(ChatInboxNativeAdSlot)

    var id: String {
        switch self {
        case .conversation(let friend):
            return "chat-\(friend.inboxKind.rawValue)-\(friend.id.uuidString.lowercased())"
        case .nativeAd(let slot):
            return slot.id
        }
    }
}

struct ChatInboxNativeAdSlot: Hashable {
    let ordinal: Int
    let insertedAfterConversationPosition: Int

    var id: String {
        "chat-inbox-native-ad-\(insertedAfterConversationPosition)"
    }

    var slotIndex: Int {
        ChatInboxAdPlacement.nativeAdSlotIndex + ordinal
    }
}

enum ChatInboxAdPlacement {
    /// Dedicated AdMob in-flight slot id (separate from venue comment ad slots 0/1).
    static let nativeAdSlotIndex = 2

    /// Cached placement for an identical conversation-id fingerprint.
    private static var cachedFingerprint: String?
    private static var cachedItems: [ChatInboxListItem]?
#if DEBUG
    private static var lastLoggedFingerprint: String?
#endif

    static var debugOverrideEnabled: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    static func shouldInsertNativeAd(conversationCount: Int) -> Bool {
        !insertionPositions(for: conversationCount).isEmpty
    }

    static func skippedReason(conversationCount: Int) -> String? {
        shouldInsertNativeAd(conversationCount: conversationCount) ? nil : "noConversations"
    }

    static func insertionPositions(for conversationCount: Int) -> [Int] {
        guard conversationCount > 0 else { return [] }
        return [conversationCount]
    }

    static func nativeAdSlots(for conversationCount: Int) -> [ChatInboxNativeAdSlot] {
        insertionPositions(for: conversationCount).enumerated().map { index, position in
            ChatInboxNativeAdSlot(ordinal: index, insertedAfterConversationPosition: position)
        }
    }

    /// Conversation-id fingerprint — ignores presence/unread/last-message churn.
    static func fingerprint(for friends: [ChatViewModel.FriendDisplay]) -> String {
        friends.map { item in
            let cid = item.conversationId?.uuidString.lowercased() ?? "nil"
            return "\(item.inboxKind.rawValue):\(item.id.uuidString.lowercased()):\(cid)"
        }
        .joined(separator: "|")
    }

    static func listItems(for friends: [ChatViewModel.FriendDisplay]) -> [ChatInboxListItem] {
        listItems(for: friends, insertAds: true)
    }

    /// When ``insertAds`` is false (DM/group route covering inbox), return conversations only
    /// and skip placement work. Otherwise reuse cached placement for an identical fingerprint.
    static func listItems(
        for friends: [ChatViewModel.FriendDisplay],
        insertAds: Bool
    ) -> [ChatInboxListItem] {
        guard insertAds, FanGeoAdPolicy.shouldInsertAdsInFeeds() else {
            return friends.map { .conversation($0) }
        }
        let fp = fingerprint(for: friends)
        if fp == cachedFingerprint, let cachedItems {
            return cachedItems
        }
        let slots = nativeAdSlots(for: friends.count)
        guard !slots.isEmpty else {
            let items = friends.map { ChatInboxListItem.conversation($0) }
            cachedFingerprint = fp
            cachedItems = items
            return items
        }
        let slotsByPosition = Dictionary(uniqueKeysWithValues: slots.map {
            ($0.insertedAfterConversationPosition, $0)
        })

        var items: [ChatInboxListItem] = []
        items.reserveCapacity(friends.count + slots.count)

        for (index, friend) in friends.enumerated() {
            items.append(.conversation(friend))
            if let slot = slotsByPosition[index + 1] {
                items.append(.nativeAd(slot))
            }
        }
        cachedFingerprint = fp
        cachedItems = items
        return items
    }

#if DEBUG
    /// Returns true once per meaningful fingerprint change (for ad diagnostics).
    static func shouldLogDiagnostics(for friends: [ChatViewModel.FriendDisplay]) -> Bool {
        let fp = fingerprint(for: friends)
        guard fp != lastLoggedFingerprint else { return false }
        lastLoggedFingerprint = fp
        return true
    }
#endif
}
