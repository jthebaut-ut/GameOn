import CoreLocation
import Foundation
import Supabase

// End-user Supabase Auth (sign up / sign in / session) and `user_profiles` load/save, avatar upload, and profile caching.

extension MapViewModel {

    /// Last explicit account surface the user chose (fan vs business owner vs local admin UI). Drives cold-start session restoration together with ``storedAccountAuthUserIdKey``.
    enum StoredAccountMode: String, Sendable {
        case fanUser
        case businessOwner
        case admin
    }

    static let fanPasswordResetRedirectURL = URL(string: "fangeo://reset-password")!
    static let emailVerificationRedirectURL = URL(string: "fangeo://email-confirmed")!
    private static let emailDeliveryGuidanceMessage = "We sent you an email. If you don’t see it, check your Spam or Junk folder and mark FanGeo as safe."
    static let emailVerifiedSignInContinueMessage = "Email verified. Sign in to continue."
    static let finishingEmailVerificationMessage = "Finishing email verification…"
    static let emailConfirmationLinkFailedMessage =
        "This verification link is invalid or expired. Request a new email or sign in."

    private static let storedAccountModeKey = "GameOn.storedAccountMode"
    private static let storedAccountAuthUserIdKey = "GameOn.storedAccountAuthUserId"
    private static let pendingBusinessEmailSignupDraftFilename = "pending-business-email-signup-draft.json"
    private static let pendingFanEmailSignupDraftFilename = "pending-fan-email-signup-draft.json"

    private static var pendingBusinessEmailSignupDraftURL: URL? {
        do {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return directory.appendingPathComponent(pendingBusinessEmailSignupDraftFilename)
        } catch {
#if DEBUG
            print("[BusinessSignupDraft] applicationSupportURLFailed error=\(error.localizedDescription)")
#endif
            return nil
        }
    }

    private static var pendingFanEmailSignupDraftURL: URL? {
        do {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return directory.appendingPathComponent(pendingFanEmailSignupDraftFilename)
        } catch {
#if DEBUG
            print("[FanSignupDraft] applicationSupportURLFailed error=\(error.localizedDescription)")
#endif
            return nil
        }
    }

    /// When true, cold-start must not treat a still-cached Supabase session as a signed-in user until the next successful manual sign-in.
    private static let didExplicitlyLogoutKey = "didExplicitlyLogout"

    /// Clears ``didExplicitlyLogoutKey`` after email/password (or sign-up) auth establishes a session.
    func clearExplicitLogoutMarkerAfterManualAuthSucceeded() {
        UserDefaults.standard.set(false, forKey: Self.didExplicitlyLogoutKey)
#if DEBUG
        print("[Auth] manual login succeeded, logout marker cleared")
#endif
    }

    @MainActor
    func markEmailVerificationPending(
        email: String,
        kind: EmailVerificationAccountKind,
        verificationEmailConfirmedAsSent: Bool = true,
        includeEmailDeliveryGuidance: Bool = false
    ) {
        pendingEmailVerificationEmail = OwnerBusinessEmail.normalized(email)
        pendingEmailVerificationKind = kind
        if kind == .business {
            businessEmailVerificationUIFlowActive = true
        }
        emailVerificationError = ""
        if kind == .business, !verificationEmailConfirmedAsSent {
            emailVerificationMessage = ""
            emailVerificationError = "Account created, but verification email was not confirmed as sent. Try resend."
        } else {
            let successMessage = kind == .business
                ? "Verification email sent. Check your business email to continue."
                : "Check your email to verify your FanGeo account."
            emailVerificationMessage = includeEmailDeliveryGuidance
                ? Self.withEmailDeliveryGuidance(successMessage)
                : successMessage
        }
        print("[EmailVerifyDebug] signupNeedsConfirmation=true")
    }

    private static func withEmailDeliveryGuidance(_ message: String) -> String {
        "\(message)\n\n\(emailDeliveryGuidanceMessage)"
    }

    @MainActor
    func clearEmailVerificationPending(clearFanDraft: Bool = false) {
        pendingEmailVerificationEmail = ""
        pendingEmailVerificationKind = nil
        businessEmailVerificationUIFlowActive = false
        emailVerificationError = ""
        emailVerificationMessage = ""
        if clearFanDraft {
            clearPendingFanEmailSignupDraft()
        }
    }

    @MainActor
    func clearPendingFanEmailSignupDraft() {
        pendingFanEmailSignupDraft = nil
        clearPersistedPendingFanEmailSignupDraft()
    }

    @MainActor
    func restorePendingFanEmailSignupDraftIfNeeded() {
        if pendingFanEmailSignupDraft != nil { return }
        guard let url = Self.pendingFanEmailSignupDraftURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let draft = try JSONDecoder().decode(PendingFanEmailSignupDraft.self, from: data)
            pendingFanEmailSignupDraft = draft
            let normalized = OwnerBusinessEmail.normalized(draft.email)
            if OwnerBusinessEmail.isValidStrict(normalized) {
                pendingEmailVerificationEmail = normalized
                if pendingEmailVerificationKind == nil {
                    pendingEmailVerificationKind = .fan
                }
            }
#if DEBUG
            print("[FanSignupDraft] restoredPendingFanEmailSignupDraft=true")
#endif
        } catch {
#if DEBUG
            print("[FanSignupDraft] restoreFailed error=\(error.localizedDescription)")
#endif
            try? FileManager.default.removeItem(at: url)
        }
    }

    func persistPendingFanEmailSignupDraft(_ draft: PendingFanEmailSignupDraft) {
        guard let url = Self.pendingFanEmailSignupDraftURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(draft)
            try data.write(to: url, options: [.atomic])
#if DEBUG
            print("[FanSignupDraft] persistedPendingFanEmailSignupDraft=true")
#endif
        } catch {
#if DEBUG
            print("[FanSignupDraft] persistFailed error=\(error.localizedDescription)")
#endif
        }
    }

    func clearPersistedPendingFanEmailSignupDraft() {
        guard let url = Self.pendingFanEmailSignupDraftURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    @MainActor
    func clearPendingBusinessEmailSignupState() {
        pendingBusinessEmailSignupDraft = nil
        clearPersistedPendingBusinessEmailSignupDraft()
        pendingEmailVerificationEmail = ""
        pendingEmailVerificationKind = nil
        emailVerificationError = ""
        emailVerificationMessage = ""
        resumePendingBusinessSetupForDraftEmail = false
        businessEmailVerificationUIFlowActive = false
    }

    /// Hides the verification waiting UI while keeping the persisted business signup draft for resume.
    @MainActor
    func dismissBusinessEmailVerificationPendingUIForSignIn() {
        pendingEmailVerificationKind = nil
        businessEmailVerificationUIFlowActive = false
        emailVerificationError = ""
        resumePendingBusinessSetupForDraftEmail = false
        if pendingBusinessEmailSignupDraft != nil {
            emailVerificationMessage = ""
            venueAuthErrorMessage = "After verifying your email, sign in to add your first venue for FanGeo review."
        }
    }

    /// Email is verified; venue setup can begin while the identity-only draft is preserved.
    @MainActor
    func markBusinessEmailVerifiedAwaitingVenueSetup(email: String) {
        let normalized = OwnerBusinessEmail.normalized(email)
        pendingEmailVerificationKind = nil
        businessEmailVerificationUIFlowActive = false
        pendingEmailVerificationEmail = normalized
        emailVerificationError = ""
        emailVerificationMessage = ""
        venueAuthErrorMessage = ""

        if let draft = pendingBusinessEmailSignupDraft,
           OwnerBusinessEmail.normalized(draft.email) == normalized,
           !draft.emailVerified {
            let verifiedDraft = draft.markingEmailVerified()
            pendingBusinessEmailSignupDraft = verifiedDraft
            persistPendingBusinessEmailSignupDraft(verifiedDraft)
        }
#if DEBUG
        let venueName = pendingBusinessEmailSignupDraft?.signup.firstLocation.venueName
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        print(
            "[BusinessSignupFlow] source=emailConfirmReturn markedVerified email=\(normalized) authUserId=\(currentUserAuthId?.uuidString.lowercased() ?? "nil") draftPresent=\(pendingBusinessEmailSignupDraft != nil) venueNameEmpty=\(venueName.isEmpty) needsVenueSetup=\(businessEmailVerifiedNeedsVenueSetup)"
        )
#endif
    }

    /// Confirmed Supabase session with a matching pending business draft → verified venue-setup state.
    @MainActor
    @discardableResult
    func applyVerifiedBusinessSignupSessionIfNeeded(session: Session) -> Bool {
        guard Self.userEmailConfirmed(session.user) else { return false }
        let sessionEmail = OwnerBusinessEmail.normalized(session.user.email ?? "")
        guard OwnerBusinessEmail.isValidStrict(sessionEmail) else { return false }

        restorePendingBusinessEmailSignupDraftIfNeeded()

        guard let draft = pendingBusinessEmailSignupDraft,
              OwnerBusinessEmail.normalized(draft.email) == sessionEmail else {
            return false
        }

        if hasBusinessAccountForOwner() {
            clearPendingBusinessEmailSignupState()
            return false
        }

        markBusinessEmailVerifiedAwaitingVenueSetup(email: sessionEmail)
        currentUserAuthId = session.user.id
        venueOwnerEmail = sessionEmail
        venueAuthErrorMessage = ""
        return !draft.isVenueSubmissionReady
    }

    /// Lifecycle-gated wrapper for pending business venue setup after sign-in.
    func applyVerifiedBusinessSignupSessionIfAllowed(session: Session) async -> Bool {
        let sessionEmail = OwnerBusinessEmail.normalized(session.user.email ?? "")
        guard Self.userEmailConfirmed(session.user),
              OwnerBusinessEmail.isValidStrict(sessionEmail) else {
            return false
        }

        let lifecycle = await resolveBusinessProfileLifecycleState()
        switch lifecycle {
        case .missing:
            break
        case .active:
            await MainActor.run { clearPendingBusinessEmailSignupState() }
            return false
        case .deleted, .archived, .disabled, .unknown:
#if DEBUG
            print("[DeletedBusinessLoginDebug] signupPrevented reason=\(lifecycle.rawValue) source=applyVerifiedBusinessSignupSessionIfAllowed")
#endif
            _ = await enforceBusinessLifecycleGate(
                userId: session.user.id,
                sessionEmail: sessionEmail,
                source: "applyVerifiedBusinessSignupSessionIfAllowed"
            )
            return true
        }

        return await MainActor.run {
            applyVerifiedBusinessSignupSessionIfNeeded(session: session)
        }
    }

    /// Signs out after post-verification venue setup while preserving the pending business draft for resume.
    func deferBusinessVenueSetupUntilLater() async {
        let draftEmail = await MainActor.run {
            pendingBusinessEmailSignupDraft.map { OwnerBusinessEmail.normalized($0.email) } ?? ""
        }

        await PushNotificationRegistrationService.shared.deleteCurrentTokenForCurrentSession(
            reason: "deferBusinessVenueSetup"
        )

        do {
            try await supabase.auth.signOut()
        } catch {
#if DEBUG
            print("[BusinessVenueSetup] deferSignOutFailed error=\(error.localizedDescription)")
#endif
        }

        await stopVenueOwnerAnalyticsRealtime()
        await removeAllVenueEventCommentsRealtimeListeners()
        await clearFanActiveSessionOnLogout()

        await MainActor.run {
            clearAuthenticatedSessionCaches()
            clearVenueOwnerDraftState()
            isLoggedIn = false
            isVenueOwnerLoggedIn = false
            venueOwnerMode = false
            isAdminLoggedIn = false
            markAuthSignedOut(reason: "businessVenueSetupDeferred")

            if !draftEmail.isEmpty {
                markBusinessEmailVerifiedAwaitingVenueSetup(email: draftEmail)
            }
            resumePendingBusinessSetupForDraftEmail = false
        }

        clearPersistedAccountMode()
    }

    @MainActor
    func restorePendingBusinessEmailSignupDraftIfNeeded() {
        guard let url = Self.pendingBusinessEmailSignupDraftURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let draft = try JSONDecoder().decode(PendingBusinessEmailSignupDraft.self, from: data)
            pendingBusinessEmailSignupDraft = draft
            pendingEmailVerificationEmail = OwnerBusinessEmail.normalized(draft.email)
            if draft.emailVerified {
                pendingEmailVerificationKind = nil
            } else if pendingEmailVerificationKind == nil {
                pendingEmailVerificationKind = .business
            }
            if emailVerificationMessage.isEmpty, pendingEmailVerificationKind == .business {
                emailVerificationMessage = Self.withEmailDeliveryGuidance(
                    "Verification email sent. After you verify, sign in to add your first venue for FanGeo review."
                )
            }
#if DEBUG
            print("[BusinessSignupDraft] restoredPendingBusinessEmailSignupDraft=true email=\(pendingEmailVerificationEmail)")
#endif
        } catch {
#if DEBUG
            print("[BusinessSignupDraft] restoreFailed error=\(error.localizedDescription)")
#endif
            try? FileManager.default.removeItem(at: url)
        }
    }

    func persistPendingBusinessEmailSignupDraft(_ draft: PendingBusinessEmailSignupDraft) {
        guard let url = Self.pendingBusinessEmailSignupDraftURL else { return }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(draft)
            try data.write(to: url, options: [.atomic])
#if DEBUG
            print("[BusinessSignupDraft] persistedPendingBusinessEmailSignupDraft=true email=\(OwnerBusinessEmail.normalized(draft.email)) bytes=\(data.count)")
#endif
        } catch {
#if DEBUG
            print("[BusinessSignupDraft] persistFailed error=\(error.localizedDescription)")
#endif
        }
    }

    func clearPersistedPendingBusinessEmailSignupDraft() {
        guard let url = Self.pendingBusinessEmailSignupDraftURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: url)
#if DEBUG
            print("[BusinessSignupDraft] clearedPersistedPendingBusinessEmailSignupDraft=true")
