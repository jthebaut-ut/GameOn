import Foundation
import UserNotifications

/// Payload keys for remote support-reply push notification deep links.
enum SupportReplyNotificationDeepLinkPayload {
    static let conversationIDKey = "support_conversation_id"
    static let sourceKey = "source"
    static let sourceValue = "support_reply_notification"

    static func isSupportReplyNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo[sourceKey] as? String) == sourceValue
    }

    static func conversationID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard isSupportReplyNotification(userInfo) else { return nil }
        let raw = (userInfo[conversationIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)
    }

    static func debugPayloadSummary(_ userInfo: [AnyHashable: Any]) -> String {
        let source = (userInfo[sourceKey] as? String) ?? "nil"
        let conversationRaw = (userInfo[conversationIDKey] as? String) ?? "nil"
        return "source=\(source) support_conversation_id=\(conversationRaw)"
    }
}

/// Build 10: open Support Center only. Re-enable ticket drill-in after stability validation.
enum SupportReplyNotificationDeepLinkConfiguration {
    static let opensTicketDirectly = false
}

struct SupportReplyNotificationDeepLinkRequest: Equatable {
    let id: UUID
    let conversationID: UUID
}

/// Delivers support-reply notification taps to ``MapViewModel`` once the root view model is bound.
@MainActor
final class SupportReplyNotificationDeepLinkBridge {
    static let shared = SupportReplyNotificationDeepLinkBridge()

    private weak var viewModel: MapViewModel?
    private var pendingUserInfo: [AnyHashable: Any]?
    private var lastDeliveredConversationID: UUID?
    private var lastDeliveredAt: Date?

    private init() {}

    func bind(viewModel: MapViewModel) {
        self.viewModel = viewModel
        if let pendingUserInfo {
            self.pendingUserInfo = nil
            deliver(userInfo: pendingUserInfo)
        }
    }

    func handleNotificationResponse(_ response: UNNotificationResponse) {
        deliver(userInfo: response.notification.request.content.userInfo)
    }

    func deliver(userInfo: [AnyHashable: Any]) {
#if DEBUG
        print("[SupportDeepLink] received payload=\(SupportReplyNotificationDeepLinkPayload.debugPayloadSummary(userInfo))")
#endif
        guard let conversationID = SupportReplyNotificationDeepLinkPayload.conversationID(from: userInfo) else {
#if DEBUG
            print("[SupportDeepLink] invalid or missing conversationId; ignoring")
#endif
            return
        }

#if DEBUG
        print("[SupportDeepLink] valid conversationId=\(conversationID.uuidString.lowercased())")
#endif

        if isDuplicate(conversationID: conversationID) {
#if DEBUG
            print("[SupportDeepLink] ignored duplicate conversationId=\(conversationID.uuidString.lowercased())")
#endif
            return
        }

        lastDeliveredConversationID = conversationID
        lastDeliveredAt = Date()

        let request = SupportReplyNotificationDeepLinkRequest(
            id: UUID(),
            conversationID: conversationID
        )

        if let viewModel {
            viewModel.enqueueSupportReplyNotificationDeepLink(request)
        } else {
#if DEBUG
            print("[SupportDeepLink] queued conversationId=\(conversationID.uuidString.lowercased()) viewModel=nil")
#endif
            pendingUserInfo = userInfo
        }
    }

    private func isDuplicate(conversationID: UUID) -> Bool {
        guard let lastDeliveredConversationID,
              let lastDeliveredAt,
              lastDeliveredConversationID == conversationID else {
            return false
        }
        return Date().timeIntervalSince(lastDeliveredAt) < 2.0
    }
}
