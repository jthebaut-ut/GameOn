import Foundation

extension MapViewModel {
    func enqueueSupportReplyNotificationDeepLink(_ request: SupportReplyNotificationDeepLinkRequest) {
#if DEBUG
        print("[SupportNotificationRoute] enqueue pendingSupportReplyNotificationDeepLink conversationId=\(request.conversationID.uuidString.lowercased())")
#endif
        pendingSupportReplyNotificationDeepLink = request
    }

    func clearPendingSupportReplyNotificationDeepLink() {
#if DEBUG
        if let pending = pendingSupportReplyNotificationDeepLink {
            print("[SupportNotificationRoute] pending route cleared from MapViewModel conversationId=\(pending.conversationID.uuidString.lowercased())")
        }
#endif
        pendingSupportReplyNotificationDeepLink = nil
    }
}
