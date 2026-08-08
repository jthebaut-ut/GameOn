import Foundation

/// Reference-type tap gate so arming/generation do not publish SwiftUI `@State`.
@MainActor
final class ChatConversationOpenGate {
    var generation: Int = 0
    var isArmed: Bool = false
}

#if DEBUG
/// Capped `[ChatNav]` counters so one open doesn't flood the console.
@MainActor
enum ChatNavDebugCounters {
    private static var counts: [String: Int] = [:]
    private static let cap = 40

    static func log(_ key: String, detail: String = "") {
        let next = (counts[key] ?? 0) + 1
        counts[key] = next
        guard next <= cap else { return }
        if detail.isEmpty {
            print("[ChatNav] \(key) #\(next)")
        } else {
            print("[ChatNav] \(key) #\(next) \(detail)")
        }
        if next == cap {
            print("[ChatNav] \(key) capped at \(cap)")
        }
    }
}
#endif

/// Stable DM navigation identity — hash/equality exclude presence/display fields that churn.
/// Payload is an immutable open seed only (ids + display/avatar seeds + account/venue flags).
/// Mutable peer presence, unread, and last-message live in ChatViewModel and hydrate after paint.
struct DirectChatNavRoute: Identifiable, Hashable {
    var id: String {
        if let conversationId {
            return "dm-c-\(conversationId.uuidString.lowercased())"
        }
        if let venueId = businessVenueId {
            return "dm-v-\(venueId.uuidString.lowercased())"
        }
        return "dm-p-\(peerUserId.uuidString.lowercased())"
    }

    let peerUserId: UUID
    let conversationId: UUID?
    let displayName: String
    let username: String?
    let avatarURL: String?
    let avatarThumbnailURL: String?
    let isBusinessAccount: Bool
    let isDeleted: Bool
    let businessVenueId: UUID?
    let businessVenueBusinessId: UUID?
    let businessVenueBusinessName: String?
    let venueScopedThread: Bool

    init(preview: UserPreview) {
        peerUserId = preview.id
        conversationId = preview.dmConversationId
        displayName = preview.displayName
        username = preview.username
        avatarURL = preview.avatarURL
        avatarThumbnailURL = preview.avatarThumbnailURL
        isBusinessAccount = preview.isBusinessAccount
        isDeleted = preview.isDeleted
        businessVenueId = preview.businessVenueId
        businessVenueBusinessId = preview.businessVenueBusinessId
        businessVenueBusinessName = preview.businessVenueBusinessName
        venueScopedThread = preview.venueScopedThread
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: DirectChatNavRoute, rhs: DirectChatNavRoute) -> Bool {
        lhs.id == rhs.id
    }

    func makePreview() -> UserPreview {
        UserPreview(
            id: peerUserId,
            displayName: displayName,
            username: username,
            avatarURL: avatarURL,
            avatarThumbnailURL: avatarThumbnailURL,
            isBusinessAccount: isBusinessAccount,
            isDeleted: isDeleted,
            dmConversationId: conversationId,
            businessVenueId: businessVenueId,
            businessVenueBusinessId: businessVenueBusinessId,
            businessVenueBusinessName: businessVenueBusinessName,
            venueScopedThread: venueScopedThread
        )
    }
}

/// Stable group/pickup navigation identity (UUID only).
struct GroupChatNavRoute: Identifiable, Hashable {
    var id: UUID { conversationId }
    let conversationId: UUID

    init(conversationId: UUID) {
        self.conversationId = conversationId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(conversationId)
    }

    static func == (lhs: GroupChatNavRoute, rhs: GroupChatNavRoute) -> Bool {
        lhs.conversationId == rhs.conversationId
    }
}
