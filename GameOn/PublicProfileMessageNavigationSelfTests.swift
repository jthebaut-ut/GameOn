import Foundation

#if DEBUG
enum PublicProfileMessageNavigationSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[PublicProfileMessageNavTest] PASS \(name)")
            } else {
                failures += 1
                print("[PublicProfileMessageNavTest] FAIL \(name)")
            }
        }

        let userId = UUID()
        let conversationId = UUID()
        let data = PublicUserProfileData(
            userId: userId,
            displayName: "Fan",
            publicHandleLine: "@jtapple",
            profileCreatedAt: nil,
            bio: nil,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            totalXP: 0,
            reputation: FanReputationEngine.evaluate(FanReputationSignals(fanXP: .rookie)),
            organizerStats: nil,
            favoriteTeams: [],
            primaryFavoriteTeamID: nil,
            nationalTeam: nil,
            profileBackgroundKey: .fangeo,
            isBusinessAccount: false,
            hasResolvedIdentity: true,
            isPubliclyVisible: true,
            isDiscoverableByFans: true,
            memberSinceLabel: nil,
            openToItems: [],
            mutualFansCount: 0,
            mutualFanAvatars: [],
            sharedTeamsCount: 0,
            venueCount: 0,
            venueCards: [],
            homeCrowd: nil,
            homeCityDisplayLine: nil,
            pickupHostedCount: 0,
            pickupJoinedCount: 0,
            lastPickupGameCreatedAt: nil,
            socialHighlightLabels: [],
            personalityTags: [],
            sharedTeamNames: [],
            lastSeenAtRaw: nil,
            fanTeamMemberships: [],
            myTeamsProfileVisibility: .friends,
            genderRaw: nil
        )

        let withoutConversation = data.userPreviewForMessaging()
        expect(withoutConversation.id == userId, "profile Message preview uses fan user id")
        expect(withoutConversation.username == "jtapple", "profile Message preview stores handle without @")
        expect(
            withoutConversation.dmConversationId == nil,
            "preview without conversation id is not a complete pending DM seed"
        )

        let seeded = data.userPreviewForMessaging(conversationId: conversationId)
        expect(seeded.dmConversationId == conversationId, "Message attaches canonical conversation id")
        let route = DirectChatNavRoute(preview: seeded)
        expect(route.conversationId == conversationId, "pending DM route reuses existing conversation")
        expect(
            route.id == "dm-c-\(conversationId.uuidString.lowercased())",
            "existing DM route identity is conversation-stable"
        )
        expect(
            DirectChatNavRoute(preview: seeded) == route,
            "double tap keeps one conversation route identity"
        )

        let newRoute = DirectChatNavRoute(preview: withoutConversation)
        expect(newRoute.conversationId == nil, "new DM seed stays peer-stable until create returns")
        expect(
            newRoute.id == "dm-p-\(userId.uuidString.lowercased())",
            "new DM route identity is peer-stable"
        )

        if failures == 0 {
            print("[PublicProfileMessageNavTest] ALL PASSED")
        } else {
            print("[PublicProfileMessageNavTest] FAILURES=\(failures)")
            assertionFailure("PublicProfileMessageNavigationSelfTests failed: \(failures)")
        }
    }
}
#endif
