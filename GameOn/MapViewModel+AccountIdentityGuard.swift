import Foundation
import Supabase

enum AccountIdentityType: String {
    case fan
    case business
}

/// What to do when `claim_account_type` fails without the server proving an account-type conflict.
enum AccountIdentityInconclusiveFailurePolicy: String {
    /// Sign-up / sign-in flows: an unverifiable claim must undo the partial Supabase session.
    case signOut
    /// Session restore: the session predates this call, so a transient failure must leave it alone.
    case preserveSession
}

/// How a `claim_account_type` failure was interpreted. Only `confirmedConflict` may force a logout.
private enum AccountIdentityClaimFailure: String {
    case cancelled
    case confirmedConflict
    case inconclusive
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
        context: String,
        inconclusiveFailurePolicy: AccountIdentityInconclusiveFailurePolicy = .signOut
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
            // A cancelled RPC proves nothing about the account type, so it can never be treated
            // as a conflict and must leave any already-restored session exactly as it was.
            if Self.isAccountIdentityCancellation(error) {
#if DEBUG
                print(
                    "[AuthRestore] classification=\(AccountIdentityClaimFailure.cancelled.rawValue) "
                    + "context=\(context) type=\(accountType.rawValue) "
                    + "cancellationIgnoredForMismatch=true willSignOut=false"
                )
#endif
                return false
            }

            let message = Self.accountIdentityUserMessage(for: error, attemptedType: accountType)
            let fanConflict = Self.isFanAccountIdentityConflictError(error)
            let allowPendingBusinessClaim = accountType == .business && pendingOverride && fanConflict
            let confirmedConflict = Self.isConfirmedAccountTypeConflictError(error)
            let classification: AccountIdentityClaimFailure = confirmedConflict ? .confirmedConflict : .inconclusive
            let willSignOut = !allowPendingBusinessClaim
                && Self.accountIdentityFailureForcesSignOut(
                    error: error,
                    policy: inconclusiveFailurePolicy
                )

#if DEBUG
            print(
                "[AuthRestore] classification=\(classification.rawValue) context=\(context) "
                + "type=\(accountType.rawValue) policy=\(inconclusiveFailurePolicy.rawValue) willSignOut=\(willSignOut)"
            )
            print("[AuthAccountTypeGuard] claimFailed type=\(accountType.rawValue) context=\(context) error=\(error.localizedDescription)")
            print("[PendingBusinessSignupTrace] claimAccountIdentity RPC failed context=\(context) fanConflict=\(fanConflict) allowPendingBusinessClaim=\(allowPendingBusinessClaim) pendingDraftOverride=\(pendingOverride) sessionEmail=\(sessionEmail) authUserId=\(sessionUserId?.uuidString.lowercased() ?? "nil") message=\(message)")
            await MainActor.run {
                logBusinessAuthFanConflictGate(
                    context: "claimAccountIdentity",
                    email: sessionEmail,
                    userId: sessionUserId,
                    userProfileExists: fanConflict,
                    blockingReason: willSignOut ? "claim_account_type_failed" : nil,
                    pendingDraftOverride: pendingOverride,
                    message: willSignOut ? message : nil,
                    willSignOut: willSignOut,
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

            guard willSignOut else {
#if DEBUG
                print(
                    "[AuthRestore] inconclusiveClaimFailurePreservedSession=true context=\(context) "
                    + "type=\(accountType.rawValue)"
                )
#endif
                return false
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

    /// True only when the server answered and that answer proves the attempted account type is invalid.
    static func isConfirmedAccountTypeConflictError(_ error: Error) -> Bool {
        let text = accountIdentityErrorText(error)
        return text.contains("email already used for a fan account")
            || text.contains("already claimed as a fan account")
            || text.contains("email already used for a business account")
            || text.contains("already claimed as a business account")
    }

    /// Cancellation can arrive as `CancellationError`, as a cancelled URL task, or wrapped by the
    /// transport/decoding layer, and none of those forms carry a server verdict.
    static func isAccountIdentityCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if Task.isCancelled { return true }

        var candidate: Error? = error
        var depth = 0
        while let current = candidate, depth < 4 {
            if current is CancellationError { return true }
            let ns = current as NSError
            if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return true }
            if ns.domain == NSCocoaErrorDomain, ns.code == NSUserCancelledError { return true }
            candidate = ns.userInfo[NSUnderlyingErrorKey] as? Error
            depth += 1
        }
        return false
    }

    /// Mirrors the failure branch of `claimAccountIdentity` so the decision can be tested directly.
    static func accountIdentityFailureForcesSignOut(
        error: Error,
        policy: AccountIdentityInconclusiveFailurePolicy
    ) -> Bool {
        if isAccountIdentityCancellation(error) { return false }
        return isConfirmedAccountTypeConflictError(error) || policy == .signOut
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

#if DEBUG
/// Deterministic checks that a cancelled or inconclusive `claim_account_type` failure can never be
/// mistaken for a verified account-type conflict during session restore (no XCTest target).
@MainActor
enum AccountIdentityClassificationSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[AccountIdentityClassificationTest] PASS \(name)")
            } else {
                failures += 1
                print("[AccountIdentityClassificationTest] FAIL \(name)")
            }
        }

