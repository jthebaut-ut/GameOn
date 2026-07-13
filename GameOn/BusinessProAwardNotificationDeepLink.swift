import Foundation
import UserNotifications

/// Payload keys for remote admin Business Pro award push notification deep links.
enum BusinessProAwardNotificationDeepLinkPayload {
    static let sourceKey = "source"
    static let sourceValue = "admin_business_pro_award"
    static let businessIDKey = "business_id"
    static let expiresAtKey = "expires_at"
    static let entitlementSourceKey = "entitlement_source"
    static let eventKindKey = "event_kind"
    static let awardEventIDKey = "award_event_id"

    static func isBusinessProAwardNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo[sourceKey] as? String) == sourceValue
    }

    static func businessID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard isBusinessProAwardNotification(userInfo) else { return nil }
        let raw = (userInfo[businessIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)
    }

    static func debugPayloadSummary(_ userInfo: [AnyHashable: Any]) -> String {
        let source = (userInfo[sourceKey] as? String) ?? "nil"
        let businessID = (userInfo[businessIDKey] as? String) ?? "nil"
        let expiresAt = (userInfo[expiresAtKey] as? String) ?? "nil"
        let entitlementSource = (userInfo[entitlementSourceKey] as? String) ?? "nil"
        let eventKind = (userInfo[eventKindKey] as? String) ?? "nil"
        return "source=\(source) business_id=\(businessID) expires_at=\(expiresAt) entitlement_source=\(entitlementSource) event_kind=\(eventKind)"
    }
}

/// Delivers Business Pro award notification taps to ``MapViewModel`` once the root view model is bound.
@MainActor
final class BusinessProAwardNotificationDeepLinkBridge {
    static let shared = BusinessProAwardNotificationDeepLinkBridge()

    private weak var viewModel: MapViewModel?
    private var pendingUserInfo: [AnyHashable: Any]?
    private var lastDeliveredBusinessID: UUID?
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
        print(
            "[BusinessProAwardDeepLink] received payload=" +
            BusinessProAwardNotificationDeepLinkPayload.debugPayloadSummary(userInfo)
        )
#endif
        guard BusinessProAwardNotificationDeepLinkPayload.isBusinessProAwardNotification(userInfo) else {
            return
        }

        let businessID = BusinessProAwardNotificationDeepLinkPayload.businessID(from: userInfo)

        if isDuplicate(businessID: businessID) {
#if DEBUG
            print("[BusinessProAwardDeepLink] ignored duplicate tap")
#endif
            return
        }

        lastDeliveredBusinessID = businessID
        lastDeliveredAt = Date()

        if let viewModel {
            viewModel.enqueueBusinessProAwardNotificationDeepLink(businessID: businessID)
        } else {
#if DEBUG
            print("[BusinessProAwardDeepLink] queued; viewModel=nil")
#endif
            pendingUserInfo = userInfo
        }
    }

    private func isDuplicate(businessID: UUID?) -> Bool {
        guard let lastDeliveredAt else { return false }
        if Date().timeIntervalSince(lastDeliveredAt) >= 2.0 {
            return false
        }
        return lastDeliveredBusinessID == businessID
    }
}