#endif
        } catch {
#if DEBUG
            print("[BusinessSignupDraft] clearPersistedFailed error=\(error.localizedDescription)")
#endif
        }
    }

    static func isUnconfirmedEmailAuthError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("email not confirmed")
            || message.contains("email not verified")
            || message.contains("confirm your email")
            || message.contains("verify your email")
    }

    static func userEmailConfirmed(_ user: User) -> Bool {
        user.emailConfirmedAt != nil || user.confirmedAt != nil
    }

    static func userConfirmationEmailConfirmedAsSent(_ user: User) -> Bool {
        user.confirmationSentAt != nil
    }

    static func authUserProviderDebugSummary(_ user: User) -> String {
        let provider = user.appMetadata["provider"].map { String(describing: $0) } ?? "nil"
        let providers = user.appMetadata["providers"].map { String(describing: $0) } ?? "nil"
        let identityProviders = user.identities?
            .map(\.provider)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: ",") ?? "nil"
        return "appProvider=\(provider) appProviders=\(providers) identityProviders=\(identityProviders) identityCount=\(user.identities?.count ?? 0)"
    }

    static func businessEmailVerificationSignupDebugLines(
        response: AuthResponse,
        redirectURL: URL
    ) -> [String] {
        let user = response.user
        return [
            "[BusinessEmailVerification] signUpResponse user_id=\(user.id.uuidString.lowercased())",
            "[BusinessEmailVerification] signUpResponse session_nil=\(response.session == nil)",
            "[BusinessEmailVerification] signUpResponse email_confirmed_at=\((user.emailConfirmedAt ?? user.confirmedAt)?.description ?? "nil")",
            "[BusinessEmailVerification] signUpResponse confirmation_sent_at=\(user.confirmationSentAt?.description ?? "nil")",
            "[BusinessEmailVerification] signUpResponse confirmation_email_confirmed_as_sent=\(userConfirmationEmailConfirmedAsSent(user))",
            "[BusinessEmailVerification] signUpResponse \(authUserProviderDebugSummary(user))",
            "[BusinessEmailVerification] signUpRequest redirect_to=\(redirectURL.absoluteString)"
        ]
    }

    private func readPersistedAccountMode() -> (mode: StoredAccountMode, authUserId: String?) {
        let raw = UserDefaults.standard.string(forKey: Self.storedAccountModeKey)
        let mode = StoredAccountMode(rawValue: raw ?? "") ?? .fanUser
        let uid = UserDefaults.standard.string(forKey: Self.storedAccountAuthUserIdKey)
        return (mode, uid)
    }

    func clearPersistedAccountMode() {
        UserDefaults.standard.removeObject(forKey: Self.storedAccountModeKey)
        UserDefaults.standard.removeObject(forKey: Self.storedAccountAuthUserIdKey)
    }

    func logBusinessOwnerSessionFlags(context: String) {
#if DEBUG
        let normalizedOwnerEmail = OwnerBusinessEmail.normalized(venueOwnerEmail)
        print("[BusinessSessionFlags] context=\(context)")
        print("[BusinessSessionFlags] isVenueOwnerLoggedIn=\(isVenueOwnerLoggedIn)")
        print("[BusinessSessionFlags] venueOwnerMode=\(venueOwnerMode)")
        print("[BusinessSessionFlags] currentUserAuthId=\(currentUserAuthId?.uuidString ?? "nil")")
        print("[BusinessSessionFlags] venueOwnerEmail=\(normalizedOwnerEmail)")
        print("[BusinessSessionFlags] hasAuthenticatedVenueOwnerSession=\(hasAuthenticatedVenueOwnerSession)")
#endif
    }

    private enum BusinessOwnerActiveValidationResult {
        case active
        case inactive
        case inconclusive(Error)

        var debugValue: String {
            switch self {
            case .active:
                return "active"
            case .inactive:
                return "inactive"
            case .inconclusive(let error):
                return "inconclusive:\(error.localizedDescription)"
            }
        }
    }

    private enum BusinessAdminStatusValidationResult {
        case active(String)
        case blocked(String)
        case noBusiness
        case inconclusive(Error)

        var debugStatus: String {
            switch self {
            case .active(let status), .blocked(let status):
                return status
            case .noBusiness:
                return "noBusiness"
            case .inconclusive(let error):
                return "inconclusive:\(error.localizedDescription)"
            }
        }
    }

    private struct BusinessAdminStatusRow: Decodable {
        let id: UUID?
        let owner_email: String?
        let owner_user_id: UUID?
        let admin_status: String?
        let business_origin: String?
    }

    private func logBusinessSessionRestoreDebug(_ message: String) {
#if DEBUG
        print("[BusinessSessionRestoreDebug] \(message)")
#endif
    }

    private func logBusinessLogoutTrace(_ message: String) {
#if DEBUG
        print("[BusinessLogoutTrace] \(message)")
#endif
    }

    func logDeletedAccountRestoreDebug(_ message: String) {
#if DEBUG
        print("[DeletedAccountRestoreDebug] \(message)")
#endif
    }

    @MainActor
    private func clearStaleDeletedAccountBlockIfNeeded(context: String) {
        let staleDeletedBlock = authSessionState == .deletedAccountConfirmed
            || authSessionState == .deletedBusinessAccountConfirmed
            || Self.isDeletedAccountBlockMessage(authErrorMessage)
            || Self.isDeletedAccountBlockMessage(venueAuthErrorMessage)
        guard staleDeletedBlock else { return }

        if authSessionState == .deletedAccountConfirmed
            || authSessionState == .deletedBusinessAccountConfirmed {
            transitionAuthSessionState(.loadingSession, reason: "\(context)_staleDeletedBlockCleared")
        }
        authErrorMessage = ""
        venueAuthErrorMessage = ""
        logDeletedAccountRestoreDebug("staleBlockCleared=true context=\(context)")
    }

    private static func isDeletedAccountBlockMessage(_ message: String) -> Bool {
        MapViewModel.isDeletedAccountLoginBlockMessage(message)
    }

    private func hasStoredAccountModeForRestore() -> Bool {
        UserDefaults.standard.string(forKey: Self.storedAccountModeKey) != nil
    }

    private func storedAccountModeDebugValue() -> String {
        let raw = UserDefaults.standard.string(forKey: Self.storedAccountModeKey)
        return raw ?? "nil"
    }

    func shouldPreserveMissingSessionForRestore() -> Bool {
        guard !UserDefaults.standard.bool(forKey: Self.didExplicitlyLogoutKey) else { return false }
        if resolvingEmailConfirmation { return true }
        if hasStoredAccountModeForRestore() { return true }
        return isAuthenticatedForSocialFeatures
            || isAuthSessionRestoringForProfilePresentation
            || authSessionState == .loadingSession
            || isBusinessOwnerSessionRestorePending
    }

    func markTransientMissingSessionPreserved(reason: String, source: String) async {
        let persisted = readPersistedAccountMode()
        let hasStoredMode = hasStoredAccountModeForRestore()
        let didExplicitlyLogout = UserDefaults.standard.bool(forKey: Self.didExplicitlyLogoutKey)
        logBusinessLogoutTrace("transientMissingSessionPreserved=true reason=\(reason) source=\(source)")
        logBusinessLogoutTrace("didExplicitlyLogout=\(didExplicitlyLogout)")
        logBusinessLogoutTrace("storedAccountMode=\(storedAccountModeDebugValue())")

        await MainActor.run {
            if !didExplicitlyLogout, hasStoredMode, persisted.mode == .businessOwner {
                isBusinessOwnerSessionRestorePending = true
                if authSessionState != .signedIn {
                    transitionAuthSessionState(.loadingSession, reason: reason)
                }
            } else if !didExplicitlyLogout, isAuthenticatedForSocialFeatures {
                transitionAuthSessionState(.loadingSession, reason: reason)
            }
        }
    }

    private func destructiveLogoutAllowed(reason: String, source: String) -> Bool {
        let reasonKey = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sourceKey = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if reasonKey.contains("explicituserlogout") { return true }
        if reasonKey.contains("explicitlogoutbootstrap") { return true }
        if sourceKey.contains("logoutuser") { return true }
        if reasonKey.contains("deletedaccountconfirmed") { return true }
        if reasonKey.contains("deletedbusinessaccountconfirmed") { return true }
        if reasonKey.contains("disabledaccountconfirmed") { return true }
        if reasonKey.contains("accountdeletion") { return true }
        if reasonKey.contains("accounttypemismatch") { return true }
        if reasonKey.contains("singlesessionmismatch") { return true }
        if reasonKey.contains("passwordreset") { return true }
        return false
    }

    private func validateActiveBusinessAccount(ownerEmail: String, ownerUserId: UUID?) async -> BusinessOwnerActiveValidationResult {
        let normalized = OwnerBusinessEmail.normalized(ownerEmail)
        guard OwnerBusinessEmail.isValidStrict(normalized) else { return .inactive }

        if ownedBusinesses.contains(where: {
            OwnerBusinessEmail.normalized($0.owner_email ?? "") == normalized
                && $0.admin_status == "active"
                && BusinessOrigin.isLoginOwned($0.business_origin)
        }) {
            return .active
        }
        if let ownerUserId,
           ownedBusinesses.contains(where: {
               $0.owner_user_id == ownerUserId
                   && $0.admin_status == "active"
                   && BusinessOrigin.isLoginOwned($0.business_origin)
           }) {
            return .active
        }

        struct BusinessExistenceRow: Decodable {
            let id: UUID
        }

        do {
            let byEmail: [BusinessExistenceRow] = try await supabase
                .from("businesses")
                .select("id")
                .eq("owner_email", value: normalized)
                .eq("admin_status", value: "active")
                .in("business_origin", values: BusinessOrigin.loginOwnedValues)
                .limit(1)
                .execute()
                .value
            if !byEmail.isEmpty { return .active }

            if let ownerUserId {
                let byUser: [BusinessExistenceRow] = try await supabase
                    .from("businesses")
                    .select("id")
                    .eq("owner_user_id", value: ownerUserId)
                    .eq("admin_status", value: "active")
                    .in("business_origin", values: BusinessOrigin.loginOwnedValues)
                    .limit(1)
                    .execute()
                    .value
                if !byUser.isEmpty { return .active }
            }
            return .inactive
        } catch {
#if DEBUG
            print("[BusinessSessionFlags] hasActiveBusinessAccount failed email=\(normalized):", error)
#endif
            return .inconclusive(error)
        }
    }

    private func validateBusinessAdminStatus(ownerEmail: String, ownerUserId: UUID?) async -> BusinessAdminStatusValidationResult {
        let normalized = OwnerBusinessEmail.normalized(ownerEmail)
        logDeletedAccountRestoreDebug("email=\(normalized.isEmpty ? "nil" : normalized)")

        var rowsById: [BusinessAdminStatusRow] = []
        var rowsByEmail: [BusinessAdminStatusRow] = []

        do {
            if let ownerUserId {
                rowsById = try await supabase
                    .from("businesses")
                    .select("id,owner_email,owner_user_id,admin_status,business_origin")
                    .eq("owner_user_id", value: ownerUserId)
                    .in("business_origin", values: BusinessOrigin.loginOwnedValues)
                    .limit(5)
                    .execute()
                    .value
            }

            if OwnerBusinessEmail.isValidStrict(normalized) {
                rowsByEmail = try await supabase
                    .from("businesses")
                    .select("id,owner_email,owner_user_id,admin_status,business_origin")
                    .eq("owner_email", value: normalized)
                    .in("business_origin", values: BusinessOrigin.loginOwnedValues)
                    .limit(5)
                    .execute()
                    .value
            }
        } catch {
            logDeletedAccountRestoreDebug("businessAdminStatus=inconclusive:\(error.localizedDescription)")
            logDeletedAccountRestoreDebug("inconclusiveNotDeleted=true")
            return .inconclusive(error)
        }

        let rows = rowsById + rowsByEmail
        guard !rows.isEmpty else {
            logDeletedAccountRestoreDebug("businessAdminStatus=noBusiness")
            logDeletedAccountRestoreDebug("inconclusiveNotDeleted=true reason=noBusinessRow")
            return .noBusiness
        }

        let statuses = rows.map { ($0.admin_status ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let debugStatus = statuses.isEmpty ? "nil" : statuses.joined(separator: ",")
        logDeletedAccountRestoreDebug("businessAdminStatus=\(debugStatus)")

        if statuses.contains("active") {
            logDeletedAccountRestoreDebug("activeBusinessClearsBlock=true")
            return .active("active")
        }

        if let blocked = statuses.first(where: { ["archived", "deleted", "disabled"].contains($0) }) {
            logDeletedAccountRestoreDebug("dbConfirmedDeleted=true status=\(blocked)")
            return .blocked(blocked)
        }

        logDeletedAccountRestoreDebug("inconclusiveNotDeleted=true reason=unrecognizedBusinessStatus")
        return .noBusiness
    }

    @discardableResult
    private func restoreActiveBusinessFromAdminStatusIfNeeded(
        session: Session,
        sessionEmail: String,
        context: String
    ) async -> Bool {
        let lifecycle = await resolveBusinessProfileLifecycleState()
        switch lifecycle {
        case .active:
            await MainActor.run {
                clearStaleDeletedAccountBlockIfNeeded(context: context)
            }
            return true
        case .deleted:
            if Self.shouldAllowDualFanFallbackAfterDeletedBusiness(source: context),
               await resolveFanProfileLifecycleState(userId: session.user.id) == .active {
                await routeDualFanModeAfterDeletedBusiness(context: context)
                return false
            }
            await blockDeletedBusinessLogin(
                userId: session.user.id,
                sessionEmail: sessionEmail,
                source: context
            )
            return false
        case .archived, .disabled:
            await handleAdminLifecycleBlockedBusiness(status: lifecycle.rawValue, context: context)
            return false
        case .missing:
            logDeletedAccountRestoreDebug("businessLifecycle=missing context=\(context)")
            return true
        case .unknown:
            logDeletedAccountRestoreDebug("businessLifecycle=unknown context=\(context)")
            return false
        }
    }

    private func handleBlockedBusinessAccount(status: String, context: String) async {
        logDeletedAccountRestoreDebug("blockedStateSetBy=\(context)")
        await forceLogout(reason: "disabledAccountConfirmed", source: "MapViewModel.\(context)")
        await MainActor.run {
            resetProfilePresentationLoadStateForNewAuth()
            transitionAuthSessionState(.deletedAccountConfirmed, reason: "\(context)_businessStatus_\(status)")
            authErrorMessage = "This business account is no longer active.\nContact support if you believe this was a mistake."
            venueAuthErrorMessage = authErrorMessage
        }
    }

    func businessAccountAccessIsAllowedForAuthenticatedSession(
        ownerEmail: String,
        userId: UUID,
        context: String
    ) async -> Bool {
        if await enforceBusinessLifecycleGate(
            userId: userId,
            sessionEmail: ownerEmail,
            source: context,
            allowDualFanFallback: false
        ) {
            return false
        }
        await MainActor.run {
            clearStaleDeletedAccountBlockIfNeeded(context: context)
        }
        return true
    }

    private func shouldSuppressDeletedProfileBlockForBusinessSession(
        session: Session,
        context: String
    ) async -> Bool {
        let sessionEmail = OwnerBusinessEmail.normalized(session.user.email ?? "")
        let validation = await validateBusinessAdminStatus(ownerEmail: sessionEmail, ownerUserId: session.user.id)
        switch validation {
        case .active:
            await MainActor.run {
                clearStaleDeletedAccountBlockIfNeeded(context: context)
            }
            logDeletedAccountRestoreDebug("inconclusiveNotDeleted=true reason=activeBusinessProfileDeletedIgnored context=\(context)")
            return true
        case .blocked(let status):
            await handleBlockedBusinessAccount(status: status, context: context)
            return true
        case .noBusiness, .inconclusive:
            let shouldTreatAsBusinessRestore = await MainActor.run {
                readPersistedAccountMode().mode == .businessOwner
                    || currentUserIsBusinessAccount
                    || isVenueOwnerLoggedIn
                    || isBusinessOwnerSessionRestorePending
            }
            if shouldTreatAsBusinessRestore {
                logDeletedAccountRestoreDebug("inconclusiveNotDeleted=true reason=businessContextProfileDeletedIgnored context=\(context)")
                return true
            }
            return false
        }
    }

    private func hasActiveBusinessAccount(ownerEmail: String, ownerUserId: UUID?) async -> Bool {
        if case .active = await validateActiveBusinessAccount(ownerEmail: ownerEmail, ownerUserId: ownerUserId) {
            return true
        }
        return false
    }

    /// Window in which an identical validation is reused instead of repeating the same RPC set.
    private static let businessOwnerSessionFlagsFreshnessWindow: TimeInterval = 2.0

    /// Identifies "the same validation": anything that would change the outcome locally.
    private func businessOwnerSessionFlagsIdentity() -> String {
        [
            currentUserAuthId?.uuidString.lowercased() ?? "nil",
            OwnerBusinessEmail.normalized(venueOwnerEmail),
            hasAuthenticatedVenueOwnerSession ? "1" : "0",
            venueOwnerMode ? "1" : "0",
            isVenueOwnerLoggedIn ? "1" : "0"
        ].joined(separator: "|")
    }

    /// Coalescing front door for business-owner session validation.
    ///
    /// Both Discover triggers stay in place; an equivalent call that arrives while one is in flight
    /// (or moments after it finished) observes that result instead of issuing the RPCs again.
    /// Callers that must re-check server state pass `allowsRecentResultReuse: false`.
    @discardableResult
    func ensureBusinessOwnerSessionFlagsIfPossible(
        context: String,
        allowsRecentResultReuse: Bool = true
    ) async -> Bool {
        let identity = businessOwnerSessionFlagsIdentity()

        if let inFlight = businessOwnerSessionFlagsEnsureTask,
           businessOwnerSessionFlagsEnsureIdentity == identity {
#if DEBUG
            print("[BusinessSessionPerf] validationCoalesced=true context=\(context)")
#endif
            StartupPerf.taskCoalesced(name: "ensureBusinessOwnerSessionFlags")
            return await inFlight.value
        }

        if allowsRecentResultReuse,
           let last = businessOwnerSessionFlagsLastValidation,
           last.identity == identity,
           Date().timeIntervalSince(last.at) < Self.businessOwnerSessionFlagsFreshnessWindow {
#if DEBUG
            print("[BusinessSessionPerf] validationSkippedFresh=true context=\(context)")
#endif
            StartupPerf.duplicateSkipped(reason: "ensureBusinessOwnerSessionFlagsFresh")
            return last.result
        }

        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            return await self.performEnsureBusinessOwnerSessionFlagsIfPossible(context: context)
        }
        businessOwnerSessionFlagsEnsureTask = task
        businessOwnerSessionFlagsEnsureIdentity = identity

        let result = await task.value

        if businessOwnerSessionFlagsEnsureTask == task {
            businessOwnerSessionFlagsEnsureTask = nil
            businessOwnerSessionFlagsEnsureIdentity = nil
        }
        businessOwnerSessionFlagsLastValidation = (identity: identity, result: result, at: Date())
        return result
    }

    private func performEnsureBusinessOwnerSessionFlagsIfPossible(context: String) async -> Bool {
        logBusinessOwnerSessionFlags(context: "\(context)_before")

        if await businessBanGuardBlocks(path: context, action: "ensureBusinessOwnerSessionFlagsIfPossible") {
            return false
        }

        if hasAuthenticatedVenueOwnerSession {
            logBusinessOwnerSessionFlags(context: "\(context)_already_valid")
            return true
        }

        guard let authId = currentUserAuthId else {
            logBusinessOwnerSessionFlags(context: "\(context)_missing_auth_id")
            return false
        }

        let normalizedOwnerEmail = OwnerBusinessEmail.normalized(venueOwnerEmail)
        guard OwnerBusinessEmail.isValidStrict(normalizedOwnerEmail) else {
            logBusinessOwnerSessionFlags(context: "\(context)_invalid_owner_email")
            return false
        }

        let businessAdminStatus = await resolveBusinessProfileLifecycleState()
        switch businessAdminStatus {
        case .active:
            clearStaleDeletedAccountBlockIfNeeded(context: context)
        case .deleted, .archived, .disabled, .unknown:
            _ = await enforceBusinessLifecycleGate(
                userId: authId,
                sessionEmail: normalizedOwnerEmail,
                source: context
            )
            return false
        case .missing:
            break
        }

        let validation = await validateActiveBusinessAccount(ownerEmail: normalizedOwnerEmail, ownerUserId: authId)
        logBusinessSessionRestoreDebug("activeBusinessValidation=\(validation.debugValue)")
        guard case .active = validation else {
            logBusinessOwnerSessionFlags(context: "\(context)_no_business_account")
            return false
        }

        isVenueOwnerLoggedIn = true
        venueOwnerMode = true
        isLoggedIn = false
        isAdminLoggedIn = false
        currentUserAuthId = authId
        markAuthSignedIn(reason: "\(context)_businessOwner")
        venueOwnerEmail = normalizedOwnerEmail
        currentUserEmail = ""
        currentUserDisplayName = ""
        currentUserBio = ""
        currentUserIsBusinessAccount = true
        currentUserAvatarURL = ""
        currentUserAvatarThumbnailURL = ""
        currentUserNationalTeam = nil
        currentUserHomeCity = ""
        currentUserHomeRegion = ""
        currentUserHomeCountry = ""
        currentUserShowHomeCity = false
        currentUserProfileBackgroundKey = .fangeo
        isAuthSessionRestoringForProfilePresentation = false
        isUserProfileLoadingForPresentation = false
        hasLoadedUserProfileForPresentation = false
        userProfileExistsForPresentation = false
        currentUserLiveVisibilityEnabled = true
        currentUserLiveVisibilityMode = .allFriends
        currentUserSelectedLiveVisibilityFriendIDs = []
        currentUserDiscoverableByFans = true
        isBusinessOwnerSessionRestorePending = false

        await persistAccountModeForActiveAuthSession(.businessOwner)
        restorePersistedSelectedVenueForBusinessLaunch()
        print("[BusinessLaunchPerf] criticalBootstrapMinimal=true")
        Task { [weak self] in
            await self?.runDeferredBusinessOwnerHydrationAfterLaunch()
        }
        logBusinessOwnerSessionFlags(context: "\(context)_restored")
        return true
    }

    private func restoreBusinessOwnerSessionFromSupabaseSessionIfNeeded(
        session: Session,
        sessionEmail: String,
        context: String
    ) async -> Bool {
        logBusinessOwnerSessionFlags(context: "\(context)_before")

        if await businessBanGuardBlocks(path: context, action: "restoreBusinessOwnerSessionFromSupabaseSessionIfNeeded") {
            return false
        }

        guard !hasAuthenticatedVenueOwnerSession else {
            logBusinessOwnerSessionFlags(context: "\(context)_already_valid")
            return true
        }

        guard OwnerBusinessEmail.isValidStrict(sessionEmail) else {
            logBusinessOwnerSessionFlags(context: "\(context)_invalid_session_email")
            return false
        }

        guard await restoreActiveBusinessFromAdminStatusIfNeeded(
            session: session,
            sessionEmail: sessionEmail,
            context: context
        ) else {
            return false
        }

        await MainActor.run {
            restorePendingBusinessEmailSignupDraftIfNeeded()
        }
        let pendingVerifiedVenueSetup: Bool
        let lifecycleForPending = await resolveBusinessProfileLifecycleState()
        if lifecycleForPending == .missing {
            pendingVerifiedVenueSetup = await MainActor.run { () -> Bool in
                guard hasPendingVerifiedBusinessVenueSetup,
                      let draft = pendingBusinessEmailSignupDraft,
                      OwnerBusinessEmail.normalized(draft.email) == sessionEmail else {
                    return false
                }
                markBusinessEmailVerifiedAwaitingVenueSetup(email: sessionEmail)
                currentUserAuthId = session.user.id
                venueOwnerEmail = sessionEmail
                isLoggedIn = false
                isVenueOwnerLoggedIn = false
                venueOwnerMode = false
                isAdminLoggedIn = false
                markAuthSignedIn(reason: "\(context)_pendingBusinessVenueSetup")
                isBusinessOwnerSessionRestorePending = false
                return true
            }
        } else {
            if lifecycleForPending != .active {
#if DEBUG
                print("[DeletedBusinessLoginDebug] deletedSessionBlocked reason=\(lifecycleForPending.rawValue) source=\(context)_pendingBusinessVenueSetup")
#endif
                _ = await enforceBusinessLifecycleGate(
                    userId: session.user.id,
                    sessionEmail: sessionEmail,
                    source: "\(context)_pendingBusinessVenueSetup"
                )
            } else {
                await MainActor.run { clearPendingBusinessEmailSignupState() }
            }
            pendingVerifiedVenueSetup = false
        }
        if pendingVerifiedVenueSetup {
            logBusinessOwnerSessionFlags(context: "\(context)_pending_business_venue_setup")
            return true
        }

        let validation = await validateActiveBusinessAccount(ownerEmail: sessionEmail, ownerUserId: session.user.id)
        logBusinessSessionRestoreDebug("activeBusinessValidation=\(validation.debugValue)")
        guard case .active = validation else {
            let lifecycle = await resolveBusinessProfileLifecycleState()
            if lifecycle == .deleted,
               await resolveFanProfileLifecycleState(userId: session.user.id) == .active {
                await routeDualFanModeAfterDeletedBusiness(context: context)
            }
            logBusinessOwnerSessionFlags(context: "\(context)_no_business_account lifecycle=\(lifecycle.rawValue)")
            return false
        }

        // Restore-only: see `fanSessionRestore` above for why inconclusive failures preserve.
        guard await claimAccountIdentity(
            .business,
            context: context,
            inconclusiveFailurePolicy: .preserveSession
        ) else {
            logBusinessOwnerSessionFlags(context: "\(context)_account_identity_blocked")
            return false
        }

        venueOwnerEmail = sessionEmail
        isVenueOwnerLoggedIn = true
        venueOwnerMode = true
        isLoggedIn = false
        currentUserEmail = ""
        currentUserDisplayName = ""
        currentUserBio = ""
        currentUserIsBusinessAccount = true
        currentUserAvatarURL = ""
        currentUserAvatarThumbnailURL = ""
        currentUserNationalTeam = nil
        currentUserHomeCity = ""
        currentUserHomeRegion = ""
        currentUserHomeCountry = ""
        currentUserShowHomeCity = false
        currentUserProfileBackgroundKey = .fangeo
        currentUserLiveVisibilityEnabled = true
        currentUserLiveVisibilityMode = .allFriends
        currentUserSelectedLiveVisibilityFriendIDs = []
        currentUserDiscoverableByFans = true
        isAdminLoggedIn = false
        currentUserAuthId = session.user.id
        markAuthSignedIn(reason: "\(context)_businessOwner")
        isBusinessOwnerSessionRestorePending = false

        await persistAccountModeForActiveAuthSession(.businessOwner)
        restorePersistedSelectedVenueForBusinessLaunch()
        print("[BusinessLaunchPerf] criticalBootstrapMinimal=true")
        logBusinessOwnerSessionFlags(context: "\(context)_restored")
        return true
    }

    func clearCurrentUserProfileLocalCache() {
        UserDefaults.standard.removeObject(forKey: "cachedUserDisplayName")
        UserDefaults.standard.removeObject(forKey: "cachedUserUsername")
        UserDefaults.standard.removeObject(forKey: "cachedUserBio")
        UserDefaults.standard.removeObject(forKey: "cachedUserProfileCreatedAt")
        UserDefaults.standard.removeObject(forKey: "cachedUserAvatarURL")
        UserDefaults.standard.removeObject(forKey: "cachedUserAvatarThumbnailURL")
        UserDefaults.standard.removeObject(forKey: "cachedUserNationalTeamCountryCode")
        UserDefaults.standard.removeObject(forKey: "cachedUserNationalTeamCountryName")
        UserDefaults.standard.removeObject(forKey: "cachedUserNationalTeamFlag")
        UserDefaults.standard.removeObject(forKey: "cachedUserNationalTeamSupporterLabel")
        UserDefaults.standard.removeObject(forKey: "cachedUserHomeCity")
        UserDefaults.standard.removeObject(forKey: "cachedUserHomeRegion")
        UserDefaults.standard.removeObject(forKey: "cachedUserHomeCountry")
        UserDefaults.standard.removeObject(forKey: "cachedUserShowHomeCity")
        UserDefaults.standard.removeObject(forKey: "cachedUserProfileBackgroundKey")
        UserDefaults.standard.removeObject(forKey: "cachedUserLiveVisibilityEnabled")
        UserDefaults.standard.removeObject(forKey: "cachedUserLiveVisibilityMode")
        UserDefaults.standard.removeObject(forKey: "cachedUserSelectedLiveVisibilityFriendIDs")
        UserDefaults.standard.removeObject(forKey: "cachedUserDiscoverableByFans")
        UserDefaults.standard.removeObject(forKey: "cachedUserActivityStatusVisible")
    }

    /// Clears authenticated/private session caches that must never survive logout, session loss, or account switching.
    /// Intentionally does not mutate the high-level signed-in flags; callers clear caches first, then update flags.
    @MainActor
    @discardableResult
    func bumpAccountProfileGeneration(reason: String, accountId: UUID?) -> UInt64 {
        accountProfileGeneration &+= 1
        profileLoadTask?.cancel()
        profileLoadTask = nil
        profileLoadOwnerUserId = nil
        profileLoadOwnerGeneration = 0
        profileLoadTaskToken = nil
        lightweightStartupPrefetchTask?.cancel()
        lightweightStartupPrefetchTask = nil
        lastLightweightStartupPrefetchAt = nil
#if DEBUG
        AccountSwitchDebug.generation(accountProfileGeneration)
        _ = reason
        _ = accountId
#endif
        return accountProfileGeneration
    }

    @MainActor
    func clearLogoutProfilePresentationImmediately(for logoutAccountId: UUID?) {
        currentUserAvatarURL = ""
        currentUserAvatarThumbnailURL = ""
        currentUserDisplayName = ""
        currentUserUsername = ""
        currentUserBio = ""
        currentUserProfileBackgroundKey = .fangeo
        clearCurrentUserProfileLocalCache()
        resetProfilePresentationLoadStateForNewAuth()
        bumpCurrentUserAvatarDisplayRefresh()
#if DEBUG
        _ = logoutAccountId
#endif
    }

    @MainActor
    func cancelProfilePresentationLoadIfOwned(userId: UUID, generation: UInt64) {
        guard profileLoadContextStillValid(userId: userId, generation: generation) else { return }
        guard isUserProfileLoadingForPresentation else { return }
        guard !hasLoadedUserProfileForPresentation else { return }
        isUserProfileLoadingForPresentation = false
        AccountSwitchDebug.presentationLoadCancelledAndReset(accountId: userId, generation: generation)
    }

    @MainActor
    func clearProfileLoadTaskReferenceIfOwned(userId: UUID, generation: UInt64, taskToken: UUID) {
        guard profileLoadTaskToken == taskToken else {
            AccountSwitchDebug.staleTaskCompletionIgnored(accountId: userId, generation: generation, taskToken: taskToken)
            return
        }
        guard profileLoadOwnerUserId == userId, profileLoadOwnerGeneration == generation else {
            AccountSwitchDebug.staleTaskCompletionIgnored(accountId: userId, generation: generation, taskToken: taskToken)
            return
        }
        profileLoadTask = nil
        profileLoadOwnerUserId = nil
        profileLoadOwnerGeneration = 0
        profileLoadTaskToken = nil
        AccountSwitchDebug.profileTaskReferenceCleared(accountId: userId, generation: generation, taskToken: taskToken)
    }

    @MainActor
    func finalizeOwnedProfileLoadSession(
        userId: UUID,
        generation: UInt64,
        taskToken: UUID,
        applied: Bool
    ) {
        AccountSwitchDebug.profileTaskCompleted(accountId: userId, generation: generation, taskToken: taskToken)
        clearProfileLoadTaskReferenceIfOwned(userId: userId, generation: generation, taskToken: taskToken)
        if !applied {
            cancelProfilePresentationLoadIfOwned(userId: userId, generation: generation)
        }
    }

    @MainActor
    func startOwnedProfileLoad(userId: UUID, generation: UInt64, reason: String, allowRetry: Bool = true) {
        if let ownerId = profileLoadOwnerUserId,
           profileLoadOwnerGeneration == generation,
           ownerId == userId,
           let existing = profileLoadTask,
           !existing.isCancelled {
            return
        }
        beginProfilePresentationLoad()
        profileLoadOwnerUserId = userId
        profileLoadOwnerGeneration = generation
        let taskToken = UUID()
        profileLoadTaskToken = taskToken
        profileLoadTask?.cancel()
        let capturedUserId = userId
        let capturedGeneration = generation
        profileLoadTask = Task { [weak self] in
            await self?.scheduleAuthoritativeProfileLoad(
                userId: capturedUserId,
                generation: capturedGeneration,
                reason: reason,
                allowRetry: allowRetry,
                taskToken: taskToken
            )
        }
    }

    /// Begins a fan login session: bumps generation, clears stale caches, and starts one authoritative profile load.
    @MainActor
    func beginFanLoginSession(
        userId: UUID,
        reason: String,
        email: String,
        displayName: String = "",
        configure: () -> Void
    ) {
        guard !isDeletedAccountLoginBlocked else {
#if DEBUG
            print("[DeletedAccountLoginDebug] profileCreationPrevented reason=deleted_account_blockedSession")
#endif
            return
        }
        let generation = bumpAccountProfileGeneration(reason: reason, accountId: userId)
        AccountSwitchDebug.loginStarted(accountId: userId, generation: generation)
        clearAuthenticatedSessionCaches()
        resetProfilePresentationLoadStateForNewAuth()
        currentUserEmail = email
        currentUserDisplayName = displayName
        currentUserUsername = ""
        currentUserBio = ""
        currentUserIsBusinessAccount = false
        currentUserAvatarURL = ""
        currentUserAvatarThumbnailURL = ""
        configure()
        currentUserAuthId = userId
        startOwnedProfileLoad(userId: userId, generation: generation, reason: reason)
    }

    private func isProfileLoadCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if Task.isCancelled { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return true }
        return false
    }

    @MainActor
    private func profileLoadContextStillValid(userId: UUID, generation: UInt64) -> Bool {
        accountProfileGeneration == generation && currentUserAuthId == userId
    }

    private func scheduleAuthoritativeProfileLoad(
        userId: UUID,
        generation: UInt64,
        reason: String,
        allowRetry: Bool,
        taskToken: UUID
    ) async {
        var applied = await performProfileLoad(
            userId: userId,
            generation: generation,
            reason: reason,
            isRetry: false
        )
        if !applied, allowRetry, !Task.isCancelled {
            let shouldRetry = await MainActor.run {
                profileLoadContextStillValid(userId: userId, generation: generation)
                    && !hasLoadedUserProfileForPresentation
            }
            if shouldRetry {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if !Task.isCancelled {
                    let stillValid = await MainActor.run {
                        profileLoadContextStillValid(userId: userId, generation: generation)
                    }
                    if stillValid {
                        applied = await performProfileLoad(
                            userId: userId,
                            generation: generation,
                            reason: "\(reason).retry",
                            isRetry: true
                        )
                    }
                }
            }
        }

        await MainActor.run { [weak self] in
            self?.finalizeOwnedProfileLoadSession(
                userId: userId,
                generation: generation,
                taskToken: taskToken,
                applied: applied
            )
        }
    }

    @discardableResult
    private func performProfileLoad(
        userId: UUID,
        generation: UInt64,
        reason: String,
        isRetry: Bool
    ) async -> Bool {
        AccountSwitchDebug.profileLoadStarted(accountId: userId, generation: generation, reason: reason)

        let stillValidAtStart = await MainActor.run {
            profileLoadContextStillValid(userId: userId, generation: generation)
        }
        guard stillValidAtStart else {
            AccountSwitchDebug.profileLoadCancelled(
                accountId: userId,
                generation: generation,
                stale: true,
                reason: "startContextInvalid"
            )
            return false
        }

        let sessionResolution = await supabaseResolvedAuthSessionResult()
        if case .refreshFailed(let error) = sessionResolution {
            await MainActor.run {
                markAuthRefreshFailed(error, reason: "loadUserProfile")
                finishProfilePresentationLoad(profileExists: false, userId: userId, generation: generation)
            }
#if DEBUG
            print("[ProfilePersistenceDebug] profileLoadSkipped reason=authRefreshFailed")
#endif
            return false
        }

        if case .active(let session) = sessionResolution {
            guard session.user.id == userId else {
                AccountSwitchDebug.profileLoadCancelled(
                    accountId: userId,
                    generation: generation,
                    stale: true,
                    reason: "sessionUserMismatch"
                )
                return false
            }

            guard await checkCurrentUserAdminStatus() else {
                await MainActor.run {
                    finishProfilePresentationLoad(profileExists: false, userId: userId, generation: generation)
                }
                return false
            }

            let authId = session.user.id
#if DEBUG
            print("[ProfilePersistenceDebug] loadingProfileForUserId=\(authId.uuidString.lowercased())")
#endif
            do {
                try Task.checkCancellation()
                let rows: [UserProfileRow] = try await supabase
                    .from("user_profiles")
                    .select(Self.userProfileSelectColumns)
                    .eq("id", value: authId)
                    .limit(1)
                    .execute()
                    .value

                let stillValidAfterFetch = await MainActor.run {
                    profileLoadContextStillValid(userId: userId, generation: generation)
                }
                guard stillValidAfterFetch else {
                    AccountSwitchDebug.profileLoadCancelled(
                        accountId: userId,
                        generation: generation,
                        stale: true,
                        reason: "postFetchContextInvalid"
                    )
                    return false
                }

                if let profile = rows.first {
#if DEBUG
                    print("[ProfilePersistenceDebug] existingProfileFound=true")
                    ProfileAvatarDebug.profileFetchDecoded(
                        userId: authId,
                        rawAvatarURL: profile.avatar_url,
                        rawAvatarThumbnailURL: profile.avatar_thumbnail_url,
                        profileFound: true
                    )
#endif
                    if profile.isDeletedAccount {
                        if await shouldSuppressDeletedProfileBlockForBusinessSession(
                            session: session,
                            context: "loadUserProfile"
                        ) {
                            await MainActor.run {
                                finishProfilePresentationLoad(profileExists: false, userId: userId, generation: generation)
                            }
                            return false
                        }
                        await handleDeletedCurrentUser()
                        await MainActor.run {
                            finishProfilePresentationLoad(profileExists: false, userId: userId, generation: generation)
                        }
                        return false
                    }
                    let applied = await MainActor.run { () -> Bool in
                        guard profileLoadContextStillValid(userId: userId, generation: generation) else {
                            return false
                        }
                        if applyLoadedUserProfileRow(profile, authId: authId, generation: generation) {
                            finishProfilePresentationLoad(profileExists: true, userId: userId, generation: generation)
                            AccountSwitchDebug.profileResultApplied(
                                accountId: userId,
                                generation: generation,
                                profileExists: true
                            )
                            return true
                        }
                        return false
                    }
#if DEBUG
                    print("[ProfileDiscoverabilityDebug] loaded=\(profile.discoverableByFans)")
#endif
                    if applied {
                        print("USER PROFILE LOADED")
                        await refreshProfileXP()
                    }
                    return applied
                }

#if DEBUG
                print("[ProfilePersistenceDebug] existingProfileFound=false")
#endif
                await MainActor.run {
                    finishProfilePresentationLoad(profileExists: false, userId: userId, generation: generation)
                    AccountSwitchDebug.profileResultApplied(
                        accountId: userId,
                        generation: generation,
                        profileExists: false
                    )
                }
                print("NO USER PROFILE FOUND")
                return false
            } catch {
                if isProfileLoadCancellation(error) {
                    AccountSwitchDebug.profileLoadCancelled(
                        accountId: userId,
                        generation: generation,
                        stale: !isRetry,
                        reason: error.localizedDescription
                    )
#if DEBUG
                    print("[ProfilePersistenceDebug] profileDecodeFailed=\(error.localizedDescription)")
#endif
                    return false
                }
#if DEBUG
                print("[ProfilePersistenceDebug] profileDecodeFailed=\(error.localizedDescription)")
#endif
                await MainActor.run {
                    finishProfilePresentationLoad(profileExists: false, userId: userId, generation: generation)
                }
                print("ERROR LOADING USER PROFILE:", error)
                return false
            }
        }

        return false
    }

    func clearAuthenticatedSessionCaches(
        expectedGeneration: UInt64? = nil,
        logoutAccountId: UUID? = nil
    ) {
        if let expectedGeneration {
            guard accountProfileGeneration == expectedGeneration else {
                AccountSwitchDebug.staleCleanupIgnored(
                    oldAccountId: logoutAccountId,
                    currentAccountId: currentUserAuthId,
                    expectedGeneration: expectedGeneration,
                    currentGeneration: accountProfileGeneration
                )
                return
            }
            AccountSwitchDebug.logoutCleanup(accountId: logoutAccountId, generation: expectedGeneration)
        }

#if DEBUG
        if MemoryAuditProbe.isEnabled {
            let store = fanUpdatesStore
            MemoryAuditProbe.log(
                "logout_before_clear",
                details: "commentsEvents=\(store.venueEventComments.count) vibes=\(store.venueEventVibeCounts.count) appChannel=\(store.fanChatAppLevelRealtimeChannel != nil) warmTask=\(userPreferencesWarmCacheTask != nil) goingPrefetch=\(fanUpdatesGoingProfilePrefetchTasks.count) socialPrefetch=\(discoverVisibleSocialPrefetchTasksByKey.count) dashPreload=\(businessDashboardPreloadTask != nil) fanXPQueue=\(fanXPRewardOverlay.debugQueuedCount) predictionVenue=\(venueEventPredictionSummaries.count) predictionPro=\(proGamePredictionSummaries.count)"
            )
        }
#endif

        profileLoadTask?.cancel()
        profileLoadTask = nil
        profileLoadOwnerUserId = nil
        profileLoadOwnerGeneration = 0
        profileLoadTaskToken = nil
        currentUserEmail = ""
        currentUserDisplayName = ""
        currentUserUsername = ""
        currentUserBio = ""
        currentUserProfileCreatedAt = ""
        currentUserIsBusinessAccount = false
        isBusinessOwnerSessionRestorePending = false
        deferredBusinessOwnerHydrationTask?.cancel()
        deferredBusinessOwnerHydrationTask = nil
        activeBusinessAccountBan = nil
        isBusinessBanGatePresented = false
        isCheckingActiveBusinessBan = false
        currentUserFanXP = .rookie
        currentUserFanIdentityPreferences = .empty
        fanIdentityPreferencesLoadTask?.cancel()
        fanIdentityPreferencesLoadTask = nil
        lastFanIdentityPreferencesLoadAt = nil
        lastFanIdentityPreferencesLoadUserId = nil
        lastMyPickupOrganizerSummaryRefreshAt = nil
        currentUserHomeCrowdVenueId = nil
        currentUserHomeCrowdVenue = nil
        discoverFocusVenueId = nil
        currentUserAvatarURL = ""
        currentUserAvatarThumbnailURL = ""
        currentUserNationalTeam = nil
        currentUserHomeCity = ""
        currentUserHomeRegion = ""
        currentUserHomeCountry = ""
        currentUserShowHomeCity = false
        currentUserProfileBackgroundKey = .fangeo
        currentUserLiveVisibilityEnabled = true
        currentUserLiveVisibilityMode = .allFriends
        currentUserSelectedLiveVisibilityFriendIDs = []
        currentUserDiscoverableByFans = true
        currentUserActivityStatusVisible = true
        isUpdatingLiveVisibilitySetting = false
        isUpdatingProfileDiscoverabilitySetting = false
        isUpdatingActivityStatusVisibilitySetting = false
        currentUserAuthId = nil
        FanGeoUserEntitlements.reset()
        clearUnseenPokesBadgeState()
        clearPendingPokeNotificationDeepLink()
        clearPostSignupPresentation(reason: "clearAuthenticatedSessionCaches")
        emailVerifiedSignInNotice = ""
        dismissPublicProfile()
        ProfilePhase1PersonalizationCache.clear(for: nil)

        Task { await GameReminderNotificationService.shared.cancelAllProGameReminders() }
        Task { await GameReminderNotificationService.shared.cancelAllPickupCreatorRatingReminders() }
        savedProGames = []
        favoriteTeamProGames = []
        favoriteTeamProGameAlertOverrides = [:]
        FavoriteTeamsStore.clearAppStorage()
        favoriteTeamsHydrationGeneration &+= 1
        clearBusinessFavoriteTeamState()
        favoriteVenueIDs = []
        interestedVenueEventKeys = []
        favoriteVenueWriteInFlightIDs = []
        venueEventInterestWriteInFlightIDs = []
        recentlyConfirmedVenueEventGoingAt = [:]
        recentlyConfirmedVenueEventNotGoingAt = [:]
        venueEventInterestIDs = []
        venueEventInterestCounts = [:]
        venueGameCardInitialGoingRefreshTask?.cancel()
        venueGameCardInitialGoingRefreshTask = nil
        venueGameCardInitialGoingRefreshLastIDs = []
        venueGameCardSnapshotStore.reset()
        socialActionToastDismissTask?.cancel()
        socialActionToastDismissTask = nil
        socialActionToastText = nil
        socialActionToastIsError = false
        followingMapNavigationMessage = nil
        pendingFollowingMapPickupGameID = nil
        pendingFollowingMapPickupGameSnapshot = nil
        isRoutingPickupGameFromChatGroupInfo = false
        clearFollowingTabCaches()
        clearFollowingInterestedOnlyDefaults()
        // Live sessions are stopped in forceLogout before auth invalidation.
        // Clear residual local cache only (never restart GPS / never network stop here).
        ChatLiveLocationManager.shared.clearLocalLiveLocationStateAfterLogout()
        pendingPickupCreatorRatingNotificationDeepLink = nil
        pendingPickupPlayingHighlightGameID = nil
        pendingSharedPickupGameDetailToken = nil
        pendingSharedProGameDetailMatch = nil
        clearPendingSaveProGameIntent()
        presentSaveProGameSignInPrompt = false

        goingUserProfiles = []
        goingProfilesByVenueEventID = [:]
        // Keep public pickup pins on Discover after sign-out; refresh will reconcile from Supabase.
        markPickupDiscoverMapDataDirtyForNextRefresh()
        selectedPickupGameForMap = nil
        myPickupGamesForSettings = []
        myRemovedPickupGamesForSettings = []
        pickupOrganizerJoinStatsByGameId = [:]
        pickupOrganizerWithdrawnRequestsByGameId = [:]
        pickupOrganizerApprovedJoinerUserIdsByGameId = [:]
        lightweightStartupPrefetchTask?.cancel()
        lightweightStartupPrefetchTask = nil
        lastLightweightStartupPrefetchAt = nil
        favoriteVenueIDsLoadTask?.cancel()
        favoriteVenueIDsLoadTask = nil
        lastFavoriteVenueIDsLoadAt = nil
        favoriteTeamsLoadTask?.cancel()
        favoriteTeamsLoadTask = nil
        lastFavoriteTeamsLoadAt = nil
        followingTodayPlansLoadTask?.cancel()
        followingTodayPlansLoadTask = nil
        lastFollowingTodayPlansLoadAt = nil
        followingTabGlobalRefreshTask?.cancel()
        followingTabGlobalRefreshTask = nil
        followingJoinRequestsLoadTask?.cancel()
        followingJoinRequestsLoadTask = nil
        myPickupGamesLightweightLoadTask?.cancel()
        myPickupGamesLightweightLoadTask = nil
        lastMyPickupGamesLightweightLoadAt = nil
        incomingPickupInvitesLoadTask?.cancel()
        incomingPickupInvitesLoadTask = nil
        lastIncomingPickupInvitesLoadAt = nil
        lastPickupInviteForegroundRefreshAt = nil
        unseenPokesBadgeRefreshTask?.cancel()
        unseenPokesBadgeRefreshTask = nil
        lastUnseenPokesBadgeRefreshAt = nil
        lastUnseenPokesBadgeRefreshUserId = nil
        pendingPickupJoinRequestCountLoadTask?.cancel()
        pendingPickupJoinRequestCountLoadTask = nil
        lastPendingPickupJoinRequestCountLoadAt = nil
        lastPendingPickupJoinRequestCountUserId = nil
        pendingPickupGameJoinRequestCount = 0
        myPickupGameJoinRequestCards = []
        incomingPickupGameInvites = []
        pickupGamesFollowingTabCache.removeAll()
        pickupJoinRequestLatestByPickupGameIdForFan.removeAll()
        pickupCreatorPublicRatingStatsByUserId = [:]
        pickupOrganizerSummaryByUserId = [:]
        pickupOrganizerSummaryFetchedAtByUserId = [:]
        pickupOrganizerSummaryInFlightUserIds = []
        pickupOrganizerSummaryFetchGenerationByUserId = [:]
        myPickupOrganizerSummary = .empty
        myPickupOrganizerSummaryLoadedForUserId = nil
        pickupGameIdsWithMyCreatorRating = []
        pickupMyCreatorRatingValueByGameId = [:]
        pickupMyCreatorRatingCreatedAtByGameId = [:]
        pickupCreatorRatingPostSubmitPromptGameIds = []
        pickupCreatorRatingDeferredGameIds = []
        pickupCreatorRatingSessionUserId = nil
        pickupMyLatestJoinRequestByGameId = [:]
        clearPickupGameRosterCaches()
        pickupCreatorDisplayNameByUserId = [:]
        pickupCreatorAvatarThumbnailURLByUserId = [:]
        pickupCreatorAvatarURLByUserId = [:]
        pickupCreatorEmailByUserId = [:]
        pickupCreatorAvatarTokenByUserId = [:]
        commentIDsReportedByCurrentUser = []
        userProfilesByEmail = [:]
        myVenueEventVibes = [:]
        venueEventVibeWriteInFlightKeys = []
        venueUserStarRatings = [:]
        venueRatingContributionCount = [:]
        venueRatingStatsByVenueId = [:]

        // Memory: cancel orphan session Tasks and drop regenerable user-scoped Fan Updates state.
        // Realtime channels for comments/pickup/fan-chat are already torn down in ``forceLogout``
        // *before* signOut; this Task is a best-effort residual cleanup for other call sites.
        userPreferencesWarmCacheTask?.cancel()
        userPreferencesWarmCacheTask = nil
        for task in fanUpdatesGoingProfilePrefetchTasks.values { task.cancel() }
        fanUpdatesGoingProfilePrefetchTasks.removeAll(keepingCapacity: false)
        for task in discoverVisibleSocialPrefetchTasksByKey.values { task.cancel() }
        discoverVisibleSocialPrefetchTasksByKey.removeAll(keepingCapacity: false)
        fanXPRewardOverlay.clearAll()
        venueEventPredictionSummaries.removeAll(keepingCapacity: false)
        proGamePredictionSummaries.removeAll(keepingCapacity: false)
        fanUpdatesStore.clearSessionScopedStateForLogout()
        Task { await ProfileStatsService.shared.clearAll() }
        ProGamePredictionService.shared.clearAllCachedSummaries()
        VenueEventPredictionService.shared.clearAllCachedSummaries()

        Task { [weak self] in
            await self?.removeAllVenueEventCommentsRealtimeListeners()
            await self?.stopFanChatAppLevelRealtime()
            await self?.stopPickupJoinRequestBadgeRealtime()
            await self?.stopFollowingPickupRealtime()
            await self?.stopPickupInviteRealtime()
#if DEBUG
            if MemoryAuditProbe.isEnabled {
                MemoryAuditProbe.log(
                    "logout_after_clear",
                    details: "commentsEvents=\(self?.fanUpdatesStore.venueEventComments.count ?? -1) appChannel=\(self?.fanUpdatesStore.fanChatAppLevelRealtimeChannel != nil)"
                )
            }
#endif
        }

        venueOwnerEmail = ""
        ownerVenueDatabaseId = nil
        isVenueOwnerBusinessDataLoading = false
        clearVenueOwnerOwnedBusinessCaches()
        venueClaimSubmitted = false
        venueClaimStatus = "Not submitted"
        venueIsApproved = false
        venueClaimSubmittedDate = ""
        venueOwnerJustCompletedRegistration = false
        hasUnackedRejectedVenueClaimForOwnerEmail = false
        approvedVenueOwnershipByVenueID = [:]
        venueBusinessEmail = ""
        venueClaims = []

        reportedComments = []
        reportedCommentDisplays = []

        authErrorMessage = ""
        notificationPermissionMessage = ""
        userPasswordResetMessage = ""
        userPasswordResetError = ""
        passwordResetUpdateMessage = ""
        passwordResetUpdateError = ""
        applePendingFanSignupEmail = ""
        applePendingFanSignupDisplayName = ""
        appleFanOnboardingPasswordBypassActive = false
        applePendingBusinessSignupEmail = ""
        applePendingBusinessSignupDisplayName = ""
        appleAuthFanMessage = ""
        appleAuthFanMessageIsError = false
        appleAuthBusinessMessage = ""
        appleAuthBusinessMessageIsError = false
        appleAuthFanMessageAutoClearTask?.cancel()
        appleAuthBusinessMessageAutoClearTask?.cancel()
        appleAuthFanMessageAutoClearTask = nil
        appleAuthBusinessMessageAutoClearTask = nil
        venueAuthErrorMessage = ""
        venuePasswordResetMessage = ""
        venuePasswordResetError = ""

        bumpCurrentUserAvatarDisplayRefresh()
        clearCurrentUserProfileLocalCache()
        discoverCalendarGuestUserPinnedDateThisSession = false
        privateSessionClearNonce = UUID()
    }

    /// Sign-out/session-loss cleanup for venue-owner drafts and claim context in addition to the shared cache reset.
    func clearVenueOwnerDraftState() {
        clearPendingVenueClaimContext()
        ownerVenueName = ""
        ownerVenueAddress = ""
        ownerVenueAddressLine2 = ""
        ownerVenueCity = ""
        ownerVenueState = ""
        ownerVenueZipCode = ""
        ownerVenueCountry = BusinessLocationCountryPolicy.defaultCountryCode
        ownerVenueSupporterCountry = ""
        ownerVenuePhoneDialISO = BusinessPhoneFields.defaultISO
        ownerVenuePhone = ""
        ownerVenueWebsite = ""
        ownerVenueDescription = ""
        ownerVenueFeatures = ""
        ownerVenuePrimarySport = "Soccer"
        ownerVenueScreenCount = 1
        ownerVenueServesFood = false
        ownerVenueHasWifi = false
        ownerVenueHasGarden = false
        ownerVenueHasProjector = false
        ownerVenuePetFriendly = false
        venueCoverPhotoURL = ""
        venueCoverPhotoThumbnailURL = ""
        venueCrowdPhotoURL = ""
        venueTVWallPhotoURL = ""
        venueMenuPhotoURL = ""
        venueMenuPhotoThumbnailURL = ""
        venueSpecialsPhotoURL = ""
        venueProofNote = ""
        switchToAccountForVenueClaim = false
        openVenueOwnerAuthSheetFromClaimFlow = false
    }

    /// Persists the account mode and, when a Supabase session exists, the auth user id (so a different account on the same device does not restore the wrong mode).
    func persistAccountModeForActiveAuthSession(_ mode: StoredAccountMode) async {
        let uid: String?
        switch await supabaseResolvedAuthSessionResult() {
        case .active(let session):
            uid = session.user.id.uuidString.lowercased()
        case .missingSession:
            uid = nil
        case .refreshFailed(let error):
            await MainActor.run {
                markAuthRefreshFailed(error, reason: "persistAccountMode")
            }
            uid = await MainActor.run {
                currentUserAuthId?.uuidString.lowercased()
            }
        }
        await MainActor.run {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.storedAccountModeKey)
            if let uid {
                UserDefaults.standard.set(uid, forKey: Self.storedAccountAuthUserIdKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.storedAccountAuthUserIdKey)
            }
        }
    }

    /// Legacy venue-owner logout entry point. Full account-tab logout uses the centralized Supabase teardown.
    func venueOwnerLocalSignOutPreservingSupabaseSession() {
        Task {
            await forceLogout(
                reason: "venueOwnerLocalSignOutPreservingSupabaseSession",
                source: "MapViewModel.venueOwnerLocalSignOutPreservingSupabaseSession"
            )
        }
    }

    func adminDashboardLoginTapped() {
        isAdminLoggedIn = true
        Task {
            await persistAccountModeForActiveAuthSession(.admin)
            await refreshLiveOperationsPresenceMetrics()
            await refreshAdminBusinessVenueOverrides()
        }
    }

    func adminDashboardLogoutTapped() {
        isAdminLoggedIn = false
        liveOperationsPresenceMetrics = .empty
        adminBusinessVenueOverrideSummaries = []
        adminBusinessVenueOverrideMessage = ""
        Task {
            await persistAccountModeForActiveAuthSession(.fanUser)
        }
    }

    func refreshLiveOperationsPresenceMetrics() async {
        guard isAdminLoggedIn else { return }
        do {
            let rows: [LiveOperationsPresenceMetrics] = try await supabase
                .rpc("get_live_operations_presence_metrics")
                .execute()
                .value
            await MainActor.run {
                liveOperationsPresenceMetrics = rows.first ?? .empty
            }
#if DEBUG
            print("[PresenceDebug] liveOpsMetricsLoaded=true")
#endif
        } catch {
#if DEBUG
            print("[PresenceDebug] liveOpsMetricsFailed=\(error.localizedDescription)")
#endif
        }
    }

    func refreshAdminBusinessVenueOverrides() async {
        guard isAdminLoggedIn else { return }
        await MainActor.run {
            isLoadingAdminBusinessVenueOverrides = true
            adminBusinessVenueOverrideMessage = ""
        }
        do {
            struct Params: Encodable {
                let p_admin_email: String
            }
            let rows: [AdminBusinessVenueOverrideSummary] = try await supabase
                .rpc("admin_business_venue_override_summaries", params: Params(p_admin_email: adminEmail))
                .execute()
                .value
            await MainActor.run {
                adminBusinessVenueOverrideSummaries = rows
                isLoadingAdminBusinessVenueOverrides = false
            }
#if DEBUG
            print("[AdminVenueOverrideDebug] summariesLoaded count=\(rows.count)")
#endif
        } catch {
            await MainActor.run {
                isLoadingAdminBusinessVenueOverrides = false
                adminBusinessVenueOverrideMessage = "Could not load business venue overrides."
            }
#if DEBUG
            print("[AdminVenueOverrideDebug] summariesFailed error=\(error.localizedDescription) reflected=\(String(reflecting: error))")
#endif
        }
    }

    func loadAdminBusinessOverrideVenues(businessId: UUID) async -> [AdminBusinessVenueOverrideVenue] {
        guard isAdminLoggedIn else { return [] }
        do {
            struct Params: Encodable {
                let p_business_id: UUID
                let p_admin_email: String
            }
            let rows: [AdminBusinessVenueOverrideVenue] = try await supabase
                .rpc("admin_business_venue_override_venues", params: Params(
                    p_business_id: businessId,
                    p_admin_email: adminEmail
                ))
                .execute()
                .value
#if DEBUG
            print("[AdminVenueOverrideDebug] venuesLoaded businessId=\(businessId.uuidString.lowercased()) count=\(rows.count)")
#endif
            return rows
        } catch {
#if DEBUG
            print("[AdminVenueOverrideDebug] venuesFailed businessId=\(businessId.uuidString.lowercased()) error=\(error.localizedDescription) reflected=\(String(reflecting: error))")
#endif
            return []
        }
    }

    @discardableResult
    func setAdminBusinessActiveVenueLimitOverride(businessId: UUID, override: Int) async -> Bool {
        guard isAdminLoggedIn else { return false }
        do {
            struct Params: Encodable {
                let p_business_id: UUID
                let p_admin_email: String
                let p_override: Int
            }
            try await supabase
                .rpc("admin_set_business_active_venue_limit_override", params: Params(
                    p_business_id: businessId,
                    p_admin_email: adminEmail,
                    p_override: override
                ))
                .execute()
            await refreshAdminBusinessVenueOverrides()
#if DEBUG
            print("[AdminVenueOverrideDebug] setOverride businessId=\(businessId.uuidString.lowercased()) override=\(override) saved=true")
#endif
            return true
        } catch {
#if DEBUG
            print("[AdminVenueOverrideDebug] setOverride businessId=\(businessId.uuidString.lowercased()) override=\(override) saved=false error=\(error.localizedDescription) reflected=\(String(reflecting: error))")
#endif
            return false
        }
    }

    @discardableResult
    func clearAdminBusinessActiveVenueLimitOverride(businessId: UUID) async -> Bool {
        guard isAdminLoggedIn else { return false }
        do {
            struct Params: Encodable {
                let p_business_id: UUID
                let p_admin_email: String
            }
            try await supabase
                .rpc("admin_clear_business_active_venue_limit_override", params: Params(
                    p_business_id: businessId,
                    p_admin_email: adminEmail
                ))
                .execute()
            await refreshAdminBusinessVenueOverrides()
#if DEBUG
            print("[AdminVenueOverrideDebug] clearOverride businessId=\(businessId.uuidString.lowercased()) saved=true")
#endif
            return true
        } catch {
#if DEBUG
            print("[AdminVenueOverrideDebug] clearOverride businessId=\(businessId.uuidString.lowercased()) saved=false error=\(error.localizedDescription) reflected=\(String(reflecting: error))")
#endif
            return false
        }
    }

    @discardableResult
    func setAdminBusinessVenueActivation(businessId: UUID, venueId: UUID, active: Bool) async -> Bool {
        guard isAdminLoggedIn else { return false }
        do {
            struct Params: Encodable {
                let p_business_id: UUID
                let p_venue_id: UUID
                let p_admin_email: String
                let p_active: Bool
            }
            try await supabase
                .rpc("admin_set_business_venue_activation", params: Params(
                    p_business_id: businessId,
                    p_venue_id: venueId,
                    p_admin_email: adminEmail,
                    p_active: active
                ))
                .execute()
            await refreshAdminBusinessVenueOverrides()
#if DEBUG
            print("[AdminVenueActivationDebug] businessId=\(businessId.uuidString.lowercased()) venueId=\(venueId.uuidString.lowercased()) active=\(active) saved=true")
#endif
            return true
        } catch {
#if DEBUG
            print("[AdminVenueActivationDebug] businessId=\(businessId.uuidString.lowercased()) venueId=\(venueId.uuidString.lowercased()) active=\(active) saved=false error=\(error.localizedDescription) reflected=\(String(reflecting: error))")
#endif
            return false
        }
    }

    private static let userProfileSelectColumns =
        "id,email,display_name,username,bio,avatar_url,avatar_thumbnail_url,is_business_account,admin_status,live_visibility_enabled,live_visibility_mode,selected_live_visibility_friend_ids,discoverable_by_fans,activity_status_visible,is_deleted,created_at,last_seen_at,national_team_country_code,national_team_country_name,national_team_flag,national_team_supporter_label,national_team_updated_at,ad_free_enabled,home_city,home_region,home_country,show_home_city,profile_background_key"

    private static let userProfileIdentitySelectColumns =
        "id,email,display_name,username,bio,avatar_url,avatar_thumbnail_url,is_deleted,national_team_country_code,national_team_country_name,national_team_flag,national_team_supporter_label,national_team_updated_at,profile_background_key"

    private struct UserProfileIdentityRow: Decodable {
        let id: UUID?
        let email: String?
        let display_name: String?
        let username: String?
        let bio: String?
        let avatar_url: String?
        let avatar_thumbnail_url: String?
        let is_deleted: Bool?
        let national_team_country_code: String?
        let national_team_country_name: String?
        let national_team_flag: String?
        let national_team_supporter_label: String?
        let national_team_updated_at: String?
    }

    private static func logPostgrestError(_ prefix: String, _ error: Error) {
        print("\(prefix):", error)
        if let pe = error as? PostgrestError {
            print(
                "\(prefix) PostgrestError code=\(pe.code ?? "nil") message=\(pe.message) detail=\(pe.detail ?? "nil") hint=\(pe.hint ?? "nil")"
            )
        }
        let ns = error as NSError
        print("\(prefix) NSError domain=\(ns.domain) code=\(ns.code) userInfo=\(ns.userInfo)")
    }

    @MainActor
    func transitionAuthSessionState(_ newState: FanGeoAuthSessionState, reason: String) {
        let oldState = authSessionState
        guard oldState != newState else {
#if DEBUG
            print("[AuthStateDebug] authStateTransition=\(oldState.rawValue)->\(newState.rawValue) reason=\(reason) unchanged=true")
#endif
            return
        }
        authSessionState = newState
#if DEBUG
        print("[AuthStateDebug] authStateTransition=\(oldState.rawValue)->\(newState.rawValue) reason=\(reason)")
#endif
    }

    @MainActor
    private func markAuthSignedOut(reason: String) {
        transitionAuthSessionState(.signedOut, reason: reason)
    }

    @MainActor
    private func markAuthSignedIn(reason: String) {
        guard !isDeletedAccountLoginBlocked else {
#if DEBUG
            print("[DeletedAccountLoginDebug] mainAppEntryBlocked reason=deleted_account_staleSignedInTask")
#endif
            return
        }
        guard !isDeletedBusinessLoginBlocked else {
#if DEBUG
            print("[DeletedBusinessLoginDebug] dashboardEntryBlocked reason=deleted_business_staleSignedInTask")
#endif
            return
        }
        transitionAuthSessionState(.signedIn, reason: reason)
    }

    @MainActor
    private func markAuthRefreshFailed(_ error: Error, reason: String) {
        transitionAuthSessionState(.authRefreshFailed, reason: reason)
#if DEBUG
        print("[AuthStateDebug] tokenRefreshFailed=true reason=\(reason) error=\(error.localizedDescription)")
#endif
    }

    private func logForcedLogoutReason(_ reason: String) {
#if DEBUG
        print("[AuthStateDebug] forcedLogoutReason=\(reason)")
#endif
    }

    /// Cancels authenticated Realtime listen tasks and detaches channel removal so logout never
    /// waits forever on websocket unsubscribe acknowledgements or `for await` streams.
    /// Normal UI leave-paths still use the awaited ``stop*`` helpers (which now removeChannel
    /// *before* awaiting task completion).
    @MainActor
    private func abandonAuthenticatedRealtimeForLogout() {
        SafeLogoutDebug.step("abandon_realtime_begin")

        var channels: [RealtimeChannelV2] = []

        venueOwnerAnalyticsDebounceTask?.cancel()
        venueOwnerAnalyticsDebounceTask = nil
        venueOwnerAnalyticsRealtimeTask?.cancel()
        venueOwnerAnalyticsRealtimeTask = nil
        if let ch = venueOwnerAnalyticsRealtimeChannel {
            channels.append(ch)
            venueOwnerAnalyticsRealtimeChannel = nil
        }

        fanChatAppLevelRealtimeResubscribeTask?.cancel()
        fanChatAppLevelRealtimeResubscribeTask = nil
        fanChatAppLevelRealtimeTask?.cancel()
        fanChatAppLevelRealtimeTask = nil
        fanUpdatesStore.crowdReactionVibeRealtimeRefreshTask?.cancel()
        fanUpdatesStore.crowdReactionVibeRealtimeRefreshTask = nil
        if let ch = fanChatAppLevelRealtimeChannel {
            channels.append(ch)
            fanChatAppLevelRealtimeChannel = nil
        }
        fanChatAppLevelRealtimeTrackedEventIDs = []

        pickupInviteRealtimeDebounceTask?.cancel()
        pickupInviteRealtimeDebounceTask = nil
        pickupInviteRealtimeTask?.cancel()
        pickupInviteRealtimeTask = nil
        pickupInviteRealtimeBoundUserId = nil
        if let ch = pickupInviteRealtimeChannel {
            channels.append(ch)
            pickupInviteRealtimeChannel = nil
        }

        pickupJoinRequestBadgeDebounceTask?.cancel()
        pickupJoinRequestBadgeDebounceTask = nil
        pickupJoinRequestBadgeRealtimeTask?.cancel()
        pickupJoinRequestBadgeRealtimeTask = nil
        pickupJoinRequestBadgeRealtimeOwnerUserId = nil
        pickupJoinRequestBadgeRealtimeTrackedGameIds = nil
        if let ch = pickupJoinRequestBadgeRealtimeChannel {
            channels.append(ch)
            pickupJoinRequestBadgeRealtimeChannel = nil
        }

        pickupFollowingRealtimeDebounceTask?.cancel()
        pickupFollowingRealtimeDebounceTask = nil
        pickupFollowingRealtimeTask?.cancel()
        pickupFollowingRealtimeTask = nil
        if let ch = pickupFollowingRealtimeChannel {
            channels.append(ch)
            pickupFollowingRealtimeChannel = nil
        }

        fanSingleSessionRealtimeDebounceTask?.cancel()
        fanSingleSessionRealtimeDebounceTask = nil
        fanSingleSessionRealtimeTask?.cancel()
        fanSingleSessionRealtimeTask = nil
        if let ch = fanSingleSessionRealtimeChannel {
            channels.append(ch)
            fanSingleSessionRealtimeChannel = nil
        }

        let commentIDs = Array(
            Set(venueEventCommentsRealtimeTasks.keys)
                .union(venueEventCommentsRealtimeChannels.keys)
                .union(venueEventCommentsRealtimeListenerTokens.keys)
        )
        for venueEventID in commentIDs {
            venueEventCommentsRealtimeTasks[venueEventID]?.cancel()
            venueEventCommentsRealtimeTasks[venueEventID] = nil
            venueEventCommentsRealtimeListenerTokens[venueEventID] = nil
            venueEventCommentsRealtimeReadyIDs.remove(venueEventID)
            venueEventCommentsRealtimeSubscribeStartedAt[venueEventID] = nil
            venueEventCommentsRealtimeLastEventAt[venueEventID] = nil
            if let ch = venueEventCommentsRealtimeChannels.removeValue(forKey: venueEventID) {
                channels.append(ch)
            }
        }

        let channelCount = channels.count
        for channel in channels {
            Task {
                await supabase.removeChannel(channel)
            }
        }
        SafeLogoutDebug.step(
            "abandon_realtime_dispatched",
            detail: "channelCount=\(channelCount) commentSheets=\(commentIDs.count)"
        )
    }

    @discardableResult
    func forceLogout(reason: String, source: String) async -> Bool {
        let destructiveAllowed = destructiveLogoutAllowed(reason: reason, source: source)
        logBusinessLogoutTrace("forceLogoutCalled reason=\(reason)")
        logBusinessLogoutTrace("destructiveLogoutAllowed=\(destructiveAllowed)")
        logBusinessLogoutTrace("didExplicitlyLogout=\(UserDefaults.standard.bool(forKey: Self.didExplicitlyLogoutKey))")
        logBusinessLogoutTrace("storedAccountMode=\(storedAccountModeDebugValue())")
        guard destructiveAllowed else {
            logBusinessLogoutTrace("supabaseSignOutCalled=false")
            await markTransientMissingSessionPreserved(reason: reason, source: source)
            return false
        }

        SafeLogoutDebug.step("forceLogout_enter", detail: "reason=\(reason) source=\(source)")

        let (logoutAccountId, cleanupGeneration) = await MainActor.run { () -> (UUID?, UInt64) in
            AgeAccessGateService.shared.handleLogoutOrAccountSwitch()
            let accountId = currentUserAuthId
            let generation = bumpAccountProfileGeneration(reason: reason, accountId: accountId)
            clearLogoutProfilePresentationImmediately(for: accountId)
            return (accountId, generation)
        }
        SafeLogoutDebug.step("generation_bumped", detail: "accountId=\(logoutAccountId?.uuidString.lowercased() ?? "nil")")

        let snapshot = await MainActor.run {
            (
                currentUserId: currentUserAuthId?.uuidString.lowercased() ?? "nil",
                currentEmail: currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? venueOwnerEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                    : currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines),
                authState: authSessionState.rawValue
            )
        }

        print("[AuthForceLogoutDebug] reason=\(reason)")
        print("[AuthForceLogoutDebug] source=\(source)")
        print("[AuthForceLogoutDebug] currentUserId=\(snapshot.currentUserId)")
        print("[AuthForceLogoutDebug] currentEmail=\(snapshot.currentEmail.isEmpty ? "nil" : snapshot.currentEmail)")
        print("[AuthForceLogoutDebug] authState=\(snapshot.authState)")
        print("[AuthForceLogoutDebug] callStack=\(Thread.callStackSymbols.joined(separator: " | "))")

        // Tear down Realtime *before* signOut, without awaiting websocket unsubscribe acks.
        // Awaiting listen-task completion before removeChannel (or awaiting removeChannel on a
        // dying socket after signOut) was the logout hang root cause.
        SafeLogoutDebug.step("realtime_teardown_begin")
        await MainActor.run {
            abandonAuthenticatedRealtimeForLogout()
        }
        SafeLogoutDebug.step("realtime_teardown_completed")

        // Stop live-location shares while JWT is still valid (bounded). Local GPS ends first.
        SafeLogoutDebug.step("live_location_stop_begin")
        await ChatLiveLocationManager.shared.stopOutgoingSessionsBeforeAuthInvalidation()
        SafeLogoutDebug.step("live_location_stop_completed")

        SafeLogoutDebug.step("push_token_delete_begin")
        // Best-effort: never block logout on PostgREST / network for token deletion.
        let pushUserId = logoutAccountId
        Task {
            await PushNotificationRegistrationService.shared.deleteCurrentTokenForCurrentSession(
                reason: "forceLogout",
                knownUserId: pushUserId
            )
            SafeLogoutDebug.step("push_token_delete_completed_background")
        }
        SafeLogoutDebug.step("push_token_delete_dispatched")

        // Never call the awaited stopFanSingleSessionRealtime / clearFanActiveSessionOnLogout
        // path from explicit logout — removeChannel + task.result can hang forever, and a
        // lifecycle race can recreate the channel between abandonRealtime and this step.
        SafeLogoutDebug.step("single_session_clear_begin")
        await MainActor.run {
            abandonFanSingleSessionForLogout(knownUserId: logoutAccountId)
        }
        SafeLogoutDebug.step("single_session_clear_completed")

        // Local session invalidation must ALWAYS complete for the UI to leave loggingOut, and
        // must never await the Supabase `/logout` network call. Remote revocation is dispatched
        // separately as best effort and can never keep the overlay up.
        SafeLogoutDebug.step("local_supabase_session_invalidation_begin")
        let localResult = await invalidateLocalAuthenticatedSessionForExplicitLogout(
            logoutAccountId: logoutAccountId,
            generation: cleanupGeneration
        )
        await MainActor.run { safeLogoutLocalSessionInvalidated = localResult.succeeded }
        SafeLogoutDebug.step("local_supabase_session_invalidation_completed", detail: "result=\(localResult)")

        SafeLogoutDebug.step("local_fangeo_auth_clear_begin")
        SafeLogoutDebug.step("clear_session_caches_begin")
        await MainActor.run {
            clearAuthenticatedSessionCaches(
                expectedGeneration: cleanupGeneration,
                logoutAccountId: logoutAccountId
            )
            clearVenueOwnerDraftState()
            isLoggedIn = false
            isVenueOwnerLoggedIn = false
            venueOwnerMode = false
            isAdminLoggedIn = false
            markAuthSignedOut(reason: reason)
        }
        SafeLogoutDebug.step("clear_session_caches_completed")
        SafeLogoutDebug.step("local_auth_state_cleared")
        SafeLogoutDebug.step("local_fangeo_auth_clear_completed")
        SafeLogoutDebug.step("view_models_reset_completed")

        clearPersistedAccountMode()
        UserDefaults.standard.set(true, forKey: Self.didExplicitlyLogoutKey)
        SafeLogoutDebug.step("explicit_logout_marker_set")
        SafeLogoutDebug.step("blocking_logout_pipeline_returned")
        return true
    }

    /// Outcome of clearing the *local* Supabase session for an explicit user logout.
    /// Never reflects remote `/logout` revocation — that is dispatched separately as best effort.
    enum LocalLogoutResult: CustomStringConvertible, Sendable {
        /// No reusable session existed to begin with.
        case noSessionPresent
        /// The SDK's own local removal (inside `signOut`) took effect before the deadline.
        case clearedBySDK
        /// The SDK removal stalled; the truly-local keychain purge invalidated the session.
        case clearedByLocalFallback
        /// A reusable session could not be confirmed cleared — the caller must not report success.
        case failed

        var succeeded: Bool {
            switch self {
            case .noSessionPresent, .clearedBySDK, .clearedByLocalFallback: return true
            case .failed: return false
            }
        }

        var description: String {
            switch self {
            case .noSessionPresent: return "noSessionPresent"
            case .clearedBySDK: return "clearedBySDK"
            case .clearedByLocalFallback: return "clearedByLocalFallback"
            case .failed: return "failed"
            }
        }
    }

    /// Clears the locally persisted Supabase session so the blocking UI can leave `loggingOut`
    /// promptly. It **never** awaits the remote `/logout` network call.
    ///
    /// Root cause this replaces: `AuthClient.signOut(scope:)` removes the local session and
    /// then awaits a `/logout` POST for every scope except `.others`. The previous
    /// `withTaskGroup` "timeout" could not bound it — a structured group cannot return until
    /// all children finish, and the child awaiting the SDK sign-out never finished when the
    /// network hung and the SDK task ignored cancellation.
    ///
    /// Strategy (all network-independent for the blocking path):
    /// 1. Stop the SDK auto-refresh loop so it cannot re-persist a session after removal.
    /// 2. Dispatch full remote+local sign-out as detached best effort (captures the access
    ///    token, emits `.signedOut`, hits `/logout`) — never awaited here.
    /// 3. Bounded, wall-clock confirmation that the local session is gone (the SDK's local
    ///    removal runs before its network call, so this normally succeeds within a tick).
    /// 4. If the SDK removal is blocked past the deadline, purge the keychain directly.
    @MainActor
    private func invalidateLocalAuthenticatedSessionForExplicitLogout(
        logoutAccountId: UUID?,
        generation: UInt64
    ) async -> LocalLogoutResult {
        logBusinessLogoutTrace("localSessionInvalidationBegin scope=local")

        let invalidator = ExplicitLogoutLocalInvalidator(
            stopAutoRefresh: { await supabase.auth.stopAutoRefresh() },
            hasLocalSession: { supabase.auth.currentSession != nil },
            dispatchRemoteBestEffort: { [weak self] in
                self?.dispatchRemoteLogoutBestEffort(
                    logoutAccountId: logoutAccountId,
                    generation: generation
                )
            },
            directLocalPurge: { purgeSupabaseLocalAuthSessionStorage() }
        )
        return await invalidator.run()
    }

    /// Fire-and-forget remote sign-out / token revocation. Never awaited by the logout UI
    /// pipeline, so a hung or non-cancellable network call cannot keep the overlay up.
    ///
    /// The logout account + generation are captured for logging and to make the intent
    /// explicit; this work only touches SDK auth state (not app/UI state), so a late
    /// completion after a *different* account signs in cannot alter the new session.
    @MainActor
    private func dispatchRemoteLogoutBestEffort(logoutAccountId: UUID?, generation: UInt64) {
        let accountText = logoutAccountId?.uuidString.lowercased() ?? "nil"
        // Unstructured, top-level Task: independent of the logout pipeline's lifetime and
        // never cancelled when `forceLogout` returns.
        Task {
            do {
                try await supabase.auth.signOut(scope: .local)
                SafeLogoutDebug.step("remote_logout_completed", detail: "account=\(accountText) gen=\(generation)")
            } catch {
                SafeLogoutDebug.step(
                    "remote_logout_failed",
                    detail: "account=\(accountText) gen=\(generation) error=\(error.localizedDescription)"
                )
            }
        }
        SafeLogoutDebug.step("remote_logout_dispatched", detail: "account=\(accountText) gen=\(generation)")
    }

    private func logSessionRestored(_ restored: Bool, reason: String, userId: UUID? = nil) {
#if DEBUG
        let userText = userId?.uuidString.lowercased() ?? "nil"
        print("[AuthStateDebug] sessionRestored=\(restored) reason=\(reason) userId=\(userText)")
#endif
    }

    private static func liveVisibilityErrorText(_ error: Error) -> String {
        let ns = error as NSError
        var parts = [
            error.localizedDescription,
            ns.domain,
            "\(ns.code)"
        ]
        if let pe = error as? PostgrestError {
            parts.append(pe.code ?? "")
            parts.append(pe.message)
            parts.append(pe.detail ?? "")
            parts.append(pe.hint ?? "")
        }
        return parts.joined(separator: " ").lowercased()
    }

    private static func isMissingLiveVisibilityAudienceColumnsError(_ error: Error) -> Bool {
        let text = liveVisibilityErrorText(error)
        let mentionsColumn = text.contains("live_visibility_mode")
            || text.contains("selected_live_visibility_friend_ids")
        return mentionsColumn
            && (
                text.contains("column")
                || text.contains("schema cache")
                || text.contains("pgrst204")
                || text.contains("not find")
                || text.contains("does not exist")
            )
    }

    private static func isMissingLiveVisibilityEnabledColumnError(_ error: Error) -> Bool {
        let text = liveVisibilityErrorText(error)
        return text.contains("live_visibility_enabled")
            && (
                text.contains("column")
                || text.contains("schema cache")
                || text.contains("pgrst204")
                || text.contains("not find")
                || text.contains("does not exist")
            )
    }

    private static func trimmedNonEmpty(_ raw: String?) -> String {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func emailLocalDisplayFallback(for email: String) -> String {
        let local = OwnerBusinessEmail.normalized(email)
            .split(separator: "@")
            .first
            .map(String.init) ?? ""
        guard !local.isEmpty else { return "" }
        return local.prefix(1).uppercased() + local.dropFirst()
    }

    private static func isEmailFallbackDisplayName(_ displayName: String, email: String) -> Bool {
        let candidate = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !candidate.isEmpty else { return false }
        let normalizedEmail = OwnerBusinessEmail.normalized(email)
        let local = normalizedEmail.split(separator: "@").first.map(String.init)?.lowercased() ?? ""
        guard !local.isEmpty else { return false }
        return candidate == local || candidate == emailLocalDisplayFallback(for: normalizedEmail).lowercased()
    }

    @MainActor
    func resetProfilePresentationLoadStateForNewAuth() {
        isUserProfileLoadingForPresentation = false
        hasLoadedUserProfileForPresentation = false
        userProfileExistsForPresentation = false
    }

    @MainActor
    func beginProfilePresentationLoad() {
        isUserProfileLoadingForPresentation = true
        hasLoadedUserProfileForPresentation = false
        userProfileExistsForPresentation = false
    }

    @MainActor
    func finishProfilePresentationLoad(profileExists: Bool, userId: UUID? = nil, generation: UInt64? = nil) {
        if let generation {
            guard accountProfileGeneration == generation else { return }
        }
        if let userId {
            guard currentUserAuthId == userId else { return }
        }
        userProfileExistsForPresentation = profileExists
        hasLoadedUserProfileForPresentation = true
        isUserProfileLoadingForPresentation = false
    }

    /// Account-tab recovery: fetch active fan profile when presentation state was reset but warm preload has not hydrated yet.
    func recoverUserProfilePresentationForAccountTabIfNeeded() async {
        let snapshot = await MainActor.run { () -> (UUID, UInt64)? in
            guard isLoggedIn, !isVenueOwnerLoggedIn, let userId = currentUserAuthId else { return nil }
            guard !hasLoadedUserProfileForPresentation && !isUserProfileLoadingForPresentation else { return nil }
            return (userId, accountProfileGeneration)
        }
        guard let (userId, generation) = snapshot else { return }

#if DEBUG
        print("[ProfilePersistenceDebug] accountTabRecoveryLoadStarted=true")
#endif
        await MainActor.run {
            startOwnedProfileLoad(userId: userId, generation: generation, reason: "accountTabRecovery")
        }
        if let task = await MainActor.run(body: { profileLoadTask }) {
            await task.value
        }
        // Profile fields can recover without favorite-team AppStorage; force a server reload so Profile does not stay on "Add Team".
        await loadFavoriteTeamsFromSupabase(forceRefresh: true)
    }

    @MainActor
    private func shouldApplyLoadedUserProfile(authId: UUID) -> Bool {
        guard let activeAuthId = currentUserAuthId else { return true }
        guard activeAuthId == authId else {
#if DEBUG
            print("[ProfilePersistenceDebug] staleProfileApplyDiscarded=true fetchedAuthId=\(authId.uuidString.lowercased()) activeAuthId=\(activeAuthId.uuidString.lowercased())")
#endif
            return false
        }
        return true
    }

    @MainActor
    @discardableResult
    private func applyLoadedUserProfileRow(_ profile: UserProfileRow, authId: UUID, generation: UInt64? = nil) -> Bool {
        if let generation {
            guard accountProfileGeneration == generation else { return false }
        }
        guard !isDeletedAccountLoginBlocked else { return false }
        guard !profile.isDeletedAccount else { return false }
        guard shouldApplyLoadedUserProfile(authId: authId) else { return false }

        if let em = profile.email?.trimmingCharacters(in: .whitespacesAndNewlines), !em.isEmpty {
            currentUserEmail = em
        }
        currentUserDisplayName = profile.display_name ?? ""
        currentUserUsername = profile.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        currentUserBio = profile.bio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        currentUserProfileCreatedAt = profile.created_at?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        currentUserIsBusinessAccount = profile.isBusinessIdentity
        currentUserAvatarURL = ImageDisplayURL.canonicalStorageURLString(profile.avatar_url)
        currentUserAvatarThumbnailURL = ImageDisplayURL.canonicalStorageURLString(profile.avatar_thumbnail_url)
#if DEBUG
        ProfileAvatarDebug.profileAppliedToViewModel(
            canonicalAvatarURL: currentUserAvatarURL,
            canonicalAvatarThumbnailURL: currentUserAvatarThumbnailURL,
            source: "applyLoadedUserProfileRow"
        )
        ProfileAvatarDebug.profileReloaded(
            handlePresent: !currentUserUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            avatarURLPresent: !currentUserAvatarURL.isEmpty || !currentUserAvatarThumbnailURL.isEmpty
        )
#endif
        currentUserNationalTeam = profile.nationalTeamIdentity
        applyCurrentUserHomeCityFromProfile(profile)
        currentUserProfileBackgroundKey = profile.resolvedProfileBackgroundKey
        currentUserLiveVisibilityEnabled = profile.isVisibleForLiveFriendPresence
        currentUserLiveVisibilityMode = profile.liveVisibilityMode
        currentUserSelectedLiveVisibilityFriendIDs = profile.selectedLiveVisibilityFriendIDs
        currentUserDiscoverableByFans = profile.discoverableByFans
        currentUserActivityStatusVisible = profile.activityStatusVisible
        currentUserAuthId = authId
        FanGeoUserEntitlements.apply(adFreeEnabled: profile.adFreeEnabled)
        bumpCurrentUserAvatarDisplayRefresh()
        cacheCurrentUserProfileLocally()
        return true
    }

    /// Ensures `public.user_profiles` has a row with `id == auth.uid`; inserts a minimal row if missing. Does not use email as PK or random UUIDs.
    func ensureUserProfileExists() async {
        let session: Session
        do {
            session = try await supabase.auth.session
        } catch {
            return
        }

        let authId = session.user.id
#if DEBUG
        print("[ProfileBootstrap] auth uid = \(authId)")
        print("[ProfilePersistenceDebug] loadingProfileForUserId=\(authId.uuidString.lowercased())")
#endif

        let sessionEmail = OwnerBusinessEmail.normalized(session.user.email ?? "")
        let skipForPendingBusinessVenueSetup = await MainActor.run {
            shouldBypassFanAccountConflictForPendingBusinessVenueSetup(
                email: sessionEmail,
                userId: authId,
                sessionEmailConfirmed: Self.userEmailConfirmed(session.user)
            )
        }
        if skipForPendingBusinessVenueSetup {
#if DEBUG
            print("[ProfileBootstrap] skipped user_profiles bootstrap for pending business venue setup")
            logBusinessAuthFanConflictGate(
                context: "ensureUserProfileExists_skip",
                email: sessionEmail,
                userId: authId,
                userProfileExists: false,
                blockingReason: nil,
                pendingDraftOverride: true
            )
#endif
            await MainActor.run { currentUserAuthId = authId }
            return
        }

        do {
            let existing: [UserProfileRow] = try await supabase
                .from("user_profiles")
                .select(Self.userProfileSelectColumns)
                .eq("id", value: authId)
                .limit(1)
                .execute()
                .value

            if let profile = existing.first {
#if DEBUG
                print("[ProfileBootstrap] profile found")
                print("[ProfilePersistenceDebug] existingProfileFound=true")
#endif
                if profile.isDeletedAccount {
                    if await shouldSuppressDeletedProfileBlockForBusinessSession(
                        session: session,
                        context: "ensureUserProfileExists"
                    ) {
                        return
                    }
                    await handleDeletedCurrentUser()
                    return
                }
                await MainActor.run { currentUserAuthId = authId }
                return
            }
#if DEBUG
            print("[ProfilePersistenceDebug] existingProfileFound=false")
#endif
        } catch {
#if DEBUG
            print("[ProfilePersistenceDebug] profileDecodeFailed=\(error.localizedDescription)")
#endif
            Self.logPostgrestError("[ProfileBootstrap] error querying user_profiles by id", error)
            return
        }

#if DEBUG
        print("[ProfileBootstrap] profile missing -> creating")
#endif

        let emailFromSession = OwnerBusinessEmail.normalized(session.user.email ?? "")
        let emailForRow: String
        if !emailFromSession.isEmpty {
            emailForRow = emailFromSession
        } else {
            let fallback = await MainActor.run {
                OwnerBusinessEmail.normalized(currentUserEmail)
            }
            guard !fallback.isEmpty else {
#if DEBUG
                print("[ProfileBootstrap] cannot insert user_profiles: no email on session or in memory")
#endif
                return
            }
            emailForRow = fallback
        }

        guard !FanProfileDefaults.isAnonymizedOrDeletedEmail(emailForRow) else {
#if DEBUG
            print("[ProfileBootstrap] skipped profile defaults for deleted/anonymized email")
#endif
            return
        }

        let defaultDisplayName = FanProfileDefaults.defaultDisplayName(email: emailForRow)
        let usernameBase = FanProfileDefaults.defaultUsernameBase(email: emailForRow, authUserId: authId)
        let defaultUsername = await resolveAvailableDefaultUsername(base: usernameBase, authId: authId)
#if DEBUG
        ProfileDefaultsDebug.generatedDisplayName(defaultDisplayName)
        ProfileDefaultsDebug.generatedUsername(defaultUsername)
#endif

        let row = UserProfileBootstrapInsert(
            id: authId,
            email: emailForRow,
            display_name: defaultDisplayName,
            username: defaultUsername,
            bio: nil,
            avatar_url: "",
            avatar_thumbnail_url: nil,
            live_visibility_enabled: true,
            live_visibility_mode: LiveVisibilityMode.allFriends.rawValue,
            selected_live_visibility_friend_ids: [],
            discoverable_by_fans: true
        )

        do {
            try await supabase
                .from("user_profiles")
                .insert(row)
                .execute()
#if DEBUG
            print("[ProfileBootstrap] profile created successfully")
#endif
            await MainActor.run {
                currentUserAuthId = authId
                if currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    currentUserDisplayName = defaultDisplayName
                }
                if currentUserUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    currentUserUsername = defaultUsername
                }
                cacheCurrentUserProfileLocally()
            }
        } catch {
            Self.logPostgrestError("[ProfileBootstrap] insert failed", error)
            if let pe = error as? PostgrestError, pe.code == "23505" {
#if DEBUG
                print("[ProfileBootstrap] profile already exists (unique violation); continuing")
#endif
                await MainActor.run { currentUserAuthId = authId }
            }
        }
    }

    private func resolveAvailableDefaultUsername(base: String, authId: UUID) async -> String {
        let normalizedBase = FanGeoHandleRules.normalizeForStorage(base)
        guard !normalizedBase.isEmpty else {
            return FanProfileDefaults.defaultUsernameBase(email: "", authUserId: authId)
        }

        if await checkUsernameAvailable(normalizedBase) == true {
            return normalizedBase
        }

        let idSuffix = FanProfileDefaults.shortAuthSuffix(authId, length: 4)
        let idCandidate = FanProfileDefaults.usernameByAppendingSuffix(normalizedBase, suffix: idSuffix)
        if await checkUsernameAvailable(idCandidate) == true {
#if DEBUG
            ProfileDefaultsDebug.usernameCollisionResolved(base: normalizedBase, resolved: idCandidate)
#endif
            return idCandidate
        }

        for index in 2...99 {
            let numbered = FanProfileDefaults.usernameByAppendingSuffix(normalizedBase, suffix: "\(index)")
            if await checkUsernameAvailable(numbered) == true {
#if DEBUG
                ProfileDefaultsDebug.usernameCollisionResolved(base: normalizedBase, resolved: numbered)
#endif
                return numbered
            }
        }

        let fallback = FanProfileDefaults.usernameByAppendingSuffix(
            "fan",
            suffix: FanProfileDefaults.shortAuthSuffix(authId, length: 6)
        )
#if DEBUG
        ProfileDefaultsDebug.usernameCollisionResolved(base: normalizedBase, resolved: fallback)
#endif
        return fallback
    }

    func bumpCurrentUserAvatarDisplayRefresh() {
        currentUserAvatarDisplayRefreshToken = UUID()
    }

    /// Public URLs for a full-size avatar and its list thumbnail (see ``ImageCompression/UploadPreset-swift.enum.avatarThumbnail``).
    /// `replaced*` are prior objects to delete only after the profile row successfully points at the new URLs.
    struct UploadedAvatarURLs: Sendable {
        let fullURL: String
        let thumbnailURL: String
        let replacedFullURL: String?
        let replacedThumbnailURL: String?

        init(
            fullURL: String,
            thumbnailURL: String,
            replacedFullURL: String? = nil,
            replacedThumbnailURL: String? = nil
        ) {
            self.fullURL = fullURL
            self.thumbnailURL = thumbnailURL
            self.replacedFullURL = replacedFullURL
            self.replacedThumbnailURL = replacedThumbnailURL
        }
    }

    /// Unique object name under `user-avatars/{uid}/` so each successful upload changes the public URL.
    static func makeVersionedAvatarFileName() -> String {
        "avatar-\(UUID().uuidString.lowercased()).jpg"
    }

    private static func companionAvatarThumbnailFileName(for fullFileName: String) -> String {
        if let dot = fullFileName.lastIndex(of: "."), dot < fullFileName.endIndex {
            let base = String(fullFileName[..<dot])
            let ext = String(fullFileName[fullFileName.index(after: dot)...])
            return "\(base)_thumb.\(ext)"
        }
        return fullFileName + "_thumb.jpg"
    }

    func registerUser(email: String, password: String, recordFanGuidelinesAcceptance: Bool = false) async {
        let fanEmail = OwnerBusinessEmail.normalized(email)
        guard OwnerBusinessEmail.isValidStrict(fanEmail) else {
            await MainActor.run { authErrorMessage = OwnerBusinessEmail.invalidOwnerEmailUserMessage }
            return
        }

        guard await requireAgeAccessForSignUp(email: fanEmail) else {
            let message = AgeAccessGateService.shared.latestState.isBlockingUnder13
                ? L10n.t("age_gate_under13_body")
                : L10n.t("age_gate_confirmation_body")
            await MainActor.run { authErrorMessage = message }
            return
        }

        if await businessAccountExistsForOwnerEmailOnly(fanEmail) {
#if DEBUG
            print("[AuthAccountTypeGate] fan registration blocked businessEmail=\(fanEmail)")
#endif
            await MainActor.run { authErrorMessage = Self.fanLoginBlockedBecauseBusinessMessage }
            return
        }

        do {
            let signUpResponse = try await supabase.auth.signUp(
                email: fanEmail,
                password: password,
                redirectTo: Self.emailVerificationRedirectURL
            )

            let signUpSession = signUpResponse.session
            let restoredSession = try? await supabase.auth.session
            guard let activeSession = signUpSession ?? restoredSession,
                  Self.userEmailConfirmed(activeSession.user) else {
                await forceLogout(reason: "registerUserNeedsEmailConfirmation", source: "MapViewModel.registerUser")
                await MainActor.run {
                    markEmailVerificationPending(
                        email: fanEmail,
                        kind: .fan,
                        includeEmailDeliveryGuidance: true
                    )
                }
                return
            }

            if await businessAccountExistsForOwnerEmailOrUserId(email: fanEmail, userId: activeSession.user.id) {
#if DEBUG
                print("[AuthAccountTypeGate] fan registration blocked businessEmail=\(fanEmail)")
#endif
                await undoPartialSupabaseSessionAfterAccountTypeMismatch()
                await MainActor.run { authErrorMessage = Self.fanLoginBlockedBecauseBusinessMessage }
                return
            }

            guard await claimAccountIdentity(.fan, context: "registerUser") else {
                return
            }

            if await enforceDeletedFanAccountLoginGate(
                userId: activeSession.user.id,
                sessionEmail: fanEmail,
                source: "registerUser"
            ) {
                return
            }

            await MainActor.run {
                beginFanLoginSession(
                    userId: activeSession.user.id,
                    reason: "registerUser",
                    email: fanEmail
                ) {
                    isLoggedIn = true
                    isVenueOwnerLoggedIn = false
                    venueOwnerMode = false
                    markAuthSignedIn(reason: "registerUser")
                    bumpCurrentUserAvatarDisplayRefresh()
                }
            }

            await persistAccountModeForActiveAuthSession(.fanUser)

            // Profile row now exists: hand this sign-up's single-use age grant to the
            // server so the authoritative record — not a local cache — grants access.
            await claimAgeAccessSignUpOwnership(userId: activeSession.user.id, email: fanEmail)

            if (try? await supabase.auth.session) != nil {
                clearExplicitLogoutMarkerAfterManualAuthSucceeded()
            }

            await registerFanActiveSessionOnLogin()

            if recordFanGuidelinesAcceptance {
                UserDefaults.standard.set(true, forKey: "fanGuidelinesAccepted")
            }

            Task {
                await loadFavoriteTeamsFromSupabase(forceRefresh: true)
                await refreshUserPersonalizationInBackground()
            }
        } catch {
            print("User registration failed:", error)
        }
    }

    func loginUser(email: String, password: String, loginGeneration: UInt64? = nil) async {
        let generationOrNil: UInt64? = await MainActor.run {
            if let loginGeneration { return loginGeneration }
            return beginSafeLogin(method: .emailPasswordFan, source: "loginUserLegacy")
        }
        guard let generation = generationOrNil else { return }

        let fanEmail = OwnerBusinessEmail.normalized(email)
        guard OwnerBusinessEmail.isValidStrict(fanEmail) else {
            await MainActor.run {
                authErrorMessage = OwnerBusinessEmail.invalidOwnerEmailUserMessage
                failSafeLogin(
                    generation: generation,
                    message: OwnerBusinessEmail.invalidOwnerEmailUserMessage,
                    accountMode: .fan,
                    failurePhase: "validation"
                )
            }
            return
        }

        do {
            _ = try await supabase.auth.signIn(
                email: fanEmail,
                password: password
            )

            guard await MainActor.run(body: { isActiveSafeLoginGeneration(generation) }) else {
                SafeLoginDebug.log("stale previous-session result ignored phase=postSignIn")
                return
            }

            await MainActor.run {
                markSafeLoginPreparingSession(generation: generation)
            }

            guard let session = try? await supabase.auth.session else {
                await forceLogout(reason: "loginUserSessionMissingAfterSignIn", source: "MapViewModel.loginUser")
                await MainActor.run {
                    authErrorMessage = "Unable to login."
                    failSafeLogin(
                        generation: generation,
                        message: "Unable to login.",
                        accountMode: .fan,
                        failurePhase: "sessionMissing"
                    )
                }
                return
            }

            guard Self.userEmailConfirmed(session.user) else {
                await forceLogout(reason: "loginUserEmailUnconfirmed", source: "MapViewModel.loginUser")
                await MainActor.run {
                    authErrorMessage = "Please verify your email before signing in."
                    markEmailVerificationPending(email: fanEmail, kind: .fan)
                    print("[EmailVerifyDebug] signInBlockedUnconfirmed=true")
                    failSafeLogin(
                        generation: generation,
                        message: "Please verify your email before signing in.",
                        accountMode: .fan,
                        failurePhase: "emailUnconfirmed"
                    )
                }
                return
            }

            if await refreshActiveBanGate(reason: "emailPasswordFanLogin") {
                clearExplicitLogoutMarkerAfterManualAuthSucceeded()
                await MainActor.run {
                    clearSafeLoginProgress(generation: generation, reason: "banGate")
                }
                return
            }

            await MainActor.run {
                restorePendingFanEmailSignupDraftIfNeeded()
            }
            if let draft = pendingFanEmailSignupDraft,
               OwnerBusinessEmail.normalized(draft.email) == fanEmail {
                _ = await completePendingEmailFanSignupAfterConfirmation(session: session, draft: draft)
                await MainActor.run {
                    if isLoggedIn {
                        completeSafeLoginSuccess(generation: generation, accountKind: "fan")
                    } else {
                        failSafeLogin(
                            generation: generation,
                            message: authErrorMessage,
                            accountMode: .fan,
                            failurePhase: "pendingSignup"
                        )
                    }
                }
                return
            }

            if await businessAccountExistsForOwnerEmailOrUserId(email: fanEmail, userId: session.user.id) {
#if DEBUG
                print("[AuthAccountTypeGate] fan login blocked businessEmail=\(fanEmail)")
#endif
                await undoPartialSupabaseSessionAfterAccountTypeMismatch()
                await MainActor.run {
                    authErrorMessage = Self.fanLoginBlockedBecauseBusinessMessage
                    failSafeLogin(
                        generation: generation,
                        message: Self.fanLoginBlockedBecauseBusinessMessage,
                        accountMode: .fan,
                        failurePhase: "accountTypeGate"
                    )
                }
                return
            }

            guard await claimAccountIdentity(.fan, context: "loginUser") else {
                await MainActor.run {
                    failSafeLogin(
                        generation: generation,
                        message: authErrorMessage,
                        accountMode: .fan,
                        failurePhase: "claimIdentity"
                    )
                }
                return
            }

            if await enforceDeletedFanAccountLoginGate(
                userId: session.user.id,
                sessionEmail: fanEmail,
                source: "loginUser"
            ) {
                await MainActor.run {
                    failSafeLogin(
                        generation: generation,
                        message: authErrorMessage,
                        accountMode: .fan,
                        failurePhase: "deletedAccountGate"
                    )
                }
                return
            }

            if !(await checkCurrentUserAdminStatus()) {
                await MainActor.run {
                    failSafeLogin(
                        generation: generation,
                        message: authErrorMessage,
                        accountMode: .fan,
                        failurePhase: "adminStatus"
                    )
                }
                return
            }

            guard await MainActor.run(body: { isActiveSafeLoginGeneration(generation) }) else {
                SafeLoginDebug.log("stale previous-session result ignored phase=beginFanLoginSession")
                return
            }

            await MainActor.run {
                beginFanLoginSession(
                    userId: session.user.id,
                    reason: "loginUser",
                    email: fanEmail
                ) {
                    isLoggedIn = true
                    isVenueOwnerLoggedIn = false
                    venueOwnerMode = false
                    markAuthSignedIn(reason: "loginUser")
                    authErrorMessage = ""
                    emailVerifiedSignInNotice = ""
                    bumpCurrentUserAvatarDisplayRefresh()
                }
                FanGeoStartupGuidePreferences.migrateLegacyGlobalPreferenceIfNeeded(for: session.user.id)
                SafeLoginDebug.log("minimum profile/preferences loading started")
            }

            await persistAccountModeForActiveAuthSession(.fanUser)

            clearExplicitLogoutMarkerAfterManualAuthSucceeded()

            await MainActor.run {
                completeSafeLoginSuccess(generation: generation, accountKind: "fan")
            }

            // Secondary hydration — must not block authenticated root.
            Task {
                await registerFanActiveSessionOnLogin()
                await loadFavoriteTeamsFromSupabase(forceRefresh: true)
                await refreshUserPersonalizationInBackground()
            }
        } catch {
            await MainActor.run {
                guard isActiveSafeLoginGeneration(generation) else {
                    SafeLoginDebug.log("stale previous-session result ignored phase=catch")
                    return
                }
                // Never wipe a successfully established session from a racing older attempt.
                if isLoggedIn, currentUserAuthId != nil {
                    SafeLoginDebug.log("stale previous-session result ignored phase=catchAlreadyAuthenticated")
                    return
                }

                isLoggedIn = false
                currentUserAuthId = nil
                markAuthSignedOut(reason: "loginUserError")

                let message = error.localizedDescription.lowercased()
                let userMessage: String

                if Self.isUnconfirmedEmailAuthError(error) {
                    userMessage = "Please verify your email before signing in."
                    authErrorMessage = userMessage
                    emailVerifiedSignInNotice = ""
                    markEmailVerificationPending(email: fanEmail, kind: .fan)
                    print("[EmailVerifyDebug] signInBlockedUnconfirmed=true")
                } else if message.contains("invalid login credentials") {
                    userMessage = "No account found or incorrect password."
                    authErrorMessage = userMessage
                    emailVerifiedSignInNotice = ""
                } else {
                    userMessage = "Unable to login."
                    authErrorMessage = userMessage
                    emailVerifiedSignInNotice = ""
                }

                failSafeLogin(
                    generation: generation,
                    message: userMessage,
                    accountMode: .fan,
                    failurePhase: "signInError"
                )
            }

            print("LOGIN ERROR:", error)
        }
    }

    func resendEmailVerification(email: String? = nil, kind: EmailVerificationAccountKind? = nil) async {
        let targetEmail = OwnerBusinessEmail.normalized(email ?? pendingEmailVerificationEmail)
        let targetKind = kind ?? pendingEmailVerificationKind ?? .fan
        guard OwnerBusinessEmail.isValidStrict(targetEmail) else {
            await MainActor.run {
                emailVerificationError = OwnerBusinessEmail.invalidOwnerEmailUserMessage
            }
            return
        }

        print("[EmailVerifyDebug] resendStarted=true")
        print("[BusinessVerificationResend] resendStarted kind=\(targetKind.rawValue) email=\(targetEmail) type=signup redirect_to=\(Self.emailVerificationRedirectURL.absoluteString)")
        do {
            try await supabase.auth.resend(
                email: targetEmail,
                type: .signup,
                emailRedirectTo: Self.emailVerificationRedirectURL
            )
            await MainActor.run {
                pendingEmailVerificationEmail = targetEmail
                pendingEmailVerificationKind = targetKind
                emailVerificationError = ""
                let successMessage = targetKind == .business
                    ? "Verification email sent. Check your business email to continue."
                    : "Verification email sent. Check your email to continue."
                emailVerificationMessage = Self.withEmailDeliveryGuidance(successMessage)
            }
            print("[EmailVerifyDebug] resendSuccess=true")
            print("[BusinessVerificationResend] resendSuccess=true kind=\(targetKind.rawValue) email=\(targetEmail)")
        } catch {
            await MainActor.run {
                let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                let lowercased = message.lowercased()
                if lowercased.contains("email rate limit") || lowercased.contains("rate limit") {
                    emailVerificationError = "Verification emails are being rate limited. Please wait a few minutes and try again."
                } else if lowercased.contains("email signups are disabled") || lowercased.contains("provider") {
                    emailVerificationError = "Email verification is not available right now. Please contact support."
                } else if !message.isEmpty {
                    emailVerificationError = "Could not resend verification email: \(message)"
                } else {
                    emailVerificationError = "Could not resend verification email. Please try again."
                }
            }
            print("[EmailVerifyDebug] resendSuccess=false error=\(error.localizedDescription)")
            let nsError = error as NSError
            print("[BusinessVerificationResend] resendSuccess=false kind=\(targetKind.rawValue) email=\(targetEmail) domain=\(nsError.domain) code=\(nsError.code) localized=\(error.localizedDescription) raw=\(String(reflecting: error)) userInfo=\(nsError.userInfo)")
        }
    }

    func handleEmailVerificationDeepLink(_ url: URL) async {
        guard Self.isEmailVerificationDeepLink(url) else { return }

        let shouldStart = await MainActor.run { () -> Bool in
            if resolvingEmailConfirmation {
                return false
            }
            resolvingEmailConfirmation = true
            isAuthSessionRestoringForProfilePresentation = true
            transitionAuthSessionState(.loadingSession, reason: "emailConfirmationCallback")
            restorePendingBusinessEmailSignupDraftIfNeeded()
            restorePendingFanEmailSignupDraftIfNeeded()
            authErrorMessage = ""
            venueAuthErrorMessage = ""
            emailVerifiedSignInNotice = ""
            emailVerificationError = ""
            return true
        }
        guard shouldStart else {
#if DEBUG
            print("[EmailConfirmationRoute] callbackIgnored=alreadyResolving")
#endif
            return
        }
#if DEBUG
        print("[EmailConfirmationRoute] callbackReceived=true")
#endif
        let params = Self.passwordResetDeepLinkParams(from: url)
        let alreadySignedInUserId = await MainActor.run { () -> UUID? in
            isLoggedIn ? currentUserAuthId : nil
        }

        if params["error"] != nil || params["error_code"] != nil || params["error_description"] != nil {
#if DEBUG
            print("[EmailConfirmationRoute] exchangeResult=callbackError")
#endif
            await finishEmailConfirmationResolutionAsSignInRequired(
                notice: Self.emailConfirmationLinkFailedMessage,
                isSuccessNotice: false,
                preserveSignedInUserId: alreadySignedInUserId
            )
            return
        }

#if DEBUG
        print("[EmailConfirmationRoute] exchangeStarted=true")
#endif

        do {
            UserDefaults.standard.set(false, forKey: Self.didExplicitlyLogoutKey)
            let session = try await emailConfirmationSession(from: url, params: params)
            guard await passwordResetRecoverySessionIsAllowed(session: session) else {
                await MainActor.run {
                    resolvingEmailConfirmation = false
                    isAuthSessionRestoringForProfilePresentation = false
                }
                return
            }

            let confirmedAt = session.user.emailConfirmedAt ?? session.user.confirmedAt
            print("[EmailConfirmDebug] emailConfirmedAt=\(confirmedAt?.description ?? "nil")")

            // Idempotent: already authenticated as this confirmed user (e.g. double-tap / reuse).
            if await MainActor.run(body: { isLoggedIn && currentUserAuthId == session.user.id }) {
                await MainActor.run {
                    if let draft = pendingFanEmailSignupDraft,
                       OwnerBusinessEmail.normalized(draft.email)
                        == OwnerBusinessEmail.normalized(session.user.email ?? "") {
                        clearPendingFanEmailSignupDraft()
                    }
                    pendingEmailVerificationKind = nil
                    businessEmailVerificationUIFlowActive = false
                    emailVerificationError = ""
                    emailVerificationMessage = ""
                    emailVerifiedSignInNotice = ""
                    authErrorMessage = ""
                    venueAuthErrorMessage = ""
                    resolvingEmailConfirmation = false
                    isAuthSessionRestoringForProfilePresentation = false
                }
#if DEBUG
                print("[EmailConfirmationRoute] exchangeResult=alreadySignedInIdempotent")
#endif
                return
            }

            if await completePendingEmailSignupAfterConfirmationIfPossible(session: session) {
#if DEBUG
                print("[EmailConfirmationRoute] exchangeResult=sessionEstablished")
                print("[EmailConfirmationRoute] profileState=complete")
                print("[EmailConfirmationRoute] destination=discoverWelcomeGuide")
#endif
                await MainActor.run {
                    resolvingEmailConfirmation = false
                    isAuthSessionRestoringForProfilePresentation = false
                    emailVerifiedSignInNotice = ""
                    authErrorMessage = ""
                    venueAuthErrorMessage = ""
                }
                return
            }

            if await activateConfirmedFanSessionAfterEmailVerification(session: session) {
#if DEBUG
                print("[EmailConfirmationRoute] exchangeResult=sessionEstablished")
                print("[EmailConfirmationRoute] destination=discoverWelcomeGuide")
#endif
                return
            }

            let sessionEmail = OwnerBusinessEmail.normalized(session.user.email ?? "")
            if Self.userEmailConfirmed(session.user),
               let draft = pendingBusinessEmailSignupDraft,
               OwnerBusinessEmail.normalized(draft.email) == sessionEmail {
                guard await enforceBusinessCreationAllowed(
                    userId: session.user.id,
                    sessionEmail: sessionEmail,
                    source: "handleEmailVerificationDeepLink"
                ) else {
                    await MainActor.run {
                        resolvingEmailConfirmation = false
                        isAuthSessionRestoringForProfilePresentation = false
                    }
                    return
                }
                await forceLogout(
                    reason: "businessSignupResumeAfterEmailVerification",
                    source: "MapViewModel.handleEmailVerificationDeepLink"
                )
                await MainActor.run {
                    markBusinessEmailVerifiedAwaitingVenueSetup(email: sessionEmail)
                    authErrorMessage = ""
                    venueAuthErrorMessage = ""
                    emailVerifiedSignInNotice = ""
                    openVenueOwnerAuthSheetFromClaimFlow = true
                    resolvingEmailConfirmation = false
                    isAuthSessionRestoringForProfilePresentation = false
                    requestPostAccountCreationLanguageSelector(
                        userId: session.user.id,
                        source: "emailConfirmationBusinessVerified"
                    )
                }
                return
            }

            // Session established, email confirmed, but no fan/business draft route applied —
            // safe fallback: ask for sign-in without framing the account as blocked.
#if DEBUG
            print("[EmailConfirmationRoute] exchangeResult=verifiedNoSessionRouteFallback")
#endif
            await forceLogout(
                reason: "emailVerificationVerifiedAwaitingSignIn",
                source: "MapViewModel.handleEmailVerificationDeepLink"
            )
            await finishEmailConfirmationResolutionAsSignInRequired(
                notice: Self.emailVerifiedSignInContinueMessage,
                isSuccessNotice: true,
                prefillEmail: sessionEmail
            )
        } catch {
#if DEBUG
            print("[EmailConfirmationRoute] exchangeResult=verifiedNoSession")
            print("[EmailConfirmationRoute] exchangeError=\(error.localizedDescription)")
#endif
            await MainActor.run {
                restorePendingBusinessEmailSignupDraftIfNeeded()
                restorePendingFanEmailSignupDraftIfNeeded()
            }

            // Preserve an already-authenticated session on invalid/expired/reused links.
            if let alreadySignedInUserId,
               await MainActor.run(body: { isLoggedIn && currentUserAuthId == alreadySignedInUserId }) {
                await MainActor.run {
                    resolvingEmailConfirmation = false
                    isAuthSessionRestoringForProfilePresentation = false
                    emailVerifiedSignInNotice = ""
                    authErrorMessage = ""
                }
#if DEBUG
                print("[EmailConfirmationRoute] exchangeResult=preservedExistingSession")
#endif
                return
            }

            if let draft = await MainActor.run(body: { pendingBusinessEmailSignupDraft }) {
                let draftEmail = OwnerBusinessEmail.normalized(draft.email)
                if OwnerBusinessEmail.isValidStrict(draftEmail) {
                    await MainActor.run {
                        markBusinessEmailVerifiedAwaitingVenueSetup(email: draftEmail)
                        authErrorMessage = ""
                        venueAuthErrorMessage = ""
                        emailVerificationMessage = "Email verified. Sign in to add your first venue for FanGeo review."
                        emailVerificationError = ""
                        emailVerifiedSignInNotice = ""
                        openVenueOwnerAuthSheetFromClaimFlow = true
                        resolvingEmailConfirmation = false
                        isAuthSessionRestoringForProfilePresentation = false
                        markAuthSignedOut(reason: "emailConfirmationBusinessVerifiedNoSession")
                    }
                    return
                }
            }

            let prefill = await MainActor.run { () -> String in
                if let draft = pendingFanEmailSignupDraft {
                    return OwnerBusinessEmail.normalized(draft.email)
                }
                return OwnerBusinessEmail.normalized(pendingEmailVerificationEmail)
            }
            let hasPendingFanSignup = await MainActor.run {
                pendingFanEmailSignupDraft != nil
                    || OwnerBusinessEmail.isValidStrict(OwnerBusinessEmail.normalized(pendingEmailVerificationEmail))
            }
            await finishEmailConfirmationResolutionAsSignInRequired(
                notice: hasPendingFanSignup
                    ? Self.emailVerifiedSignInContinueMessage
                    : Self.emailConfirmationLinkFailedMessage,
                isSuccessNotice: hasPendingFanSignup,
                prefillEmail: prefill,
                preserveSignedInUserId: alreadySignedInUserId
            )
        }
    }

    private func emailConfirmationSession(from url: URL, params: [String: String]) async throws -> Session {
        if let accessToken = params["access_token"], let refreshToken = params["refresh_token"] {
            return try await supabase.auth.setSession(accessToken: accessToken, refreshToken: refreshToken)
        }

        if let tokenHash = params["token_hash"] ?? params["token_hashes"] {
            let typeRaw = (params["type"] ?? "signup").lowercased()
            let otpType = EmailOTPType(rawValue: typeRaw) ?? .signup
            let response = try await supabase.auth.verifyOTP(tokenHash: tokenHash, type: otpType)
            if let session = response.session {
                return session
            }
            struct EmailConfirmationVerifiedWithoutSessionError: Error {}
            throw EmailConfirmationVerifiedWithoutSessionError()
        }

        return try await supabase.auth.session(from: url)
    }

    @MainActor
    private func finishEmailConfirmationResolutionAsSignInRequired(
        notice: String,
        isSuccessNotice: Bool,
        prefillEmail: String = "",
        preserveSignedInUserId: UUID? = nil
    ) async {
        // Invalid/expired/reused confirmation links must not tear down an active session.
        if let preserveSignedInUserId,
           isLoggedIn,
           currentUserAuthId == preserveSignedInUserId {
            resolvingEmailConfirmation = false
            isAuthSessionRestoringForProfilePresentation = false
            emailVerifiedSignInNotice = ""
            if !isSuccessNotice {
                // Keep soft diagnostics only; do not surface blocked-account UI.
                emailVerificationError = ""
                authErrorMessage = ""
            }
#if DEBUG
            print("[EmailConfirmationRoute] destination=preservedSignedInSession")
#endif
            return
        }

        let normalizedPrefill = OwnerBusinessEmail.normalized(prefillEmail)
        resolvingEmailConfirmation = false
        isAuthSessionRestoringForProfilePresentation = false
        markAuthSignedOut(reason: "emailConfirmationRequiresSignIn")

        // Keep pending fan draft for profile creation after sign-in.
        pendingEmailVerificationKind = nil
        businessEmailVerificationUIFlowActive = false
        emailVerificationError = isSuccessNotice ? "" : notice
        emailVerificationMessage = ""
        authErrorMessage = ""
        venueAuthErrorMessage = ""

        if OwnerBusinessEmail.isValidStrict(normalizedPrefill) {
            pendingEmailVerificationEmail = normalizedPrefill
        }

        if isSuccessNotice {
            emailVerifiedSignInNotice = notice
#if DEBUG
            print("[EmailConfirmationRoute] destination=signInVerifiedNotice")
#endif
        } else {
            emailVerifiedSignInNotice = ""
            authErrorMessage = notice
#if DEBUG
            print("[EmailConfirmationRoute] destination=signInRecoverableError")
#endif
        }

        fanUserAuthSheetOpenInRegisterMode = false
        presentFanUserAuthSheetFromDiscover = true
    }

    private func activateConfirmedFanSessionAfterEmailVerification(session: Session) async -> Bool {
        guard Self.userEmailConfirmed(session.user) else { return false }
        let fanEmail = OwnerBusinessEmail.normalized(session.user.email ?? "")
        guard OwnerBusinessEmail.isValidStrict(fanEmail) else { return false }

        if let businessDraft = pendingBusinessEmailSignupDraft,
           OwnerBusinessEmail.normalized(businessDraft.email) == fanEmail {
            return false
        }

        if await businessAccountExistsForOwnerEmailOrUserId(email: fanEmail, userId: session.user.id) {
            return false
        }

        if let draft = pendingFanEmailSignupDraft,
           OwnerBusinessEmail.normalized(draft.email) == fanEmail {
            return await completePendingEmailFanSignupAfterConfirmation(session: session, draft: draft)
        }

        if await refreshActiveBanGate(reason: "emailConfirmationFanActivate") {
            await MainActor.run {
                resolvingEmailConfirmation = false
                isAuthSessionRestoringForProfilePresentation = false
            }
            return true
        }

        guard await claimAccountIdentity(.fan, context: "emailConfirmationFanActivate") else {
            await MainActor.run {
                resolvingEmailConfirmation = false
                isAuthSessionRestoringForProfilePresentation = false
            }
            return true
        }

        if await enforceDeletedFanAccountLoginGate(
            userId: session.user.id,
            sessionEmail: fanEmail,
            source: "emailConfirmationFanActivate"
        ) {
            await MainActor.run {
                resolvingEmailConfirmation = false
                isAuthSessionRestoringForProfilePresentation = false
            }
            return true
        }

        if !(await checkCurrentUserAdminStatus()) {
            await MainActor.run {
                resolvingEmailConfirmation = false
                isAuthSessionRestoringForProfilePresentation = false
            }
            return true
        }

        let shouldRequestWelcomeGuide = await MainActor.run {
            pendingEmailVerificationKind == .fan || pendingFanEmailSignupDraft != nil
        }

        await MainActor.run {
            beginFanLoginSession(
                userId: session.user.id,
                reason: "emailConfirmationFanActivate",
                email: fanEmail
            ) {
                isLoggedIn = true
                isVenueOwnerLoggedIn = false
                venueOwnerMode = false
                markAuthSignedIn(reason: "emailConfirmationFanActivate")
                authErrorMessage = ""
                venueAuthErrorMessage = ""
                emailVerifiedSignInNotice = ""
                emailVerificationError = ""
                emailVerificationMessage = ""
                pendingEmailVerificationKind = nil
                businessEmailVerificationUIFlowActive = false
                bumpCurrentUserAvatarDisplayRefresh()
            }
            resolvingEmailConfirmation = false
            isAuthSessionRestoringForProfilePresentation = false
            if shouldRequestWelcomeGuide {
                markPostSignupDiscoverWelcomeGuideIfPossible(source: "emailConfirmationFanActivate")
            } else {
                FanGeoStartupGuidePreferences.migrateLegacyGlobalPreferenceIfNeeded(for: session.user.id)
            }
        }

        await persistAccountModeForActiveAuthSession(.fanUser)
        clearExplicitLogoutMarkerAfterManualAuthSucceeded()
        await registerFanActiveSessionOnLogin()
        Task {
            await loadFavoriteTeamsFromSupabase(forceRefresh: true)
            await refreshUserPersonalizationInBackground()
        }
#if DEBUG
        print("[EmailConfirmationRoute] profileState=existingOrLoading")
#endif
        return true
    }

    private func completePendingEmailSignupAfterConfirmationIfPossible(session: Session) async -> Bool {
        await MainActor.run {
            restorePendingBusinessEmailSignupDraftIfNeeded()
            restorePendingFanEmailSignupDraftIfNeeded()
        }
        guard Self.userEmailConfirmed(session.user) else { return false }
        let sessionEmail = OwnerBusinessEmail.normalized(session.user.email ?? "")

        if (pendingEmailVerificationKind == .fan || pendingFanEmailSignupDraft != nil),
           let draft = pendingFanEmailSignupDraft,
           OwnerBusinessEmail.normalized(draft.email) == sessionEmail {
            print("[EmailConfirmDebug] creatingProfileAfterConfirmation=true")
            return await completePendingEmailFanSignupAfterConfirmation(session: session, draft: draft)
        }

        if let draft = pendingBusinessEmailSignupDraft,
           OwnerBusinessEmail.normalized(draft.email) == sessionEmail {
            if draft.isVenueSubmissionReady {
                print("[EmailConfirmDebug] creatingProfileAfterConfirmation=true")
                return await completePendingBusinessSignupAfterConfirmation(session: session, draft: draft)
            }
            guard await enforceBusinessCreationAllowed(
                userId: session.user.id,
                sessionEmail: sessionEmail,
                source: "completePendingEmailSignupAfterConfirmationIfPossible"
            ) else {
                return true
            }
            await MainActor.run {
                markBusinessEmailVerifiedAwaitingVenueSetup(email: sessionEmail)
            }
            return false
        }

        return false
    }

    /// Verifies the signed-in profile has not been disabled or deleted.
    /// Returns `false` after signing out and clearing local state when access must be blocked.
    @discardableResult
    func checkCurrentUserAdminStatus() async -> Bool {
        let sessionResolution = await supabaseResolvedAuthSessionResult()
        let session: Session
        switch sessionResolution {
        case .active(let activeSession):
            session = activeSession
        case .missingSession:
#if DEBUG
            print("[AuthStateDebug] deletedAccountConfirmed=false reason=adminStatusNoSession")
#endif
            return true
        case .refreshFailed(let error):
            await MainActor.run {
                markAuthRefreshFailed(error, reason: "adminStatusCheck")
            }
#if DEBUG
            print("[AuthStateDebug] deletedAccountConfirmed=false reason=adminStatusRefreshFailed")
#endif
            return true
        }

        let sessionEmail = OwnerBusinessEmail.normalized(session.user.email ?? "")
        let businessValidation = await validateBusinessAdminStatus(ownerEmail: sessionEmail, ownerUserId: session.user.id)
        switch businessValidation {
        case .active:
            await MainActor.run {
                clearStaleDeletedAccountBlockIfNeeded(context: "checkCurrentUserAdminStatus")
            }
            return true
        case .blocked(let status):
            await handleBlockedBusinessAccount(status: status, context: "checkCurrentUserAdminStatus")
            return false
        case .noBusiness, .inconclusive:
            break
        }

        do {
            let rows: [UserProfileRow] = try await supabase
                .from("user_profiles")
                .select(Self.userProfileSelectColumns)
                .eq("id", value: session.user.id)
                .limit(1)
                .execute()
                .value

            guard let profile = rows.first else {
                return true
            }

            if profile.isDeletedAccount {
                let shouldTreatAsBusinessRestore = await MainActor.run {
                    readPersistedAccountMode().mode == .businessOwner
                        || currentUserIsBusinessAccount
                        || isVenueOwnerLoggedIn
                        || isBusinessOwnerSessionRestorePending
                }
                if shouldTreatAsBusinessRestore {
                    logDeletedAccountRestoreDebug("inconclusiveNotDeleted=true reason=businessRestoreProfileDeletedWithoutBusinessConfirmation")
                    await markTransientMissingSessionPreserved(
                        reason: "profileDeletedBusinessRestoreInconclusive",
                        source: "MapViewModel.checkCurrentUserAdminStatus"
                    )
                    return true
                }
#if DEBUG
                print("[AuthStateDebug] deletedAccountConfirmed=true reason=adminStatusProfile userId=\(session.user.id.uuidString.lowercased())")
#endif
                await handleDeletedCurrentUser()
                return false
            }

            if profile.admin_status == "disabled" {
                await handleDisabledCurrentUser()
                return false
            }

            return true
        } catch {
            print("ERROR CHECKING USER ADMIN STATUS:", error)
            return true
        }
    }

    func handleDeletedCurrentUser() async {
        logDeletedAccountRestoreDebug("blockedStateSetBy=handleDeletedCurrentUser")
        logDeletedAccountRestoreDebug("dbConfirmedDeleted=true source=user_profiles")
        await forceLogout(reason: "deletedAccountConfirmed", source: "MapViewModel.handleDeletedCurrentUser")
        await MainActor.run {
            resetProfilePresentationLoadStateForNewAuth()
            transitionAuthSessionState(.deletedAccountConfirmed, reason: "profileVerifiedDeleted")
            authErrorMessage = Self.deletedAccountLoginBlockedMessage
        }
#if DEBUG
        print("[AuthStateDebug] deletedAccountConfirmed=true")
#endif

    }

    func handleDisabledCurrentUser() async {
        logDeletedAccountRestoreDebug("blockedStateSetBy=handleDisabledCurrentUser")
        logDeletedAccountRestoreDebug("dbConfirmedDeleted=true source=user_profiles_disabled")
        await forceLogout(reason: "disabledAccountConfirmed", source: "MapViewModel.handleDisabledCurrentUser")
        await MainActor.run {
            authErrorMessage = "This account has been disabled by FanGeo support."
        }
    }

    @MainActor
    func acknowledgeDeletedAccountLoginBlock() {
        blockedDeletedAccountAttemptEmail = ""
        authErrorMessage = ""
        transitionAuthSessionState(.signedOut, reason: "deletedAccountGateDismissed")
    }

    @discardableResult
    func logoutUser(reason: String = "explicitUserLogout", preserveAuthErrorMessage: Bool = false) async -> Bool {
#if DEBUG
        print("[Auth] logout requested")
#endif
        SafeLogoutDebug.step("logoutUser_enter", detail: "reason=\(reason)")
        let preservedAuthErrorMessage = preserveAuthErrorMessage ? await MainActor.run { authErrorMessage } : ""

        await MainActor.run {
            AgeAccessGateService.shared.handleLogoutOrAccountSwitch()
        }
        SafeLogoutDebug.step("age_access_gate_cleared")

        let didLogout = await forceLogout(reason: reason, source: "MapViewModel.logoutUser")
        guard didLogout else {
#if DEBUG
            print("[Auth] logout failed; local auth state preserved")
#endif
            SafeLogoutDebug.step("logoutUser_forceLogout_returned_false")
            return false
        }

        if preserveAuthErrorMessage, !preservedAuthErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await MainActor.run {
                authErrorMessage = preservedAuthErrorMessage
            }
        }

