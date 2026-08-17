import SwiftUI

/// Compatibility bridge to `FriendGroupArtworkResolver`.
/// Prefer `FriendGroupArtworkResolver.resolve(groupName:)` for new call sites.
struct FriendGroupCoverStyle: Equatable, Sendable {
    typealias Theme = FriendGroupArtworkResolver.Category

    let theme: Theme
    let systemImage: String
    let colors: [Color]

    static func resolve(groupName: String, groupId: UUID = UUID()) -> FriendGroupCoverStyle {
        _ = groupId // Legacy hash fallback removed — keywords + friends default.
        let art = FriendGroupArtworkResolver.resolve(groupName: groupName)
        return FriendGroupCoverStyle(
            theme: art.category,
            systemImage: art.systemImage,
            colors: [art.accent, art.accent.opacity(0.75)]
        )
    }
}
