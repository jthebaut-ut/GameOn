import Foundation

enum FanTeamPollSelfTests {
    static func runAll() {
        testPermissionResolved()
        testAccessGates()
        testAccessSnapshotDecode()
        testPayloadReuse()
    }

    private static func testPermissionResolved() {
        precondition(FanTeamPollCreatePermission.resolved(nil) == .managementOnly)
        precondition(FanTeamPollCreatePermission.resolved("anyone") == .anyone)
        precondition(FanTeamPollCreatePermission.resolved("MANAGEMENT_ONLY") == .managementOnly)
        precondition(FanTeamPollCreatePermission.resolved("bogus") == .managementOnly)
    }

    private static func testAccessGates() {
        precondition(
            FanTeamPollAccess.canCreate(
                canManageTeam: true,
                permission: .managementOnly,
                isActiveTeamChatMember: true
            )
        )
        precondition(
            !FanTeamPollAccess.canCreate(
                canManageTeam: false,
                permission: .managementOnly,
                isActiveTeamChatMember: true
            )
        )
        precondition(
            FanTeamPollAccess.canCreate(
                canManageTeam: false,
                permission: .anyone,
                isActiveTeamChatMember: true
            )
        )
        precondition(
            !FanTeamPollAccess.canCreate(
                canManageTeam: false,
                permission: .anyone,
                isActiveTeamChatMember: false
            )
        )
        // Managed-player guardians without an account Team seat must not create.
        precondition(
            !FanTeamPollAccess.canCreate(
                canManageTeam: false,
                permission: .anyone,
                isActiveTeamChatMember: false
            )
        )
        precondition(FanTeamPollAccess.canModerate(canManageTeam: true))
        precondition(!FanTeamPollAccess.canModerate(canManageTeam: false))
    }

    private static func testAccessSnapshotDecode() {
        let teamId = UUID()
        let conversationId = UUID()
        let json = """
        {
          "team_id": "\(teamId.uuidString.lowercased())",
          "conversation_id": "\(conversationId.uuidString.lowercased())",
          "poll_create_permission": "anyone",
          "viewer_can_manage": false,
          "viewer_can_create": true
        }
        """.data(using: .utf8)!
        let snap = try! JSONDecoder().decode(FanTeamPollAccessSnapshot.self, from: json)
        precondition(snap.teamId == teamId)
        precondition(snap.conversationId == conversationId)
        precondition(snap.permission == .anyone)
        precondition(snap.viewerCanCreate)
        precondition(!snap.viewerCanManage)
    }

    private static func testPayloadReuse() {
        let payload = PickupGamePollPayload(
            pollId: UUID(),
            question: "Practice day?",
            allowMultiple: false,
            isAnonymous: false,
            autoCloseAtGameStart: false,
            closesAt: nil,
            createdByName: "Manager"
        )
        let body = PickupGamePollMessage.encodeBody(payload: payload)
        let decoded = PickupGamePollMessage.decode(from: body)
        precondition(decoded?.pollId == payload.pollId)
        precondition(decoded?.question == "Practice day?")
        precondition(PickupGamePollMessage.inboxPreview(from: body) != nil)
    }
}
