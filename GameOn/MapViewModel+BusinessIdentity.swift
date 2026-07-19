import Foundation
import Supabase

extension MapViewModel {
    /// Fresh display name / @handle for the Business Identity editor.
    func fetchBusinessIdentityFields(businessId: UUID) async -> (displayName: String, handle: String?)? {
        do {
            let row: BusinessRow = try await supabase
                .from("businesses")
                .select(BusinessRow.supabaseSelectColumns)
                .eq("id", value: businessId)
                .single()
                .execute()
                .value
            return (row.display_name, row.business_handle)
        } catch {
#if DEBUG
            print("[BusinessIdentity] fetchFailed businessId=\(businessId.uuidString) error=\(error.localizedDescription)")
#endif
            return nil
        }
    }

    /// Authenticated business @handle availability for an existing business row.
    func checkBusinessHandleAvailableForOwner(_ rawHandle: String, excludeBusinessId: UUID) async -> Bool? {
        let stored = FanGeoHandleRules.normalizeForStorage(rawHandle)
        // Format only — reserved-token policy is enforced by `validateBusinessHandleForEdit` / signup validators.
        guard FanGeoHandleRules.validateFormat(rawHandle) == nil else { return false }

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
        previousDisplayName: String,
        previousHandle: String?
    ) async -> String? {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedHandle = FanGeoHandleRules.normalizeForStorage(businessHandle)
        let previousNormalizedHandle = previousHandle
            .map { FanGeoHandleRules.normalizeForStorage($0) } ?? ""

        if let nameError = BusinessIdentityValidation.validateBusinessNameForEdit(
            trimmedName,
            original: previousDisplayName
        ) {
            return nameError
        }
        if let handleError = BusinessIdentityValidation.validateBusinessHandleForEdit(
            storedHandle,
            original: previousNormalizedHandle
        ) {
            return handleError
        }

        if storedHandle != previousNormalizedHandle {
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
