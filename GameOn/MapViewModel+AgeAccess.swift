import Foundation
import Supabase

extension MapViewModel {
    /// Shared 13+ gate before any new FanGeo account activation path.
    /// - Parameter email: sign-up email, so the resulting single-use grant is bound to
    ///   the transaction that produced it and cannot be harvested by another account.
    @MainActor
    func requireAgeAccessForSignUp(email: String? = nil) async -> Bool {
        switch await AgeAccessGateService.shared.ensureEligibleForSignUp(presentUI: true, email: email) {
        case .allow:
            return true
        case .blockedUnder13, .needsConfirmation, .cancelled:
            return false
        }
    }

    /// Consumes the sign-up grant for the UUID that just finished activation and records
    /// the coarse result server-side. Call only after the `user_profiles` row exists.
    @MainActor
    func claimAgeAccessSignUpOwnership(userId: UUID, email: String?) async {
        await AgeAccessGateService.shared.claimSignUpOwnership(userId: userId, email: email)
    }

    /// Quarantine an incomplete auth session when age eligibility fails after provider account creation.
    func quarantineSessionAfterAgeAccessBlock(reason: String) async {
        AgeAccessRuntimeLog.result(userId: currentUserAuthId, state: .under13)
        if let currentUserAuthId {
            AgeAccessLocalStore.persist(state: .under13, userId: currentUserAuthId)
        }
        await syncAgeAccessStatusToServerIfPossible(.under13)
        await forceLogout(reason: reason, source: "MapViewModel.quarantineSessionAfterAgeAccessBlock")
    }

    func evaluateAgeAccessForExistingAuthenticatedSessionIfNeeded(
        reason: AgeAccessGateService.EvaluationReason = .launch
    ) async {
        guard isLoggedIn || isVenueOwnerLoggedIn || hasAuthenticatedVenueOwnerSession else {
            AgeAccessGateService.shared.handleLogoutOrAccountSwitch()
            return
        }

        guard let userId = currentUserAuthId else {
            // Authenticated flags without a UUID — fail closed; do not mount social.
            AgeAccessGateService.shared.failClosedPendingAuthenticatedResolution()
            return
        }

        // The gate hydrates the authoritative server record and records any new coarse
        // result itself, so no extra client-side write is needed for allow/unresolved.
        let decision = await AgeAccessGateService.shared.ensureEligibleForSocialSession(
            userId: userId,
            reason: reason,
            presentUI: true,
            sessionKind: isLoggedIn ? .fan : .businessOwner
        )
        if decision == .blockedUnder13 {
            await quarantineSessionAfterAgeAccessBlock(reason: "ageAccessBlockedUnder13ExistingUser")
        }
    }

    /// Best-effort coarse server write through the guarded RPC.
    func syncAgeAccessStatusToServerIfPossible(_ state: AgeAccessState) async {
        guard let userId = currentUserAuthId else {
            let session = try? await supabase.auth.session
            guard let sessionUserId = session?.user.id else { return }
            await writeAgeAccessStatus(sessionUserId, state: state)
            return
        }
        await writeAgeAccessStatus(userId, state: state)
    }

    private func writeAgeAccessStatus(_ userId: UUID, state: AgeAccessState) async {
        // Trust boundary: Apple Declared Age Range is evaluated on-device. The server
        // receives only this coarse status via a guarded RPC that binds to auth.uid(),
        // stamps the authoritative policy version, and refuses to clear a sticky
        // blocked_under_13. There is no cryptographic verification of Apple's response.
        let recorded = await AgeAccessServerStateLoader.record(userId: userId, state: state)
        AgeAccessRuntimeLog.serverResultRecorded(userId: userId, state: state, success: recorded)
    }
}
