import Foundation

/// Pure inbox snapshot preparation shared by Chat refresh, enrichment, and Realtime patch paths.
///
/// Nothing here touches published UI state, so callers may run it off the MainActor and publish
/// the result back on the MainActor. Ordering semantics are the existing ones: most recent message
/// first. The only addition is a deterministic tie-break, which keeps rows that share a timestamp
/// (or have none, such as accepted friends without a thread) from shuffling between refreshes.
nonisolated enum ChatInboxSnapshotBuilder {

    /// Recency-descending, then stable by id so equal timestamps cannot reorder between rebuilds.
    static func isOrderedBefore(
        lhsLastMessageAt: Date?,
        lhsId: UUID,
        rhsLastMessageAt: Date?,
        rhsId: UUID
    ) -> Bool {
        let lhs = lhsLastMessageAt ?? .distantPast
        let rhs = rhsLastMessageAt ?? .distantPast
        if lhs != rhs {
            return lhs > rhs
        }
        return lhsId.uuidString < rhsId.uuidString
    }

    struct GroupAvatarMembership: Sendable {
        let memberIdsByConversationId: [UUID: [UUID]]
        let referencedMemberIds: Set<UUID>
    }

    /// Groups active-member rows per conversation and applies the existing avatar display order.
    static func groupAvatarMembership(
        memberRows: [GroupActiveMemberRow],
        conversationIds: [UUID],
        currentUserId: UUID
    ) -> GroupAvatarMembership {
        var membersByConversation: [UUID: [(userId: UUID, joinedAt: String)]] = [:]
        for row in memberRows {
            membersByConversation[row.conversation_id, default: []].append(
                (userId: row.user_id, joinedAt: row.joined_at)
            )
        }

        var memberIdsByConversationId: [UUID: [UUID]] = [:]
        var referenced = Set<UUID>()
        for conversationId in conversationIds {
            let ordered = GroupInboxAvatarMembership.orderedAvatarMemberIds(
                members: membersByConversation[conversationId] ?? [],
                currentUserId: currentUserId
            )
            memberIdsByConversationId[conversationId] = ordered
            referenced.formUnion(ordered)
        }

        return GroupAvatarMembership(
            memberIdsByConversationId: memberIdsByConversationId,
            referencedMemberIds: referenced
        )
    }

    /// Network previews win over seeded ones; result is trimmed to members the inbox still shows.
    static func mergedGroupMemberPreviews(
        seeded: [UUID: UserPreview],
        fetched: [UUID: UserPreview],
        referenced: Set<UUID>
    ) -> [UUID: UserPreview] {
        var merged = seeded
        for (id, preview) in fetched {
            merged[id] = preview
        }
        return merged.filter { referenced.contains($0.key) }
    }
}

/// Deterministic structural fingerprint for Chat inbox snapshot rebuild skipping.
///
/// Encodes exactly the fields previously concatenated into
/// ``friendDisplaySnapshotFingerprint``'s interpolated String, so equality matches the old
/// change-detection semantics without MainActor string allocation per row.
nonisolated struct ChatFriendDisplaySnapshotFingerprint: Hashable, Sendable {
    enum ChipKind: String, Hashable, Sendable {
        case add
        case out
        case `in`
        case friends
        case declined
    }

    struct Row: Hashable, Sendable {
        let id: UUID
        let previewId: UUID
        let unreadCount: Int
        let lastMessageAtEpoch: TimeInterval
        let subtitle: String
        let lastSeenAtRaw: String
        /// Canonical list/thumbnail avatar URLs — required so photo changes rebuild inbox snapshots.
        let avatarURL: String
        let avatarThumbnailURL: String
        let isConversationBacked: Bool
        let inboxKind: String
        let chip: ChipKind
        let groupConversationId: UUID?
        let groupMemberIds: [UUID]
        /// Canonical avatar keys for stacked group faces (id + thumb/full), sorted.
        let groupMemberAvatarKeys: [String]
        let groupMemberCount: Int
        let isGroupMuted: Bool
    }

    let query: String
    let rows: [Row]
}
