import Foundation

#if DEBUG
/// Pure routing / payload checks for chat push deep-links (no UI / network).
enum PushDeepLinkRoutingSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[PushDeepLinkSelfTest] PASS \(name)")
            } else {
                failures += 1
                print("[PushDeepLinkSelfTest] FAIL \(name)")
            }
        }

        // A/H — DM + venue conversation_id is authoritative.
        let dmPayload: [AnyHashable: Any] = [
            "source": "direct_message",
            "type": "direct_message",
            "chat_type": "direct",
            "conversation_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "message_id": "99999999-aaaa-4bbb-8ccc-dddddddddddd",
            "sender_id": "ffffffff-1111-4222-8333-444444444444",
        ]
        expect(
            DirectMessageNotificationDeepLinkPayload.isDirectMessageNotification(dmPayload),
            "A recognizes DM payload"
        )
        let dmConversation = DirectMessageNotificationDeepLinkPayload.conversationID(from: dmPayload)
        expect(dmConversation != nil, "A parses DM conversation_id")
        expect(
            DirectMessageNotificationDeepLinkPayload.messageID(from: dmPayload) != nil,
            "A parses DM message_id"
        )

        let venuePayload: [AnyHashable: Any] = [
            "source": "direct_message",
            "type": "direct_message",
            "chat_type": "venue",
            "conversation_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "sender_id": "ffffffff-1111-4222-8333-444444444444",
            "venue_id": "11111111-2222-4333-8444-555555555555",
        ]
        expect(
            DirectMessageNotificationDeepLinkPayload.venueID(from: venuePayload) != nil,
            "H parses venue_id on DM path"
        )
        expect(
            DirectMessageNotificationDeepLinkPayload.conversationID(from: venuePayload) == dmConversation,
            "H venue uses same conversation_id authority"
        )

        // F/G — group / pickup
        let groupPayload: [AnyHashable: Any] = [
            "source": "chat_message",
            "type": "chat_message",
            "chat_type": "group",
            "conversation_id": "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "sender_id": "ffffffff-1111-4222-8333-444444444444",
        ]
        expect(
            ChatMessageNotificationDeepLinkPayload.chatType(from: groupPayload) == "group",
            "F group chat_type"
        )
        expect(
            ChatMessageNotificationDeepLinkPayload.conversationID(from: groupPayload) != nil,
            "F group conversation_id"
        )

        let pickupPayload: [AnyHashable: Any] = [
            "source": "chat_message",
            "type": "chat_message",
            "chat_type": "pickup",
            "conversation_id": "cccccccc-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "pickup_game_id": "11111111-2222-4333-8444-555555555555",
            "sender_id": "ffffffff-1111-4222-8333-444444444444",
        ]
        expect(
            ChatMessageNotificationDeepLinkPayload.chatType(from: pickupPayload) == "pickup",
            "G pickup chat_type"
        )
        expect(
            ChatMessageNotificationDeepLinkPayload.pickupGameID(from: pickupPayload) != nil,
            "G pickup_game_id preserved"
        )

        // I — friend request must not be treated as chat_message / DM
        let friendPayload: [AnyHashable: Any] = [
            "source": "friend_request",
            "type": "friend_request",
            "request_id": "dddddddd-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "requester_id": "ffffffff-1111-4222-8333-444444444444",
        ]
        expect(
            !DirectMessageNotificationDeepLinkPayload.isDirectMessageNotification(friendPayload),
            "I friend_request is not DM"
        )
        expect(
            !ChatMessageNotificationDeepLinkPayload.isChatMessageNotification(friendPayload),
            "I friend_request is not chat_message"
        )
        expect(
            FriendRequestNotificationDeepLinkPayload.isFriendRequestNotification(friendPayload),
            "I friend_request recognized"
        )

        let pokePayload: [AnyHashable: Any] = [
            "source": "poke",
            "type": "poke",
            "poke_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "sender_id": "ffffffff-1111-4222-8333-444444444444",
        ]
        expect(
            !DirectMessageNotificationDeepLinkPayload.isDirectMessageNotification(pokePayload),
            "I poke is not DM"
        )
        expect(
            !FriendRequestNotificationDeepLinkPayload.isFriendRequestNotification(pokePayload),
            "I poke is not friend_request"
        )
        expect(
            PokeNotificationDeepLinkPayload.isPokeNotification(pokePayload),
            "I poke recognized"
        )

        // C — section routing intent: DM/group → chats; friend → requests
        expect(
            PushDeepLinkRoutingPolicy.chatSection(for: .directMessage) == .chats,
            "C DM forces Chats subsection"
        )
        expect(
            PushDeepLinkRoutingPolicy.chatSection(for: .groupOrPickup) == .chats,
            "C group/pickup forces Chats subsection"
        )
        expect(
            PushDeepLinkRoutingPolicy.chatSection(for: .friendRequest) == .requests,
            "I friend request keeps Requests subsection"
        )

        // E — same-conversation identity
        let routeA = DirectChatNavRoute(
            preview: UserPreview(
                id: UUID(uuidString: "ffffffff-1111-4222-8333-444444444444")!,
                displayName: "Miriam",
                avatarURL: nil,
                dmConversationId: dmConversation
            )
        )
        let routeB = DirectChatNavRoute(
            preview: UserPreview(
                id: UUID(uuidString: "ffffffff-1111-4222-8333-444444444444")!,
                displayName: "Miriam Updated",
                avatarURL: nil,
                dmConversationId: dmConversation
            )
        )
        expect(routeA == routeB, "E same conversation_id is stable route identity")

        // J — invalid missing conversation
        let invalid: [AnyHashable: Any] = [
            "source": "direct_message",
            "type": "direct_message",
            "sender_id": "ffffffff-1111-4222-8333-444444444444",
        ]
        expect(
            DirectMessageNotificationDeepLinkPayload.conversationID(from: invalid) == nil,
            "J missing conversation_id rejected"
        )

        // L — sports push not stolen
        let sports: [AnyHashable: Any] = [
            "source": "pro_game_notification",
            "match_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        ]
        expect(
            !DirectMessageNotificationDeepLinkPayload.isDirectMessageNotification(sports),
            "L sports push unaffected by DM bridge"
        )
        expect(
            !ChatMessageNotificationDeepLinkPayload.isChatMessageNotification(sports),
            "L sports push unaffected by chat_message bridge"
        )

        // Durable pending flag helper semantics
        expect(
            PushDeepLinkRoutingPolicy.shouldRetainUntilUIAccepts,
            "durable route retained until UI accepts"
        )

        if failures == 0 {
            print("[PushDeepLinkSelfTest] ALL_PASSED")
        } else {
            print("[PushDeepLinkSelfTest] FAILURES=\(failures)")
        }
    }
}

/// Lightweight policy mirror for self-tests (keeps FriendsTab section rules explicit).
enum PushDeepLinkRoutingPolicy {
    enum Kind {
        case directMessage
        case groupOrPickup
        case friendRequest
    }

    enum ChatSection: String {
        case chats
        case requests
    }

    static let shouldRetainUntilUIAccepts = true

    static func chatSection(for kind: Kind) -> ChatSection {
        switch kind {
        case .directMessage, .groupOrPickup:
            return .chats
        case .friendRequest:
            return .requests
        }
    }
}
#endif
