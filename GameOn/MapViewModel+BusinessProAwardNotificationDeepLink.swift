import Foundation

extension MapViewModel {
    func enqueueBusinessProAwardNotificationDeepLink(businessID: UUID?) {
#if DEBUG
        print("[BusinessProAwardDeepLink] enqueue → Account tab businessId=\(businessID?.uuidString.lowercased() ?? "nil")")
#endif
        // Open Account (Business Profile / Plan & Access). Safe if already visible.
        requestedMainTabRaw = "account"
        Task {
            await refreshBusinessProEntitlementAfterAwardPush(businessID: businessID)
        }
    }

    private func refreshBusinessProEntitlementAfterAwardPush(businessID: UUID?) async {
        let resolvedBusinessID = businessID ?? currentBusinessIdForAddLocation()
        guard let resolvedBusinessID else {
#if DEBUG
            print("[BusinessProAwardDeepLink] entitlement refresh skipped: missing business id")
#endif
            return
        }

        // Refresh canonical Business Pro entitlements (v2 → v1 fallback).
        _ = await loadBusinessEntitlements(businessId: resolvedBusinessID)
        // Also refresh FanGeo+ / paid-Pro derived flags used by Account UI.
        await refreshCurrentBusinessFanGeoPlusEntitlementFromServer(reason: "businessProAwardPush")

        // Warm posting/venue gate status so Account reflects the new plan without a second tap.
        _ = await businessVenueGamePostingStatus(
            storeKitBusinessProActive: false,
            businessId: resolvedBusinessID
        )
    }
}
