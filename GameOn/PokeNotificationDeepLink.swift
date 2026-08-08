import Foundation
import UserNotifications

/// Payload keys for remote poke APNs deep links (`notify-poke`).
enum PokeNotificationDeepLinkPayload {
    static let sourceKey = "source"
    static let typeKey = "type"
    static let sourceValue = "poke"
    static let pokeIDKey = "poke_id"
    static let eventIDKey = "event_id"
    static let senderIDKey = "sender_id"
    static let pokerIDKey = "poker_id"
    static let recipientIDKey = "recipient_id"

    static func isPokeNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        let source = (userInfo[sourceKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let type = (userInfo[typeKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return source == sourceValue || type == sourceValue
    }

    static func pokeID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard isPokeNotification(userInfo) else { return nil }
        let raw = (userInfo[pokeIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (userInfo[eventIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        guard !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)
    }

    static func senderID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard isPokeNotification(userInfo) else { return nil }
        let raw = (userInfo[senderIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (userInfo[pokerIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        guard !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)
    }

    static func recipientID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard isPokeNotification(userInfo) else { return nil }
        let raw = (userInfo[recipientIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)
    }

    static func debugPayloadSummary(_ userInfo: [AnyHashable: Any]) -> String {
        let source = (userInfo[sourceKey] as? String) ?? "nil"
        let poke = (userInfo[pokeIDKey] as? String)
            ?? (userInfo[eventIDKey] as? String)
            ?? "nil"
        let sender = (userInfo[senderIDKey] as? String)
            ?? (userInfo[pokerIDKey] as? String)
            ?? "nil"
        return "source=\(source) poke_id=\(poke) sender_id=\(sender)"
    }
}

struct PokeNotificationDeepLinkRequest: Equatable {
    let id: UUID
    let pokeID: UUID?
    let senderID: UUID
    let recipientID: UUID?
}

/// Delivers poke notification taps to ``MapViewModel`` → sender Fan Profile.
@MainActor
final class PokeNotificationDeepLinkBridge {
    static let shared = PokeNotificationDeepLinkBridge()

    private weak var viewModel: MapViewModel?
    private var pendingUserInfo: [AnyHashable: Any]?
    private var lastDeliveredPokeID: UUID?
    private var lastDeliveredSenderID: UUID?
    private var lastDeliveredAt: Date?

    private init() {}

    func bind(viewModel: MapViewModel) {
        self.viewModel = viewModel
        if let pendingUserInfo {
            self.pendingUserInfo = nil
            deliver(userInfo: pendingUserInfo)
        }
    }

    /// Foreground: suppress system banners so the in-app poke badge remains the single path.
    func shouldSuppressForegroundSystemPresentation(userInfo: [AnyHashable: Any]) -> Bool {
        guard PokeNotificationDeepLinkPayload.isPokeNotification(userInfo) else { return false }
        viewModel?.refreshUnseenPokesBadgeForPushNotification()
        return true
    }

    func handleNotificationResponse(_ response: UNNotificationResponse) {
        deliver(userInfo: response.notification.request.content.userInfo)
    }

    func deliver(userInfo: [AnyHashable: Any]) {
#if DEBUG
        print("[PokePushRoute] received payload=\(PokeNotificationDeepLinkPayload.debugPayloadSummary(userInfo))")
#endif
        guard PokeNotificationDeepLinkPayload.isPokeNotification(userInfo) else {
            return
        }

        guard let senderID = PokeNotificationDeepLinkPayload.senderID(from: userInfo) else {
#if DEBUG
            print("[PokePushRoute] missing sender_id; ignoring")
#endif
            return
        }

        let pokeID = PokeNotificationDeepLinkPayload.pokeID(from: userInfo)
        let recipientID = PokeNotificationDeepLinkPayload.recipientID(from: userInfo)

        if isDuplicate(pokeID: pokeID, senderID: senderID) {
#if DEBUG
            print("[PokePushRoute] duplicate presentation prevented")
#endif
            return
        }

        lastDeliveredPokeID = pokeID
        lastDeliveredSenderID = senderID
        lastDeliveredAt = Date()

        let request = PokeNotificationDeepLinkRequest(
            id: UUID(),
            pokeID: pokeID,
            senderID: senderID,
            recipientID: recipientID
        )

        if let viewModel {
            viewModel.enqueuePokeNotificationDeepLink(request)
        } else {
#if DEBUG
            print("[PokePushRoute] viewModel=nil; queuing payload")
#endif
            pendingUserInfo = userInfo
        }
    }

    private func isDuplicate(pokeID: UUID?, senderID: UUID) -> Bool {
        guard let lastDeliveredAt else { return false }
        guard Date().timeIntervalSince(lastDeliveredAt) < 2.0 else { return false }
        if let pokeID, let lastDeliveredPokeID, pokeID == lastDeliveredPokeID {
            return true
        }
        if let lastDeliveredSenderID, senderID == lastDeliveredSenderID, pokeID == nil {
            return true
        }
        return false
    }
}
