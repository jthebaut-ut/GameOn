import Foundation

extension MapViewModel {
    func enqueueFanGeoPlusAwardNotificationDeepLink() {
#if DEBUG
        print("[FanGeoPlusAwardDeepLink] enqueue → Account tab")
#endif
        // Open Account (Settings / FanGeo+ status). Safe if Settings is already visible.
        requestedMainTabRaw = "account"
        Task {
            await refreshCurrentUserAdFreeEntitlementFromServer(reason: "fanGeoPlusAwardPush")
        }
    }
}