#if DEBUG
        print("[Auth] local auth state cleared")
        print("[Auth] explicit logout marker set")
#endif
        SafeLogoutDebug.step("logoutUser_return_true")
        return true
    }

    /// True while the shared safe-logout overlay should block authenticated UI / tab bar.
    var isSafeLogoutBlockingUI: Bool {
        switch safeLogoutPhase {
        case .loggingOut, .failed:
            return true
        case .idle:
            return false
        }
    }

    /// True while shared safe-login progress should block competing auth actions / sheet dismissal.
    var isSafeLoginBlockingUI: Bool {
        switch safeLoginPhase {
        case .authenticating, .preparingSession:
            return true
        case .idle:
            return false
        }
    }

    var isSafeLoginInFlight: Bool {
        isSafeLoginBlockingUI
    }

    /// Suppress new authenticated profile/tab activation work during logout.
    var shouldSuppressAuthenticatedRefreshForSafeLogout: Bool {
        safeLogoutPhase == .loggingOut || FanGeoExplicitLogoutGuard.isInProgress
    }

    /// Single authoritative user-initiated logout. Progress is session-owned, not Settings `@State`.
    @MainActor
    func beginSafeUserLogout(source: String) {
        if isSafeLoginInFlight {
            SafeLogoutDebug.log("logout blocked loginInFlight source=\(source)")
            return
        }
        if safeLogoutPhase == .loggingOut {
            SafeLogoutDebug.log("duplicate request ignored source=\(source)")
            return
        }
        if let existing = safeLogoutTask, !existing.isCancelled {
            SafeLogoutDebug.log("duplicate request ignored inFlight source=\(source)")
            return
        }

        safeLogoutSource = source
        safeLogoutFailureMessage = ""
        safeLogoutNeedsDiscoverReset = false
        safeLogoutLocalSessionInvalidated = false
        safeLogoutWatchdogTask?.cancel()
        safeLogoutWatchdogTask = nil
        safeLogoutPhase = .loggingOut
        safeLogoutStartedAt = Date()
        // Authoritative in-progress guard: every realtime/presence/session startup must refuse
        // authenticated work while this is true, even before isLoggedIn flips.
        FanGeoExplicitLogoutGuard.isInProgress = true
        SafeLogoutDebug.step("explicit_logout_guard_enabled")
        SafeLogoutDebug.beginPipeline(source: source)
        SafeLogoutDebug.log("logout requested source=\(source)")
        SafeLogoutDebug.log("state changed to logging out")
        SafeLogoutDebug.log("authenticated refresh suppression enabled")

        // Cancel any leftover listen tasks / channels immediately so a lifecycle callback
        // cannot re-attach them between this moment and forceLogout's abandon pass.
        PresenceService.shared.stop(reason: "explicitLogoutBegin")
        ActivityStatusMinuteClock.shared.stop(reason: "explicitLogoutBegin")
        abandonAuthenticatedRealtimeForLogout()
        abandonFanSingleSessionForLogout(knownUserId: currentUserAuthId)

        safeLogoutTask = Task { @MainActor [weak self] in
            defer {
                // Always clear the task reference — cancellation / unexpected exit must not
                // leave a permanently non-nil handle that blocks future logout attempts.
                self?.safeLogoutTask = nil
            }
            guard let self else { return }
            SafeLogoutDebug.step("logoutUser_begin")
            let didLogout = await self.logoutUser(reason: "explicitUserLogout")
            guard !Task.isCancelled else {
                SafeLogoutDebug.step("logout_cancelled")
                FanGeoExplicitLogoutGuard.isInProgress = false
                return
            }
            if didLogout {
                SafeLogoutDebug.step("logoutUser_succeeded")
                SafeLogoutDebug.log("auth sign-out completed")
                SafeLogoutDebug.log("local cleanup completed")
                self.safeLogoutNeedsDiscoverReset = true
                SafeLogoutDebug.step("discover_reset_requested")
                SafeLogoutDebug.step("present_signed_out_root_requested")
                SafeLogoutDebug.log("root session changed to signed out")
                // Keep `loggingOut` until MainTabView selects Discover and acknowledges settlement.
                // Independent watchdog guarantees the overlay clears even if that ack is missed.
                self.startSafeLogoutUISettlementWatchdog()
            } else {
                let message = self.authErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? self.venueAuthErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    : self.authErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                self.safeLogoutFailureMessage = message
                self.safeLogoutPhase = .failed
                FanGeoExplicitLogoutGuard.isInProgress = false
                SafeLogoutDebug.endPipeline(success: false)
                SafeLogoutDebug.log("failure and recovery path messageEmpty=\(message.isEmpty)")
            }
        }
    }

    /// Network-independent watchdog: if MainTabView never acknowledges the signed-out Discover
    /// root (e.g. the root remounted and the `onChange` was missed), this finalizes the overlay
    /// itself — but only after confirming the logout genuinely succeeded locally. It can never
    /// fabricate success while a reusable session might remain.
    @MainActor
    private func startSafeLogoutUISettlementWatchdog() {
        safeLogoutWatchdogTask?.cancel()
        safeLogoutWatchdogTask = Task { @MainActor [weak self] in
            // Short main-actor window for the normal MainTabView acknowledgement first.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.safeLogoutPhase == .loggingOut else { return }
            guard !self.isLoggedIn,
                  !self.isVenueOwnerLoggedIn,
                  self.safeLogoutLocalSessionInvalidated,
                  UserDefaults.standard.bool(forKey: Self.didExplicitlyLogoutKey) else {
                SafeLogoutDebug.step("ui_settlement_watchdog_skipped_conditions_unmet")
                return
            }
            SafeLogoutDebug.step("ui_settlement_watchdog_fired")
            self.acknowledgeSafeLogoutUISettled(reason: "watchdogFallback")
        }
    }

    @MainActor
    func retrySafeUserLogout() {
        SafeLogoutDebug.log("retry requested source=\(safeLogoutSource)")
        let source = safeLogoutSource.isEmpty ? "retrySafeUserLogout" : safeLogoutSource
        safeLogoutWatchdogTask?.cancel()
        safeLogoutWatchdogTask = nil
        safeLogoutPhase = .idle
        FanGeoExplicitLogoutGuard.isInProgress = false
        beginSafeUserLogout(source: source)
    }

    @MainActor
    func cancelSafeLogoutFailureUI() {
        guard safeLogoutPhase == .failed else { return }
        safeLogoutWatchdogTask?.cancel()
        safeLogoutWatchdogTask = nil
        safeLogoutPhase = .idle
        safeLogoutFailureMessage = ""
        FanGeoExplicitLogoutGuard.isInProgress = false
        SafeLogoutDebug.log("failure UI dismissed")
    }

    /// Call from MainTabView after Discover is selected and authenticated roots are no longer interactive.
    @MainActor
    func acknowledgeSafeLogoutUISettled(reason: String) {
        guard safeLogoutPhase == .loggingOut else { return }
        guard !isLoggedIn, !isVenueOwnerLoggedIn else { return }
        // Idempotent: the normal MainTabView ack and the watchdog both route here; the first
        // one wins and cancels the other.
        safeLogoutWatchdogTask?.cancel()
        safeLogoutWatchdogTask = nil
        safeLogoutNeedsDiscoverReset = false
        safeLogoutPhase = .idle
        FanGeoExplicitLogoutGuard.isInProgress = false
        let ms: Int
        if let started = safeLogoutStartedAt {
            ms = Int(Date().timeIntervalSince(started) * 1000)
        } else {
            ms = -1
        }
        safeLogoutStartedAt = nil
        SafeLogoutDebug.step("discover_reset_acknowledged", detail: "reason=\(reason)")
        SafeLogoutDebug.step("present_login_or_discover_root", detail: "reason=\(reason)")
        SafeLogoutDebug.step("overlay_cleared")
        SafeLogoutDebug.log("signed-out root appeared reason=\(reason)")
        SafeLogoutDebug.log("progress presentation cleared")
        SafeLogoutDebug.log("total logout durationMs=\(ms)")
        SafeLogoutDebug.endPipeline(success: true)
    }

    // MARK: - Safe login coordinator

    /// Begins a session-owned login transition. Returns a generation token, or `nil` if ignored.
    @MainActor
    @discardableResult
    func beginSafeLogin(method: SafeLoginMethod, source: String) -> UInt64? {
        if isSafeLogoutBlockingUI {
            SafeLoginDebug.log("login blocked logoutIncomplete source=\(source) method=\(method.rawValue)")
            authErrorMessage = "Please wait until sign-out finishes, then try again."
            venueAuthErrorMessage = authErrorMessage
            return nil
        }
        if isSafeLoginInFlight {
            SafeLoginDebug.log("duplicate login ignored source=\(source) method=\(method.rawValue)")
            return nil
        }
        if let existing = safeLoginTask, !existing.isCancelled {
            SafeLoginDebug.log("duplicate login ignored inFlight source=\(source) method=\(method.rawValue)")
            return nil
        }

        safeLoginGeneration &+= 1
        let generation = safeLoginGeneration
        safeLoginMethod = method
        safeLoginSource = source
        safeLoginStartedAt = Date()
        safeLoginAuthCompletedAt = nil
        safeLoginNeedsDiscoverReset = false
        safeLoginPhase = .authenticating
        authErrorMessage = ""
        venueAuthErrorMessage = ""
        SafeLoginDebug.log("login tap received source=\(source) method=\(method.rawValue)")
        SafeLoginDebug.log("validation started")
        SafeLoginDebug.log("validation completed")
        SafeLoginDebug.log("authentication started method=\(method.rawValue)")
        SafeLoginDebug.log("state changed to authenticating")
        return generation
    }

    @MainActor
    func markSafeLoginPreparingSession(generation: UInt64) {
        guard generation == safeLoginGeneration else {
            SafeLoginDebug.log("stale previous-session result ignored phase=preparingSession")
            return
        }
        guard safeLoginPhase == .authenticating || safeLoginPhase == .preparingSession else { return }
        if safeLoginAuthCompletedAt == nil {
            safeLoginAuthCompletedAt = Date()
            if let started = safeLoginStartedAt {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                SafeLoginDebug.log("authentication succeeded tapToAuthMs=\(ms)")
            } else {
                SafeLoginDebug.log("authentication succeeded")
            }
            SafeLoginDebug.log("authenticated user ID changed")
        }
        if safeLoginPhase != .preparingSession {
            safeLoginPhase = .preparingSession
            SafeLoginDebug.log("session preparation started")
            SafeLoginDebug.log("state changed to preparingSession")
            SafeLoginDebug.log("account type resolution started")
            SafeLoginDebug.log("previous-account caches cleared")
        }
    }

    @MainActor
    func completeSafeLoginSuccess(generation: UInt64, accountKind: String) {
        guard generation == safeLoginGeneration else {
            SafeLoginDebug.log("stale previous-session result ignored phase=success")
            return
        }
        guard isSafeLoginInFlight else { return }

        SafeLoginDebug.log("account type resolution completed kind=\(accountKind)")
        SafeLoginDebug.log("minimum profile/preferences loading completed")
        SafeLoginDebug.log("authenticated root transition started")
        safeLoginNeedsDiscoverReset = true
        safeLoginPhase = .idle
        safeLoginTask = nil

        let tapToRootMs: Int
        let tapToAuthMs: Int
        if let started = safeLoginStartedAt {
            tapToRootMs = Int(Date().timeIntervalSince(started) * 1000)
        } else {
            tapToRootMs = -1
        }
        if let started = safeLoginStartedAt, let authAt = safeLoginAuthCompletedAt {
            tapToAuthMs = Int(authAt.timeIntervalSince(started) * 1000)
        } else {
            tapToAuthMs = -1
        }
        safeLoginStartedAt = nil
        safeLoginAuthCompletedAt = nil
        SafeLoginDebug.log("secondary hydration started")
        SafeLoginDebug.log("login state cleared")
        SafeLoginDebug.log("tapToAuthenticationMs=\(tapToAuthMs)")
        SafeLoginDebug.log("tapToAuthenticatedRootMs=\(tapToRootMs)")
    }

    /// Call from MainTabView after Discover is forced for the new authenticated session.
    @MainActor
    func acknowledgeSafeLoginUISettled(reason: String) {
        guard safeLoginNeedsDiscoverReset else { return }
        safeLoginNeedsDiscoverReset = false
        SafeLoginDebug.log("authenticated root appeared reason=\(reason)")
    }

    @MainActor
    func failSafeLogin(
        generation: UInt64,
        message: String,
        accountMode: AppleAuthAccountMode = .fan,
        failurePhase: String
    ) {
        guard generation == safeLoginGeneration else {
            SafeLoginDebug.log("stale previous-session result ignored phase=failure")
            return
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        safeLoginPhase = .idle
        safeLoginTask = nil
        safeLoginNeedsDiscoverReset = false
        safeLoginStartedAt = nil
        safeLoginAuthCompletedAt = nil
        switch accountMode {
        case .fan:
            authErrorMessage = trimmed.isEmpty ? "Unable to login." : trimmed
        case .business:
            venueAuthErrorMessage = trimmed.isEmpty ? "Unable to login venue owner." : trimmed
        }
        SafeLoginDebug.log("authentication failed phase=\(failurePhase)")
        SafeLoginDebug.log("failure phase and recovery path=\(failurePhase)")
        SafeLoginDebug.log("login state cleared")
    }

    /// Clears login progress without forcing an error (onboarding / gate handoff).
    @MainActor
    func clearSafeLoginProgress(generation: UInt64, reason: String) {
        guard generation == safeLoginGeneration else {
            SafeLoginDebug.log("stale previous-session result ignored phase=clear")
            return
        }
        safeLoginPhase = .idle
        safeLoginTask = nil
        safeLoginNeedsDiscoverReset = false
        safeLoginStartedAt = nil
        safeLoginAuthCompletedAt = nil
        SafeLoginDebug.log("login state cleared reason=\(reason)")
    }

    /// True when this login generation is still the active in-flight attempt.
    @MainActor
    func isActiveSafeLoginGeneration(_ generation: UInt64) -> Bool {
        generation == safeLoginGeneration && isSafeLoginInFlight
    }

    /// Fan email/password login owned by the session coordinator (survives sheet reconstruction).
    @MainActor
    func submitFanEmailLogin(email: String, password: String, source: String) {
        guard let generation = beginSafeLogin(method: .emailPasswordFan, source: source) else { return }
        safeLoginTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.safeLoginTask = nil }
            await self.loginUser(email: email, password: password, loginGeneration: generation)
            // Safety net if loginUser returned without completing/failing the coordinator.
            if self.isActiveSafeLoginGeneration(generation) {
                if self.isLoggedIn {
                    self.completeSafeLoginSuccess(generation: generation, accountKind: "fan")
                } else {
                    let message = self.authErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.failSafeLogin(
                        generation: generation,
                        message: message.isEmpty ? "Unable to login." : message,
                        accountMode: .fan,
                        failurePhase: "loginUserEarlyReturn"
                    )
                }
            }
        }
    }

    /// Business email/password login owned by the session coordinator.
    @MainActor
    func submitBusinessEmailLogin(email: String, password: String, source: String) {
        guard let generation = beginSafeLogin(method: .emailPasswordBusiness, source: source) else { return }
        safeLoginTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.safeLoginTask = nil }
            await self.loginVenueOwner(email: email, password: password, loginGeneration: generation)
            if self.isActiveSafeLoginGeneration(generation) {
                if self.isVenueOwnerLoggedIn {
                    self.completeSafeLoginSuccess(generation: generation, accountKind: "business")
                } else {
                    let message = self.venueAuthErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.failSafeLogin(
                        generation: generation,
                        message: message.isEmpty ? "Unable to login venue owner." : message,
                        accountMode: .business,
                        failurePhase: "loginVenueOwnerEarlyReturn"
                    )
                }
            }
        }
    }

    func hasValidSession() async -> Bool {
        if UserDefaults.standard.bool(forKey: Self.didExplicitlyLogoutKey) {
            return false
        }

        switch await supabaseResolvedAuthSessionResult() {
        case .active:
            return true
        case .missingSession:
            let restoreInProgress = await MainActor.run {
                isAuthSessionRestoringForProfilePresentation || authSessionState == .loadingSession
            }
            if restoreInProgress {
                logBusinessSessionRestoreDebug("forceLogoutSuppressedDuringRestore=true reason=hasValidSessionMissing")
                await markTransientMissingSessionPreserved(
                    reason: "hasValidSessionMissingRestoreInProgress",
                    source: "MapViewModel.hasValidSession"
                )
                return true
            }
            if await MainActor.run(body: { shouldPreserveMissingSessionForRestore() }) {
                await markTransientMissingSessionPreserved(
                    reason: "hasValidSessionMissingPersistedRestore",
                    source: "MapViewModel.hasValidSession"
                )
                Task { [weak self] in
                    await self?.bootstrapAuthSessionOnly()
                }
                return true
            }
            let wasAuthenticated = await MainActor.run { isAuthenticatedForSocialFeatures }
#if DEBUG
            if wasAuthenticated {
                print("[AuthStateDebug] sessionRestored=false reason=hasValidSessionMissingPreserved")
            }
#endif
            return wasAuthenticated
        case .refreshFailed(let error):
            await MainActor.run {
                markAuthRefreshFailed(error, reason: "hasValidSession")
            }
            return true
        }
    }

    /// Strict-normalized email from the active Supabase session (same key used by ``favorite_venues`` / ``venue_event_interests``).
    /// Falls back to ``currentUserEmail`` when the JWT omits `user.email` (mirrors profile bootstrap / save), but **not** for an active business-owner session.
    func strictNormalizedSessionEmailForSocialTables() async -> String? {
        guard let session = try? await supabase.auth.session else { return nil }
        let fromSession = OwnerBusinessEmail.normalized(session.user.email ?? "")
        if OwnerBusinessEmail.isValidStrict(fromSession) {
            return fromSession
        }
        guard !hasAuthenticatedVenueOwnerSession else { return nil }
        let fallback = OwnerBusinessEmail.normalized(currentUserEmail)
        guard OwnerBusinessEmail.isValidStrict(fallback) else { return nil }
        return fallback
    }

    private func applyFanUserSessionRestoreAfterBootstrap(
        session: Session,
        sessionEmail: String,
        clearVenueOwnerCaches: Bool
    ) async {
        // Restore-only: the session already exists, so only a server-confirmed account-type
        // conflict may tear it down. Cancellation or a network blip must leave it untouched.
        guard await claimAccountIdentity(
            .fan,
            context: "fanSessionRestore",
            inconclusiveFailurePolicy: .preserveSession
        ) else {
            return
        }

        if await enforceDeletedFanAccountLoginGate(
            userId: session.user.id,
            sessionEmail: sessionEmail,
            source: "fanSessionRestore"
        ) {
            return
        }

        await MainActor.run {
            currentUserDisplayName = UserDefaults.standard.string(forKey: "cachedUserDisplayName") ?? ""
            currentUserUsername = UserDefaults.standard.string(forKey: "cachedUserUsername") ?? ""
            currentUserBio = UserDefaults.standard.string(forKey: "cachedUserBio") ?? ""
            currentUserProfileCreatedAt = UserDefaults.standard.string(forKey: "cachedUserProfileCreatedAt") ?? ""
            currentUserIsBusinessAccount = false
            currentUserAvatarURL = ImageDisplayURL.canonicalStorageURLString(UserDefaults.standard.string(forKey: "cachedUserAvatarURL"))
            currentUserAvatarThumbnailURL = ImageDisplayURL.canonicalStorageURLString(UserDefaults.standard.string(forKey: "cachedUserAvatarThumbnailURL"))
#if DEBUG
            ProfileAvatarDebug.profileReloaded(
                handlePresent: !currentUserUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                avatarURLPresent: !currentUserAvatarURL.isEmpty || !currentUserAvatarThumbnailURL.isEmpty
            )
#endif
            currentUserNationalTeam = cachedNationalTeamIdentity()
            currentUserHomeCity = UserDefaults.standard.string(forKey: "cachedUserHomeCity") ?? ""
            currentUserHomeRegion = UserDefaults.standard.string(forKey: "cachedUserHomeRegion") ?? ""
            currentUserHomeCountry = UserDefaults.standard.string(forKey: "cachedUserHomeCountry") ?? ""
            currentUserShowHomeCity = UserDefaults.standard.object(forKey: "cachedUserShowHomeCity") as? Bool ?? false
            currentUserProfileBackgroundKey = ProfileBackgroundCatalog.resolveKey(
                UserDefaults.standard.string(forKey: "cachedUserProfileBackgroundKey")
            )
            currentUserLiveVisibilityEnabled = UserDefaults.standard.object(forKey: "cachedUserLiveVisibilityEnabled") as? Bool ?? true
            currentUserLiveVisibilityMode = cachedLiveVisibilityMode()
            currentUserSelectedLiveVisibilityFriendIDs = cachedSelectedLiveVisibilityFriendIDs()
            currentUserDiscoverableByFans = UserDefaults.standard.object(forKey: "cachedUserDiscoverableByFans") as? Bool ?? true
            currentUserActivityStatusVisible = UserDefaults.standard.object(forKey: "cachedUserActivityStatusVisible") as? Bool ?? true
            currentUserEmail = sessionEmail
            isLoggedIn = !sessionEmail.isEmpty
            isVenueOwnerLoggedIn = false
            venueOwnerMode = false
            venueOwnerEmail = ""
            FanGeoStartupGuidePreferences.migrateLegacyGlobalPreferenceIfNeeded(for: session.user.id)
            isAdminLoggedIn = false
            isBusinessOwnerSessionRestorePending = false
            currentUserAuthId = session.user.id
            markAuthSignedIn(reason: "fanSessionRestore")
            if clearVenueOwnerCaches {
                clearVenueOwnerOwnedBusinessCaches()
                ownerVenueDatabaseId = nil
            }
        }
#if DEBUG
        print("[AuthRestore] restoredFanUser email=\(sessionEmail)")
#endif
        // Session restore does not hydrate favorite teams; force a server reload after auth id is set.
        Task {
            await loadFavoriteTeamsFromSupabase(forceRefresh: true)
        }
    }

    private func bootstrapAuthSessionResultWithRetry() async -> SupabaseAuthSessionResolution {
        let first = await supabaseResolvedAuthSessionResult()
        switch first {
        case .active:
            logBusinessSessionRestoreDebug("supabaseSessionExists=true")
            return first
        case .refreshFailed:
            logBusinessSessionRestoreDebug("supabaseSessionExists=false")
            return first
        case .missingSession:
            logBusinessSessionRestoreDebug("supabaseSessionExists=false")
            logBusinessSessionRestoreDebug("restorePending=missingSessionRetry")
            logBusinessSessionRestoreDebug("forceLogoutSuppressedDuringRestore=true reason=bootstrapMissingSession")
            try? await Task.sleep(nanoseconds: 450_000_000)
            let retry = await supabaseResolvedAuthSessionResult()
            if case .active = retry {
                logBusinessSessionRestoreDebug("supabaseSessionExists=true")
            } else {
                logBusinessSessionRestoreDebug("supabaseSessionExists=false")
            }
            return retry
        }
    }

    private func preserveBusinessOwnerAuthIdentity(
        session: Session,
        sessionEmail: String,
        reason: String
    ) async {
        await MainActor.run {
            currentUserAuthId = session.user.id
            currentUserEmail = sessionEmail
            venueOwnerEmail = sessionEmail
            currentUserIsBusinessAccount = true
            isVenueOwnerLoggedIn = false
            venueOwnerMode = false
            isLoggedIn = false
            isAdminLoggedIn = false
            isBusinessOwnerSessionRestorePending = true
            restorePersistedSelectedVenueForBusinessLaunch()
        }
        await persistAccountModeForActiveAuthSession(.businessOwner)
        logBusinessSessionRestoreDebug("preservedAuthIdentity=true userId=\(session.user.id.uuidString.lowercased()) email=\(sessionEmail)")
    }

    private func sessionUserIsDefinitelyFanProfile(userId: UUID) async -> Bool {
        do {
            let rows: [UserProfileRow] = try await supabase
                .from("user_profiles")
                .select(Self.userProfileSelectColumns)
                .eq("id", value: userId)
                .eq("admin_status", value: "active")
                .limit(1)
                .execute()
                .value
            guard let profile = rows.first else { return false }
            return profile.isRegularFanProfile()
        } catch {
#if DEBUG
            print("[BusinessSessionRestoreDebug] fanProfileValidation=inconclusive:\(error.localizedDescription)")
#endif
            return false
        }
    }

    private func handleFailedBusinessOwnerBootstrapRestore(
        session: Session,
        sessionEmail: String
    ) async {
        logBusinessSessionRestoreDebug("fallbackBusinessRestoreStarted=true")
        await preserveBusinessOwnerAuthIdentity(
            session: session,
            sessionEmail: sessionEmail,
            reason: "bootstrapBusinessOwnerFallbackPreserveIdentity"
        )

        let validation = await validateActiveBusinessAccount(ownerEmail: sessionEmail, ownerUserId: session.user.id)
        logBusinessSessionRestoreDebug("activeBusinessValidation=\(validation.debugValue)")

        switch validation {
        case .active:
            let restored = await restoreBusinessOwnerSessionFromSupabaseSessionIfNeeded(
                session: session,
                sessionEmail: sessionEmail,
                context: "bootstrap_restore_business_owner_fallback_retry"
            )
            logBusinessSessionRestoreDebug("restoreBusinessReturned=\(restored)")
            if restored {
                await MainActor.run { isBusinessOwnerSessionRestorePending = false }
                logBusinessSessionRestoreDebug("restoreCompleted=business")
            } else {
                logBusinessSessionRestoreDebug("restorePending=true reason=businessRestoreRetryReturnedFalse")
            }

        case .inactive:
            let lifecycle = await resolveBusinessProfileLifecycleState()
            if lifecycle == .deleted,
               await sessionUserIsDefinitelyFanProfile(userId: session.user.id) {
                await MainActor.run { isBusinessOwnerSessionRestorePending = false }
                await persistAccountModeForActiveAuthSession(.fanUser)
                await applyFanUserSessionRestoreAfterBootstrap(
                    session: session,
                    sessionEmail: sessionEmail,
                    clearVenueOwnerCaches: true
                )
                logBusinessSessionRestoreDebug("restoreCompleted=fan_deletedBusinessDualMode")
            } else if await sessionUserIsDefinitelyFanProfile(userId: session.user.id) {
                await MainActor.run { isBusinessOwnerSessionRestorePending = false }
                await persistAccountModeForActiveAuthSession(.fanUser)
                await applyFanUserSessionRestoreAfterBootstrap(
                    session: session,
                    sessionEmail: sessionEmail,
                    clearVenueOwnerCaches: true
                )
                logBusinessSessionRestoreDebug("restoreCompleted=fan")
            } else if lifecycle == .deleted {
                _ = await enforceBusinessLifecycleGate(
                    userId: session.user.id,
                    sessionEmail: sessionEmail,
                    source: "bootstrapInactiveDeletedBusiness",
                    allowDualFanFallback: false
                )
            } else {
                logBusinessSessionRestoreDebug("restorePending=true reason=inactiveBusinessWithoutFanProfile")
            }

        case .inconclusive(_):
            logBusinessSessionRestoreDebug("restorePending=true reason=activeBusinessValidationInconclusive")
        }
    }

    /// Reads Supabase session and applies cached profile URLs from `UserDefaults` only. Does **not** load profile, favorites, or following (see ``refreshUserPersonalizationInBackground()``).
    func bootstrapAuthSessionOnly() async {
        let restoreID = UUID()
        await MainActor.run {
            authSessionRestoreID = restoreID
            isAuthSessionRestoringForProfilePresentation = true
            transitionAuthSessionState(.loadingSession, reason: "bootstrapStart")
            restorePendingFanEmailSignupDraftIfNeeded()
            restorePendingBusinessEmailSignupDraftIfNeeded()
        }
        logBusinessSessionRestoreDebug("bootstrapStart=true")
        defer {
            Task { @MainActor [weak self, restoreID] in
                guard let self, self.authSessionRestoreID == restoreID else { return }
                self.authSessionRestoreID = nil
                self.isAuthSessionRestoringForProfilePresentation = false
            }
        }

        if UserDefaults.standard.bool(forKey: Self.didExplicitlyLogoutKey) {
#if DEBUG
            print("[Auth] startup session restore skipped due to explicit logout")
#endif
            await forceLogout(reason: "explicitLogoutBootstrap", source: "MapViewModel.bootstrapAuthSessionOnly")
            logSessionRestored(false, reason: "explicitLogout")
            return
        }

        switch await bootstrapAuthSessionResultWithRetry() {
        case .missingSession:
            await markTransientMissingSessionPreserved(
                reason: "bootstrapMissingSessionAfterRetry",
                source: "MapViewModel.bootstrapAuthSessionOnly"
            )
            logSessionRestored(false, reason: "missingSession")
            logBusinessSessionRestoreDebug("restorePending=true reason=missingSessionAfterRetry")
            print("NO ACTIVE SESSION")
            return

        case .refreshFailed(let error):
            await MainActor.run {
                markAuthRefreshFailed(error, reason: "bootstrap")
            }
            logSessionRestored(false, reason: "tokenRefreshFailed")
            return

        case .active(let session):
                let sessionEmail = OwnerBusinessEmail.normalized(session.user.email ?? "")
                let sessionUid = session.user.id.uuidString.lowercased()
                logBusinessOwnerSessionFlags(context: "bootstrap_session_loaded")
                logSessionRestored(true, reason: "bootstrap", userId: session.user.id)

                guard Self.userEmailConfirmed(session.user) else {
                    await forceLogout(reason: "bootstrapEmailUnconfirmed", source: "MapViewModel.bootstrapAuthSessionOnly")
                    await MainActor.run {
                        markEmailVerificationPending(email: sessionEmail, kind: .fan)
                        authErrorMessage = "Please verify your email before signing in."
                        print("[EmailVerifyDebug] signInBlockedUnconfirmed=true")
                    }
                    return
                }

                if await refreshActiveBanGate(reason: "sessionRestore") {
                    return
                }

                if !(await checkCurrentUserAdminStatus()) {
                    print("SESSION RESTORE BLOCKED: account unavailable")
                    return
                }

                // Resume only an explicitly active, unexpired chat live-location session.
                await ChatLiveLocationManager.shared.restoreActiveOutgoingSessionsIfNeeded(userId: session.user.id)

                let persisted = readPersistedAccountMode()
#if DEBUG
                print("[AuthRestore] storedAccountMode=\(persisted.mode.rawValue)")
#endif
                logBusinessSessionRestoreDebug("persistedMode=\(persisted.mode.rawValue)")
                let storedId = persisted.authUserId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                let idMismatch = !storedId.isEmpty && storedId != sessionUid

                if idMismatch {
#if DEBUG
                    print("[AuthRestore] auth uid mismatch session=\(sessionUid) stored=\(storedId) -> fan restore")
#endif
                    await MainActor.run {
                        clearCurrentUserProfileLocalCache()
                    }
                    await persistAccountModeForActiveAuthSession(.fanUser)
                    await applyFanUserSessionRestoreAfterBootstrap(
                        session: session,
                        sessionEmail: sessionEmail,
                        clearVenueOwnerCaches: true
                    )
                    print("SESSION RESTORED:", sessionEmail)
                    return
                }

                switch persisted.mode {
                case .admin:
#if DEBUG
                    print("[AuthRestore] restoredAdmin (local admin UI)")
#endif
                    await MainActor.run {
                        isAdminLoggedIn = true
                        isLoggedIn = false
                        isVenueOwnerLoggedIn = false
                        venueOwnerMode = false
                        venueOwnerEmail = ""
                        currentUserEmail = ""
                        currentUserDisplayName = UserDefaults.standard.string(forKey: "cachedUserDisplayName") ?? ""
                        currentUserBio = UserDefaults.standard.string(forKey: "cachedUserBio") ?? ""
                        currentUserProfileCreatedAt = UserDefaults.standard.string(forKey: "cachedUserProfileCreatedAt") ?? ""
                        currentUserIsBusinessAccount = false
                        currentUserAvatarURL = ImageDisplayURL.canonicalStorageURLString(UserDefaults.standard.string(forKey: "cachedUserAvatarURL"))
                        currentUserAvatarThumbnailURL = ImageDisplayURL.canonicalStorageURLString(UserDefaults.standard.string(forKey: "cachedUserAvatarThumbnailURL"))
                        currentUserNationalTeam = cachedNationalTeamIdentity()
                        currentUserHomeCity = UserDefaults.standard.string(forKey: "cachedUserHomeCity") ?? ""
                        currentUserHomeRegion = UserDefaults.standard.string(forKey: "cachedUserHomeRegion") ?? ""
                        currentUserHomeCountry = UserDefaults.standard.string(forKey: "cachedUserHomeCountry") ?? ""
                        currentUserShowHomeCity = UserDefaults.standard.object(forKey: "cachedUserShowHomeCity") as? Bool ?? false
                        currentUserProfileBackgroundKey = ProfileBackgroundCatalog.resolveKey(
                            UserDefaults.standard.string(forKey: "cachedUserProfileBackgroundKey")
                        )
                        currentUserLiveVisibilityEnabled = UserDefaults.standard.object(forKey: "cachedUserLiveVisibilityEnabled") as? Bool ?? true
                        currentUserLiveVisibilityMode = cachedLiveVisibilityMode()
                        currentUserSelectedLiveVisibilityFriendIDs = cachedSelectedLiveVisibilityFriendIDs()
                        currentUserDiscoverableByFans = UserDefaults.standard.object(forKey: "cachedUserDiscoverableByFans") as? Bool ?? true
            currentUserActivityStatusVisible = UserDefaults.standard.object(forKey: "cachedUserActivityStatusVisible") as? Bool ?? true
                        currentUserAuthId = session.user.id
                        markAuthSignedIn(reason: "adminSessionRestore")
                        clearVenueOwnerOwnedBusinessCaches()
                        ownerVenueDatabaseId = nil
                    }
                    print("SESSION RESTORED:", sessionEmail)
                    return

                case .businessOwner:
                    guard OwnerBusinessEmail.isValidStrict(sessionEmail) else {
#if DEBUG
                        print("[AuthRestore] businessOwner restore missing_or_invalid session email -> fan")
#endif
                        await persistAccountModeForActiveAuthSession(.fanUser)
                        await applyFanUserSessionRestoreAfterBootstrap(
                            session: session,
                            sessionEmail: sessionEmail,
                            clearVenueOwnerCaches: true
                        )
                        print("SESSION RESTORED:", sessionEmail)
                        return
                    }
#if DEBUG
                    print("[AuthRestore] restoredBusinessOwner email=\(sessionEmail)")
#endif
                    let restored = await restoreBusinessOwnerSessionFromSupabaseSessionIfNeeded(
                        session: session,
                        sessionEmail: sessionEmail,
                        context: "bootstrap_restore_business_owner"
                    )
                    logBusinessSessionRestoreDebug("restoreBusinessReturned=\(restored)")
                    if !restored {
                        await handleFailedBusinessOwnerBootstrapRestore(
                            session: session,
                            sessionEmail: sessionEmail
                        )
                    } else {
                        logBusinessSessionRestoreDebug("restoreCompleted=business")
                    }
                    print("SESSION RESTORED:", sessionEmail)
                    return

                case .fanUser:
                    let restoredBusiness = await restoreBusinessOwnerSessionFromSupabaseSessionIfNeeded(
                        session: session,
                        sessionEmail: sessionEmail,
                        context: "bootstrap_restore_business_owner_fallback"
                    )
                    logBusinessSessionRestoreDebug("restoreBusinessReturned=\(restoredBusiness)")
                    if restoredBusiness {
                        logBusinessSessionRestoreDebug("restoreCompleted=business")
                        print("SESSION RESTORED:", sessionEmail)
                        return
                    }
                    await applyFanUserSessionRestoreAfterBootstrap(
                        session: session,
                        sessionEmail: sessionEmail,
                        clearVenueOwnerCaches: false
                    )
                    logBusinessOwnerSessionFlags(context: "bootstrap_restore_fan_user")
                    print("SESSION RESTORED:", sessionEmail)
                    Task {
                        await self.enforceFanSingleSessionOnForeground()
                        await self.startFanSingleSessionRealtimeIfNeeded()
                    }
                    return
                }
        }
    }

    /// Profile bootstrap, fan profile row, favorites, and Following-tab caches. Runs after Discover core so map/calendar are not blocked.
    func refreshUserPersonalizationInBackground() async {
        let t0 = Date()
        switch await supabaseResolvedAuthSessionResult() {
        case .active:
            break
        case .missingSession:
            await markTransientMissingSessionPreserved(
                reason: "personalizationMissingSession",
                source: "MapViewModel.refreshUserPersonalizationInBackground"
            )
            #if DEBUG
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[Background] personalization loaded ms=\(ms) (no session)")
            #endif
            return
        case .refreshFailed(let error):
            await MainActor.run {
                markAuthRefreshFailed(error, reason: "personalization")
            }
            #if DEBUG
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[Background] personalization skipped ms=\(ms) (auth refresh failed)")
            #endif
            return
        }

        guard await checkCurrentUserAdminStatus() else {
            #if DEBUG
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[Background] personalization blocked ms=\(ms) (account unavailable)")
            #endif
            return
        }

        let skipPersonalization = await MainActor.run {
            isAdminLoggedIn
        }
        if skipPersonalization {
            #if DEBUG
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[Background] personalization skipped ms=\(ms) (admin)")
            #endif
            return
        }

        await prefetchLightweightUserDataForStartup()

        #if DEBUG
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("[Background] personalization loaded ms=\(ms)")
        #endif
    }

    // Called on app launch when something needs the legacy “await everything” behavior: session + personalization in sequence.
    func restoreSession() async {
        await bootstrapAuthSessionOnly()
        guard await checkCurrentUserAdminStatus() else { return }
        await refreshUserPersonalizationInBackground()
    }

    private struct UserAdFreeEntitlementRow: Decodable {
        let ad_free_enabled: Bool?
    }

    /// Lightweight refresh of `user_profiles.ad_free_enabled` for the signed-in fan.
    func refreshCurrentUserAdFreeEntitlementFromServer(reason: String) async {
        let sessionResolution = await supabaseResolvedAuthSessionResult()
        guard case .active(let session) = sessionResolution else { return }
        guard await checkCurrentUserAdminStatus() else { return }

        do {
            let rows: [UserAdFreeEntitlementRow] = try await supabase
                .from("user_profiles")
                .select("ad_free_enabled")
                .eq("id", value: session.user.id)
                .limit(1)
                .execute()
                .value
            let enabled = rows.first?.ad_free_enabled == true
            await MainActor.run {
                FanGeoUserEntitlements.apply(adFreeEnabled: enabled)
            }
#if DEBUG
            print("[AdDebug] adFreeEntitlementRefresh reason=\(reason) ad_free_enabled=\(enabled)")
#endif
        } catch {
#if DEBUG
            print("[AdDebug] adFreeEntitlementRefreshFailed reason=\(reason) error=\(error.localizedDescription)")
#endif
        }
    }

    // Fetches the row for the current user by `auth.uid` when a session exists; otherwise falls back to email (e.g. venue-owner context without fan session).
    func loadUserProfile() async {
        if let ownedTask = await MainActor.run(body: { profileLoadTask }) {
            await ownedTask.value
            return
        }

        let sessionResolution = await supabaseResolvedAuthSessionResult()
        if case .refreshFailed(let error) = sessionResolution {
            let generation = await MainActor.run { accountProfileGeneration }
            let userId = await MainActor.run { currentUserAuthId }
            await MainActor.run {
                markAuthRefreshFailed(error, reason: "loadUserProfile")
                finishProfilePresentationLoad(profileExists: false, userId: userId, generation: generation)
            }
#if DEBUG
            print("[ProfilePersistenceDebug] profileLoadSkipped reason=authRefreshFailed")
#endif
            return
        }

        if case .active(let session) = sessionResolution {
            let generation = await MainActor.run { accountProfileGeneration }
            let applied = await performProfileLoad(
                userId: session.user.id,
                generation: generation,
                reason: "loadUserProfile",
                isRetry: false
            )
            if !applied {
                await MainActor.run {
                    cancelProfilePresentationLoadIfOwned(userId: session.user.id, generation: generation)
                }
            }
            return
        }

        let email = await MainActor.run {
            !currentUserEmail.isEmpty ? currentUserEmail : venueOwnerEmail
        }
        let generation = await MainActor.run { accountProfileGeneration }

        guard !email.isEmpty else {
            await MainActor.run {
                finishProfilePresentationLoad(profileExists: false, generation: generation)
            }
            print("NO USER EMAIL FOR PROFILE LOAD")
            return
        }

        do {
            try Task.checkCancellation()
            let rows: [UserProfileRow] = try await supabase
                .from("user_profiles")
                .select(Self.userProfileSelectColumns)
                .eq("email", value: email)
                .eq("admin_status", value: "active")
                .limit(1)
                .execute()
                .value

            if let profile = rows.first {
#if DEBUG
                print("[ProfilePersistenceDebug] existingProfileFound=true")
#endif
                if profile.isDeletedAccount {
                    await handleDeletedCurrentUser()
                    await MainActor.run {
                        finishProfilePresentationLoad(profileExists: false, generation: generation)
                    }
                    return
                }
                await MainActor.run {
                    guard let profileAuthId = profile.id else {
                        finishProfilePresentationLoad(profileExists: false, generation: generation)
                        return
                    }
                    if applyLoadedUserProfileRow(profile, authId: profileAuthId, generation: generation) {
                        finishProfilePresentationLoad(profileExists: true, userId: profileAuthId, generation: generation)
                    }
                }
#if DEBUG
                print("[ProfileDiscoverabilityDebug] loaded=\(profile.discoverableByFans)")
#endif

                print("USER PROFILE LOADED")
                await refreshProfileXP()
            } else {
#if DEBUG
                print("[ProfilePersistenceDebug] existingProfileFound=false")
#endif
                await MainActor.run {
                    finishProfilePresentationLoad(profileExists: false, generation: generation)
                }
                print("NO USER PROFILE FOUND")
            }

        } catch {
            if isProfileLoadCancellation(error) {
#if DEBUG
                print("[ProfilePersistenceDebug] profileDecodeFailed=\(error.localizedDescription)")
#endif
                return
            }
#if DEBUG
            print("[ProfilePersistenceDebug] profileDecodeFailed=\(error.localizedDescription)")
#endif
            await MainActor.run {
                finishProfilePresentationLoad(profileExists: false, generation: generation)
            }
            print("ERROR LOADING USER PROFILE:", error)
        }
    }

    /// Checks whether a @handle is available for the signed-in user (`check_username_available` RPC).
    func checkUsernameAvailable(_ rawHandle: String) async -> Bool? {
        let stored = FanGeoHandleRules.normalizeForStorage(rawHandle)
        print("[HandleValidationDebug] normalizedHandle=\(stored)")
        // Format only — reserved-token policy is enforced by edit/signup validators before this RPC.
        guard FanGeoHandleRules.validateFormat(rawHandle) == nil else {
            print("[HandleValidationDebug] handleRejected reason=invalid")
            return false
        }

        let session: Session
        do {
            session = try await supabase.auth.session
        } catch {
            return nil
        }

        struct RpcParams: Encodable {
            let p_username: String
            let p_exclude_user_id: UUID
        }

        do {
            print("[HandleValidationDebug] availabilityCheck=\(stored)")
            let available: Bool = try await supabase
                .rpc(
                    "check_username_available",
                    params: RpcParams(p_username: stored, p_exclude_user_id: session.user.id)
                )
                .execute()
                .value
#if DEBUG
            print("[HandleAvailabilityDebug] handle=\(stored) available=\(available)")
#endif
            print("[HandleValidationDebug] handleAvailable=\(available)")
            return available
        } catch {
#if DEBUG
            print("[HandleAvailabilityDebug] rpc_failed handle=\(stored) error=\(error.localizedDescription)")
#endif
            return nil
        }
    }

    /// Writes avatar URLs to `user_profiles` without touching identity/handle fields.
    /// Publishes ``FanProfileChangeCenter`` only after the profile row update succeeds.
    @discardableResult
    func persistUserProfileAvatar(
        fullURL: String,
        thumbnailURL: String?,
        replacedFullURL: String? = nil,
        replacedThumbnailURL: String? = nil
    ) async -> String? {
        let session: Session
        do {
            session = try await supabase.auth.session
        } catch {
            return "You need to be signed in to save your profile."
        }

        let authId = session.user.id
        let authIdKey = authId.uuidString.lowercased()
        await MainActor.run { currentUserAuthId = authId }

        let canonFull = ImageDisplayURL.canonicalStorageURLString(fullURL)
        guard !canonFull.isEmpty else {
            return "Unable to save avatar URL."
        }

        let finalThumb: String? = {
            guard let thumbnailURL else { return nil }
            let trimmed = thumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let canonical = ImageDisplayURL.canonicalStorageURLString(trimmed)
            return canonical.isEmpty ? nil : canonical
        }()

        await ensureUserProfileExists()

        do {
            let avatarPatch = UserProfileAvatarPatch(
                avatar_url: canonFull,
                avatar_thumbnail_url: finalThumb
            )
#if DEBUG
            ProfileAvatarDebug.profileUpdateStarted(fields: "avatar_url,avatar_thumbnail_url")
#endif
            try await supabase
                .from("user_profiles")
                .update(avatarPatch)
                .eq("id", value: authIdKey)
                .execute()

            let change = FanProfileAvatarChange(
                userId: authId,
                avatarURL: canonFull,
                avatarThumbnailURL: finalThumb
            )
            FanProfileChangeCenter.invalidateCachedAvatarImages(
                previousAvatarURL: replacedFullURL,
                previousThumbnailURL: replacedThumbnailURL,
                nextAvatarURL: canonFull,
                nextThumbnailURL: finalThumb
            )
            await MainActor.run {
                currentUserAvatarURL = canonFull
                currentUserAvatarThumbnailURL = finalThumb ?? ""
                bumpCurrentUserAvatarDisplayRefresh()
                cacheCurrentUserProfileLocally()
                applyFanProfileAvatarChangeToLocalCaches(change)
            }
            FanProfileChangeCenter.postAvatarChange(change)
#if DEBUG
            ProfileAvatarDebug.profileUpdated(avatarURLPresent: true)
#endif
            Task {
                await deleteReplacedStorageObjectIfNeeded(
                    oldPublicURL: replacedFullURL,
                    newPublicURL: canonFull,
                    bucket: "user-avatars"
                )
                await deleteReplacedStorageObjectIfNeeded(
                    oldPublicURL: replacedThumbnailURL,
                    newPublicURL: finalThumb ?? canonFull,
                    bucket: "user-avatars"
                )
            }
            return nil
        } catch {
            print("ERROR PERSISTING USER AVATAR:", error)
            // Orphan cleanup: remove newly uploaded objects that never became the profile URL.
            Task {
                await deleteReplacedStorageObjectIfNeeded(
                    oldPublicURL: canonFull,
                    newPublicURL: "",
                    bucket: "user-avatars"
                )
                if let finalThumb, !finalThumb.isEmpty {
                    await deleteReplacedStorageObjectIfNeeded(
                        oldPublicURL: finalThumb,
                        newPublicURL: "",
                        bucket: "user-avatars"
                    )
                }
            }
            return "Couldn't save your avatar. Please try again."
        }
    }

    /// Merges a coarse avatar URL change into MapViewModel profile presentation caches.
    @MainActor
    func applyFanProfileAvatarChangeToLocalCaches(_ change: FanProfileAvatarChange) {
        let userId = change.userId
        let full = change.avatarURL
        let thumb = change.avatarThumbnailURL

        func patched(_ row: UserProfileRow) -> UserProfileRow {
            UserProfileRow(
                id: row.id,
                email: row.email,
                display_name: row.display_name,
                username: row.username,
                bio: row.bio,
                avatar_url: full.isEmpty ? row.avatar_url : full,
                avatar_thumbnail_url: thumb ?? row.avatar_thumbnail_url,
                is_business_account: row.is_business_account,
                admin_status: row.admin_status,
                live_visibility_enabled: row.live_visibility_enabled,
                live_visibility_mode: row.live_visibility_mode,
                selected_live_visibility_friend_ids: row.selected_live_visibility_friend_ids,
                discoverable_by_fans: row.discoverable_by_fans,
                activity_status_visible: row.activity_status_visible,
                is_deleted: row.is_deleted,
                created_at: row.created_at,
                last_seen_at: row.last_seen_at,
                national_team_country_code: row.national_team_country_code,
                national_team_country_name: row.national_team_country_name,
                national_team_flag: row.national_team_flag,
                national_team_supporter_label: row.national_team_supporter_label,
                national_team_updated_at: row.national_team_updated_at,
                ad_free_enabled: row.ad_free_enabled,
                home_city: row.home_city,
                home_region: row.home_region,
                home_country: row.home_country,
                show_home_city: row.show_home_city,
                profile_background_key: row.profile_background_key
            )
        }

        for (key, row) in userProfilesByEmail where row.id == userId {
            userProfilesByEmail[key] = patched(row)
        }
        if let row = pickupJoinRequesterProfileByUserId[userId] {
            pickupJoinRequesterProfileByUserId[userId] = patched(row)
        }
        goingUserProfiles = goingUserProfiles.map { $0.id == userId ? patched($0) : $0 }
        for eventID in goingProfilesByVenueEventID.keys {
            goingProfilesByVenueEventID[eventID] = goingProfilesByVenueEventID[eventID]?.map {
                $0.id == userId ? patched($0) : $0
            }
        }
        ProfilePhase1PersonalizationCache.applyAvatarChange(change)
    }

    /// Upserts `user_profiles` keyed by authenticated user id. Returns `nil` on success, or a user-visible error string.
    @discardableResult
    func saveUserProfile(
        displayName: String,
        avatarURL: String,
        avatarThumbnailURL: String? = nil,
        username: String? = nil,
        bio: String? = nil
    ) async -> String? {
        let session: Session
        do {
            session = try await supabase.auth.session
        } catch {
#if DEBUG
            print("[ProfileSave] no authenticated session; skipping user_profiles upsert")
#endif
            return "You need to be signed in to save your profile."
        }

        let authId = session.user.id
        let emailFromSession = OwnerBusinessEmail.normalized(session.user.email ?? "")
        let emailForRow: String
        if !emailFromSession.isEmpty {
            emailForRow = emailFromSession
        } else {
            let fallback = OwnerBusinessEmail.normalized(currentUserEmail)
            guard !fallback.isEmpty else {
#if DEBUG
                print("[ProfileSave] auth user id = \(authId)")
                print("[ProfileSave] profile upsert id = \(authId)")
                print("[ProfileSave] current email = (empty — cannot upsert user_profiles without email)")
#endif
                return "You need to be signed in to save your profile."
            }
            emailForRow = fallback
        }

#if DEBUG
        print("[ProfileSave] auth user id = \(authId)")
        print("[ProfileSave] profile upsert id = \(authId)")
        print("[ProfileSave] current email = \(emailForRow)")
        print("[ProfilePersistenceDebug] loadingProfileForUserId=\(authId.uuidString.lowercased())")
        print("[FanProfileSave] requestStarted table=user_profiles")
#endif

        if let cached = currentUserAuthId, cached != authId {
#if DEBUG
            print("[ProfileSave] warning: currentUserAuthId \(cached) differs from session \(authId); using session id")
#endif
        }
        await MainActor.run { currentUserAuthId = authId }

        let existingProfile: UserProfileIdentityRow?
        do {
            let rows: [UserProfileIdentityRow] = try await supabase
                .from("user_profiles")
                .select(Self.userProfileIdentitySelectColumns)
                .eq("id", value: authId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value
            existingProfile = rows.first
#if DEBUG
            print("[ProfilePersistenceDebug] existingProfileFound=\(existingProfile != nil)")
#endif
        } catch {
#if DEBUG
            print("[ProfilePersistenceDebug] profileDecodeFailed=\(error.localizedDescription)")
            print("[ProfilePersistenceDebug] preventedBlankProfileOverwrite=true reason=existing_profile_unavailable")
#endif
            return "Couldn’t verify your existing profile before saving. Please try again."
        }

        if existingProfile?.is_deleted == true {
            if let session = try? await supabase.auth.session,
               await shouldSuppressDeletedProfileBlockForBusinessSession(
                    session: session,
                    context: "saveUserProfile"
               ) {
                return "Business profile restore is still finishing. Please try again in a moment."
            }
            await handleDeletedCurrentUser()
            return "This account has been deleted.\nContact support if you believe this was a mistake."
        }

        let localDisplayWasBlank = await MainActor.run {
            currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let incomingDisplay = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingDisplay = Self.trimmedNonEmpty(existingProfile?.display_name)
        let finalDisplayName: String
        var preventedBlankProfileOverwrite = false
        if !existingDisplay.isEmpty,
           incomingDisplay.isEmpty || (localDisplayWasBlank && Self.isEmailFallbackDisplayName(incomingDisplay, email: emailForRow)) {
            finalDisplayName = existingDisplay
            preventedBlankProfileOverwrite = true
        } else {
            finalDisplayName = displayName
        }

        if let nameReservedError = ReservedNameValidation.editReservedRejectionMessage(
            edited: finalDisplayName,
            original: existingDisplay.isEmpty ? currentUserDisplayName : existingDisplay
        ) {
#if DEBUG
            print("[FanProfileValidation] originalDisplayName=\(existingDisplay.isEmpty ? currentUserDisplayName : existingDisplay)")
            print("[FanProfileValidation] draftDisplayName=\(finalDisplayName)")
            print("[FanProfileValidation] reservedDisplayNameResult=true")
            print("[FanProfileValidation] saveAllowed=false reason=reservedDisplayName")
#endif
            return nameReservedError
        }
#if DEBUG
        if ReservedNameValidation.containsReservedTerm(finalDisplayName) {
            print("[FanProfileValidation] reservedDisplayNameResult=grandfatheredBaselineTokens")
        }
#endif

        if let username {
            let stored = FanGeoHandleRules.normalizeForStorage(username)
            let existingHandleRaw = Self.trimmedNonEmpty(existingProfile?.username).isEmpty
                ? currentUserUsername
                : Self.trimmedNonEmpty(existingProfile?.username)
            let existingStored = FanGeoHandleRules.normalizeForStorage(existingHandleRaw)
            let handleChanged = stored != existingStored
#if DEBUG
            print("[FanProfileValidation] originalHandle=\(existingHandleRaw)")
            print("[FanProfileValidation] draftHandle=\(username)")
            print("[FanProfileValidation] normalizedOriginalHandle=\(existingStored)")
            print("[FanProfileValidation] normalizedDraftHandle=\(stored)")
            print("[FanProfileValidation] handleChanged=\(handleChanged)")
#endif
            if handleChanged {
                if let handleError = FanIdentityValidation.validateHandleForEdit(
                    username,
                    original: existingHandleRaw
                ) {
                    print("[HandleValidationDebug] handleRejected reason=editValidation")
#if DEBUG
                    print("[FanProfileValidation] reservedHandleResult=\(handleError == ReservedNameValidation.rejectionMessage)")
                    print("[FanProfileValidation] handleAvailabilityState=skipped_invalid")
                    print("[FanProfileValidation] saveAllowed=false reason=handleInvalid")
#endif
                    return handleError
                }
                print("[HandleValidationDebug] normalizedHandle=\(stored)")
                guard !stored.isEmpty else {
                    print("[HandleValidationDebug] handleRejected reason=empty")
#if DEBUG
                    print("[FanProfileValidation] handleAvailabilityState=empty")
                    print("[FanProfileValidation] saveAllowed=false reason=emptyHandle")
#endif
                    return "Choose a @handle."
                }
                if let available = await checkUsernameAvailable(stored) {
#if DEBUG
                    print("[FanProfileValidation] reservedHandleResult=false")
                    print("[FanProfileValidation] handleAvailabilityState=\(available ? "available" : "taken")")
#endif
                    if !available {
                        print("[HandleValidationDebug] handleRejected reason=already_taken")
#if DEBUG
                        print("[FanProfileValidation] saveAllowed=false reason=handleTaken")
#endif
                        return "That handle is already taken."
                    }
                } else {
#if DEBUG
                    print("[FanProfileValidation] handleAvailabilityState=rpc_failed")
                    print("[FanProfileValidation] saveAllowed=false reason=handleAvailabilityUnknown")
#endif
                    return "Could not verify whether this handle is available. Please try again."
                }
            } else {
#if DEBUG
                print("[FanProfileValidation] reservedHandleResult=skippedUnchanged")
                print("[FanProfileValidation] handleAvailabilityState=skippedUnchangedOwnHandle")
#endif
            }
        }

#if DEBUG
        print("[FanProfileValidation] saveAllowed=true")
#endif

        let usernameToSave: String? = {
            if let username {
                let stored = FanGeoHandleRules.normalizeForStorage(username)
                return stored.isEmpty ? nil : stored
            }
            let existing = currentUserUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            return existing.isEmpty ? nil : FanGeoHandleRules.normalizeForStorage(existing)
        }()

        let finalBioToSave: String? = {
            let candidate: String
            if let bio {
                candidate = bio.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                let current = currentUserBio.trimmingCharacters(in: .whitespacesAndNewlines)
                candidate = current.isEmpty ? Self.trimmedNonEmpty(existingProfile?.bio) : current
            }
            return candidate.isEmpty ? nil : candidate
        }()
        if let finalBioToSave, finalBioToSave.count > 160 {
            return "Bio must be 160 characters or less."
        }

        do {
            let canonFull = ImageDisplayURL.canonicalStorageURLString(avatarURL)
            let updatingAvatar = !canonFull.isEmpty
            let existingAvatarURL = ImageDisplayURL.canonicalStorageURLString(existingProfile?.avatar_url)
            let finalAvatarURL: String
            if updatingAvatar {
                finalAvatarURL = canonFull
            } else if !existingAvatarURL.isEmpty {
                finalAvatarURL = existingAvatarURL
            } else {
                finalAvatarURL = ""
            }

            let resolvedThumb: String? = {
                if let t = avatarThumbnailURL {
                    let x = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !x.isEmpty else { return nil }
                    let c = ImageDisplayURL.canonicalStorageURLString(x)
                    return c.isEmpty ? nil : c
                }
                let x = currentUserAvatarThumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !x.isEmpty else { return nil }
                let c = ImageDisplayURL.canonicalStorageURLString(x)
                return c.isEmpty ? nil : c
            }()
            let existingAvatarThumbnailURL = ImageDisplayURL.canonicalStorageURLString(existingProfile?.avatar_thumbnail_url)
            let finalAvatarThumbnailURL: String? = {
                guard updatingAvatar else {
                    if !existingAvatarThumbnailURL.isEmpty {
                        return existingAvatarThumbnailURL
                    }
                    return nil
                }
                let incoming = ImageDisplayURL.canonicalStorageURLString(resolvedThumb)
                if incoming.isEmpty, !existingAvatarThumbnailURL.isEmpty {
                    preventedBlankProfileOverwrite = true
                    return existingAvatarThumbnailURL
                }
                return incoming.isEmpty ? nil : incoming
            }()

            let existingUsername = Self.trimmedNonEmpty(existingProfile?.username)
            let finalUsernameToSave: String?
            if usernameToSave == nil, !existingUsername.isEmpty {
                finalUsernameToSave = FanGeoHandleRules.normalizeForStorage(existingUsername)
                preventedBlankProfileOverwrite = true
            } else {
                finalUsernameToSave = usernameToSave
            }

            let authIdKey = authId.uuidString.lowercased()

#if DEBUG
            print(
                "[ProfilePersistenceDebug] profileUpsertPayload=id=\(authIdKey), email=\(emailForRow), displayNameEmpty=\(finalDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), usernameEmpty=\((finalUsernameToSave ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), bioLength=\(finalBioToSave?.count ?? 0), avatarEmpty=\(finalAvatarURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), updatingAvatar=\(updatingAvatar), live_visibility_enabled=\(currentUserLiveVisibilityEnabled), live_visibility_mode=\(currentUserLiveVisibilityMode.rawValue), selectedFriendCount=\(currentUserSelectedLiveVisibilityFriendIDs.count), discoverable_by_fans=\(currentUserDiscoverableByFans)"
            )
            if preventedBlankProfileOverwrite {
                print("[ProfilePersistenceDebug] preventedBlankProfileOverwrite=true")
            }
#endif

            if existingProfile != nil {
                let savePatch = UserProfileSavePatch(
                    email: emailForRow,
                    display_name: finalDisplayName,
                    username: finalUsernameToSave,
                    bio: finalBioToSave,
                    live_visibility_enabled: currentUserLiveVisibilityEnabled,
                    live_visibility_mode: currentUserLiveVisibilityMode.rawValue,
                    selected_live_visibility_friend_ids: currentUserSelectedLiveVisibilityFriendIDs
                        .sorted { $0.uuidString < $1.uuidString }
                        .map { $0.uuidString.lowercased() },
                    discoverable_by_fans: currentUserDiscoverableByFans
                )
                try await supabase
                    .from("user_profiles")
                    .update(savePatch)
                    .eq("id", value: authIdKey)
                    .execute()

                if updatingAvatar {
#if DEBUG
                    ProfileAvatarDebug.profileUpdateStarted(fields: "avatar_url,avatar_thumbnail_url")
#endif
                    let avatarPatch = UserProfileAvatarPatch(
                        avatar_url: finalAvatarURL,
                        avatar_thumbnail_url: finalAvatarThumbnailURL
                    )
                    try await supabase
                        .from("user_profiles")
                        .update(avatarPatch)
                        .eq("id", value: authIdKey)
                        .execute()
#if DEBUG
                    ProfileAvatarDebug.profileUpdated(avatarURLPresent: !finalAvatarURL.isEmpty)
#endif
                }
            } else {
                let profile = UserProfileInsert(
                    id: authId,
                    email: emailForRow,
                    display_name: finalDisplayName,
                    username: finalUsernameToSave,
                    bio: finalBioToSave,
                    avatar_url: finalAvatarURL,
                    avatar_thumbnail_url: finalAvatarThumbnailURL,
                    live_visibility_enabled: currentUserLiveVisibilityEnabled,
                    live_visibility_mode: currentUserLiveVisibilityMode.rawValue,
                    selected_live_visibility_friend_ids: currentUserSelectedLiveVisibilityFriendIDs
                        .sorted { $0.uuidString < $1.uuidString }
                        .map { $0.uuidString.lowercased() },
                    discoverable_by_fans: currentUserDiscoverableByFans
                )
                if updatingAvatar {
#if DEBUG
                    ProfileAvatarDebug.profileUpdateStarted(fields: "avatar_url,avatar_thumbnail_url")
#endif
                }
                try await supabase
                    .from("user_profiles")
                    .upsert(profile, onConflict: "id")
                    .execute()
#if DEBUG
                if updatingAvatar {
                    ProfileAvatarDebug.profileUpdated(avatarURLPresent: !finalAvatarURL.isEmpty)
                }
#endif
            }

            await MainActor.run {
                if currentUserEmail != emailForRow {
                    currentUserEmail = emailForRow
                }
                currentUserDisplayName = finalDisplayName
                if let finalUsernameToSave {
                    currentUserUsername = finalUsernameToSave
                }
                currentUserBio = finalBioToSave ?? ""
                if updatingAvatar {
                    currentUserAvatarURL = finalAvatarURL
                    currentUserAvatarThumbnailURL = finalAvatarThumbnailURL ?? ""
                    bumpCurrentUserAvatarDisplayRefresh()
                    let change = FanProfileAvatarChange(
                        userId: authId,
                        avatarURL: finalAvatarURL,
                        avatarThumbnailURL: finalAvatarThumbnailURL
                    )
                    applyFanProfileAvatarChangeToLocalCaches(change)
                    FanProfileChangeCenter.postAvatarChange(change)
                } else if !finalAvatarURL.isEmpty {
                    currentUserAvatarURL = finalAvatarURL
                    currentUserAvatarThumbnailURL = finalAvatarThumbnailURL ?? ""
                }
                cacheCurrentUserProfileLocally()
                applyCurrentUserBioToProfileCaches(bio: finalBioToSave)
                publicProfileBioRevision &+= 1
            }

#if DEBUG
            print("[ProfileBioDebug] saveBio=\(finalBioToSave ?? "")")
            print("[ProfileBioDebug] savedUserProfilesBio=\(finalBioToSave ?? "")")
            print("[FanProfileSave] requestSucceeded table=user_profiles username=\(finalUsernameToSave ?? "") bioLen=\(finalBioToSave?.count ?? 0)")
            print("[FanProfileSave] profileRefreshed=true source=localViewModelCache")
#endif
            print("[HandleValidationDebug] profileSaved handle=\(finalUsernameToSave.map { FanGeoHandleRules.displayHandle(stored: $0) } ?? "nil")")
            print("USER PROFILE SAVED")
            return nil

        } catch {
            print("ERROR SAVING USER PROFILE:", error)
#if DEBUG
            print("[FanProfileSave] requestFailed=\(error.localizedDescription)")
#endif
            if Self.isDuplicateUsernameConstraintViolation(error) {
                return "That handle is already taken."
            }
            return "Couldn’t save your profile. Please try again."
        }
    }

    func setLiveVisibilityEnabled(_ enabled: Bool) async {
        await setLiveVisibilitySettings(
            enabled: enabled,
            mode: currentUserLiveVisibilityMode,
            selectedFriendIDs: currentUserSelectedLiveVisibilityFriendIDs
        )
    }

    func setProfileDiscoverableByFans(_ discoverable: Bool) async {
        guard canUseFanSocialFeatures else {
            await MainActor.run {
                socialActionToastText = "Profile discoverability is available for fan accounts only."
                socialActionToastIsError = true
            }
            return
        }

        let session: Session
        do {
            session = try await supabase.auth.session
        } catch {
            await MainActor.run {
                socialActionToastText = "Sign in to update profile discoverability."
                socialActionToastIsError = true
            }
            return
        }

        let previous = await MainActor.run { currentUserDiscoverableByFans }
        guard previous != discoverable else {
#if DEBUG
            print("[ProfileDiscoverabilityDebug] saved=\(discoverable) skipped=true")
#endif
            return
        }

        await MainActor.run {
            currentUserDiscoverableByFans = discoverable
            isUpdatingProfileDiscoverabilitySetting = true
            cacheCurrentUserProfileLocally()
        }

        do {
            try await supabase
                .from("user_profiles")
                .update(UserProfileDiscoverabilityPatch(discoverable_by_fans: discoverable))
                .eq("id", value: session.user.id.uuidString.lowercased())
                .execute()

#if DEBUG
            print("[ProfileDiscoverabilityDebug] saved=\(discoverable)")
#endif

            await MainActor.run {
                isUpdatingProfileDiscoverabilitySetting = false
            }

            // Discoverability alone is not Nearby — write a fresh coarse location when enabling.
            FansNearbyService.shared.invalidateAmongMembership(reason: "discoverabilityChanged")
            if discoverable {
                _ = await refreshCurrentUserLocationIfAuthorized(timeoutSeconds: 5)
                await MainActor.run {
                    if let coordinate = currentUserLocation {
                        PresenceService.shared.updateHeartbeatLocation(
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude
                        )
                    }
                    PresenceService.shared.startIfNeeded(
                        userID: session.user.id,
                        isAuthenticated: true,
                        reason: "discoverabilityEnabled"
                    )
                }
                _ = await PresenceService.shared.sendHeartbeatAwaitingWrite(
                    reason: "discoverabilityEnabled",
                    force: true
                )
            }
        } catch {
#if DEBUG
            Self.logPostgrestError("[ProfileDiscoverabilityDebug] save failed", error)
#endif
            await MainActor.run {
                currentUserDiscoverableByFans = previous
                isUpdatingProfileDiscoverabilitySetting = false
                cacheCurrentUserProfileLocally()
                socialActionToastText = "Couldn’t update profile discoverability. Please try again."
                socialActionToastIsError = true
            }
        }
    }

    func setActivityStatusVisible(_ visible: Bool) async {
        let session: Session
        do {
            session = try await supabase.auth.session
        } catch {
            await MainActor.run {
                socialActionToastText = "Sign in to update activity status."
                socialActionToastIsError = true
            }
            return
        }

        let previous = await MainActor.run { currentUserActivityStatusVisible }
        guard previous != visible else { return }

        await MainActor.run {
            currentUserActivityStatusVisible = visible
            isUpdatingActivityStatusVisibilitySetting = true
            cacheCurrentUserProfileLocally()
        }

        do {
            try await supabase
                .from("user_profiles")
                .update(UserProfileActivityStatusVisibilityPatch(activity_status_visible: visible))
                .eq("id", value: session.user.id.uuidString.lowercased())
                .execute()
            await MainActor.run {
                isUpdatingActivityStatusVisibilitySetting = false
            }
            ActivityStatusDebug.lifecycle(
                visible ? "activity visibility enabled" : "activity visibility disabled",
                details: "saved=true"
            )
        } catch {
            await MainActor.run {
                currentUserActivityStatusVisible = previous
                isUpdatingActivityStatusVisibilitySetting = false
                cacheCurrentUserProfileLocally()
                socialActionToastText = "Couldn’t update activity status. Please try again."
                socialActionToastIsError = true
            }
            ActivityStatusDebug.lifecycle("statistics request failed", details: "reason=activity_visibility_save")
        }
    }

    @discardableResult
    func saveNationalTeamIdentity(_ identity: NationalTeamIdentity) async -> String? {
        let session: Session
        do {
            session = try await supabase.auth.session
        } catch {
            return "Sign in to update your national team."
        }

        let storedSupporterLabel = NationalTeamCopy.storageSupporterLabelKey(from: identity.supporterLabel)
        let storedIdentity = NationalTeamIdentity(
            countryCode: identity.countryCode,
            countryName: identity.countryName,
            flag: identity.flag,
            supporterLabel: storedSupporterLabel
        )
        let patch = UserProfileNationalTeamPatch(
            national_team_country_code: storedIdentity.countryCode,
            national_team_country_name: storedIdentity.countryName,
            national_team_flag: storedIdentity.flag,
            national_team_supporter_label: storedIdentity.supporterLabel,
            national_team_updated_at: ISO8601DateFormatter().string(from: Date())
        )

        do {
            try await supabase
                .from("user_profiles")
                .update(patch)
                .eq("id", value: session.user.id.uuidString.lowercased())
                .execute()

            await MainActor.run {
                currentUserNationalTeam = storedIdentity
                cacheCurrentUserProfileLocally()
                publicProfileBioRevision &+= 1
#if DEBUG
                print("[NationalTeamDebug] profileSavedNationalTeam=\(storedIdentity.countryCode)")
#endif
            }
            return nil
        } catch {
#if DEBUG
            Self.logPostgrestError("[NationalTeamDebug] save failed", error)
#endif
            return "Couldn’t save your national team. Please try again."
        }
    }

    @discardableResult
    func saveUserProfileHomeCity(
        city: String,
        region: String,
        country: String,
        displayFallback: String,
        showOnProfile: Bool
    ) async -> String? {
        let session: Session
        do {
            session = try await supabase.auth.session
        } catch {
            return "Sign in to update your home city."
        }

        func normalizedOptional(_ raw: String) -> String? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let resolvedCity = normalizedOptional(city) ?? normalizedOptional(displayFallback)
        let resolvedRegion = normalizedOptional(region)
        let resolvedCountry = normalizedOptional(country)
        let resolvedShowOnProfile = showOnProfile && resolvedCity != nil

        let patch = UserProfileHomeCityPatch(
            home_city: resolvedCity,
            home_region: resolvedRegion,
            home_country: resolvedCountry,
            show_home_city: resolvedShowOnProfile
        )

        do {
            try await supabase
                .from("user_profiles")
                .update(patch)
                .eq("id", value: session.user.id.uuidString.lowercased())
                .execute()

            await MainActor.run {
                currentUserHomeCity = resolvedCity ?? ""
                currentUserHomeRegion = resolvedRegion ?? ""
                currentUserHomeCountry = resolvedCountry ?? ""
                currentUserShowHomeCity = resolvedShowOnProfile
                cacheCurrentUserProfileLocally()
                publicProfileBioRevision &+= 1
            }
            return nil
        } catch {
#if DEBUG
            Self.logPostgrestError("[HomeCityDebug] save failed", error)
#endif
            return "Couldn’t save your home city. Please try again."
        }
    }

    @discardableResult
    func saveUserProfileBackgroundKey(_ key: ProfileBackgroundKey) async -> String? {
        let session: Session
        do {
            session = try await supabase.auth.session
        } catch {
            return "Sign in to update your profile background."
        }

        let resolved = ProfileBackgroundCatalog.resolveKey(key.rawValue)
        let patch = UserProfileBackgroundPatch(profile_background_key: resolved.rawValue)

        do {
            try await supabase
                .from("user_profiles")
                .update(patch)
                .eq("id", value: session.user.id.uuidString.lowercased())
                .execute()

            await MainActor.run {
                currentUserProfileBackgroundKey = resolved
                cacheCurrentUserProfileLocally()
                publicProfileBioRevision &+= 1
            }
            return nil
        } catch {
#if DEBUG
            Self.logPostgrestError("[ProfileBackground] save failed", error)
#endif
            return "Couldn’t save your profile background. Please try again."
        }
    }

    @MainActor
    private func applyCurrentUserHomeCityFromProfile(_ profile: UserProfileRow) {
        currentUserHomeCity = profile.home_city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        currentUserHomeRegion = profile.home_region?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        currentUserHomeCountry = profile.home_country?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        currentUserShowHomeCity = profile.showsHomeCityOnProfile
    }

    func setLiveVisibilityMode(_ mode: LiveVisibilityMode) async {
        await setLiveVisibilitySettings(
            enabled: currentUserLiveVisibilityEnabled,
            mode: mode,
            selectedFriendIDs: currentUserSelectedLiveVisibilityFriendIDs
        )
    }

    func setSelectedLiveVisibilityFriendIDs(_ selectedFriendIDs: Set<UUID>) async {
        await setLiveVisibilitySettings(
            enabled: currentUserLiveVisibilityEnabled,
            mode: currentUserLiveVisibilityMode,
            selectedFriendIDs: selectedFriendIDs
        )
    }

    func setLiveVisibilitySettings(
        enabled: Bool,
        mode: LiveVisibilityMode,
        selectedFriendIDs: Set<UUID>
    ) async {
        guard canUseFanSocialFeatures else {
            await MainActor.run {
                socialActionToastText = "Live friend presence is available for fan accounts only."
                socialActionToastIsError = true
            }
            return
        }

        let session: Session
        do {
            session = try await supabase.auth.session
        } catch {
            await MainActor.run {
                socialActionToastText = "Sign in to update Live visibility."
                socialActionToastIsError = true
            }
            return
        }

        let selectedIDs = selectedFriendIDs.sorted { $0.uuidString < $1.uuidString }
        let selectedIDStrings = selectedIDs.map { $0.uuidString.lowercased() }
        let payloadDebugDescription = "enabled=\(enabled), mode=\(mode.rawValue), selected_live_visibility_friend_ids=\(selectedIDStrings)"
        let previous = await MainActor.run {
            (
                enabled: currentUserLiveVisibilityEnabled,
                mode: currentUserLiveVisibilityMode,
                selectedFriendIDs: currentUserSelectedLiveVisibilityFriendIDs
            )
        }

        if previous.enabled == enabled,
           previous.mode == mode,
           previous.selectedFriendIDs == Set(selectedIDs) {
#if DEBUG
            print("[LiveVisibilityDebug] no changes; skipping save")
            print("[LiveVisibilityDebug] selectedFriendCount=\(selectedIDs.count)")
#endif
            return
        }

#if DEBUG
        print("[LiveVisibilityDebug] payload=\(payloadDebugDescription)")
        print("[LiveVisibilityDebug] selectedFriendCount=\(selectedIDs.count)")
        print("[ProfilePersistenceDebug] liveVisibilityUpdatePayload=\(payloadDebugDescription)")
#endif

        await MainActor.run {
            currentUserLiveVisibilityEnabled = enabled
            currentUserLiveVisibilityMode = mode
            currentUserSelectedLiveVisibilityFriendIDs = Set(selectedIDs)
            isUpdatingLiveVisibilitySetting = true
            applyCurrentUserLiveVisibilityToProfileCaches(
                enabled: enabled,
                mode: mode,
                selectedFriendIDs: selectedIDs,
                userId: session.user.id
            )
            cacheCurrentUserProfileLocally()
        }

        do {
            let response = try await supabase
                .from("user_profiles")
                .update(
                    UserLiveVisibilityPatch(
                        live_visibility_enabled: enabled,
                        live_visibility_mode: mode.rawValue,
                        selected_live_visibility_friend_ids: selectedIDStrings
                    )
                )
                .eq("id", value: session.user.id.uuidString.lowercased())
                .execute()

#if DEBUG
            print("[LiveVisibilityDebug] response=\(response)")
#endif

            await MainActor.run {
                isUpdatingLiveVisibilitySetting = false
                refreshLiveVisibilityPresentationCaches()
            }
        } catch {
            if Self.isMissingLiveVisibilityAudienceColumnsError(error) {
#if DEBUG
                print("[LiveVisibilityDebug] error=\(error)")
                Self.logPostgrestError("[LiveVisibilityDebug] missing audience columns; trying boolean-only fallback", error)
#endif
                do {
                    let fallbackResponse = try await supabase
                        .from("user_profiles")
                        .update(UserLiveVisibilityEnabledPatch(live_visibility_enabled: enabled))
                        .eq("id", value: session.user.id.uuidString.lowercased())
                        .execute()

#if DEBUG
                    print("[LiveVisibilityDebug] response=\(fallbackResponse)")
#endif

                    await MainActor.run {
                        isUpdatingLiveVisibilitySetting = false
                        refreshLiveVisibilityPresentationCaches()
                        if mode == .selectedFriends {
                            socialActionToastText = "Live sharing was updated, but Selected Friends needs the latest Supabase migration."
                            socialActionToastIsError = true
                        }
                    }
                    return
                } catch {
#if DEBUG
                    print("[LiveVisibilityDebug] error=\(error)")
                    Self.logPostgrestError("[LiveVisibilityDebug] boolean-only fallback failed", error)
#endif
                    await MainActor.run {
                        currentUserLiveVisibilityEnabled = previous.enabled
                        currentUserLiveVisibilityMode = previous.mode
                        currentUserSelectedLiveVisibilityFriendIDs = previous.selectedFriendIDs
                        isUpdatingLiveVisibilitySetting = false
                        applyCurrentUserLiveVisibilityToProfileCaches(
                            enabled: previous.enabled,
                            mode: previous.mode,
                            selectedFriendIDs: previous.selectedFriendIDs.sorted { $0.uuidString < $1.uuidString },
                            userId: session.user.id
                        )
                        cacheCurrentUserProfileLocally()
                        socialActionToastText = Self.isMissingLiveVisibilityEnabledColumnError(error)
                            ? "Live visibility needs the latest Supabase migration before it can be saved."
                            : "Couldn’t update Live visibility. Please try again."
                        socialActionToastIsError = true
                    }
                    return
                }
            }

            await MainActor.run {
                currentUserLiveVisibilityEnabled = previous.enabled
                currentUserLiveVisibilityMode = previous.mode
                currentUserSelectedLiveVisibilityFriendIDs = previous.selectedFriendIDs
                isUpdatingLiveVisibilitySetting = false
                applyCurrentUserLiveVisibilityToProfileCaches(
                    enabled: previous.enabled,
                    mode: previous.mode,
                    selectedFriendIDs: previous.selectedFriendIDs.sorted { $0.uuidString < $1.uuidString },
                    userId: session.user.id
                )
                cacheCurrentUserProfileLocally()
                socialActionToastText = "Couldn’t update Live visibility. Please try again."
                socialActionToastIsError = true
            }
#if DEBUG
            print("[LiveVisibilityDebug] error=\(error)")
            Self.logPostgrestError("[LiveVisibility] update failed", error)
#endif
        }
    }

    @MainActor
    func applyCurrentUserBioToProfileCaches(bio: String?) {
        guard let userId = currentUserAuthId else { return }
        let trimmed = bio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedBio = trimmed.isEmpty ? nil : trimmed

        func patched(_ row: UserProfileRow) -> UserProfileRow {
            UserProfileRow(
                id: row.id,
                email: row.email,
                display_name: row.display_name,
                username: row.username,
                bio: normalizedBio,
                avatar_url: row.avatar_url,
                avatar_thumbnail_url: row.avatar_thumbnail_url,
                is_business_account: row.is_business_account,
                admin_status: row.admin_status,
                live_visibility_enabled: row.live_visibility_enabled,
                live_visibility_mode: row.live_visibility_mode,
                selected_live_visibility_friend_ids: row.selected_live_visibility_friend_ids,
                discoverable_by_fans: row.discoverable_by_fans,
                is_deleted: row.is_deleted,
                created_at: row.created_at,
                national_team_country_code: row.national_team_country_code,
                national_team_country_name: row.national_team_country_name,
                national_team_flag: row.national_team_flag,
                national_team_supporter_label: row.national_team_supporter_label,
                national_team_updated_at: row.national_team_updated_at
            )
        }

        let currentEmail = OwnerBusinessEmail.normalized(currentUserEmail)
        for (key, row) in userProfilesByEmail {
            let rowEmail = OwnerBusinessEmail.normalized(row.email ?? "")
            if row.id == userId || (!currentEmail.isEmpty && rowEmail == currentEmail) {
                userProfilesByEmail[key] = patched(row)
            }
        }

        if let row = pickupJoinRequesterProfileByUserId[userId] {
            pickupJoinRequesterProfileByUserId[userId] = patched(row)
        }

        goingUserProfiles = goingUserProfiles.map { $0.id == userId ? patched($0) : $0 }
        for eventID in goingProfilesByVenueEventID.keys {
            goingProfilesByVenueEventID[eventID] = goingProfilesByVenueEventID[eventID]?.map {
                $0.id == userId ? patched($0) : $0
            }
        }
    }

    @MainActor
    private func applyCurrentUserLiveVisibilityToProfileCaches(
        enabled: Bool,
        mode: LiveVisibilityMode,
        selectedFriendIDs: [UUID],
        userId: UUID
    ) {
        func patched(_ row: UserProfileRow) -> UserProfileRow {
            UserProfileRow(
                id: row.id,
                email: row.email,
                display_name: row.display_name,
                username: row.username,
                bio: row.bio,
                avatar_url: row.avatar_url,
                avatar_thumbnail_url: row.avatar_thumbnail_url,
                is_business_account: row.is_business_account,
                admin_status: row.admin_status,
                live_visibility_enabled: enabled,
                live_visibility_mode: mode.rawValue,
                selected_live_visibility_friend_ids: selectedFriendIDs,
                discoverable_by_fans: row.discoverable_by_fans,
                is_deleted: row.is_deleted,
                national_team_country_code: row.national_team_country_code,
                national_team_country_name: row.national_team_country_name,
                national_team_flag: row.national_team_flag,
                national_team_supporter_label: row.national_team_supporter_label,
                national_team_updated_at: row.national_team_updated_at
            )
        }

        let currentEmail = OwnerBusinessEmail.normalized(currentUserEmail)
        for (key, row) in userProfilesByEmail {
            let rowEmail = OwnerBusinessEmail.normalized(row.email ?? "")
            if row.id == userId || (!currentEmail.isEmpty && rowEmail == currentEmail) {
                userProfilesByEmail[key] = patched(row)
            }
        }

        goingUserProfiles = goingUserProfiles.map { $0.id == userId ? patched($0) : $0 }
        for eventID in goingProfilesByVenueEventID.keys {
            goingProfilesByVenueEventID[eventID] = goingProfilesByVenueEventID[eventID]?.map {
                $0.id == userId ? patched($0) : $0
            }
        }
    }

    @MainActor
    private func refreshLiveVisibilityPresentationCaches() {
        fanUpdatesGoingProfilePrefetchedAt.removeAll()
        refreshFollowingInterestDerivedSnapshotsForUI()
    }

    private static func isDuplicateUsernameConstraintViolation(_ error: Error) -> Bool {
        let d = error.localizedDescription.lowercased()
        let isDup = d.contains("23505") || d.contains("duplicate key")
        guard isDup else { return false }
        return d.contains("username")
            || d.contains("uq_user_profiles_username_lower")
            || d.contains("handle")
            || d.contains("idx_user_profiles_handle_unique")
    }

    /// Uploads full + thumbnail JPEGs to `user-avatars` under `{auth_user_uuid}/` (RLS: first path segment must equal `auth.uid()`).
    /// Always uses a unique versioned object path so the public URL changes on every successful upload.
    /// Does not delete the previous object — callers must delete via ``UploadedAvatarURLs/replacedFullURL`` only after the profile row is updated.
    func uploadUserAvatar(data: Data, fileName: String? = nil) async -> UploadedAvatarURLs? {
        do {
            let session = try await supabase.auth.session
            let authUserId = session.user.id
#if DEBUG
            ProfileAvatarDebug.uploadStarted(userId: authUserId)
            print("[ProfileSave] auth user id = \(authUserId) (avatar storage path prefix)")
#endif
            let folder = authUserId.uuidString.lowercased()

            let requested = (fileName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            _ = requested // Call sites may still pass a hint; uploads always use a unique versioned path.
            let normalizedFileName = Self.makeVersionedAvatarFileName()

            let pathFull = "\(folder)/\(normalizedFileName)"
            let thumbName = Self.companionAvatarThumbnailFileName(for: normalizedFileName)
            let pathThumb = "\(folder)/\(thumbName)"

            let oldFull = ImageDisplayURL.canonicalStorageURLString(currentUserAvatarURL)
            let oldThumb = ImageDisplayURL.canonicalStorageURLString(currentUserAvatarThumbnailURL)

            let uploadFull = ImageCompression.jpegDataForUpload(from: data, preset: .avatar)
            let uploadThumb = ImageCompression.jpegDataForUpload(from: data, preset: .avatarThumbnail)

            try await supabase.storage
                .from("user-avatars")
                .upload(
                    pathFull,
                    data: uploadFull,
                    options: FileOptions(
                        contentType: "image/jpeg",
                        upsert: false
                    )
                )

            try await supabase.storage
                .from("user-avatars")
                .upload(
                    pathThumb,
                    data: uploadThumb,
                    options: FileOptions(
                        contentType: "image/jpeg",
                        upsert: false
                    )
                )

            let publicFull = try supabase.storage
                .from("user-avatars")
                .getPublicURL(path: pathFull)
            let publicThumb = try supabase.storage
                .from("user-avatars")
                .getPublicURL(path: pathThumb)

            let fullStr = ImageDisplayURL.canonicalStorageURLString(publicFull.absoluteString)
            let thumbStr = ImageDisplayURL.canonicalStorageURLString(publicThumb.absoluteString)

#if DEBUG
            ProfileAvatarDebug.uploadSucceeded(urlPresent: !fullStr.isEmpty)
            assert(fullStr != oldFull || oldFull.isEmpty, "Avatar upload must produce a new public URL")
#endif
            return UploadedAvatarURLs(
                fullURL: fullStr,
                thumbnailURL: thumbStr,
                replacedFullURL: oldFull.isEmpty ? nil : oldFull,
                replacedThumbnailURL: oldThumb.isEmpty ? nil : oldThumb
            )

        } catch {
            print("ERROR UPLOADING USER AVATAR:", error)
            print("hint: Require a signed-in Supabase session with a user id; path must be user-avatars/{auth.uid}/… and Storage RLS must allow that folder.")
            return nil
        }
    }

    // Batch-loads display names/avatars for a set of emails (e.g. “who’s going”) into `userProfilesByEmail`.
    func loadUserProfilesForEmails(_ emails: [String]) async {
        let uniqueEmails = Array(
            Set(
                emails
                    .map(OwnerBusinessEmail.normalized)
                    .filter(OwnerBusinessEmail.isValidStrict)
            )
        )

        guard !uniqueEmails.isEmpty else { return }

        do {
            let rows = try await SocialIdentityService().fetchUserProfileRows(forEmails: uniqueEmails)
            let fetchedKeys = Set(
                rows.compactMap { profile -> String? in
                    let key = OwnerBusinessEmail.normalized(profile.email ?? "")
                    return OwnerBusinessEmail.isValidStrict(key) ? key : nil
                }
            )

            await MainActor.run {
                let unresolvedKeys = Set(uniqueEmails).subtracting(fetchedKeys)
                for key in unresolvedKeys {
                    removeStaleFanProfileCacheEntry(forNormalizedEmail: key)
                }

                for profile in rows {
                    guard let raw = profile.email else { continue }
                    let key = OwnerBusinessEmail.normalized(raw)
                    guard OwnerBusinessEmail.isValidStrict(key) else { continue }
                    if profile.isDeletedAccount, let id = profile.id {
                        removeStaleFanProfileCacheEntries(forDeletedUserId: id, keepingNormalizedEmail: key)
                    }
                    if let existing = userProfilesByEmail[key] {
                        if existing.isBusinessIdentity, !profile.isBusinessIdentity {
                            userProfilesByEmail[key] = profile
                        } else if !existing.isBusinessIdentity, !profile.isBusinessIdentity {
                            userProfilesByEmail[key] = mergeFanProfileRow(existing: existing, fetched: profile)
                        }
                    } else {
                        userProfilesByEmail[key] = profile
                    }
                }
            }

        } catch {
            print("ERROR LOADING USER PROFILES FOR EMAILS:", error)
        }
    }

    private func removeStaleFanProfileCacheEntry(forNormalizedEmail normalizedEmail: String) {
        let keysToRemove = userProfilesByEmail.keys.filter { key in
            OwnerBusinessEmail.normalized(key) == normalizedEmail
        }
        for key in keysToRemove {
            if userProfilesByEmail[key]?.isBusinessIdentity != true {
                userProfilesByEmail.removeValue(forKey: key)
            }
        }
    }

    private func removeStaleFanProfileCacheEntries(forDeletedUserId userId: UUID, keepingNormalizedEmail keepEmail: String) {
        let keysToRemove = userProfilesByEmail.compactMap { key, profile -> String? in
            guard profile.id == userId else { return nil }
            guard profile.isBusinessIdentity != true else { return nil }
            return OwnerBusinessEmail.normalized(key) == keepEmail ? nil : key
        }
        for key in keysToRemove {
            userProfilesByEmail.removeValue(forKey: key)
        }
    }

    @MainActor
    func invalidateFanChatAuthorProfileCache(for emails: [String]) {
        let normalizedEmails = Set(
            emails
                .map(OwnerBusinessEmail.normalized)
                .filter(OwnerBusinessEmail.isValidStrict)
        )
        for email in normalizedEmails {
            removeStaleFanProfileCacheEntry(forNormalizedEmail: email)
        }
    }

    /// Prefer fresher `user_profiles.bio` when batch-loading social identity rows.
    private func mergeFanProfileRow(existing: UserProfileRow, fetched: UserProfileRow) -> UserProfileRow {
        if fetched.isDeletedAccount {
            return UserProfileRow(
                id: fetched.id ?? existing.id,
                email: fetched.email ?? existing.email,
                display_name: "Deleted User",
                username: nil,
                bio: nil,
                avatar_url: nil,
                avatar_thumbnail_url: nil,
                is_business_account: false,
                admin_status: fetched.admin_status ?? existing.admin_status,
                live_visibility_enabled: false,
                live_visibility_mode: LiveVisibilityMode.allFriends.rawValue,
                selected_live_visibility_friend_ids: [],
                discoverable_by_fans: false,
                is_deleted: true,
                created_at: fetched.created_at ?? existing.created_at
            )
        }
        let existingBio = existing.bio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fetchedBio = fetched.bio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedBio: String?
        if !fetchedBio.isEmpty {
            resolvedBio = fetchedBio
        } else if !existingBio.isEmpty {
            resolvedBio = existingBio
        } else {
            resolvedBio = nil
        }

        return UserProfileRow(
            id: fetched.id ?? existing.id,
            email: fetched.email ?? existing.email,
            display_name: {
                let f = fetched.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !f.isEmpty { return f }
                return existing.display_name
            }(),
            username: {
                let f = fetched.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !f.isEmpty { return f }
                return existing.username
            }(),
            bio: resolvedBio,
            avatar_url: {
                let f = ImageDisplayURL.canonicalStorageURLString(fetched.avatar_url)
                if !f.isEmpty { return f }
                return existing.avatar_url
            }(),
            avatar_thumbnail_url: {
                let f = ImageDisplayURL.canonicalStorageURLString(fetched.avatar_thumbnail_url)
                if !f.isEmpty { return f }
                return existing.avatar_thumbnail_url
            }(),
            is_business_account: fetched.is_business_account ?? existing.is_business_account,
            admin_status: fetched.admin_status ?? existing.admin_status,
            live_visibility_enabled: fetched.live_visibility_enabled ?? existing.live_visibility_enabled,
            live_visibility_mode: fetched.live_visibility_mode ?? existing.live_visibility_mode,
            selected_live_visibility_friend_ids: fetched.selected_live_visibility_friend_ids
                ?? existing.selected_live_visibility_friend_ids,
            discoverable_by_fans: fetched.discoverable_by_fans ?? existing.discoverable_by_fans,
            is_deleted: fetched.is_deleted ?? existing.is_deleted,
            created_at: fetched.created_at ?? existing.created_at
        )
    }

    func cacheCurrentUserProfileLocally() {
        UserDefaults.standard.set(currentUserDisplayName, forKey: "cachedUserDisplayName")
        UserDefaults.standard.set(currentUserUsername, forKey: "cachedUserUsername")
        UserDefaults.standard.set(currentUserBio, forKey: "cachedUserBio")
        UserDefaults.standard.set(currentUserProfileCreatedAt, forKey: "cachedUserProfileCreatedAt")
        UserDefaults.standard.set(currentUserAvatarURL, forKey: "cachedUserAvatarURL")
        UserDefaults.standard.set(currentUserAvatarThumbnailURL, forKey: "cachedUserAvatarThumbnailURL")
        if let currentUserNationalTeam {
            UserDefaults.standard.set(currentUserNationalTeam.countryCode, forKey: "cachedUserNationalTeamCountryCode")
            UserDefaults.standard.set(currentUserNationalTeam.countryName, forKey: "cachedUserNationalTeamCountryName")
            UserDefaults.standard.set(currentUserNationalTeam.flag, forKey: "cachedUserNationalTeamFlag")
            UserDefaults.standard.set(currentUserNationalTeam.supporterLabel, forKey: "cachedUserNationalTeamSupporterLabel")
        } else {
            UserDefaults.standard.removeObject(forKey: "cachedUserNationalTeamCountryCode")
            UserDefaults.standard.removeObject(forKey: "cachedUserNationalTeamCountryName")
            UserDefaults.standard.removeObject(forKey: "cachedUserNationalTeamFlag")
            UserDefaults.standard.removeObject(forKey: "cachedUserNationalTeamSupporterLabel")
        }
        UserDefaults.standard.set(currentUserLiveVisibilityEnabled, forKey: "cachedUserLiveVisibilityEnabled")
        UserDefaults.standard.set(currentUserLiveVisibilityMode.rawValue, forKey: "cachedUserLiveVisibilityMode")
        UserDefaults.standard.set(currentUserDiscoverableByFans, forKey: "cachedUserDiscoverableByFans")
        UserDefaults.standard.set(currentUserActivityStatusVisible, forKey: "cachedUserActivityStatusVisible")
        UserDefaults.standard.set(currentUserHomeCity, forKey: "cachedUserHomeCity")
        UserDefaults.standard.set(currentUserHomeRegion, forKey: "cachedUserHomeRegion")
        UserDefaults.standard.set(currentUserHomeCountry, forKey: "cachedUserHomeCountry")
        UserDefaults.standard.set(currentUserShowHomeCity, forKey: "cachedUserShowHomeCity")
        UserDefaults.standard.set(currentUserProfileBackgroundKey.rawValue, forKey: "cachedUserProfileBackgroundKey")
        UserDefaults.standard.set(
            currentUserSelectedLiveVisibilityFriendIDs.map { $0.uuidString.lowercased() }.sorted(),
            forKey: "cachedUserSelectedLiveVisibilityFriendIDs"
        )
    }

    private func cachedLiveVisibilityMode() -> LiveVisibilityMode {
        LiveVisibilityMode(rawValue: UserDefaults.standard.string(forKey: "cachedUserLiveVisibilityMode") ?? "") ?? .allFriends
    }

    private func cachedSelectedLiveVisibilityFriendIDs() -> Set<UUID> {
        let raw = UserDefaults.standard.stringArray(forKey: "cachedUserSelectedLiveVisibilityFriendIDs") ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    private func cachedNationalTeamIdentity() -> NationalTeamIdentity? {
        NationalTeamIdentity.fromProfile(
            countryCode: UserDefaults.standard.string(forKey: "cachedUserNationalTeamCountryCode"),
            countryName: UserDefaults.standard.string(forKey: "cachedUserNationalTeamCountryName"),
            flag: UserDefaults.standard.string(forKey: "cachedUserNationalTeamFlag"),
            supporterLabel: UserDefaults.standard.string(forKey: "cachedUserNationalTeamSupporterLabel")
        )
    }

    enum PasswordResetAccountKind {
        case fan
        case venueOwner
    }

    /// Sends Supabase Auth password recovery email; routes feedback to fan vs venue-owner UI strings on ``MapViewModel``.
    func sendPasswordResetEmail(_ email: String, accountKind: PasswordResetAccountKind) async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
#if DEBUG
        if case .fan = accountKind {
            print("[FanPasswordResetDebug] resetEmail=\(trimmed)")
        }
        if case .venueOwner = accountKind {
            print("[BusinessPasswordResetDebug] resetEmail=\(trimmed)")
        }
#endif
        guard !trimmed.isEmpty else {
            print("[PasswordResetDebug] success=false step=send_reset_link error=missing_email")
            await MainActor.run {
                switch accountKind {
                case .fan:
                    userPasswordResetError = "Enter your email first."
                    userPasswordResetMessage = ""
#if DEBUG
                    print("[FanPasswordResetDebug] resetError=Enter your email first.")
#endif
                case .venueOwner:
                    venuePasswordResetError = "Enter your business email first."
                    venuePasswordResetMessage = ""
#if DEBUG
                    print("[BusinessPasswordResetDebug] resetError=Enter your business email first.")
#endif
                }
            }
            return
        }

        do {
            print("[PasswordResetDebug] step=send_reset_link")
            try await supabase.auth.resetPasswordForEmail(
                trimmed,
                redirectTo: Self.fanPasswordResetRedirectURL
            )
            await MainActor.run {
                switch accountKind {
                case .fan:
                    userPasswordResetMessage = Self.withEmailDeliveryGuidance("If an account exists for this email, we sent a password reset link.")
                    userPasswordResetError = ""
                    print("[PasswordResetDebug] success=true step=send_reset_link")
#if DEBUG
                    print("[FanPasswordResetDebug] resetLinkSent=true")
#endif
                case .venueOwner:
                    venuePasswordResetMessage = Self.withEmailDeliveryGuidance("If an account exists for this email, we sent a password reset link.")
                    venuePasswordResetError = ""
                    print("[PasswordResetDebug] success=true step=send_reset_link")
#if DEBUG
                    print("[BusinessPasswordResetDebug] resetLinkSent=true")
#endif
                }
            }
        } catch {
            await MainActor.run {
                switch accountKind {
                case .fan:
                    userPasswordResetMessage = ""
                    userPasswordResetError = error.localizedDescription
                    print("[PasswordResetDebug] success=false step=send_reset_link error=\(error.localizedDescription)")
#if DEBUG
                    print("[FanPasswordResetDebug] resetError=\(error.localizedDescription)")
#endif
                case .venueOwner:
                    venuePasswordResetMessage = ""
                    venuePasswordResetError = error.localizedDescription
                    print("[PasswordResetDebug] success=false step=send_reset_link error=\(error.localizedDescription)")
#if DEBUG
                    print("[BusinessPasswordResetDebug] resetError=\(error.localizedDescription)")
#endif
                }
            }
        }
    }

    func handlePasswordResetDeepLink(_ url: URL) async {
        guard Self.isPasswordResetDeepLink(url) else { return }
        let params = Self.passwordResetDeepLinkParams(from: url)
        print("[PasswordResetDebug] deepLinkReceived=\(Self.redactedPasswordResetDeepLinkDescription(url, params: params))")
        await MainActor.run {
            passwordResetUpdateMessage = ""
            passwordResetUpdateError = ""
        }

        do {
            UserDefaults.standard.set(false, forKey: Self.didExplicitlyLogoutKey)
            let session = try await passwordResetRecoverySession(from: url, params: params)
            print("[PasswordResetDebug] recoverySessionDetected=true")

            guard await passwordResetRecoverySessionIsAllowed(session: session) else {
                print("[PasswordResetDebug] recoveryError=deleted_or_disabled_account")
                return
            }

            await MainActor.run {
                currentUserAuthId = session.user.id
                isPasswordResetRecoverySessionActive = true
                queuePasswordResetCreateSheetForRecovery()
            }
        } catch {
            await MainActor.run {
                passwordResetUpdateError = "This reset link is invalid or expired. Please request a new password reset link."
                isPasswordResetRecoverySessionActive = false
                queuePasswordResetCreateSheetForRecovery()
            }
            print("[PasswordResetDebug] recoverySessionDetected=false")
            print("[PasswordResetDebug] recoveryError=\(error.localizedDescription)")
        }
    }

    @MainActor
    func passwordResetRequestSheetDidAppear() {
        isPasswordResetRequestSheetPresented = true
        print("[PasswordResetDebug] sheetMode=\(passwordResetSheetMode.rawValue)")
    }

    @MainActor
    func passwordResetRequestSheetDidDisappear() {
        isPasswordResetRequestSheetPresented = false
    }

    @MainActor
    private func queuePasswordResetCreateSheetForRecovery() {
        passwordResetSheetMode = .createPassword
        isShowingPasswordResetCreateSheet = true
        print("[PasswordResetDebug] sheetMode=createPassword")
        print("[PasswordResetDebug] rootRecoveryPresentation=true")
        print("[PasswordResetDebug] blockingAllOtherAuthSheets=true")
        if isPasswordResetRequestSheetPresented {
            print("[PasswordResetDebug] reusedExistingSheetForRecovery=true")
        }
        print("[PasswordResetDebug] showingCreatePassword=true")
    }

    var passwordResetRequestSheetPresentationBlocked: Bool {
        isPasswordResetRecoverySessionActive || isShowingPasswordResetCreateSheet
    }

    @MainActor
    func canPresentPasswordResetRequestSheet() -> Bool {
        guard !passwordResetRequestSheetPresentationBlocked else {
            print("[PasswordResetDebug] blockedRequestSheetDuringRecovery=true")
            return false
        }
        passwordResetSheetMode = .requestLink
        print("[PasswordResetDebug] sheetMode=requestLink")
        return true
    }

    private func passwordResetRecoverySession(from url: URL, params: [String: String]) async throws -> Session {
        if let accessToken = params["access_token"], let refreshToken = params["refresh_token"] {
            return try await supabase.auth.setSession(accessToken: accessToken, refreshToken: refreshToken)
        }

        if let tokenHash = params["token_hash"] ?? params["token_hashes"] {
            let response = try await supabase.auth.verifyOTP(tokenHash: tokenHash, type: .recovery)
            if let session = response.session {
                return session
            }
        }

        return try await supabase.auth.session(from: url)
    }

    func updateRecoveredPassword(_ newPassword: String) async {
        print("[PasswordResetDebug] step=update_password")
        await MainActor.run {
            passwordResetUpdateMessage = ""
            passwordResetUpdateError = ""
        }

        do {
            let session = try await supabase.auth.session
            guard await passwordResetRecoverySessionIsAllowed(session: session) else {
                print("[PasswordResetDebug] success=false step=update_password error=deleted_or_disabled_account")
                return
            }

            try await supabase.auth.update(user: UserAttributes(password: newPassword))
            print("[PasswordResetDebug] success=true step=update_password")

            await forceLogout(reason: "passwordResetCompleted", source: "MapViewModel.updateRecoveredPassword")

            await MainActor.run {
                isPasswordResetRecoverySessionActive = false
                isShowingPasswordResetCreateSheet = false
                passwordResetSheetMode = .requestLink
                passwordResetUpdateMessage = "Your password has been updated. Please sign in again."
            }
        } catch {
            await MainActor.run {
                passwordResetUpdateError = error.localizedDescription
            }
            print("[PasswordResetDebug] success=false step=update_password error=\(error.localizedDescription)")
        }
    }

    func cancelPasswordResetRecovery() async {
        print("[PasswordResetDebug] step=cancel_recovery")
        if isPasswordResetRecoverySessionActive {
            await forceLogout(reason: "passwordResetCancelled", source: "MapViewModel.cancelPasswordResetRecovery")
            print("[PasswordResetDebug] success=true step=cancel_recovery")
        } else {
            print("[PasswordResetDebug] signOutSkipped=true reason=no_recovery_session")
        }

        await MainActor.run {
            isPasswordResetRecoverySessionActive = false
            isShowingPasswordResetCreateSheet = false
            passwordResetSheetMode = .requestLink
            passwordResetUpdateError = ""
        }
    }

    private static func isPasswordResetDeepLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "fangeo" else { return false }
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        return host == "reset-password" || path == "/reset-password"
    }

    private static func isEmailVerificationDeepLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "fangeo" else { return false }
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        return host == "email-confirmed"
            || path == "/email-confirmed"
            || host == "auth-callback"
            || path == "/auth-callback"
    }

    private static func passwordResetDeepLinkParams(from url: URL) -> [String: String] {
        var result: [String: String] = [:]
        if let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in queryItems {
                result[item.name] = item.value ?? ""
            }
        }
        if let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment,
           let fragmentItems = URLComponents(string: "https://fangeo.local?\(fragment)")?.queryItems {
            for item in fragmentItems {
                result[item.name] = item.value ?? ""
            }
        }
        return result
    }

    private static func redactedPasswordResetDeepLinkDescription(_ url: URL, params: [String: String]) -> String {
        let host = url.host ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        let paramKeys = params.keys.sorted().joined(separator: ",")
        return "\(url.scheme ?? "unknown")://\(host)\(path) params=[\(paramKeys)]"
    }

    private func passwordResetRecoverySessionIsAllowed(session: Session) async -> Bool {
        do {
            let rows: [UserProfileRow] = try await supabase
                .from("user_profiles")
                .select(Self.userProfileSelectColumns)
                .eq("id", value: session.user.id.uuidString.lowercased())
                .limit(1)
                .execute()
                .value

            if let profile = rows.first, profile.isDeletedAccount {
                if await shouldSuppressDeletedProfileBlockForBusinessSession(
                    session: session,
                    context: "passwordResetRecovery"
                ) {
                    return false
                }
                await handleDeletedCurrentUser()
                return false
            }

            if let profile = rows.first,
               let status = profile.admin_status,
               status != "active" {
                await handleDisabledCurrentUser()
                return false
            }

            return true
        } catch {
            print("[PasswordResetDebug] success=false step=profile_check error=\(error.localizedDescription)")
            return true
        }
    }
}
