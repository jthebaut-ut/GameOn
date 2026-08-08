import Foundation

extension MapViewModel {
    /// Remote APNs poke tap: open the poker’s Fan Profile after auth + splash/bootstrap.
    func enqueuePokeNotificationDeepLink(_ request: PokeNotificationDeepLinkRequest) {
#if DEBUG
        print(
            "[PokePushRoute] enqueue pokeId=\(request.pokeID?.uuidString.lowercased() ?? "nil") " +
            "senderId=\(request.senderID.uuidString.lowercased())"
        )
#endif
        pendingPokeNotificationDeepLink = request
        deliverPendingPokeNotificationDeepLinkIfReady(reason: "enqueue")
    }

    /// Called once the app shell is interactive (splash dismissed / bootstrap complete).
    func allowPokeNotificationDeepLinkDelivery(reason: String) {
        pokeNotificationDeepLinkDeliveryAllowed = true
        deliverPendingPokeNotificationDeepLinkIfReady(reason: reason)
    }

    func deliverPendingPokeNotificationDeepLinkIfReady(reason: String) {
        guard let request = pendingPokeNotificationDeepLink else { return }
        guard let me = currentUserAuthId else {
#if DEBUG
            print("[PokePushRoute] defer until auth reason=\(reason)")
#endif
            return
        }
        guard pokeNotificationDeepLinkDeliveryAllowed else {
#if DEBUG
            print("[PokePushRoute] defer until shell ready reason=\(reason)")
#endif
            return
        }

        // Never open the sender’s own poke push on their device.
        if request.senderID == me {
#if DEBUG
            print("[PokePushRoute] ignore: current user is poker")
#endif
            pendingPokeNotificationDeepLink = nil
            return
        }

        // Defense in depth: payload recipient must match signed-in user when present.
        if let recipientID = request.recipientID, recipientID != me {
#if DEBUG
            print("[PokePushRoute] ignore: recipient mismatch")
#endif
            pendingPokeNotificationDeepLink = nil
            return
        }

#if DEBUG
        print("[PokePushRoute] open sender profile reason=\(reason)")
#endif
        pendingPokeNotificationDeepLink = nil
        // Existing public-profile presenter handles missing/deleted profiles gracefully.
        presentPublicProfile(
            userId: request.senderID,
            context: "poke_push",
            activeSheet: "PokePush"
        )
        refreshUnseenPokesBadgeForPushNotification()
    }

    func clearPendingPokeNotificationDeepLink() {
        pendingPokeNotificationDeepLink = nil
    }
}
