import Foundation

#if DEBUG
enum ChatFansLiveNowSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[ChatFansLiveNowTest] PASS \(name)")
            } else {
                failures += 1
                print("[ChatFansLiveNowTest] FAIL \(name)")
            }
        }

        expect(
            ChatFansLiveNowCardInteraction.primaryTap == .openDirectChat,
            "primary tap opens DM, not profile"
        )
        expect(
            ChatFansLiveNowCardInteraction.accessoryTap == .openProfile,
            "info button / context menu still opens profile"
        )

        let peerId = UUID()
        let existingId = UUID()
        let existingPreview = UserPreview(
            id: peerId,
            displayName: "Fan",
            avatarURL: nil,
            dmConversationId: existingId
        )
        let existingRoute = DirectChatNavRoute(preview: existingPreview)
        expect(existingRoute.conversationId == existingId, "existing DM keeps conversation id")
        expect(
            existingRoute.id == "dm-c-\(existingId.uuidString.lowercased())",
            "existing DM route identity is conversation-stable"
        )
        expect(
            DirectChatNavRoute(preview: existingPreview) == existingRoute,
            "repeated open of the same Live Now fan does not create a second route identity"
        )

        let newPreview = UserPreview(
            id: peerId,
            displayName: "Fan",
            avatarURL: nil,
            dmConversationId: nil
        )
        let newRoute = DirectChatNavRoute(preview: newPreview)
        expect(newRoute.conversationId == nil, "new DM uses peer lookup until conversation exists")
        expect(
            newRoute.id == "dm-p-\(peerId.uuidString.lowercased())",
            "new DM route identity is peer-stable (no duplicate conversations)"
        )
        expect(
            DirectChatNavRoute(preview: newPreview) == newRoute,
            "repeated tap on a fan without a DM stays one canonical peer route"
        )

        if failures == 0 {
            print("[ChatFansLiveNowTest] ALL PASSED")
        } else {
            print("[ChatFansLiveNowTest] FAILURES=\(failures)")
            assertionFailure("ChatFansLiveNowSelfTests failed: \(failures)")
        }
    }
}
#endif
