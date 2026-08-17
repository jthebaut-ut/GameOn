import Foundation

#if DEBUG
enum FanTeamPermissionsSelfTests {
    static func runAll() {
        testOwnerAlwaysHasAllPermissions()
        testOwnerCannotEditOwnOrOwnerTargetPermissions()
        testManagerCannotEditPermissions()
        testRoleDefaultsAreIdentityOnly()
        testTeamAdministratorPreset()
        testMemberCreateEventsGrant()
        testMemberPublishAnnouncementsGrant()
        testCustomOverridesRoleDefaults()
        testSummaryGatesUsePermissions()
        testTeamCreationContextEditEvents()
    }

    private static func summary(
        role: FanTeamMemberRole,
        permissions: FanTeamPermissionSet? = nil
    ) -> FanTeamSummary {
        FanTeamSummary(
            id: UUID(),
            name: "Test",
            sport: "Soccer",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            competitionLevel: nil,
            ownerUserId: UUID(),
            groupConversationId: UUID(),
            myRole: role,
            memberCount: 4,
            pendingInvitationCount: 0,
            pushNotificationsMuted: false,
            nextGameStartsAt: nil,
            nextGameTitle: nil,
            nextGameVenue: nil,
            createdAt: Date(),
            myPermissions: permissions
        )
    }

    private static func testOwnerAlwaysHasAllPermissions() {
        let defaults = FanTeamPermissions.roleDefaults(for: .owner)
        assert(defaults == .all)
        let reduced = FanTeamPermissions.effective(
            role: .owner,
            resolution: .custom(FanTeamPermissionSet(keys: [.createEvents]))
        )
        assert(reduced == .all, "Owner cannot be reduced via custom permissions")
        let owner = summary(role: .owner)
        for key in FanTeamPermissionKey.allCases {
            assert(owner.hasPermission(key))
        }
    }

    private static func testOwnerCannotEditOwnOrOwnerTargetPermissions() {
        let ownerId = UUID()
        let otherId = UUID()
        assert(
            !FanTeamPermissions.canEditPermissions(
                viewerRole: .owner,
                targetRole: .owner,
                targetIsManagedPlayer: false,
                viewerUserId: ownerId,
                targetUserId: otherId
            ),
            "Cannot edit another Owner seat"
        )
        assert(
            !FanTeamPermissions.canEditPermissions(
                viewerRole: .owner,
                targetRole: .member,
                targetIsManagedPlayer: false,
                viewerUserId: ownerId,
                targetUserId: ownerId
            ),
            "Owner cannot revoke own permissions via UI"
        )
        assert(
            FanTeamPermissions.canEditPermissions(
                viewerRole: .owner,
                targetRole: .member,
                targetIsManagedPlayer: false,
                viewerUserId: ownerId,
                targetUserId: otherId
            )
        )
        assert(
            !FanTeamPermissions.canEditPermissions(
                viewerRole: .owner,
                targetRole: .member,
                targetIsManagedPlayer: true,
                viewerUserId: ownerId,
                targetUserId: nil
            ),
            "Managed player seats have no grantable permissions"
        )
    }

    private static func testManagerCannotEditPermissions() {
        assert(
            !FanTeamPermissions.canEditPermissions(
                viewerRole: .manager,
                targetRole: .member,
                targetIsManagedPlayer: false,
                viewerUserId: UUID(),
                targetUserId: UUID()
            ),
            "Managers cannot grant/revoke permissions"
        )
        assert(
            !FanTeamPermissions.canEditPermissions(
                viewerRole: .headCoach,
                targetRole: .member,
                targetIsManagedPlayer: false,
                viewerUserId: UUID(),
                targetUserId: UUID()
            )
        )
    }

    private static func testRoleDefaultsAreIdentityOnly() {
        assert(FanTeamPermissions.roleDefaults(for: .owner) == .all)
        for role: FanTeamMemberRole in [
            .manager, .headCoach, .assistantCoach, .captain, .assistantCaptain, .member
        ] {
            assert(
                FanTeamPermissions.roleDefaults(for: role) == .empty,
                "\(role.rawValue) role default must not grant management"
            )
        }
        assert(FanTeamLineupAuthorization.canManageLineup(role: .owner))
        assert(!FanTeamLineupAuthorization.canManageLineup(role: .manager))
        assert(!FanTeamLineupAuthorization.canManageLineup(role: .headCoach))
        assert(!FanTeamLineupAuthorization.canManageLineup(role: .assistantCoach))
        assert(FanTeamLineupAuthorization.canManageLineup(permissions: .teamAdministrator))
        assert(!FanTeamLineupAuthorization.canManageLineup(permissions: .empty))
    }

