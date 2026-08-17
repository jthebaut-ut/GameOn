import Foundation
import UserNotifications

/// Payload keys for remote Fan Team member-change APNs (`notify-fan-team-member-change`).
enum FanTeamMemberChangeNotificationDeepLinkPayload {
    static let sourceKey = "source"
    static let typeKey = "type"
    static let sourceValue = "member_change"
    static let teamIDKey = "team_id"
    static let eventIDKey = "event_id"
    static let kindKey = "kind"
    static let pickupGameIDKey = "pickup_game_id"
    static let destinationKey = "destination"

    static func isMemberChangeNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        let source = (userInfo[sourceKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return source == sourceValue
    }

    static func kind(from userInfo: [AnyHashable: Any]) -> String? {
        let raw = (userInfo[kindKey] as? String ?? userInfo[typeKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw?.isEmpty == false ? raw : nil
    }

    static func teamID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard isMemberChangeNotification(userInfo) else { return nil }
        let raw = (userInfo[teamIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return UUID(uuidString: raw)
    }

    static func pickupGameID(from userInfo: [AnyHashable: Any]) -> UUID? {
        let raw = (userInfo[pickupGameIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return UUID(uuidString: raw)
    }
}

struct FanTeamMemberChangeNotificationDeepLinkRequest: Equatable {
    let id: UUID
    let teamID: UUID?
    let kind: String?
    let pickupGameID: UUID?
}

@MainActor
final class FanTeamMemberChangeNotificationDeepLinkBridge {
    static let shared = FanTeamMemberChangeNotificationDeepLinkBridge()

    private weak var chatViewModel: ChatViewModel?
    private var pendingUserInfo: [AnyHashable: Any]?

    private init() {}

    func bind(chatViewModel: ChatViewModel) {
        self.chatViewModel = chatViewModel
        if let pendingUserInfo {
            self.pendingUserInfo = nil
            deliver(userInfo: pendingUserInfo)
        }
    }

    func shouldSuppressForegroundSystemPresentation(userInfo: [AnyHashable: Any]) -> Bool {
        FanTeamMemberChangeNotificationDeepLinkPayload.isMemberChangeNotification(userInfo)
    }

    func handleNotificationResponse(_ response: UNNotificationResponse) {
        deliver(userInfo: response.notification.request.content.userInfo)
    }

    private func deliver(userInfo: [AnyHashable: Any]) {
        guard FanTeamMemberChangeNotificationDeepLinkPayload.isMemberChangeNotification(userInfo) else {
            return
        }
        let request = FanTeamMemberChangeNotificationDeepLinkRequest(
            id: UUID(),
            teamID: FanTeamMemberChangeNotificationDeepLinkPayload.teamID(from: userInfo),
            kind: FanTeamMemberChangeNotificationDeepLinkPayload.kind(from: userInfo),
            pickupGameID: FanTeamMemberChangeNotificationDeepLinkPayload.pickupGameID(from: userInfo)
        )
        guard let chatViewModel else {
            pendingUserInfo = userInfo
            return
        }
        chatViewModel.enqueueFanTeamMemberChangeNotificationDeepLink(request)
    }
}
