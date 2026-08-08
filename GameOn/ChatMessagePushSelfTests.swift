import Foundation

#if DEBUG
/// Payload recognition / routing checks for unified chat_message APNs.
enum ChatMessagePushSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[ChatPushSelfTest] PASS \(name)")
            } else {
                failures += 1
                print("[ChatPushSelfTest] FAIL \(name)")
            }
        }

        let groupPayload: [AnyHashable: Any] = [
            "source": "chat_message",
            "type": "chat_message",
            "chat_type": "group",
            "conversation_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "message_id": "99999999-aaaa-4bbb-8ccc-dddddddddddd",
            "sender_id": "ffffffff-1111-4222-8333-444444444444",
            "sender_display_name": "Jonathan",
            "conversation_title": "Soccer Fans Utah",
        ]
        expect(
            ChatMessageNotificationDeepLinkPayload.isChatMessageNotification(groupPayload),
            "recognizes group chat_message payload"
        )
        expect(
            ChatMessageNotificationDeepLinkPayload.chatType(from: groupPayload) == "group",
            "parses chat_type=group"
        )
        expect(
            ChatMessageNotificationDeepLinkPayload.conversationID(from: groupPayload) != nil,
            "parses group conversation_id"
        )
        expect(
            ChatMessageNotificationDeepLinkPayload.senderDisplayName(from: groupPayload) == "Jonathan",
            "parses sender_display_name"
        )

        let pickupPayload: [AnyHashable: Any] = [
            "source": "chat_message",
            "type": "chat_message",
            "chat_type": "pickup",
            "conversation_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "pickup_game_id": "11111111-2222-4333-8444-555555555555",
            "sender_id": "ffffffff-1111-4222-8333-444444444444",
        ]
        expect(
            ChatMessageNotificationDeepLinkPayload.chatType(from: pickupPayload) == "pickup",
            "parses chat_type=pickup"
        )
        expect(
            ChatMessageNotificationDeepLinkPayload.pickupGameID(from: pickupPayload) != nil,
            "parses pickup_game_id"
        )

        let legacyDM: [AnyHashable: Any] = [
            "source": "direct_message",
            "type": "direct_message",
            "conversation_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "sender_id": "ffffffff-1111-4222-8333-444444444444",
        ]
        expect(
            !ChatMessageNotificationDeepLinkPayload.isChatMessageNotification(legacyDM),
            "does not steal legacy DM payloads"
        )
        expect(
            DirectMessageNotificationDeepLinkPayload.isDirectMessageNotification(legacyDM),
            "legacy DM still recognized by DM bridge"
        )

        let sports: [AnyHashable: Any] = [
            "source": "pro_game_notification",
            "match_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        ]
        expect(
            !ChatMessageNotificationDeepLinkPayload.isChatMessageNotification(sports),
            "ignores sports payload"
        )

        let collapsed = "Hey\nthere\tfriend"
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        expect(collapsed == "Hey there friend", "multiline whitespace normalize")

        if failures == 0 {
            print("[ChatPushSelfTest] ALL PASSED")
        } else {
            print("[ChatPushSelfTest] FAILURES=\(failures)")
        }
    }
}
#endif
