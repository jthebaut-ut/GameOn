import Foundation

enum ManagedPlayerTeamAccessSelfTests {
    static func runAll() {
        testAccessViaResolved()
        testGuardianOnlyPermissions()
        testAccountSeatStillLeaves()
        testChatFollowsAccountAccessNotPlayerSeat()
        print("[ManagedPlayerTeamAccessTest] ALL PASSED")
    }

    private static func testAccessViaResolved() {
        precondition(FanTeamListAccessVia.resolved(nil) == .account)
        precondition(FanTeamListAccessVia.resolved("account") == .account)
        precondition(FanTeamListAccessVia.resolved("managed_player") == .managedPlayer)
        precondition(FanTeamListAccessVia.resolved("MANAGED_PLAYER") == .managedPlayer)
        precondition(FanTeamListAccessVia.resolved("bogus") == .account)
    }

    private static func testGuardianOnlyPermissions() {
        let summary = FanTeamSummary(
            id: UUID(),
            name: "Warriors",
            sport: "soccer",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            competitionLevel: nil,
            ownerUserId: UUID(),
            groupConversationId: UUID(),
            myRole: .member,
            memberCount: 2,
            pendingInvitationCount: 0,
            pushNotificationsMuted: false,
            nextGameStartsAt: nil,
            nextGameTitle: nil,
            nextGameVenue: nil,
            createdAt: nil,
            accessVia: .managedPlayer,
            viaManagedPlayerNames: ["Emma"]
        )
        precondition(!summary.hasAccountSeat)
        precondition(summary.hasTeamAccountAccess)
        precondition(summary.canAccessTeamChat)
        precondition(FanTeamDetailTabComposition.showsChatTab(for: summary))
        precondition(
            FanTeamDetailTabComposition.visibleTabs(canAccessTeamChat: summary.canAccessTeamChat)
                == FanTeamDetailTab.allCases
        )
        precondition(!summary.canManage)
        precondition(!summary.canLeaveTeam)
        precondition(!summary.canDeleteTeam)
        precondition(!summary.canEditIdentity)
        precondition(!summary.canOrganizeActivities)
        precondition(summary.memberCount == 2)
    }

    private static func testAccountSeatStillLeaves() {
        let summary = FanTeamSummary(
            id: UUID(),
            name: "Warriors",
            sport: "soccer",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            competitionLevel: nil,
            ownerUserId: UUID(),
            groupConversationId: UUID(),
            myRole: .member,
            memberCount: 3,
            pendingInvitationCount: 0,
            pushNotificationsMuted: false,
            nextGameStartsAt: nil,
            nextGameTitle: nil,
            nextGameVenue: nil,
            createdAt: nil,
            accessVia: .account,
            viaManagedPlayerNames: ["Emma"]
        )
        precondition(summary.hasAccountSeat)
        precondition(summary.hasTeamAccountAccess)
        precondition(summary.canAccessTeamChat)
        precondition(FanTeamDetailTabComposition.showsChatTab(for: summary))
        precondition(summary.canLeaveTeam)
        precondition(!summary.canManage)
    }

    /// ACCOUNT ACCESS ≠ MYSELF PLAYER. Chat stays for every listed Team row.
    private static func testChatFollowsAccountAccessNotPlayerSeat() {
        let ownerMyselfOff = FanTeamSummary(
            id: UUID(),
            name: "JT",
            sport: "soccer",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            competitionLevel: nil,
            ownerUserId: UUID(),
            groupConversationId: UUID(),
            myRole: .owner,
            memberCount: 1,
            pendingInvitationCount: 0,
            pushNotificationsMuted: false,
            nextGameStartsAt: nil,
            nextGameTitle: nil,
            nextGameVenue: nil,
            createdAt: nil,
            accessVia: .account,
            viaManagedPlayerNames: ["Emma"]
        )
        precondition(ownerMyselfOff.hasAccountSeat)
        precondition(ownerMyselfOff.canAccessTeamChat)
        precondition(ownerMyselfOff.canManage)
        precondition(
            FanTeamDetailTabComposition.visibleTabs(canAccessTeamChat: true)
                == [.overview, .chat, .schedule, .roster]
        )

        let managerMyselfOff = FanTeamSummary(
            id: UUID(),
            name: "IMC",
            sport: "soccer",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            competitionLevel: nil,
            ownerUserId: UUID(),
            groupConversationId: UUID(),
            myRole: .manager,
            memberCount: 2,
            pendingInvitationCount: 0,
            pushNotificationsMuted: false,
            nextGameStartsAt: nil,
            nextGameTitle: nil,
            nextGameVenue: nil,
            createdAt: nil,
            accessVia: .account
        )
        precondition(managerMyselfOff.hasAccountSeat)
        precondition(managerMyselfOff.canAccessTeamChat)

        let twoChildrenNoMyself = FanTeamSummary(
            id: UUID(),
            name: "Warriors",
            sport: "soccer",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            competitionLevel: nil,
            ownerUserId: UUID(),
            groupConversationId: UUID(),
            myRole: .member,
            memberCount: 2,
            pendingInvitationCount: 0,
            pushNotificationsMuted: false,
            nextGameStartsAt: nil,
            nextGameTitle: nil,
            nextGameVenue: nil,
            createdAt: nil,
            accessVia: .managedPlayer,
            viaManagedPlayerNames: ["Emma", "Amelia"]
        )
        precondition(!twoChildrenNoMyself.hasAccountSeat)
        precondition(twoChildrenNoMyself.hasTeamAccountAccess)
        precondition(twoChildrenNoMyself.canAccessTeamChat)
        precondition(
            FanTeamDetailTabComposition.visibleTabs(
                canAccessTeamChat: twoChildrenNoMyself.canAccessTeamChat
            ).contains(.chat)
        )

        precondition(
            FanTeamDetailTabComposition.visibleTabs(canAccessTeamChat: false)
                == [.overview, .schedule, .roster]
        )
    }
}
