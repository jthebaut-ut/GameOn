import Combine
import Foundation
import SwiftUI

// MARK: - Reusable selection architecture
//
// Designed for Friends screen now, and later:
//   - Create Team → Invite Members → Groups
//   - Invite Friends to Event → Groups
//   - New Group Chat → Add People → Groups
//
// Friend Groups themselves are NOT chats/teams — they only help select friend user IDs.

/// Stable candidate for multi-select pickers (identity from existing friend/profile models).
struct FriendGroupSelectableFriend: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let displayName: String
    let username: String?
    let preview: UserPreview

    init(preview: UserPreview) {
        self.id = preview.id
        self.displayName = preview.displayName
        self.username = preview.username
        self.preview = preview
    }

    init(friend: ChatViewModel.FriendDisplay) {
        self.init(preview: friend.preview)
    }
}

/// Pure selection state — no networking. Safe to embed in Team/Event/GroupChat flows later.
@MainActor
final class FriendGroupSelectionStore: ObservableObject {
    @Published private(set) var selectedIds: Set<UUID>
    let maxSelection: Int?

    init(initialSelectedIds: Set<UUID> = [], maxSelection: Int? = nil) {
        self.selectedIds = initialSelectedIds
        self.maxSelection = maxSelection
    }

    var selectedCount: Int { selectedIds.count }

    func isSelected(_ id: UUID) -> Bool {
        selectedIds.contains(id)
    }

    func toggle(_ id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
            return
        }
        if let maxSelection, selectedIds.count >= maxSelection {
            return
        }
        selectedIds.insert(id)
    }

    func selectAll(from candidates: [FriendGroupSelectableFriend]) {
        let ids = candidates.map(\.id)
        if let maxSelection {
            selectedIds = Set(ids.prefix(maxSelection))
        } else {
            selectedIds = Set(ids)
        }
    }

    func clear() {
        selectedIds = []
    }

    func replaceSelection(_ ids: Set<UUID>) {
        if let maxSelection {
            selectedIds = Set(ids.prefix(maxSelection))
        } else {
            selectedIds = ids
        }
    }
}

/// Resolves Friend Group member IDs against an already-loaded accepted-friends cache (no N+1).
enum FriendGroupMemberResolver {
    static func selectableFriends(
        memberIds: [UUID],
        fromAcceptedFriends friends: [ChatViewModel.FriendDisplay],
        chipKind: (UUID) -> ChatViewModel.FriendshipChipKind
    ) -> [FriendGroupSelectableFriend] {
        let byId = Dictionary(
            uniqueKeysWithValues: friends
                .filter {
                    !$0.isGroupConversation
                        && !$0.preview.isBusinessAccount
                        && !$0.preview.isDeleted
                        && chipKind($0.preview.id) == .friends
                }
                .map { ($0.preview.id, $0) }
        )
        var out: [FriendGroupSelectableFriend] = []
        out.reserveCapacity(memberIds.count)
        for id in memberIds {
            guard let friend = byId[id] else { continue }
            out.append(FriendGroupSelectableFriend(friend: friend))
        }
        return out
    }

    static func acceptedSelectableFriends(
        from friends: [ChatViewModel.FriendDisplay],
        chipKind: (UUID) -> ChatViewModel.FriendshipChipKind,
        isBlocked: (UUID) -> Bool
    ) -> [FriendGroupSelectableFriend] {
        friends.compactMap { friend in
            guard !friend.isGroupConversation,
                  !friend.preview.isBusinessAccount,
                  !friend.preview.isBusinessVenueConversation,
                  !friend.preview.isDeleted,
                  chipKind(friend.preview.id) == .friends,
                  !isBlocked(friend.preview.id)
            else { return nil }
            return FriendGroupSelectableFriend(friend: friend)
        }
        .sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}

/// Future integration hooks (documentation-only helpers — do not widen Team/Event flows here).
enum FriendGroupInviteIntegrationPoints {
    /// Team: `AddFanTeamMembersSheet` in `MyTeamsChatViews.swift`
    /// can embed `FriendGroupsBrowseAndSelectView` beside the Friends list.
    static let teamInviteMembersSheet = "AddFanTeamMembersSheet"

    /// Event / pickup: `PickupGameInviteFriendsSheet` can reuse the same browse→select path.
    static let pickupInviteFriendsSheet = "PickupGameInviteFriendsSheet"

    /// Group chat: `CreateGroupChatSheet` / `GroupChatAddMembersSheet` in `GroupChatViews.swift`.
    static let createGroupChatSheet = "CreateGroupChatSheet"
}
