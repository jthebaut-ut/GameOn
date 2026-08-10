import Foundation

#if DEBUG
enum FanTeamInvitationPushSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[FanTeamInvitationPushTest] PASS \(name)")
            } else {
                failures += 1
                print("[FanTeamInvitationPushTest] FAIL \(name)")
            }
        }

        let payload: [AnyHashable: Any] = [
            "source": "team_invitation",
            "type": "team_invitation",
            "invitation_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "team_id": "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff",
            "invited_by_user_id": "ffffffff-1111-4222-8333-444444444444",
            "event_id": "99999999-aaaa-4bbb-8ccc-dddddddddddd",
        ]
        expect(
            FanTeamInvitationNotificationDeepLinkPayload.isTeamInvitationNotification(payload),
            "recognizes team_invitation payload"
        )
        expect(
            FanTeamInvitationNotificationDeepLinkPayload.invitationID(from: payload) != nil,
            "parses invitation_id"
        )
        expect(
            FanTeamInvitationNotificationDeepLinkPayload.teamID(from: payload) != nil,
            "parses team_id"
        )
        expect(
            FanTeamInvitationNotificationDeepLinkPayload.invitedByUserID(from: payload) != nil,
            "parses invited_by_user_id"
        )

        let typeOnly: [AnyHashable: Any] = [
            "type": "team_invitation",
            "invitation_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        ]
        expect(
            FanTeamInvitationNotificationDeepLinkPayload.isTeamInvitationNotification(typeOnly),
            "recognizes type-only team_invitation"
        )

        let dm: [AnyHashable: Any] = [
            "source": "direct_message",
            "conversation_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        ]
        expect(
            !FanTeamInvitationNotificationDeepLinkPayload.isTeamInvitationNotification(dm),
            "ignores DM payload"
        )

        let friend: [AnyHashable: Any] = [
            "source": "friend_request",
            "type": "friend_request",
            "request_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        ]
        expect(
            !FanTeamInvitationNotificationDeepLinkPayload.isTeamInvitationNotification(friend),
            "ignores friend_request payload"
        )

        expect(
            FanTeamInvitationNotificationDeepLinkBridge.shared
                .shouldSuppressForegroundSystemPresentation(userInfo: payload),
            "suppresses foreground system banner for team_invitation"
        )
        expect(
            !FanTeamInvitationNotificationDeepLinkBridge.shared
                .shouldSuppressForegroundSystemPresentation(userInfo: dm),
            "does not suppress foreground banner for DM"
        )

        expect(
            FanTeamInvitationResendOutcome.parse(ok: true, rateLimited: false, message: nil) == .sent,
            "resend outcome sent"
        )
        expect(
            FanTeamInvitationResendOutcome.parse(
                ok: false,
                rateLimited: true,
                message: "Invitation was recently sent. Please wait a few minutes before resending."
            ) == .rateLimited("Invitation was recently sent. Please wait a few minutes before resending."),
            "resend outcome rate limited"
        )
        expect(
            FanTeamInvitationResendOutcome.parse(ok: false, rateLimited: nil, message: nil) == .rateLimited(nil),
            "resend outcome soft failure without rate_limited flag"
        )

        // Resend deep link must reuse the same invitation identity (no second invitation).
        let resendPayload: [AnyHashable: Any] = [
            "source": "team_invitation",
            "type": "team_invitation",
            "invitation_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "team_id": "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff",
            "event_id": "11111111-aaaa-4bbb-8ccc-dddddddddddd",
        ]
        expect(
            FanTeamInvitationNotificationDeepLinkPayload.invitationID(from: resendPayload)?.uuidString
                == "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
            "resend payload keeps same invitation_id"
        )

        if failures == 0 {
            print("[FanTeamInvitationPushTest] ALL PASSED")
        } else {
            print("[FanTeamInvitationPushTest] FAILURES=\(failures)")
        }
    }
}
#endif
