import Foundation

#if DEBUG
enum FanTeamPushMuteSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[FanTeamPushMuteTest] PASS \(name)")
            } else {
                failures += 1
                print("[FanTeamPushMuteTest] FAIL \(name)")
            }
        }

        let base = FanTeamSummary(
            id: UUID(),
            name: "JT",
            sport: "Soccer",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: "#112233",
            competitionLevel: nil,
            ownerUserId: UUID(),
            groupConversationId: UUID(),
            myRole: .member,
            memberCount: 4,
            pendingInvitationCount: 0,
            pushNotificationsMuted: false,
            nextGameStartsAt: nil,
            nextGameTitle: nil,
            nextGameVenue: nil,
            createdAt: nil
        )

        expect(base.pushNotificationsMuted == false, "default unmuted")
        let muted = base.applyingPushNotificationsMuted(true)
        expect(muted.pushNotificationsMuted == true, "apply mute true")
        expect(muted.id == base.id, "mute apply keeps team id")
        expect(muted.name == base.name, "mute apply keeps name")
        expect(muted.memberCount == base.memberCount, "mute apply keeps membership")
        expect(muted.applyingPushNotificationsMuted(false).pushNotificationsMuted == false, "unmute")

        let ownerMuted = FanTeamSummary(
            id: base.id,
            name: base.name,
            sport: base.sport,
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            competitionLevel: nil,
            ownerUserId: base.ownerUserId,
            groupConversationId: base.groupConversationId,
            myRole: .owner,
            memberCount: 4,
            pendingInvitationCount: 0,
            pushNotificationsMuted: true,
            nextGameStartsAt: nil,
            nextGameTitle: nil,
            nextGameVenue: nil,
            createdAt: nil
        )
        expect(ownerMuted.canManage && ownerMuted.pushNotificationsMuted, "owner may mute self")
        expect(ownerMuted.canDeleteTeam, "owner still owns team while muted")

        let managerMuted = ownerMuted.applyingPushNotificationsMuted(true)
        // Reconstruct as manager role for role check.
        let manager = FanTeamSummary(
            id: base.id,
            name: base.name,
            sport: base.sport,
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            competitionLevel: nil,
            ownerUserId: base.ownerUserId,
            groupConversationId: base.groupConversationId,
            myRole: .manager,
            memberCount: 4,
            pendingInvitationCount: 1,
            pushNotificationsMuted: true,
            nextGameStartsAt: nil,
            nextGameTitle: nil,
            nextGameVenue: nil,
            createdAt: nil,
            myPermissions: .teamAdministrator
        )
        expect(manager.canManage && manager.pushNotificationsMuted, "manager may mute self")
        expect(managerMuted.pushNotificationsMuted, "applying mute preserves flag")

        // Identity apply must preserve mute.
        let afterIdentity = muted.applyingIdentity(
            name: "JT Renamed",
            sport: "Soccer",
            colorHex: "#112233",
            logoURL: nil,
            logoThumbnailURL: nil,
            competitionLevel: nil
        )
        expect(afterIdentity.pushNotificationsMuted == true, "identity apply preserves mute")
        expect(afterIdentity.name == "JT Renamed", "identity apply updates name")

        if failures == 0 {
            print("[FanTeamPushMuteTest] ALL PASSED")
        } else {
            print("[FanTeamPushMuteTest] FAILURES=\(failures)")
        }
    }
}
#endif
