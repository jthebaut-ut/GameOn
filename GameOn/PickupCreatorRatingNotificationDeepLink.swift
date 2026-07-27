import Foundation
import UserNotifications

/// Payload keys for local pickup-creator-rating reminder notification deep links.
enum PickupCreatorRatingNotificationDeepLinkPayload {
    static let pickupGameIDKey = "pickup_game_id"
    static let sourceKey = "source"
    static let sourceValue = "pickup_creator_rating_notification"

    static func userInfo(pickupGameId: UUID) -> [String: String] {
        [
            pickupGameIDKey: pickupGameId.uuidString.lowercased(),
            sourceKey: sourceValue
        ]
    }

    static func isPickupCreatorRatingNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo[sourceKey] as? String) == sourceValue
    }

    static func pickupGameId(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard isPickupCreatorRatingNotification(userInfo) else { return nil }
        let raw = (userInfo[pickupGameIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return UUID(uuidString: raw)
    }

    static func apply(to content: UNMutableNotificationContent, pickupGameId: UUID) {
        var merged = content.userInfo
        for (key, value) in userInfo(pickupGameId: pickupGameId) {
            merged[key] = value
        }
        content.userInfo = merged
    }
}

/// Delivers pickup rating notification taps to ``MapViewModel`` once the root view model is bound.
@MainActor
final class PickupCreatorRatingNotificationDeepLinkBridge {
    static let shared = PickupCreatorRatingNotificationDeepLinkBridge()

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
        guard let pickupGameId = PickupCreatorRatingNotificationDeepLinkPayload.pickupGameId(from: userInfo) else {
            return
        }
        if let viewModel {
            viewModel.enqueuePickupCreatorRatingNotificationDeepLink(pickupGameId: pickupGameId)
        } else {
            pendingUserInfo = userInfo
        }
#if DEBUG
        print("[PickupCreatorRatingNotificationDeepLink] delivered=\(viewModel != nil)")
#endif
    }
}

struct PickupCreatorRatingNotificationDeepLinkRequest: Equatable {
    let id: UUID
    let pickupGameId: UUID
}