        let cancellation = CancellationError()
        let urlCancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        let wrappedCancellation = NSError(
            domain: "Supabase.Transport",
            code: -1,
            userInfo: [NSUnderlyingErrorKey: urlCancelled]
        )
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let fanConflict = NSError(
            domain: "PostgREST",
            code: 400,
            userInfo: [NSLocalizedDescriptionKey: "Email already used for a Fan account"]
        )
        let businessConflict = NSError(
            domain: "PostgREST",
            code: 400,
            userInfo: [NSLocalizedDescriptionKey: "Email already claimed as a business account"]
        )

        expect(MapViewModel.isAccountIdentityCancellation(cancellation), "detectsCancellationError")
        expect(MapViewModel.isAccountIdentityCancellation(urlCancelled), "detectsCancelledURLTask")
        expect(MapViewModel.isAccountIdentityCancellation(wrappedCancellation), "detectsWrappedCancellation")
        expect(!MapViewModel.isAccountIdentityCancellation(offline), "offlineIsNotCancellation")
        expect(!MapViewModel.isAccountIdentityCancellation(fanConflict), "conflictIsNotCancellation")

        expect(MapViewModel.isConfirmedAccountTypeConflictError(fanConflict), "detectsFanConflict")
        expect(MapViewModel.isConfirmedAccountTypeConflictError(businessConflict), "detectsBusinessConflict")
        expect(!MapViewModel.isConfirmedAccountTypeConflictError(offline), "offlineIsNotConflict")
        expect(!MapViewModel.isConfirmedAccountTypeConflictError(cancellation), "cancellationIsNotConflict")

        // Restore: only a server-confirmed conflict may tear down an existing session.
        for error in [cancellation as Error, urlCancelled, wrappedCancellation, offline] {
            expect(
                !MapViewModel.accountIdentityFailureForcesSignOut(error: error, policy: .preserveSession),
                "restorePreservesSessionFor_\((error as NSError).code)"
            )
        }
        expect(
            MapViewModel.accountIdentityFailureForcesSignOut(error: fanConflict, policy: .preserveSession),
            "restoreSignsOutOnConfirmedConflict"
        )

        // Sign-up / sign-in keep failing closed, except for cancellation which proves nothing.
        expect(
            MapViewModel.accountIdentityFailureForcesSignOut(error: offline, policy: .signOut),
            "signupFailsClosedOnInconclusive"
        )
        expect(
            !MapViewModel.accountIdentityFailureForcesSignOut(error: cancellation, policy: .signOut),
            "signupDoesNotSignOutOnCancellation"
        )

        if failures == 0 {
            print("[AccountIdentityClassificationTest] ALL PASS")
        } else {
            print("[AccountIdentityClassificationTest] FAILURES=\(failures)")
        }
    }
}
#endif
