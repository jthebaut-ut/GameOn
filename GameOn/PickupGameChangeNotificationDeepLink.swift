import Foundation
import UserNotifications

/// APNs / local payload keys for pickup-game edit/cancel push deep links.
enum PickupGameChangeNotificationDeepLinkPayload {
    static let pickupGameIDKey = "pickup_game_id"
    static let updateEventIDKey = "pickup_update_event_id"
    static let sourceKey = "source"
    static let sourceValue = "pickup_game_change_notification"

    static func userInfo(pickupGameId: UUID, updateEventId: UUID? = nil) -> [String: String] {
        var info: [String: String] = [
            pickupGameIDKey: pickupGameId.uuidString.lowercased(),
            sourceKey: sourceValue
        ]
        if let updateEventId {
            info[updateEventIDKey] = updateEventId.uuidString.lowercased()
        }
        return info
    }

    static func isPickupGameChangeNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo[sourceKey] as? String) == sourceValue
    }

    static func pickupGameId(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard isPickupGameChangeNotification(userInfo) else { return nil }
        let raw = (userInfo[pickupGameIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return UUID(uuidString: raw)
    }
}

/// Delivers pickup-edit notification taps to ``MapViewModel`` once bound.
@MainActor
final class PickupGameChangeNotificationDeepLinkBridge {
    static let shared = PickupGameChangeNotificationDeepLinkBridge()

    private weak var viewModel: MapViewModel?
    private var pendingUserInfo: [AnyHashable: Any]?

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
        guard let pickupGameId = PickupGameChangeNotificationDeepLinkPayload.pickupGameId(from: userInfo) else {
            return
        }
        if let viewModel {
            viewModel.presentSharedPickupGameDetail(gameId: pickupGameId)
        } else {
            pendingUserInfo = userInfo
        }
#if DEBUG
        print("[PickupGameChangeNotificationDeepLink] delivered=\(viewModel != nil)")
#endif
    }
}
