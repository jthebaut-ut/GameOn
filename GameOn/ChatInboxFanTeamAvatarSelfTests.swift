import Foundation

#if DEBUG
enum ChatInboxFanTeamAvatarSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[ChatInboxFanTeamAvatarTest] PASS \(name)")
            } else {
                failures += 1
                print("[ChatInboxFanTeamAvatarTest] FAIL \(name)")
            }
        }

        expect(
            ChatInboxFanTeamAvatarDecision.preferredSource(
                logoThumbnailURL: "https://cdn.example/t.jpg",
                logoURL: "https://cdn.example/full.jpg"
            ) == .logoThumbnail,
            "thumbnail wins over full logo"
        )
        expect(
            ChatInboxFanTeamAvatarDecision.preferredSource(
                logoThumbnailURL: "   ",
                logoURL: "https://cdn.example/full.jpg"
            ) == .logoURL,
            "full logo when thumbnail empty"
        )
        expect(
            ChatInboxFanTeamAvatarDecision.preferredSource(
                logoThumbnailURL: nil,
                logoURL: nil
            ) == .sportColorMark,
            "sport/color mark when no logo"
        )
        expect(
            ChatInboxFanTeamAvatarDecision.preferredSource(
                logoThumbnailURL: nil,
                logoURL: ""
            ) == .sportColorMark,
            "sport/color mark when blank logo"
        )

        expect(
            ChatInboxFanTeamAvatarDecision.usesTeamIdentityMark(isFanTeamChat: true),
            "fan team chat uses team mark"
        )
        expect(
            !ChatInboxFanTeamAvatarDecision.usesTeamIdentityMark(isFanTeamChat: false),
            "non-team chat does not force team mark"
        )

        expect(
            ChatInboxFanTeamRowIdentity.preferredTitle(
                teamName: "Team JT",
                fallbackConversationTitle: "JT"
            ) == "Team JT",
            "team name wins over group conversation title"
        )
        expect(
            ChatInboxFanTeamRowIdentity.preferredTitle(
                teamName: "   ",
                fallbackConversationTitle: "JT"
            ) == "JT",
            "fallback when team name blank"
        )
        expect(
            ChatInboxFanTeamRowIdentity.preferredTitle(
                teamName: nil,
                fallbackConversationTitle: "Fallback Group"
            ) == "Fallback Group",
            "fallback when team name missing"
        )
        expect(
            ChatInboxFanTeamRowIdentity.showsTeamChatBadge(isFanTeamChat: true),
            "team chat shows Team Chat badge"
        )
        expect(
            !ChatInboxFanTeamRowIdentity.showsTeamChatBadge(isFanTeamChat: false),
            "non-team does not show Team Chat badge"
        )

        let team = makeDisplay(kind: .group, fanTeamId: UUID())
        let dm = makeDisplay(kind: .direct)
        let pickup = makeDisplay(kind: .group, pickupGameId: UUID())
        let group = makeDisplay(kind: .group)

        expect(team.isFanTeamChat, "team row classified as fan team chat")
        expect(!dm.isFanTeamChat, "DM is not fan team chat")
        expect(!pickup.isFanTeamChat, "pickup is not fan team chat")
        expect(!group.isFanTeamChat, "regular group is not fan team chat")
        expect(
            ChatInboxFanTeamAvatarDecision.usesTeamIdentityMark(isFanTeamChat: team.isFanTeamChat)
                && ChatInboxFanTeamRowIdentity.showsTeamChatBadge(isFanTeamChat: team.isFanTeamChat)
                && !ChatInboxFanTeamRowIdentity.showsTeamChatBadge(isFanTeamChat: group.isFanTeamChat)
                && !ChatInboxFanTeamRowIdentity.showsTeamChatBadge(isFanTeamChat: pickup.isFanTeamChat),
            "avatar + badge branch only for team chats"
        )

        let enBadge = L10n.t("chat_inbox_badge_team_chat", languageCode: "en")
        let enGroup = L10n.t("chat_inbox_badge_group", languageCode: "en")
        expect(enBadge == "Team Chat", "en Team Chat badge copy")
        expect(enGroup == "Group", "en Group badge unchanged")
        expect(enBadge != enGroup, "Team Chat key is not Group")

        if failures == 0 {
            print("[ChatInboxFanTeamAvatarTest] ALL PASSED")
        } else {
            print("[ChatInboxFanTeamAvatarTest] FAILURES=\(failures)")
        }
    }

    private static func makeDisplay(
        kind: ChatInboxConversationKind,
        pickupGameId: UUID? = nil,
        fanTeamId: UUID? = nil
    ) -> ChatViewModel.FriendDisplay {
        let id = UUID()
        return ChatViewModel.FriendDisplay(
            id: id,
            preview: UserPreview(id: id, displayName: "Row", avatarURL: nil),
            subtitle: "hi",
            lastMessageAt: Date(),
            unreadCount: 0,
            isConversationBacked: true,
            conversationId: id,
            inboxKind: kind,
            groupMemberCount: kind == .group ? 3 : 0,
            isGroupMuted: false,
            pickupGameId: pickupGameId,
            fanTeamId: fanTeamId
        )
    }
}
#endif
