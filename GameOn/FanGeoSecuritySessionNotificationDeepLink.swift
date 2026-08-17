import Foundation
import UserNotifications

enum FanGeoSecuritySessionNotificationDeepLinkPayload {
    static let sourceKey = "source"
    static let typeKey = "type"
    static let sourceValue = FanGeoSecuritySessionReplacement.source

    static func isSecuritySessionNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        let source = (userInfo[sourceKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let type = (userInfo[typeKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            ?? (userInfo["notification_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return source == sourceValue || type == sourceValue
    }

    static func debugPayloadSummary(_ userInfo: [AnyHashable: Any]) -> String {
        let safe = FanGeoSecuritySessionReplacement.sanitizedCustomData(userInfo)
        let source = safe["source"] ?? "nil"
        let event = safe["event_id"] ?? "nil"
        return "source=\(source) event_id=\(event)"
    }
}

struct FanGeoSecuritySessionDeepLinkRequest: Equatable {
    let id: UUID
}

@MainActor
final class FanGeoSecuritySessionNotificationDeepLinkBridge {
    static let shared = FanGeoSecuritySessionNotificationDeepLinkBridge()

    private weak var viewModel: MapViewModel?
    private var pendingUserInfo: [AnyHashable: Any]?
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
        print("[SecuritySessionRoute] received payload=\(FanGeoSecuritySessionNotificationDeepLinkPayload.debugPayloadSummary(userInfo))")
#endif
        guard FanGeoSecuritySessionNotificationDeepLinkPayload.isSecuritySessionNotification(userInfo) else {
            return
        }
        if let lastDeliveredAt, Date().timeIntervalSince(lastDeliveredAt) < 2 {
            return
        }
        lastDeliveredAt = Date()
        if let viewModel {
            viewModel.handleSecuritySessionReplacedDeepLink()
        } else {
            pendingUserInfo = userInfo
        }
    }
}
