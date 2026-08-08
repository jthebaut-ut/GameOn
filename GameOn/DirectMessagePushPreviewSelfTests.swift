import Foundation

#if DEBUG
/// Client-side mirror checks for DM push preview / payload routing helpers.
enum DirectMessagePushPreviewSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[DMPushPreviewTest] PASS \(name)")
            } else {
                failures += 1
                print("[DMPushPreviewTest] FAIL \(name)")
            }
        }

        let payload: [AnyHashable: Any] = [
            "source": "direct_message",
            "type": "direct_message",
            "conversation_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "sender_id": "ffffffff-1111-4222-8333-444444444444",
            "message_id": "99999999-aaaa-4bbb-8ccc-dddddddddddd",
        ]
        expect(
            DirectMessageNotificationDeepLinkPayload.isDirectMessageNotification(payload),
            "recognizes DM payload"
        )
        expect(
            DirectMessageNotificationDeepLinkPayload.conversationID(from: payload) != nil,
            "parses conversation_id"
        )
        expect(
            DirectMessageNotificationDeepLinkPayload.senderID(from: payload) != nil,
            "parses sender_id"
        )

        let sports: [AnyHashable: Any] = [
            "source": "pro_game_notification",
            "match_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        ]
        expect(
            !DirectMessageNotificationDeepLinkPayload.isDirectMessageNotification(sports),
            "ignores sports payload"
        )

        let collapsed = "Hey\nthere\tfriend"
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        expect(collapsed == "Hey there friend", "multiline whitespace normalize")

        if failures == 0 {
            print("[DMPushPreviewTest] ALL PASSED")
        } else {
            print("[DMPushPreviewTest] FAILURES=\(failures)")
        }
    }
}
#endif
