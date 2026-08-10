import Foundation

#if DEBUG
enum ChatInboxTypeFilterSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[ChatInboxTypeFilterTest] PASS \(name)")
            } else {
                failures += 1
                print("[ChatInboxTypeFilterTest] FAIL \(name)")
            }
        }

        let order = ChatInboxTypeFilter.allCases.map(\.rawValue)
        expect(
            order == ["all", "unread", "fans", "teams", "businesses", "groups", "pickup"],
            "filter chip order"
        )

        let fan = makeDisplay(kind: .direct, unread: 1)
        let business = makeDisplay(kind: .business, unread: 0)
        let group = makeDisplay(kind: .group, unread: 2)
        let team = makeDisplay(kind: .group, unread: 1, fanTeamId: UUID())
        let pickup = makeDisplay(kind: .group, unread: 0, pickupGameId: UUID())
        let inbox = [fan, business, group, team, pickup]

        expect(ChatInboxTypeFilter.teams.matches(team), "teams matches fan team chat")
        expect(!ChatInboxTypeFilter.teams.matches(group), "teams excludes regular group")
        expect(!ChatInboxTypeFilter.teams.matches(pickup), "teams excludes pickup")
        expect(!ChatInboxTypeFilter.groups.matches(team), "groups excludes fan team chat")
        expect(ChatInboxTypeFilter.groups.matches(group), "groups matches regular group")
        expect(ChatInboxTypeFilter.pickup.matches(pickup), "pickup matches pickup chat")
        expect(ChatInboxTypeFilter.fans.matches(fan), "fans matches DM")
        expect(ChatInboxTypeFilter.businesses.matches(business), "businesses matches business")
        expect(ChatInboxTypeFilter.all.matches(team), "all includes teams")
        expect(ChatInboxTypeFilter.unread.matches(team), "unread includes unread team")
        expect(ChatInboxTypeFilter.unread.matches(group), "unread includes unread group")
        expect(!ChatInboxTypeFilter.unread.matches(pickup), "unread excludes read pickup")

        let counts = ChatInboxTypeFilter.counts(from: inbox)
        expect(counts[.all] == 5, "all count")
        expect(counts[.unread] == 3, "unread conversation count")
        expect(counts[.fans] == 1, "fans count")
        expect(counts[.teams] == 1, "teams count")
        expect(counts[.businesses] == 1, "businesses count")
        expect(counts[.groups] == 1, "groups count excludes teams/pickup")
        expect(counts[.pickup] == 1, "pickup count")

        let teamsOnly = ChatInboxTypeFilter.filtered(inbox, by: .teams)
        expect(teamsOnly.count == 1 && teamsOnly[0].isFanTeamChat, "filtered teams list")
        let groupsOnly = ChatInboxTypeFilter.filtered(inbox, by: .groups)
        expect(groupsOnly.count == 1 && !groupsOnly[0].isFanTeamChat, "filtered groups list")

        let searchKind = ChatGlobalSearchConversationKind.resolve(
            raw: .group,
            conversationId: team.conversationId!,
            pickupGameId: nil,
            inbox: inbox
        )
        expect(searchKind == .team, "search remaps team conversation from group")
        expect(searchKind.matches(filter: .teams), "search kind matches teams filter")
        expect(!searchKind.matches(filter: .groups), "search kind excluded from groups filter")

        if failures == 0 {
            print("[ChatInboxTypeFilterTest] ALL PASSED")
        } else {
            print("[ChatInboxTypeFilterTest] FAILURES=\(failures)")
        }
    }

    private static func makeDisplay(
        kind: ChatInboxConversationKind,
        unread: Int,
        pickupGameId: UUID? = nil,
        fanTeamId: UUID? = nil
    ) -> ChatViewModel.FriendDisplay {
        let id = UUID()
        return ChatViewModel.FriendDisplay(
            id: id,
            preview: UserPreview(id: id, displayName: "Row", avatarURL: nil),
            subtitle: "hi",
            lastMessageAt: Date(),
            unreadCount: unread,
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
