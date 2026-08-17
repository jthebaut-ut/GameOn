import Foundation
import UserNotifications

/// APNs / local payload keys for pickup-game edit/cancel/create push deep links.
enum PickupGameChangeNotificationDeepLinkPayload {
    static let pickupGameIDKey = "pickup_game_id"
    static let updateEventIDKey = "pickup_update_event_id"
    static let teamIDKey = "team_id"
    static let sourceKey = "source"
    static let sourceValue = "pickup_game_change_notification"
    static let notificationTypeKey = "notification_type"
    static let changeClassKey = "change_class"
    static let rsvpResetRequiredKey = "rsvp_reset_required"

    static func userInfo(
        pickupGameId: UUID,
        updateEventId: UUID? = nil,
        teamId: UUID? = nil,
        notificationType: String? = nil,
        rsvpResetRequired: Bool = false
    ) -> [String: String] {
        var info: [String: String] = [
            pickupGameIDKey: pickupGameId.uuidString.lowercased(),
            sourceKey: sourceValue
        ]
        if let updateEventId {
            info[updateEventIDKey] = updateEventId.uuidString.lowercased()
        }
        if let teamId {
            info[teamIDKey] = teamId.uuidString.lowercased()
        }
        if let notificationType, !notificationType.isEmpty {
            info[notificationTypeKey] = notificationType
        }
        if rsvpResetRequired {
            info[rsvpResetRequiredKey] = "true"
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

    static func teamId(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard isPickupGameChangeNotification(userInfo) else { return nil }
        let raw = (userInfo[teamIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return UUID(uuidString: raw)
    }

    static func rsvpResetRequired(from userInfo: [AnyHashable: Any]) -> Bool {
        guard isPickupGameChangeNotification(userInfo) else { return false }
        let raw = (userInfo[rsvpResetRequiredKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if raw == "true" || raw == "1" { return true }
        if let flag = userInfo[rsvpResetRequiredKey] as? Bool { return flag }
        return false
    }
}

/// Team Schedule event deep link (Schedule tab + event detail; no organizer requests).
struct PendingTeamScheduleEventDeepLink: Equatable, Hashable {
    let teamId: UUID
    let pickupGameId: UUID
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
        let teamId = PickupGameChangeNotificationDeepLinkPayload.teamId(from: userInfo)
        let rsvpReset = PickupGameChangeNotificationDeepLinkPayload.rsvpResetRequired(from: userInfo)
#if DEBUG
        print(
            "[TeamScheduleNotification] deepLinkReceived pickup_game_id=\(pickupGameId.uuidString.lowercased()) " +
            "team_id=\(teamId?.uuidString.lowercased() ?? "nil") rsvp_reset=\(rsvpReset)"
        )
        let notificationType = (userInfo[PickupGameChangeNotificationDeepLinkPayload.notificationTypeKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if notificationType == "team_event_scored" || notificationType == "team_event_final" {
            print(
                "[TeamScoreNotification] deepLinkReceived teamID=\(teamId?.uuidString.lowercased() ?? "nil") " +
                "eventID=\(pickupGameId.uuidString.lowercased()) type=\(notificationType)"
            )
        }
        if notificationType == "team_game_created" {
            print(
                "[TeamGameNotification] deepLinkReceived teamID=\(teamId?.uuidString.lowercased() ?? "nil") " +
                "eventID=\(pickupGameId.uuidString.lowercased())"
            )
        }
        if notificationType == "team_announcement" {
            print(
                "[TeamAnnouncement] deepLinkReceived teamID=\(teamId?.uuidString.lowercased() ?? "nil") " +
                "announcementID=\(pickupGameId.uuidString.lowercased())"
            )
        }
#endif
        if let viewModel {
            viewModel.handlePickupGameChangeNotificationDeepLink(
                pickupGameId: pickupGameId,
                teamId: teamId,
                rsvpResetRequired: rsvpReset
            )
#if DEBUG
            print(
                "[TeamScheduleNotification] deepLinkResolved route=\(teamId == nil ? "sharedPickupDetail" : "teamScheduleEvent")"
            )
            if let teamId {
                print(
                    "[TeamGameNotification] deepLinkResolved teamID=\(teamId.uuidString.lowercased()) " +
                    "eventID=\(pickupGameId.uuidString.lowercased())"
                )
                print(
                    "[TeamAnnouncement] deepLinkResolved teamID=\(teamId.uuidString.lowercased()) " +
                    "announcementID=\(pickupGameId.uuidString.lowercased())"
                )
            }
#endif
        } else {
            pendingUserInfo = userInfo
#if DEBUG
            print("[TeamScheduleNotification] deepLinkQueued viewModel=nil")
#endif
        }
    }
}
