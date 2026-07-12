import Foundation
import Supabase

enum AccountIdentityType: String {
    case fan
    case business
}

private struct AccountIdentityClaimParams: Encodable {
    let p_account_type: String
}

private struct AccountIdentityClaimRow: Decodable {
    let account_type: String
    let email: String
    let account_id: UUID
}

extension MapViewModel {
    @discardableResult
    func claimAccountIdentity(
        _ accountType: AccountIdentityType,
        context: String
    ) async -> Bool {
#if DEBUG
        print("[PendingBusinessSignupTrace] claimAccountIdentity entering context=\(context) type=\(accountType.rawValue)")
#endif
        let session = try? await supabase.auth.session
        let sessionEmail = OwnerBusinessEmail.normalized(session?.user.email ?? "")
        let sessionUserId = session?.user.id
        let sessionConfirmed = session.map { Self.userEmailConfirmed($0.user) } ?? false
        let pendingOverride = await MainActor.run {
            guard accountType == .business,
                  OwnerBusinessEmail.isValidStrict(sessionEmail) else {
                return false
            }
            return shouldBypassFanAccountConflictForPendingBusinessVenueSetup(
                email: sessionEmail,
                userId: sessionUserId,
                sessionEmailConfirmed: sessionConfirmed
            )
        }

        do {
            let rows: [AccountIdentityClaimRow] = try await supabase
                .rpc(
                    "claim_account_type",
                    params: AccountIdentityClaimParams(p_account_type: accountType.rawValue)
                )
                .execute()
                .value
#if DEBUG
            if let row = rows.first {
                print("[AuthAccountTypeGuard] claimed type=\(row.account_type) email=\(row.email) accountId=\(row.account_id.uuidString.lowercased()) context=\(context)")
            } else {
                print("[AuthAccountTypeGuard] claimedEmptyResult type=\(accountType.rawValue) context=\(context)")
            }
            print("[PendingBusinessSignupTrace] claimAccountIdentity RPC success context=\(context) result=true returned=true sessionEmail=\(sessionEmail) authUserId=\(sessionUserId?.uuidString.lowercased() ?? "nil") pendingDraftOverride=\(pendingOverride)")
#endif
            return true
        } catch {
            let message = Self.accountIdentityUserMessage(for: error, attemptedType: accountType)
            let fanConflict = Self.isFanAccountIdentityConflictError(error)
            let allowPendingBusinessClaim = accountType == .business && pendingOverride && fanConflict

#if DEBUG
            print("[AuthAccountTypeGuard] claimFailed type=\(accountType.rawValue) context=\(context) error=\(error.localizedDescription)")
            print("[PendingBusinessSignupTrace] claimAccountIdentity RPC failed context=\(context) fanConflict=\(fanConflict) allowPendingBusinessClaim=\(allowPendingBusinessClaim) pendingDraftOverride=\(pendingOverride) sessionEmail=\(sessionEmail) authUserId=\(sessionUserId?.uuidString.lowercased() ?? "nil") message=\(message)")
            await MainActor.run {
                logBusinessAuthFanConflictGate(
                    context: "claimAccountIdentity",
                    email: sessionEmail,
                    userId: sessionUserId,
                    userProfileExists: fanConflict,
                    blockingReason: allowPendingBusinessClaim ? nil : "claim_account_type_failed",
                    pendingDraftOverride: pendingOverride,
                    message: allowPendingBusinessClaim ? nil : message,
                    willSignOut: !allowPendingBusinessClaim,
                    sessionEmailConfirmed: sessionConfirmed
                )
            }
#endif
            if allowPendingBusinessClaim {
#if DEBUG
                print("[PendingBusinessSignupTrace] claimAccountIdentity returned=true context=\(context) reason=pending_business_fan_conflict_bypass")
#endif
                return true
            }

            await undoPartialSupabaseSessionAfterAccountTypeMismatch()
            await MainActor.run {
                switch accountType {
                case .fan:
                    authErrorMessage = message
                case .business:
                    venueAuthErrorMessage = message
                }
            }
#if DEBUG
            print("[PendingBusinessSignupTrace] claimAccountIdentity returned=false context=\(context) reason=claim_failed")
#endif
            return false
        }
    }

    static func accountIdentityUserMessage(
        for error: Error,
        attemptedType: AccountIdentityType
    ) -> String {
        let text = Self.accountIdentityErrorText(error)

        if text.contains("please verify your email") {
            return "Please verify your email before continuing."
        }
        if text.contains("email already used for a fan account")
            || text.contains("already claimed as a fan account") {
            return attemptedType == .business
                ? "Email already used for a Fan account. Please use a different email for Business access."
                : "Email already used for a Fan account."
        }
        if text.contains("email already used for a business account")
            || text.contains("already claimed as a business account") {
            return attemptedType == .fan
                ? "Email already used for a Business account. Please sign in with that account type or use a different email for Fan access."
                : "Email already used for a Business account."
        }

        switch attemptedType {
        case .fan:
            return "Could not verify this email for Fan access. Please try again."
        case .business:
            return "Could not verify this email for Business access. Please try again."
        }
    }

    static func isFanAccountIdentityConflictError(_ error: Error) -> Bool {
        let text = accountIdentityErrorText(error)
        return text.contains("email already used for a fan account")
            || text.contains("already claimed as a fan account")
    }

    private static func accountIdentityErrorText(_ error: Error) -> String {
        let ns = error as NSError
        var parts = [
            error.localizedDescription,
            ns.domain,
            "\(ns.code)"
        ]
        if let postgrest = error as? PostgrestError {
            parts.append(postgrest.code ?? "")
            parts.append(postgrest.message)
            parts.append(postgrest.detail ?? "")
            parts.append(postgrest.hint ?? "")
        }
        return parts.joined(separator: " ").lowercased()
    }
}
