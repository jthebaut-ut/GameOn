import Foundation
import UserNotifications

/// Payload keys for remote admin FanGeo+ award push notification deep links.
enum FanGeoPlusAwardNotificationDeepLinkPayload {
    static let sourceKey = "source"
    static let sourceValue = "admin_fangeo_plus_award"
    static let userIDKey = "user_id"
    static let expiresAtKey = "expires_at"
    static let entitlementSourceKey = "entitlement_source"
    static let changeKindKey = "change_kind"
    static let awardEventIDKey = "award_event_id"

    static func isFanGeoPlusAwardNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo[sourceKey] as? String) == sourceValue
    }

    static func debugPayloadSummary(_ userInfo: [AnyHashable: Any]) -> String {
        let source = (userInfo[sourceKey] as? String) ?? "nil"
        let userID = (userInfo[userIDKey] as? String) ?? "nil"
        let expiresAt = (userInfo[expiresAtKey] as? String) ?? "nil"
        let entitlementSource = (userInfo[entitlementSourceKey] as? String) ?? "nil"
        return "source=\(source) user_id=\(userID) expires_at=\(expiresAt) entitlement_source=\(entitlementSource)"
    }
}

struct FanGeoPlusAwardNotificationDeepLinkRequest: Equatable {
    let id: UUID
}

/// Delivers FanGeo+ award notification taps to ``MapViewModel`` once the root view model is bound.
@MainActor
final class FanGeoPlusAwardNotificationDeepLinkBridge {
    static let shared = FanGeoPlusAwardNotificationDeepLinkBridge()

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
        print(
            "[FanGeoPlusAwardDeepLink] received payload=" +
            FanGeoPlusAwardNotificationDeepLinkPayload.debugPayloadSummary(userInfo)
        )
#endif
        guard FanGeoPlusAwardNotificationDeepLinkPayload.isFanGeoPlusAwardNotification(userInfo) else {
            return
        }

        if isDuplicate() {
#if DEBUG
            print("[FanGeoPlusAwardDeepLink] ignored duplicate tap")
#endif
            return
        }

        lastDeliveredAt = Date()

        if let viewModel {
            viewModel.enqueueFanGeoPlusAwardNotificationDeepLink()
        } else {
#if DEBUG
            print("[FanGeoPlusAwardDeepLink] queued; viewModel=nil")
#endif
            pendingUserInfo = userInfo
        }
    }

    private func isDuplicate() -> Bool {
        guard let lastDeliveredAt else { return false }
        return Date().timeIntervalSince(lastDeliveredAt) < 2.0
    }
}
