import Foundation
import UserNotifications

/// Payload keys for remote FanGeo announcement push notification deep links.
enum FanGeoAnnouncementNotificationDeepLinkPayload {
    static let announcementIDKey = "announcement_id"
    static let sourceKey = "source"
    static let sourceValue = "fangeo_announcement_notification"

    static func isFanGeoAnnouncementNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo[sourceKey] as? String) == sourceValue
    }

    static func announcementID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard isFanGeoAnnouncementNotification(userInfo) else { return nil }
        let raw = (userInfo[announcementIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)
    }

    static func debugPayloadSummary(_ userInfo: [AnyHashable: Any]) -> String {
        let source = (userInfo[sourceKey] as? String) ?? "nil"
        let announcementRaw = (userInfo[announcementIDKey] as? String) ?? "nil"
        return "source=\(source) announcement_id=\(announcementRaw)"
    }
}

struct FanGeoAnnouncementNotificationDeepLinkRequest: Equatable {
    let id: UUID
    let announcementID: UUID
}

/// Delivers FanGeo announcement notification taps to ``MapViewModel`` once the root view model is bound.
@MainActor
final class FanGeoAnnouncementNotificationDeepLinkBridge {
    static let shared = FanGeoAnnouncementNotificationDeepLinkBridge()

    private weak var viewModel: MapViewModel?
    private var pendingUserInfo: [AnyHashable: Any]?
    private var lastDeliveredAnnouncementID: UUID?
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
            "[AnnouncementDeepLink] received payload=" +
            FanGeoAnnouncementNotificationDeepLinkPayload.debugPayloadSummary(userInfo)
        )
#endif
        guard let announcementID = FanGeoAnnouncementNotificationDeepLinkPayload.announcementID(from: userInfo) else {
#if DEBUG
            print("[AnnouncementDeepLink] invalid or missing announcement_id; ignoring")
#endif
            return
        }

#if DEBUG
        print("[AnnouncementDeepLink] valid announcementId=\(announcementID.uuidString.lowercased())")
#endif

        if isDuplicate(announcementID: announcementID) {
#if DEBUG
            print("[AnnouncementDeepLink] ignored duplicate announcementId=\(announcementID.uuidString.lowercased())")
#endif
            return
        }

        lastDeliveredAnnouncementID = announcementID
        lastDeliveredAt = Date()

        if let viewModel {
            viewModel.enqueueFanGeoAnnouncementNotificationDeepLink(announcementID: announcementID)
        } else {
#if DEBUG
            print("[AnnouncementDeepLink] queued announcementId=\(announcementID.uuidString.lowercased()) viewModel=nil")
#endif
            pendingUserInfo = userInfo
        }
    }

    private func isDuplicate(announcementID: UUID) -> Bool {
        guard let lastDeliveredAnnouncementID,
              let lastDeliveredAt,
              lastDeliveredAnnouncementID == announcementID else {
            return false
        }
        return Date().timeIntervalSince(lastDeliveredAt) < 2.0
    }
}
