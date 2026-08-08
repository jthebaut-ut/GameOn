import Foundation
import UserNotifications

/// Unified remote chat-message APNs payload (`notify-chat-message`).
enum ChatMessageNotificationDeepLinkPayload {
    static let sourceKey = "source"
    static let typeKey = "type"
    static let sourceValue = "chat_message"
    static let chatTypeKey = "chat_type"
    static let conversationIDKey = "conversation_id"
    static let messageIDKey = "message_id"
    static let senderIDKey = "sender_id"
    static let senderDisplayNameKey = "sender_display_name"
    static let senderUsernameKey = "sender_username"
    static let senderHandleKey = "sender_handle"
    static let senderAvatarURLKey = "sender_avatar_url"
    static let conversationTitleKey = "conversation_title"
    static let pickupGameIDKey = "pickup_game_id"
    static let businessIDKey = "business_id"
    static let venueIDKey = "venue_id"

    static func isChatMessageNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        let source = (userInfo[sourceKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let type = (userInfo[typeKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return source == sourceValue || type == sourceValue
    }

    static func chatType(from userInfo: [AnyHashable: Any]) -> String {
        ((userInfo[chatTypeKey] as? String) ?? "direct")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func conversationID(from userInfo: [AnyHashable: Any]) -> UUID? {
        uuid(from: userInfo, key: conversationIDKey)
    }

    static func messageID(from userInfo: [AnyHashable: Any]) -> UUID? {
        uuid(from: userInfo, key: messageIDKey)
    }

    static func senderID(from userInfo: [AnyHashable: Any]) -> UUID? {
        uuid(from: userInfo, key: senderIDKey)
    }

    static func senderDisplayName(from userInfo: [AnyHashable: Any]) -> String? {
        let raw = (userInfo[senderDisplayNameKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    static func senderUsername(from userInfo: [AnyHashable: Any]) -> String? {
        let raw = (userInfo[senderUsernameKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    static func senderHandle(from userInfo: [AnyHashable: Any]) -> String? {
        let raw = (userInfo[senderHandleKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    static func senderAvatarURL(from userInfo: [AnyHashable: Any]) -> String? {
        let raw = (userInfo[senderAvatarURLKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    static func conversationTitle(from userInfo: [AnyHashable: Any]) -> String? {
        let raw = (userInfo[conversationTitleKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    static func pickupGameID(from userInfo: [AnyHashable: Any]) -> UUID? {
        uuid(from: userInfo, key: pickupGameIDKey)
    }

    static func businessID(from userInfo: [AnyHashable: Any]) -> UUID? {
        uuid(from: userInfo, key: businessIDKey)
    }

    static func venueID(from userInfo: [AnyHashable: Any]) -> UUID? {
        uuid(from: userInfo, key: venueIDKey)
    }

    private static func uuid(from userInfo: [AnyHashable: Any], key: String) -> UUID? {
        let raw = (userInfo[key] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)
    }

    static func debugPayloadSummary(_ userInfo: [AnyHashable: Any]) -> String {
        let source = (userInfo[sourceKey] as? String) ?? "nil"
        let chatType = (userInfo[chatTypeKey] as? String) ?? "nil"
        let conversation = (userInfo[conversationIDKey] as? String) ?? "nil"
        return "source=\(source) chat_type=\(chatType) conversation_id=\(conversation)"
    }
}

struct ChatMessageNotificationDeepLinkRequest: Equatable {
    let id: UUID
    let chatType: String
    let conversationID: UUID
    let messageID: UUID?
    let senderID: UUID?
    let senderDisplayName: String
    let pickupGameID: UUID?
    let businessID: UUID?
    let venueID: UUID?
    let conversationTitle: String?
}

/// Routes unified chat_message pushes (and defers to DM bridge for legacy payloads).
@MainActor
final class ChatMessageNotificationDeepLinkBridge {
    static let shared = ChatMessageNotificationDeepLinkBridge()

    private weak var chatViewModel: ChatViewModel?
    private var pendingUserInfo: [AnyHashable: Any]?
    private var lastDeliveredMessageID: UUID?
    private var lastDeliveredAt: Date?

    private init() {}

    func bind(chatViewModel: ChatViewModel) {
        self.chatViewModel = chatViewModel
        if let pendingUserInfo {
            self.pendingUserInfo = nil
            deliver(userInfo: pendingUserInfo)
        }
    }

    func shouldSuppressForegroundSystemPresentation(userInfo: [AnyHashable: Any]) -> Bool {
        guard ChatMessageNotificationDeepLinkPayload.isChatMessageNotification(userInfo) else {
            return false
        }
        // Suppress only when the exact group/pickup thread is open (realtime owns UX).
        // Elsewhere in foreground: allow the system banner (no group in-app toast yet).
        guard let conversationID = ChatMessageNotificationDeepLinkPayload.conversationID(from: userInfo),
              let chatViewModel else {
            return false
        }
        let chatType = ChatMessageNotificationDeepLinkPayload.chatType(from: userInfo)
        return chatViewModel.isUserViewingChatConversation(
            chatType: chatType,
            conversationId: conversationID
        )
    }

    func handleNotificationResponse(_ response: UNNotificationResponse) {
        deliver(userInfo: response.notification.request.content.userInfo)
    }

    func deliver(userInfo: [AnyHashable: Any]) {
#if DEBUG
        print("[ChatPushRoute] received payload=\(ChatMessageNotificationDeepLinkPayload.debugPayloadSummary(userInfo))")
#endif
        // Legacy DM payloads (`source=direct_message`) are handled by
        // DirectMessageNotificationDeepLinkBridge — do not re-route here.
        guard ChatMessageNotificationDeepLinkPayload.isChatMessageNotification(userInfo) else {
            return
        }
        guard let conversationID = ChatMessageNotificationDeepLinkPayload.conversationID(from: userInfo) else {
#if DEBUG
            print("[ChatPushRoute] missing conversation_id; ignoring")
#endif
            return
        }

        let messageID = ChatMessageNotificationDeepLinkPayload.messageID(from: userInfo)
        if isDuplicate(messageID: messageID) {
#if DEBUG
            print("[ChatPushRoute] duplicate presentation prevented")
#endif
            return
        }
        lastDeliveredMessageID = messageID
        lastDeliveredAt = Date()

        let chatType = ChatMessageNotificationDeepLinkPayload.chatType(from: userInfo)
        let senderName = ChatMessageNotificationDeepLinkPayload.senderDisplayName(from: userInfo)
            ?? responseAlertTitle(from: userInfo)
            ?? "FanGeo User"
        let trimmedSender = senderName.trimmingCharacters(in: .whitespacesAndNewlines)

        let request = ChatMessageNotificationDeepLinkRequest(
            id: UUID(),
            chatType: chatType,
            conversationID: conversationID,
            messageID: messageID,
            senderID: ChatMessageNotificationDeepLinkPayload.senderID(from: userInfo),
            senderDisplayName: trimmedSender.isEmpty ? "FanGeo User" : trimmedSender,
            pickupGameID: ChatMessageNotificationDeepLinkPayload.pickupGameID(from: userInfo),
            businessID: ChatMessageNotificationDeepLinkPayload.businessID(from: userInfo),
            venueID: ChatMessageNotificationDeepLinkPayload.venueID(from: userInfo),
            conversationTitle: ChatMessageNotificationDeepLinkPayload.conversationTitle(from: userInfo)
                ?? (chatType == "venue" || chatType == "group" || chatType == "pickup"
                    ? responseAlertTitle(from: userInfo)
                    : nil)
        )

        if let chatViewModel {
            chatViewModel.enqueueChatMessageNotificationDeepLink(request)
        } else {
            pendingUserInfo = userInfo
        }
    }

    private func responseAlertTitle(from userInfo: [AnyHashable: Any]) -> String? {
        if let aps = userInfo["aps"] as? [AnyHashable: Any] {
            if let alert = aps["alert"] as? [AnyHashable: Any], let title = alert["title"] as? String {
                return title
            }
            if let alert = aps["alert"] as? String { return alert }
        }
        return nil
    }

    private func isDuplicate(messageID: UUID?) -> Bool {
        guard let messageID, let lastDeliveredMessageID, let lastDeliveredAt else { return false }
        guard messageID == lastDeliveredMessageID else { return false }
        return Date().timeIntervalSince(lastDeliveredAt) < 2.0
    }
}