    private static func testTeamAdministratorPreset() {
        assert(FanTeamPermissionSet.teamAdministrator.isTeamAdministratorPreset)
        assert(FanTeamPermissionSet.all.isTeamAdministratorPreset)
        assert(!FanTeamPermissionSet.empty.isTeamAdministratorPreset)
        assert(!FanTeamPermissionSet(keys: [.createEvents, .manageLineups]).isTeamAdministratorPreset)

        assert(FanTeamPermissions.grantedSet(isTeamAdministrator: true) == .teamAdministrator)
        assert(FanTeamPermissions.grantedSet(isTeamAdministrator: false) == .empty)

        assert(
            FanTeamPermissions.isTeamAdministrator(role: .owner, effective: .empty),
            "Owner is always administrator"
        )
        assert(
            FanTeamPermissions.isTeamAdministrator(
                role: .headCoach,
                effective: .teamAdministrator
            )
        )
        assert(
            !FanTeamPermissions.isTeamAdministrator(
                role: .headCoach,
                effective: FanTeamPermissionSet(keys: [.createEvents, .manageLineups])
            )
        )
        assert(
            !FanTeamPermissions.isTeamAdministrator(role: .manager, effective: .empty)
        )

        let admin = summary(role: .member, permissions: .teamAdministrator)
        assert(admin.canManage)
        assert(admin.canOrganizeActivities)
        assert(admin.canEditTeamEvents)
        assert(admin.canPublishAnnouncements)
        assert(admin.canInviteMembers)
        assert(admin.canManageRoster)
        assert(admin.canManageLineup)
        assert(admin.canManageManagedPlayersStaff)
        assert(admin.canEditIdentity)
        assert(admin.canModerateTeamChat)
        assert(!admin.canAssignRoles, "Team Administrator must not assign Team titles")
        assert(!admin.canDeleteTeam)

        let member = summary(role: .member)
        assert(!member.canManage)
        assert(!member.canOrganizeActivities)
        assert(!member.canAssignRoles)
        assert(!member.canDeleteTeam)

        let managerTitleOnly = summary(role: .manager)
        assert(!managerTitleOnly.canManage)
        assert(!managerTitleOnly.canAssignRoles)
        assert(!managerTitleOnly.canOrganizeActivities)
        assert(managerTitleOnly.canScoreTeamEvents, "Manager title can score")
        assert(!member.canScoreTeamEvents)
    }

    private static func testMemberCreateEventsGrant() {
        let withCreate = summary(
            role: .member,
            permissions: FanTeamPermissionSet(keys: [.createEvents])
        )
        assert(withCreate.canOrganizeActivities)
        assert(!withCreate.canEditTeamEvents)
        assert(!withCreate.canPublishAnnouncements)
        assert(!withCreate.canInviteMembers)

        let without = summary(role: .member)
        assert(!without.canOrganizeActivities)
    }

    private static func testMemberPublishAnnouncementsGrant() {
        let withAnnounce = summary(
            role: .member,
            permissions: FanTeamPermissionSet(keys: [.publishAnnouncements])
        )
        assert(withAnnounce.canPublishAnnouncements)
        assert(!withAnnounce.canOrganizeActivities)

        let without = summary(role: .member)
        assert(!without.canPublishAnnouncements)
    }

    private static func testCustomOverridesRoleDefaults() {
        let member = FanTeamMember(
            userId: UUID(),
            role: .member,
            joinedAt: Date(),
            displayName: "Parent",
            username: nil,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            lastSeenAtRaw: nil,
            useCustomPermissions: true,
            grantedPermissions: FanTeamPermissionSet(keys: [.createEvents, .editEvents])
        )
        assert(member.hasPermission(.createEvents))
        assert(member.hasPermission(.editEvents))
        assert(!member.hasPermission(.publishAnnouncements))

        let headCustom = FanTeamMember(
            userId: UUID(),
            role: .headCoach,
            joinedAt: Date(),
            displayName: "Coach",
            username: nil,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            lastSeenAtRaw: nil,
            useCustomPermissions: true,
            grantedPermissions: FanTeamPermissionSet(keys: [.publishAnnouncements])
        )
        assert(headCustom.hasPermission(.publishAnnouncements))
        assert(!headCustom.hasPermission(.createEvents), "Custom set replaces role defaults")
    }

    private static func testSummaryGatesUsePermissions() {
        let head = summary(role: .headCoach)
        assert(!head.canOrganizeActivities)
        assert(!head.canManageLineup)
        assert(!head.canPublishAnnouncements)
        assert(!head.canEditTeamEvents)
        assert(!head.canAssignRoles)

        let manager = summary(role: .manager, permissions: .teamAdministrator)
        assert(manager.canPublishAnnouncements)
        assert(manager.canEditTeamEvents)
        assert(manager.canInviteMembers)
        assert(!manager.canAssignRoles, "Manager + Team Administrator must not assign titles")
    }

    private static func testTeamCreationContextEditEvents() {
        let parent = summary(
            role: .member,
            permissions: FanTeamPermissionSet(keys: [.editEvents])
        )
        let ctx = PickupGameTeamCreationContext(from: parent)
        assert(ctx.canEditTeamEvents)
        assert(!ctx.canPublishAnnouncements)
        assert(ctx.canManageTeam, "editEvents contributes to broad canManage")
    }
}
#endif
