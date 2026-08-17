import Foundation

/// Private organizational Friend Group owned by the signed-in user.
/// Identity of members is resolved via existing friend/`UserPreview` cache — not stored here.
struct FriendGroup: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    var name: String
    var memberCount: Int
    let createdAt: Date?
    var updatedAt: Date?

    init(
        id: UUID,
        name: String,
        memberCount: Int,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.memberCount = memberCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Navigation / collection identity is the group id only (name/count may refresh in place).
    static func == (lhs: FriendGroup, rhs: FriendGroup) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Membership row: group + friend user id only (no profile payload).
struct FriendGroupMember: Identifiable, Equatable, Hashable, Sendable {
    let groupId: UUID
    let friendUserId: UUID
    let createdAt: Date?

    var id: String { "\(groupId.uuidString.lowercased()):\(friendUserId.uuidString.lowercased())" }
}

/// Lightweight summary for lists / invite pickers.
struct FriendGroupSummary: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let name: String
    let memberCount: Int

    init(id: UUID, name: String, memberCount: Int) {
        self.id = id
        self.name = name
        self.memberCount = memberCount
    }

    init(_ group: FriendGroup) {
        self.id = group.id
        self.name = group.name
        self.memberCount = group.memberCount
    }
}

enum FriendGroupNameValidation {
    static let maxLength = 60

    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isValid(_ raw: String) -> Bool {
        let name = normalized(raw)
        return !name.isEmpty && name.count <= maxLength
    }
}

/// Presentation helpers (no network).
enum FriendGroupPresentation {
    static func memberCountLabel(count: Int, languageCode: String) -> String {
        if count == 1 {
            return L10n.t("friend_groups_member_count_one", languageCode: languageCode)
        }
        return String(
            format: L10n.t("friend_groups_member_count_other", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            Int64(count)
        )
    }

    static func accessibilityGroupLabel(name: String, memberCount: Int, languageCode: String) -> String {
        let artwork = FriendGroupArtworkResolver.resolve(groupName: name)
        let category = FriendGroupArtworkResolver.accessibilityCategoryLabel(
            for: artwork,
            languageCode: languageCode
        )
        let row = String(
            format: L10n.t("friend_groups_a11y_group_row", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            name,
            Int64(memberCount)
        )
        return "\(category). \(row)"
    }
}
