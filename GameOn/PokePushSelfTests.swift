import Foundation

#if DEBUG
enum PokePushSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[PokePushTest] PASS \(name)")
            } else {
                failures += 1
                print("[PokePushTest] FAIL \(name)")
            }
        }

        let payload: [AnyHashable: Any] = [
            "source": "poke",
            "type": "poke",
            "poke_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "event_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "sender_id": "ffffffff-1111-4222-8333-444444444444",
            "poker_id": "ffffffff-1111-4222-8333-444444444444",
            "recipient_id": "99999999-aaaa-4bbb-8ccc-dddddddddddd",
            "sender_display_name": "Michiel",
            "sender_username": "michiel",
            "sender_handle": "@michiel",
        ]
        expect(
            PokeNotificationDeepLinkPayload.isPokeNotification(payload),
            "recognizes poke payload"
        )
        expect(
            PokeNotificationDeepLinkPayload.pokeID(from: payload) != nil,
            "parses poke_id"
        )
        expect(
            PokeNotificationDeepLinkPayload.senderID(from: payload) != nil,
            "parses sender_id"
        )
        expect(
            PokeNotificationDeepLinkPayload.recipientID(from: payload) != nil,
            "parses recipient_id"
        )

        let pokerAlias: [AnyHashable: Any] = [
            "source": "poke",
            "type": "poke",
            "poker_id": "ffffffff-1111-4222-8333-444444444444",
        ]
        expect(
            PokeNotificationDeepLinkPayload.senderID(from: pokerAlias) != nil,
            "accepts poker_id alias"
        )

        let dm: [AnyHashable: Any] = [
            "source": "direct_message",
            "conversation_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        ]
        expect(
            !PokeNotificationDeepLinkPayload.isPokeNotification(dm),
            "ignores DM payload"
        )

        let friend: [AnyHashable: Any] = [
            "source": "friend_request",
            "type": "friend_request",
            "request_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        ]
        expect(
            !PokeNotificationDeepLinkPayload.isPokeNotification(friend),
            "ignores friend_request payload"
        )

        if failures == 0 {
            print("[PokePushTest] ALL PASSED")
        } else {
            print("[PokePushTest] FAILURES=\(failures)")
        }
    }
}
#endif
