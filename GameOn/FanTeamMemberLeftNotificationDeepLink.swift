import Foundation
import UserNotifications

extension Notification.Name {
    /// Posted when a member_left_team push arrives while FanGeo is foregrounded.
    static let fanTeamMemberLeftPushArrivedInForeground =
        Notification.Name("FanGeo.fanTeamMemberLeftPushArrivedInForeground")
}

/// Payload keys for remote Fan Team member-left APNs (`notify-fan-team-member-left`).
enum FanTeamMemberLeftNotificationDeepLinkPayload {
    static let sourceKey = "source"
    static let typeKey = "type"
    static let sourceValue = "member_left_team"
    static let teamIDKey = "team_id"
    static let eventIDKey = "event_id"
    static let leftUserIDKey = "left_user_id"
    static let teamNameKey = "team_name"
    static let destinationKey = "destination"
    static let rosterDestination = "team_roster"

    static func isMemberLeftNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        let source = (userInfo[sourceKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let type = (userInfo[typeKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return source == sourceValue || type == sourceValue
    }

    static func teamID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard isMemberLeftNotification(userInfo) else { return nil }
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

    static func leftUserID(from userInfo: [AnyHashable: Any]) -> UUID? {
        let raw = (userInfo[leftUserIDKey] as? String)?
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

struct FanTeamMemberLeftNotificationDeepLinkRequest: Equatable {
    let id: UUID
    let teamID: UUID?
    let eventID: UUID?
    let leftUserID: UUID?
    let teamName: String?
}

/// Delivers member_left_team taps to ``ChatViewModel`` → My Teams → Team Detail Roster.
@MainActor
final class FanTeamMemberLeftNotificationDeepLinkBridge {
    static let shared = FanTeamMemberLeftNotificationDeepLinkBridge()

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
        // Leadership admin alert: still show system banner when backgrounded/terminated.
        // Foreground: suppress duplicate system banner; refresh via notification.
        FanTeamMemberLeftNotificationDeepLinkPayload.isMemberLeftNotification(userInfo)
    }

    func noteForegroundArrival(userInfo: [AnyHashable: Any]) {
        guard FanTeamMemberLeftNotificationDeepLinkPayload.isMemberLeftNotification(userInfo) else {
            return
        }
        var info: [AnyHashable: Any] = [:]
        if let teamID = FanTeamMemberLeftNotificationDeepLinkPayload.teamID(from: userInfo) {
            info[FanTeamMemberLeftNotificationDeepLinkPayload.teamIDKey] = teamID.uuidString
        }
        NotificationCenter.default.post(
            name: .fanTeamMemberLeftPushArrivedInForeground,
            object: nil,
            userInfo: info.isEmpty ? nil : info
        )
    }

    func handleNotificationResponse(_ response: UNNotificationResponse) {
        deliver(userInfo: response.notification.request.content.userInfo)
    }

    private func deliver(userInfo: [AnyHashable: Any]) {
        guard FanTeamMemberLeftNotificationDeepLinkPayload.isMemberLeftNotification(userInfo) else {
            return
        }
#if DEBUG
        print(
            "[FanTeamMemberLeaveDebug] deep_link \(FanTeamMemberLeftNotificationDeepLinkPayload.debugPayloadSummary(userInfo))"
        )
#endif
        let eventID = FanTeamMemberLeftNotificationDeepLinkPayload.eventID(from: userInfo)
        if let eventID, lastDeliveredEventID == eventID,
           let lastDeliveredAt,
           Date().timeIntervalSince(lastDeliveredAt) < 2 {
            return
        }
        lastDeliveredEventID = eventID
        lastDeliveredAt = Date()

        let request = FanTeamMemberLeftNotificationDeepLinkRequest(
            id: UUID(),
            teamID: FanTeamMemberLeftNotificationDeepLinkPayload.teamID(from: userInfo),
            eventID: eventID,
            leftUserID: FanTeamMemberLeftNotificationDeepLinkPayload.leftUserID(from: userInfo),
            teamName: FanTeamMemberLeftNotificationDeepLinkPayload.teamName(from: userInfo)
        )

        guard let chatViewModel else {
            pendingUserInfo = userInfo
            return
        }
        chatViewModel.enqueueFanTeamMemberLeftNotificationDeepLink(request)
    }
}
