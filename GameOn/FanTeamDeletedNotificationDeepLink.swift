import Foundation
import UserNotifications

extension Notification.Name {
    /// Posted when a Team-deleted push arrives while FanGeo is foregrounded (banner suppressed).
    /// My Teams refreshes and dismisses an open detail sheet for that Team.
    static let fanTeamDeletedPushArrivedInForeground =
        Notification.Name("FanGeo.fanTeamDeletedPushArrivedInForeground")
}

/// Payload keys for remote Fan Team deletion APNs deep links (`notify-fan-team-deleted`).
enum FanTeamDeletedNotificationDeepLinkPayload {
    static let sourceKey = "source"
    static let typeKey = "type"
    static let sourceValue = "team_deleted"
    static let teamIDKey = "team_id"
    static let eventIDKey = "event_id"
    static let teamNameKey = "team_name"

    static func isTeamDeletedNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        let source = (userInfo[sourceKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let type = (userInfo[typeKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return source == sourceValue || type == sourceValue
    }

    static func teamID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard isTeamDeletedNotification(userInfo) else { return nil }
        let raw = (userInfo[teamIDKey] as? String)?
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

    static func teamName(from userInfo: [AnyHashable: Any]) -> String? {
        let raw = (userInfo[teamNameKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    static func debugPayloadSummary(_ userInfo: [AnyHashable: Any]) -> String {
        let source = (userInfo[sourceKey] as? String) ?? "nil"
        let team = (userInfo[teamIDKey] as? String) ?? "nil"
        let event = (userInfo[eventIDKey] as? String) ?? "nil"
        return "source=\(source) team_id=\(team) event_id=\(event)"
    }
}

struct FanTeamDeletedNotificationDeepLinkRequest: Equatable {
    let id: UUID
    let teamID: UUID?
    let eventID: UUID?
    let teamName: String?
}

/// Delivers Team-deleted notification taps to ``ChatViewModel`` (Chat → My Teams).
/// Never opens a dead Team Detail route.
@MainActor
final class FanTeamDeletedNotificationDeepLinkBridge {
    static let shared = FanTeamDeletedNotificationDeepLinkBridge()

    private weak var chatViewModel: ChatViewModel?
    private var pendingUserInfo: [AnyHashable: Any]?
    private var lastDeliveredEventID: UUID?
    private var lastDeliveredAt: Date?

    private init() {}

    func bind(chatViewModel: ChatViewModel) {
        self.chatViewModel = chatViewModel
        if let pendingUserInfo {
            self.pendingUserInfo = nil
            deliver(userInfo: pendingUserInfo)
        }
    }

    func shouldSuppressForegroundSystemPresentation(userInfo: [AnyHashable: Any]) -> Bool {
        FanTeamDeletedNotificationDeepLinkPayload.isTeamDeletedNotification(userInfo)
    }

    func noteForegroundArrival(userInfo: [AnyHashable: Any]) {
        guard FanTeamDeletedNotificationDeepLinkPayload.isTeamDeletedNotification(userInfo) else {
            return
        }
        var info: [AnyHashable: Any] = [:]
        if let teamID = FanTeamDeletedNotificationDeepLinkPayload.teamID(from: userInfo) {
            info[FanTeamDeletedNotificationDeepLinkPayload.teamIDKey] = teamID.uuidString
        }
        if let name = FanTeamDeletedNotificationDeepLinkPayload.teamName(from: userInfo) {
            info[FanTeamDeletedNotificationDeepLinkPayload.teamNameKey] = name
        }
        NotificationCenter.default.post(
            name: .fanTeamDeletedPushArrivedInForeground,
            object: nil,
            userInfo: info.isEmpty ? nil : info
        )
    }

    func handleNotificationResponse(_ response: UNNotificationResponse) {
        deliver(userInfo: response.notification.request.content.userInfo)
    }

    private func deliver(userInfo: [AnyHashable: Any]) {
        guard FanTeamDeletedNotificationDeepLinkPayload.isTeamDeletedNotification(userInfo) else {
            return
        }
#if DEBUG
        print(
            "[FanTeamDeletedPushRoute] deliver \(FanTeamDeletedNotificationDeepLinkPayload.debugPayloadSummary(userInfo))"
        )
#endif
        let eventID = FanTeamDeletedNotificationDeepLinkPayload.eventID(from: userInfo)
        if let eventID, lastDeliveredEventID == eventID,
           let lastDeliveredAt,
           Date().timeIntervalSince(lastDeliveredAt) < 2 {
            return
        }
        lastDeliveredEventID = eventID
        lastDeliveredAt = Date()

        let request = FanTeamDeletedNotificationDeepLinkRequest(
            id: UUID(),
            teamID: FanTeamDeletedNotificationDeepLinkPayload.teamID(from: userInfo),
            eventID: eventID,
            teamName: FanTeamDeletedNotificationDeepLinkPayload.teamName(from: userInfo)
        )

        guard let chatViewModel else {
            pendingUserInfo = userInfo
            return
        }
        chatViewModel.enqueueFanTeamDeletedNotificationDeepLink(request)
    }
}
