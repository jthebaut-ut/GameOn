import Foundation

extension MapViewModel {
    func enqueueSupportReplyNotificationDeepLink(_ request: SupportReplyNotificationDeepLinkRequest) {
        pendingSupportReplyNotificationDeepLink = request
    }

    func clearPendingSupportReplyNotificationDeepLink() {
        pendingSupportReplyNotificationDeepLink = nil
    }
}
