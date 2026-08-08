import Foundation

#if DEBUG
enum FriendRequestPushSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[FriendRequestPushTest] PASS \(name)")
            } else {
                failures += 1
                print("[FriendRequestPushTest] FAIL \(name)")
            }
        }

        let payload: [AnyHashable: Any] = [
            "source": "friend_request",
            "type": "friend_request",
            "request_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "requester_id": "ffffffff-1111-4222-8333-444444444444",
            "event_id": "99999999-aaaa-4bbb-8ccc-dddddddddddd",
        ]
        expect(
            FriendRequestNotificationDeepLinkPayload.isFriendRequestNotification(payload),
            "recognizes friend_request payload"
        )
        expect(
            FriendRequestNotificationDeepLinkPayload.requestID(from: payload) != nil,
            "parses request_id"
        )
        expect(
            FriendRequestNotificationDeepLinkPayload.requesterID(from: payload) != nil,
            "parses requester_id"
        )

        let dm: [AnyHashable: Any] = [
            "source": "direct_message",
            "conversation_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        ]
        expect(
            !FriendRequestNotificationDeepLinkPayload.isFriendRequestNotification(dm),
            "ignores DM payload"
        )

        if failures == 0 {
            print("[FriendRequestPushTest] ALL PASSED")
        } else {
            print("[FriendRequestPushTest] FAILURES=\(failures)")
        }
    }
}
#endif
