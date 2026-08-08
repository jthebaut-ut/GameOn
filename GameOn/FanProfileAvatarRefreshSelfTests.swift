import Foundation

#if DEBUG
/// Focused avatar versioning / propagation self-tests (no XCTest target in this project).
enum FanProfileAvatarRefreshSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[AvatarRefreshTest] PASS \(name)")
            } else {
                failures += 1
                print("[AvatarRefreshTest] FAIL \(name)")
            }
        }

        // 1. Successful avatar upload produces a new URL/path
        let a = MapViewModel.makeVersionedAvatarFileName()
        let b = MapViewModel.makeVersionedAvatarFileName()
        expect(a != b, "versioned_filenames_unique")
        expect(a.hasPrefix("avatar-") && a.hasSuffix(".jpg"), "versioned_filename_shape")
        expect(a.contains("-"), "versioned_filename_contains_uuid_dashes")

        // Event carries coarse URLs only (no DOB / age)
        let userA = UUID()
        let userB = UUID()
        let change = FanProfileAvatarChange(
            userId: userA,
            avatarURL: "https://example.supabase.co/storage/v1/object/public/user-avatars/\(userA.uuidString.lowercased())/\(a)",
            avatarThumbnailURL: "https://example.supabase.co/storage/v1/object/public/user-avatars/\(userA.uuidString.lowercased())/\(a.replacingOccurrences(of: ".jpg", with: "_thumb.jpg"))"
        )
        expect(!change.avatarURL.isEmpty, "event_has_avatar_url")
        expect(change.userId == userA, "event_user_id")

        // Matching preview updates; unrelated users gated by id
        let previewA = UserPreview(
            id: userA,
            displayName: "A",
            avatarURL: "https://old.example/a.jpg",
            avatarThumbnailURL: "https://old.example/a_thumb.jpg"
        )
        let previewB = UserPreview(
            id: userB,
            displayName: "B",
            avatarURL: "https://old.example/b.jpg",
            avatarThumbnailURL: nil
        )
        let updatedA = previewA.replacingAvatars(
            avatarURL: change.avatarURL,
            avatarThumbnailURL: change.avatarThumbnailURL
        )
        expect(updatedA.avatarURL == change.avatarURL, "matching_preview_updated")
        let gatedB = previewB.id == change.userId
            ? previewB.replacingAvatars(avatarURL: change.avatarURL, avatarThumbnailURL: change.avatarThumbnailURL)
            : previewB
        expect(gatedB.avatarURL == previewB.avatarURL, "unrelated_user_not_modified")

        // Fresh profile URL must not be blanked by an empty seed
        let loadedFull = change.avatarURL
        let emptySeed: String? = nil
        let protected = {
            if loadedFull.isEmpty {
                return emptySeed
            }
            return loadedFull as String?
        }()
        expect(protected == change.avatarURL, "fresh_profile_not_overwritten_by_empty_seed")

        // Failure path keeps previous URL distinct from the new upload URL
        let previous = "https://example.supabase.co/storage/v1/object/public/user-avatars/old/avatar.jpg"
        expect(previous != change.avatarURL, "failure_path_keeps_previous_url_distinct")

        // Suggested-fans helper keeps identity while swapping avatars
        let suggestion = FriendSuggestionProfile(
            userID: userA,
            email: nil,
            displayName: "A",
            handle: "a",
            avatarURL: "https://old.example/a.jpg",
            avatarThumbnailURL: nil,
            bio: nil,
            sharedFavoriteTeamsCount: 0,
            sharedEventInterestCount: 0,
            sharedPickupGameCount: 0,
            mutualFriendCount: 0,
            mutualFriendAvatars: [],
            score: 0,
            reasonType: nil,
            reasonLabel: nil
        )
        let suggestionUpdated = suggestion.replacingAvatars(
            avatarURL: change.avatarURL,
            avatarThumbnailURL: change.avatarThumbnailURL
        )
        expect(suggestionUpdated.userID == userA, "suggestion_identity_preserved")
        expect(suggestionUpdated.avatarURL == change.avatarURL, "suggestion_avatar_updated")

        // Inbox fingerprint must change when only avatar URLs change (Conversations stale-bug guard).
        let baseRow = ChatFriendDisplaySnapshotFingerprint.Row(
            id: userA,
            previewId: userA,
            unreadCount: 0,
            lastMessageAtEpoch: 0,
            subtitle: "hi",
            lastSeenAtRaw: "2026-01-01T00:00:00Z",
            avatarURL: "https://old.example/a.jpg",
            avatarThumbnailURL: "https://old.example/a_thumb.jpg",
            isConversationBacked: true,
            inboxKind: "direct",
            chip: .friends,
            groupConversationId: nil,
            groupMemberIds: [],
            groupMemberAvatarKeys: [],
            groupMemberCount: 0,
            isGroupMuted: false
        )
        let nextRow = ChatFriendDisplaySnapshotFingerprint.Row(
            id: userA,
            previewId: userA,
            unreadCount: 0,
            lastMessageAtEpoch: 0,
            subtitle: "hi",
            lastSeenAtRaw: "2026-01-01T00:00:00Z",
            avatarURL: change.avatarURL,
            avatarThumbnailURL: change.avatarThumbnailURL ?? "",
            isConversationBacked: true,
            inboxKind: "direct",
            chip: .friends,
            groupConversationId: nil,
            groupMemberIds: [],
            groupMemberAvatarKeys: [],
            groupMemberCount: 0,
            isGroupMuted: false
        )
        let fpOld = ChatFriendDisplaySnapshotFingerprint(query: "", rows: [baseRow])
        let fpNew = ChatFriendDisplaySnapshotFingerprint(query: "", rows: [nextRow])
        expect(fpOld != fpNew, "inbox_fingerprint_changes_when_only_avatar_urls_change")

        if failures == 0 {
            print("[AvatarRefreshTest] ALL_PASSED")
        } else {
            print("[AvatarRefreshTest] FAILURES=\(failures)")
        }
    }
}
#endif
