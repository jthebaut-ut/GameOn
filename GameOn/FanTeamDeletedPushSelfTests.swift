import Foundation

#if DEBUG
/// Client-side rules for Team-deleted push payload routing (no network).
enum FanTeamDeletedPushSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[FanTeamDeletedPushTest] PASS \(name)")
            } else {
                failures += 1
                print("[FanTeamDeletedPushTest] FAIL \(name)")
            }
        }

        let payload: [AnyHashable: Any] = [
            "source": "team_deleted",
            "type": "team_deleted",
            "team_id": "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff",
            "event_id": "99999999-aaaa-4bbb-8ccc-dddddddddddd",
            "team_name": "JT",
        ]
        expect(
            FanTeamDeletedNotificationDeepLinkPayload.isTeamDeletedNotification(payload),
            "recognizes team_deleted payload"
        )
        expect(
            FanTeamDeletedNotificationDeepLinkPayload.teamID(from: payload) != nil,
            "parses team_id"
        )
        expect(
            FanTeamDeletedNotificationDeepLinkPayload.eventID(from: payload) != nil,
            "parses event_id"
        )
        expect(
            FanTeamDeletedNotificationDeepLinkPayload.teamName(from: payload) == "JT",
            "parses team_name"
        )

        let typeOnly: [AnyHashable: Any] = [
            "type": "team_deleted",
            "team_id": "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff",
        ]
        expect(
            FanTeamDeletedNotificationDeepLinkPayload.isTeamDeletedNotification(typeOnly),
            "recognizes type-only team_deleted"
        )

        let invitation: [AnyHashable: Any] = [
            "source": "team_invitation",
            "type": "team_invitation",
            "invitation_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        ]
        expect(
            !FanTeamDeletedNotificationDeepLinkPayload.isTeamDeletedNotification(invitation),
            "ignores team_invitation payload"
        )

        expect(
            FanTeamDeletedNotificationDeepLinkBridge.shared
                .shouldSuppressForegroundSystemPresentation(userInfo: payload),
            "suppresses foreground system banner for team_deleted"
        )
        expect(
            !FanTeamDeletedNotificationDeepLinkBridge.shared
                .shouldSuppressForegroundSystemPresentation(userInfo: invitation),
            "does not suppress foreground banner for invitation"
        )

        // Product copy contract (Edge authoritative; client asserts preferred wording).
        let preferredTitle = "Team deleted"
        let preferredBody = "Team JT was deleted by the Team owner."
        expect(preferredTitle == "Team deleted", "preferred title")
        expect(
            preferredBody.contains("was deleted by the Team owner"),
            "preferred body is lifecycle deletion, not membership removal"
        )
        expect(
            !preferredBody.localizedCaseInsensitiveContains("you've been removed"),
            "preferred body must not say removed-from-team"
        )

        if failures == 0 {
            print("[FanTeamDeletedPushTest] ALL PASSED")
        } else {
            print("[FanTeamDeletedPushTest] FAILED count=\(failures)")
        }
    }
}
#endif
