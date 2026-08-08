import Foundation
import UserNotifications

/// Payload keys for remote friend-request APNs deep links (`notify-friend-request`).
enum FriendRequestNotificationDeepLinkPayload {
    static let sourceKey = "source"
    static let typeKey = "type"
    static let sourceValue = "friend_request"
    static let requestIDKey = "request_id"
    static let friendshipIDKey = "friendship_id"
    static let requesterIDKey = "requester_id"
    static let eventIDKey = "event_id"

    static func isFriendRequestNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        let source = (userInfo[sourceKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let type = (userInfo[typeKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return source == sourceValue || type == sourceValue
    }

    static func requestID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard isFriendRequestNotification(userInfo) else { return nil }
        let raw = (userInfo[requestIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (userInfo[friendshipIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        guard !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)
    }

    static func requesterID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard isFriendRequestNotification(userInfo) else { return nil }
        let raw = (userInfo[requesterIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)
    }

    static func eventID(from userInfo: [AnyHashable: Any]) -> UUID? {
        let raw = (userInfo[eventIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)
    }

    static func debugPayloadSummary(_ userInfo: [AnyHashable: Any]) -> String {
        let source = (userInfo[sourceKey] as? String) ?? "nil"
        let request = (userInfo[requestIDKey] as? String)
            ?? (userInfo[friendshipIDKey] as? String)
            ?? "nil"
        let requester = (userInfo[requesterIDKey] as? String) ?? "nil"
        return "source=\(source) request_id=\(request) requester_id=\(requester)"
    }
}

struct FriendRequestNotificationDeepLinkRequest: Equatable {
    let id: UUID
    let requestID: UUID?
    let requesterID: UUID?
    let eventID: UUID?
}

/// Delivers friend-request notification taps to ``ChatViewModel`` (Chat → Requests).
@MainActor
final class FriendRequestNotificationDeepLinkBridge {
    static let shared = FriendRequestNotificationDeepLinkBridge()

    private weak var chatViewModel: ChatViewModel?
    private var pendingUserInfo: [AnyHashable: Any]?
    private var lastDeliveredEventID: UUID?
    private var lastDeliveredRequestID: UUID?
    private var lastDeliveredAt: Date?

    private init() {}

    func bind(chatViewModel: ChatViewModel) {
        self.chatViewModel = chatViewModel
        if let pendingUserInfo {
            self.pendingUserInfo = nil
            deliver(userInfo: pendingUserInfo)
        }
    }

    /// Foreground: suppress system banners so badge/realtime remain the single in-app path.
    func shouldSuppressForegroundSystemPresentation(userInfo: [AnyHashable: Any]) -> Bool {
        FriendRequestNotificationDeepLinkPayload.isFriendRequestNotification(userInfo)
    }

    func handleNotificationResponse(_ response: UNNotificationResponse) {
        deliver(userInfo: response.notification.request.content.userInfo)
    }

    func deliver(userInfo: [AnyHashable: Any]) {
#if DEBUG
        print("[FriendRequestPushRoute] received payload=\(FriendRequestNotificationDeepLinkPayload.debugPayloadSummary(userInfo))")
#endif
        guard FriendRequestNotificationDeepLinkPayload.isFriendRequestNotification(userInfo) else {
            return
        }

        let requestID = FriendRequestNotificationDeepLinkPayload.requestID(from: userInfo)
        let requesterID = FriendRequestNotificationDeepLinkPayload.requesterID(from: userInfo)
        let eventID = FriendRequestNotificationDeepLinkPayload.eventID(from: userInfo)

        if isDuplicate(eventID: eventID, requestID: requestID) {
#if DEBUG
            print("[FriendRequestPushRoute] duplicate presentation prevented")
#endif
            return
        }

        lastDeliveredEventID = eventID
        lastDeliveredRequestID = requestID
        lastDeliveredAt = Date()

        let request = FriendRequestNotificationDeepLinkRequest(
            id: UUID(),
            requestID: requestID,
            requesterID: requesterID,
            eventID: eventID
        )

        if let chatViewModel {
            chatViewModel.enqueueFriendRequestNotificationDeepLink(request)
        } else {
#if DEBUG
            print("[FriendRequestPushRoute] chatViewModel=nil; queuing payload")
#endif
            pendingUserInfo = userInfo
        }
    }

    private func isDuplicate(eventID: UUID?, requestID: UUID?) -> Bool {
        guard let lastDeliveredAt else { return false }
        guard Date().timeIntervalSince(lastDeliveredAt) < 2.0 else { return false }
        if let eventID, let lastDeliveredEventID, eventID == lastDeliveredEventID {
            return true
        }
        if let requestID, let lastDeliveredRequestID, requestID == lastDeliveredRequestID {
            return true
        }
        return false
    }
}
