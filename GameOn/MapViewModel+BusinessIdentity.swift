import Foundation
import Supabase

extension MapViewModel {
    /// Authenticated business @handle availability for an existing business row.
    func checkBusinessHandleAvailableForOwner(_ rawHandle: String, excludeBusinessId: UUID) async -> Bool? {
        let stored = FanGeoHandleRules.normalizeForStorage(rawHandle)
        guard FanGeoHandleRules.validate(rawHandle) == nil else { return false }
        guard BusinessIdentityValidation.validateBusinessHandle(rawHandle) == nil else { return false }

        struct RpcParams: Encodable {
            let p_handle: String
            let p_exclude_business_id: UUID
        }

        do {
            let available: Bool = try await supabase
                .rpc(
                    "check_business_handle_available",
                    params: RpcParams(p_handle: stored, p_exclude_business_id: excludeBusinessId)
                )
                .execute()
                .value
            return available
        } catch {
            print("[BusinessIdentity] handleCheckFailed handle=\(stored) error=\(error.localizedDescription)")
            return nil
        }
    }

    /// Updates business display name and @handle on the owned `public.businesses` row.
    /// Returns a user-facing error message, or `nil` on success.
    func updateBusinessIdentity(
        businessId: UUID,
        displayName: String,
        businessHandle: String,
        previousHandle: String?
    ) async -> String? {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedHandle = FanGeoHandleRules.normalizeForStorage(businessHandle)

        if let nameError = BusinessIdentityValidation.validateBusinessName(trimmedName) {
            return nameError
        }
        guard !storedHandle.isEmpty else {
            return "Business @handle is required."
        }
        if let handleError = BusinessIdentityValidation.validateBusinessHandle(storedHandle) {
            return handleError
        }

        let previousNormalized = previousHandle
            .map { FanGeoHandleRules.normalizeForStorage($0) } ?? ""
        if storedHandle != previousNormalized {
            guard let available = await checkBusinessHandleAvailableForOwner(storedHandle, excludeBusinessId: businessId) else {
                return "Unable to verify handle availability. Try again."
            }
            guard available else {
                return "This business handle is already taken."
            }
        }

        let payload = BusinessIdentityUpdatePayload(
            display_name: trimmedName,
            business_handle: storedHandle
        )

        do {
            try await supabase
                .from("businesses")
                .update(payload)
                .eq("id", value: businessId)
                .execute()
            await refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
            return nil
        } catch {
            print("[BusinessIdentity] updateFailed businessId=\(businessId.uuidString) error=\(error.localizedDescription)")
            return "Could not save business identity. Please try again."
        }
    }
}
