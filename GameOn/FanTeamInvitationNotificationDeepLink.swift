import Foundation
import UserNotifications

extension Notification.Name {
    /// Posted when a Team invitation push arrives while FanGeo is foregrounded (banner suppressed).
    /// My Teams listens and refreshes the Invitations list without navigating.
    static let fanTeamInvitationPushArrivedInForeground =
        Notification.Name("FanGeo.fanTeamInvitationPushArrivedInForeground")
}

/// Payload keys for remote Fan Team invitation APNs deep links (`notify-fan-team-invitation`).
enum FanTeamInvitationNotificationDeepLinkPayload {
    static let sourceKey = "source"
    static let typeKey = "type"
    static let sourceValue = "team_invitation"
    static let invitationIDKey = "invitation_id"
    static let teamIDKey = "team_id"
    static let invitedByUserIDKey = "invited_by_user_id"
    static let eventIDKey = "event_id"

    static func isTeamInvitationNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        let source = (userInfo[sourceKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let type = (userInfo[typeKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return source == sourceValue || type == sourceValue
    }

    static func invitationID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard isTeamInvitationNotification(userInfo) else { return nil }
        let raw = (userInfo[invitationIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)
    }

    static func teamID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard isTeamInvitationNotification(userInfo) else { return nil }
        let raw = (userInfo[teamIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)
    }

    static func invitedByUserID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard isTeamInvitationNotification(userInfo) else { return nil }
        let raw = (userInfo[invitedByUserIDKey] as? String)?
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

    static func debugPayloadSummary(_ userInfo: [AnyHashable: Any]) -> String {
        let source = (userInfo[sourceKey] as? String) ?? "nil"
        let invitation = (userInfo[invitationIDKey] as? String) ?? "nil"
        let team = (userInfo[teamIDKey] as? String) ?? "nil"
        let invitedBy = (userInfo[invitedByUserIDKey] as? String) ?? "nil"
        return "source=\(source) invitation_id=\(invitation) team_id=\(team) invited_by=\(invitedBy)"
    }
}

struct FanTeamInvitationNotificationDeepLinkRequest: Equatable {
    let id: UUID
    let invitationID: UUID?
    let teamID: UUID?
    let invitedByUserID: UUID?
    let eventID: UUID?
}

/// Delivers Fan Team invitation notification taps to ``ChatViewModel`` (Chat → My Teams).
@MainActor
final class FanTeamInvitationNotificationDeepLinkBridge {
    static let shared = FanTeamInvitationNotificationDeepLinkBridge()

    private weak var chatViewModel: ChatViewModel?
    private var pendingUserInfo: [AnyHashable: Any]?
    private var lastDeliveredEventID: UUID?
    private var lastDeliveredInvitationID: UUID?
    private var lastDeliveredAt: Date?

    private init() {}

    func bind(chatViewModel: ChatViewModel) {
        self.chatViewModel = chatViewModel
        if let pendingUserInfo {
            self.pendingUserInfo = nil
            deliver(userInfo: pendingUserInfo)
        }
    }

    /// Foreground: suppress system banners so My Teams invitations remain the single in-app path.
    func shouldSuppressForegroundSystemPresentation(userInfo: [AnyHashable: Any]) -> Bool {
        FanTeamInvitationNotificationDeepLinkPayload.isTeamInvitationNotification(userInfo)
    }

    /// Called from `willPresent` after suppress — refresh invitations without opening a route.
    func noteForegroundArrival(userInfo: [AnyHashable: Any]) {
        guard FanTeamInvitationNotificationDeepLinkPayload.isTeamInvitationNotification(userInfo) else {
            return
        }
        var info: [AnyHashable: Any] = [:]
        if let invitationID = FanTeamInvitationNotificationDeepLinkPayload.invitationID(from: userInfo) {
            info[FanTeamInvitationNotificationDeepLinkPayload.invitationIDKey] = invitationID.uuidString
        }
        if let teamID = FanTeamInvitationNotificationDeepLinkPayload.teamID(from: userInfo) {
            info[FanTeamInvitationNotificationDeepLinkPayload.teamIDKey] = teamID.uuidString
        }
        NotificationCenter.default.post(
            name: .fanTeamInvitationPushArrivedInForeground,
            object: nil,
            userInfo: info.isEmpty ? nil : info
        )
    }

    func handleNotificationResponse(_ response: UNNotificationResponse) {
        deliver(userInfo: response.notification.request.content.userInfo)
    }

    func deliver(userInfo: [AnyHashable: Any]) {
#if DEBUG
        print("[FanTeamInvitationPushRoute] received payload=\(FanTeamInvitationNotificationDeepLinkPayload.debugPayloadSummary(userInfo))")
#endif
        guard FanTeamInvitationNotificationDeepLinkPayload.isTeamInvitationNotification(userInfo) else {
            return
        }

        let invitationID = FanTeamInvitationNotificationDeepLinkPayload.invitationID(from: userInfo)
        let teamID = FanTeamInvitationNotificationDeepLinkPayload.teamID(from: userInfo)
        let invitedByUserID = FanTeamInvitationNotificationDeepLinkPayload.invitedByUserID(from: userInfo)
        let eventID = FanTeamInvitationNotificationDeepLinkPayload.eventID(from: userInfo)

        if isDuplicate(eventID: eventID, invitationID: invitationID) {
#if DEBUG
            print("[FanTeamInvitationPushRoute] duplicate presentation prevented")
#endif
            return
        }

        lastDeliveredEventID = eventID
        lastDeliveredInvitationID = invitationID
        lastDeliveredAt = Date()

        let request = FanTeamInvitationNotificationDeepLinkRequest(
            id: UUID(),
            invitationID: invitationID,
            teamID: teamID,
            invitedByUserID: invitedByUserID,
            eventID: eventID
        )

        if let chatViewModel {
            chatViewModel.enqueueFanTeamInvitationNotificationDeepLink(request)
        } else {
#if DEBUG
            print("[FanTeamInvitationPushRoute] chatViewModel=nil; queuing payload")
#endif
            pendingUserInfo = userInfo
        }
    }

    private func isDuplicate(eventID: UUID?, invitationID: UUID?) -> Bool {
        guard let lastDeliveredAt else { return false }
        guard Date().timeIntervalSince(lastDeliveredAt) < 2.0 else { return false }
        if let eventID, let lastDeliveredEventID, eventID == lastDeliveredEventID {
            return true
        }
        if let invitationID, let lastDeliveredInvitationID, invitationID == lastDeliveredInvitationID {
            return true
        }
        return false
    }
}
