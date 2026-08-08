import Foundation
import UserNotifications

/// Payload keys for remote direct-message APNs deep links (`notify-direct-message`).
enum DirectMessageNotificationDeepLinkPayload {
    static let sourceKey = "source"
    static let typeKey = "type"
    static let sourceValue = "direct_message"
    static let conversationIDKey = "conversation_id"
    static let senderIDKey = "sender_id"
    static let messageIDKey = "message_id"
    static let businessIDKey = "business_id"
    static let venueIDKey = "venue_id"

    static func isDirectMessageNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        let source = (userInfo[sourceKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let type = (userInfo[typeKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return source == sourceValue || type == sourceValue
    }

    static func conversationID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard isDirectMessageNotification(userInfo) else { return nil }
        let raw = (userInfo[conversationIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)
    }

    static func senderID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard isDirectMessageNotification(userInfo) else { return nil }
        let raw = (userInfo[senderIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)
    }

    static func messageID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard isDirectMessageNotification(userInfo) else { return nil }
        let raw = (userInfo[messageIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)
    }

    static func businessID(from userInfo: [AnyHashable: Any]) -> UUID? {
        let raw = (userInfo[businessIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)
    }

    static func venueID(from userInfo: [AnyHashable: Any]) -> UUID? {
        let raw = (userInfo[venueIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)
    }

    static func debugPayloadSummary(_ userInfo: [AnyHashable: Any]) -> String {
        let source = (userInfo[sourceKey] as? String) ?? "nil"
        let conversation = (userInfo[conversationIDKey] as? String) ?? "nil"
        let sender = (userInfo[senderIDKey] as? String) ?? "nil"
        let message = (userInfo[messageIDKey] as? String) ?? "nil"
        return "source=\(source) conversation_id=\(conversation) sender_id=\(sender) message_id=\(message)"
    }
}

struct DirectMessageNotificationDeepLinkRequest: Equatable {
    let id: UUID
    let conversationID: UUID
    let senderID: UUID
    let messageID: UUID?
    let senderDisplayName: String
    let businessID: UUID?
    let venueID: UUID?
}

/// Delivers DM notification taps to ``ChatViewModel`` once bound (cold-start safe).
@MainActor
final class DirectMessageNotificationDeepLinkBridge {
    static let shared = DirectMessageNotificationDeepLinkBridge()

    private weak var chatViewModel: ChatViewModel?
    private var pendingUserInfo: [AnyHashable: Any]?
    private var lastDeliveredMessageID: UUID?
    private var lastDeliveredConversationID: UUID?
    private var lastDeliveredAt: Date?

    private init() {}

    func bind(chatViewModel: ChatViewModel) {
        self.chatViewModel = chatViewModel
        if let pendingUserInfo {
            self.pendingUserInfo = nil
            deliver(userInfo: pendingUserInfo)
        }
    }

    /// Foreground APNs presentation: suppress system banners for DMs so realtime /
    /// in-app banner remain the single foreground path (no duplicates).
    func shouldSuppressForegroundSystemPresentation(userInfo: [AnyHashable: Any]) -> Bool {
        DirectMessageNotificationDeepLinkPayload.isDirectMessageNotification(userInfo)
    }

    func handleNotificationResponse(_ response: UNNotificationResponse) {
        deliver(userInfo: response.notification.request.content.userInfo)
    }

    func deliver(userInfo: [AnyHashable: Any]) {
#if DEBUG
        print("[DMPushRoute] received payload=\(DirectMessageNotificationDeepLinkPayload.debugPayloadSummary(userInfo))")
#endif
        guard let conversationID = DirectMessageNotificationDeepLinkPayload.conversationID(from: userInfo) else {
#if DEBUG
            PushDeepLinkLog.failed(reason: "missing_conversation_id")
            print("[DMPushRoute] invalid or missing conversation_id; ignoring")
#endif
            return
        }
        guard let senderID = DirectMessageNotificationDeepLinkPayload.senderID(from: userInfo) else {
#if DEBUG
            PushDeepLinkLog.failed(reason: "missing_sender_id")
            print("[DMPushRoute] invalid or missing sender_id; ignoring")
#endif
            return
        }

#if DEBUG
        PushDeepLinkLog.received(type: "direct", conversation: conversationID)
#endif

        let messageID = DirectMessageNotificationDeepLinkPayload.messageID(from: userInfo)
        if isDuplicate(messageID: messageID, conversationID: conversationID) {
#if DEBUG
            print("[DMPushRoute] duplicate presentation prevented conversationId=\(conversationID.uuidString.lowercased())")
#endif
            return
        }

        lastDeliveredMessageID = messageID
        lastDeliveredConversationID = conversationID
        lastDeliveredAt = Date()

        let title = (responseAlertTitle(from: userInfo) ?? "FanGeo User")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let request = DirectMessageNotificationDeepLinkRequest(
            id: UUID(),
            conversationID: conversationID,
            senderID: senderID,
            messageID: messageID,
            senderDisplayName: title.isEmpty ? "FanGeo User" : title,
            businessID: DirectMessageNotificationDeepLinkPayload.businessID(from: userInfo),
            venueID: DirectMessageNotificationDeepLinkPayload.venueID(from: userInfo)
        )

        if let chatViewModel {
            chatViewModel.enqueueDirectMessageNotificationDeepLink(request)
        } else {
#if DEBUG
            print("[DMPushRoute] chatViewModel=nil; queuing payload")
#endif
            pendingUserInfo = userInfo
        }
    }

    private func responseAlertTitle(from userInfo: [AnyHashable: Any]) -> String? {
        // APNs alert title is mirrored into userInfo under aps.alert.title when present.
        if let aps = userInfo["aps"] as? [AnyHashable: Any] {
            if let alert = aps["alert"] as? [AnyHashable: Any] {
                if let title = alert["title"] as? String { return title }
            }
            if let alert = aps["alert"] as? String { return alert }
        }
        return nil
    }

    private func isDuplicate(messageID: UUID?, conversationID: UUID) -> Bool {
        guard let lastDeliveredAt else { return false }
        guard Date().timeIntervalSince(lastDeliveredAt) < 2.0 else { return false }
        if let messageID, let lastDeliveredMessageID, messageID == lastDeliveredMessageID {
            return true
        }
        return lastDeliveredConversationID == conversationID && messageID == nil
    }
}
