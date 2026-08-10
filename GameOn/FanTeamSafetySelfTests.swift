import Foundation

#if DEBUG
enum FanTeamSafetySelfTests {
    static func runAll() {
        testReportCategoryRawValues()
        testOwnerCannotShowLeave()
    }

    private static func testReportCategoryRawValues() {
        let expected = [
            "harassment",
            "hate",
            "spam",
            "inappropriate",
            "violence",
            "fake_account",
            "team_identity",
            "other"
        ]
        precondition(
            FanTeamReportCategory.allCases.map(\.rawValue) == expected,
            "FanTeamReportCategory raw values must match report_fan_team allowlist"
        )
    }

    private static func testOwnerCannotShowLeave() {
        precondition(!FanTeamMemberRole.owner.canLeaveTeam, "Owners must not see Leave Team")
        precondition(FanTeamMemberRole.manager.canLeaveTeam)
        precondition(FanTeamMemberRole.captain.canLeaveTeam)
        precondition(FanTeamMemberRole.member.canLeaveTeam)

        let ownerSummary = FanTeamSummary(
            id: UUID(),
            name: "Owners FC",
            sport: "Soccer",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            competitionLevel: nil,
            ownerUserId: UUID(),
            groupConversationId: UUID(),
            myRole: .owner,
            memberCount: 3,
            pendingInvitationCount: 0,
            pushNotificationsMuted: false,
            nextGameStartsAt: nil,
            nextGameTitle: nil,
            nextGameVenue: nil,
            createdAt: nil
        )
        precondition(!ownerSummary.canLeaveTeam)
    }
}
#endif
