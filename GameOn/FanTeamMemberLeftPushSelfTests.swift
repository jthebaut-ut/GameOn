import Foundation

enum FanTeamMemberLeftPushSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
            if condition() {
#if DEBUG
                print("[FanTeamMemberLeftPushTest] PASS \(name)")
#endif
            } else {
                failures += 1
#if DEBUG
                print("[FanTeamMemberLeftPushTest] FAIL \(name)")
#endif
            }
        }

        let payload: [AnyHashable: Any] = [
            "source": "member_left_team",
            "type": "member_left_team",
            "team_id": "11111111-1111-4111-8111-111111111111",
            "event_id": "22222222-2222-4222-8222-222222222222",
            "left_user_id": "33333333-3333-4333-8333-333333333333",
            "team_name": "JT",
            "destination": "team_roster",
        ]
        expect(
            FanTeamMemberLeftNotificationDeepLinkPayload.isMemberLeftNotification(payload),
            "recognizes member_left_team payload"
        )
        expect(
            FanTeamMemberLeftNotificationDeepLinkPayload.teamID(from: payload) != nil,
            "parses team_id"
        )
        expect(
            FanTeamMemberLeftNotificationDeepLinkPayload.eventID(from: payload) != nil,
            "parses event_id"
        )
        expect(
            FanTeamMemberLeftNotificationDeepLinkPayload.leftUserID(from: payload) != nil,
            "parses left_user_id"
        )
        expect(
            FanTeamMemberLeftNotificationDeepLinkPayload.teamName(from: payload) == "JT",
            "parses team_name"
        )

        let invitation: [AnyHashable: Any] = [
            "type": "team_invitation",
            "team_id": "11111111-1111-4111-8111-111111111111",
        ]
        expect(
            !FanTeamMemberLeftNotificationDeepLinkPayload.isMemberLeftNotification(invitation),
            "ignores team_invitation"
        )

        for lang in L10n.supportedLanguages.map(\.code) {
            let title = L10n.t("fan_team_member_left_push_title_format", languageCode: lang)
            let body = L10n.t("fan_team_member_left_push_body_format", languageCode: lang)
            expect(title != "fan_team_member_left_push_title_format", "title localized \(lang)")
            expect(body != "fan_team_member_left_push_body_format", "body localized \(lang)")
            expect(title.contains("%@"), "title placeholder \(lang)")
            expect(body.contains("%@"), "body placeholder \(lang)")
        }

#if DEBUG
        if failures == 0 {
            print("[FanTeamMemberLeftPushTest] ALL PASSED")
        } else {
            print("[FanTeamMemberLeftPushTest] FAILED count=\(failures)")
        }
#endif
    }
}
