import Foundation
import CryptoKit
import Supabase

private struct AppleExistingFanProfileRow: Decodable {
    let id: UUID?
    let is_deleted: Bool?
    let admin_status: String?
}

extension MapViewModel {
    var isAppleFanSignupOnboardingActive: Bool {
        if isDeletedAccountLoginBlocked {
            return false
        }
        if !OwnerBusinessEmail.normalized(applePendingFanSignupEmail).isEmpty {
            return true
        }
        return appleFanOnboardingPasswordBypassActive
    }

    @MainActor
    func clearPendingAppleFanSignupState(reason: String) {
        applePendingFanSignupEmail = ""
        applePendingFanSignupDisplayName = ""
        appleFanOnboardingPasswordBypassActive = false
#if DEBUG
        print("[DeletedAccountLoginDebug] pendingAppleSignupCleared reason=\(reason)")
#endif
    }

    static func authUserIsAppleOnly(_ user: User) -> Bool {
        let identityProviders = user.identities?
            .map { $0.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty } ?? []
        if !identityProviders.isEmpty {
            return identityProviders.contains("apple") && !identityProviders.contains("email")
        }

        if let provider = user.appMetadata["provider"]?.stringValue {
            return provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "apple"
        }
        return false
    }

    func syncAppleFanSignupOnboardingFromActiveSession() async {
        guard !isDeletedAccountLoginBlocked else { return }
        guard !isLoggedIn else { return }
        do {
            let session = try await supabase.auth.session
            guard Self.authUserIsAppleOnly(session.user) else { return }

            let lifecycle = await resolveFanProfileLifecycleState(userId: session.user.id)
            switch lifecycle {
            case .deleted:
#if DEBUG
                print("[DeletedAccountLoginDebug] onboardingRoutePrevented reason=deleted_account source=syncAppleFanSignupOnboardingFromActiveSession")
#endif
                _ = await enforceDeletedFanAccountLoginGate(
                    userId: session.user.id,
                    sessionEmail: OwnerBusinessEmail.normalized(session.user.email ?? ""),
                    source: "syncAppleFanSignupOnboardingFromActiveSession"
                )
                return
            case .disabled:
                await handleDisabledCurrentUser()
                return
            case .missing:
                break
            case .active, .suspended, .business, .unknown:
                await MainActor.run {
                    clearPendingAppleFanSignupState(reason: "activeProfileNoOnboarding")
                }
                return
            }

            let sessionEmail = OwnerBusinessEmail.normalized(session.user.email ?? "")
            guard OwnerBusinessEmail.isValidStrict(sessionEmail) else { return }

#if DEBUG
            print("[DeletedAccountLoginDebug] missingProfileOnboardingAllowed userId=\(session.user.id.uuidString.lowercased())")
#endif
            await MainActor.run {
                appleFanOnboardingPasswordBypassActive = true
                if applePendingFanSignupEmail.isEmpty {
                    applePendingFanSignupEmail = sessionEmail
                }
                if currentUserAuthId == nil {
                    currentUserAuthId = session.user.id
                }
                if currentUserEmail.isEmpty {
                    currentUserEmail = sessionEmail
                }
            }
            print("[AppleAuthDebug] appleFanOnboardingPasswordBypassActive=true source=activeSession")
            if sessionEmail.lowercased().contains("privaterelay.appleid.com") {
                print("[AppleAuthDebug] relayEmailUsed=true")
            }
        } catch {
            print("[AppleAuthDebug] syncAppleFanOnboardingFromActiveSessionSkipped=true reason=no_session")
        }
    }

    func clearAppleAuthMessage(accountMode: AppleAuthAccountMode, reason: String) {
        switch accountMode {
        case .fan:
            appleAuthFanMessageAutoClearTask?.cancel()
            appleAuthFanMessageAutoClearTask = nil
            guard !appleAuthFanMessage.isEmpty else { return }
            appleAuthFanMessage = ""
            appleAuthFanMessageIsError = false
        case .business:
            appleAuthBusinessMessageAutoClearTask?.cancel()
            appleAuthBusinessMessageAutoClearTask = nil
            guard !appleAuthBusinessMessage.isEmpty else { return }
            appleAuthBusinessMessage = ""
            appleAuthBusinessMessageIsError = false
        }
        print("[AppleAuthDebug] errorClearedReason=\(reason)")
    }

    func handleAppleAuthFailure(message: String, accountMode: AppleAuthAccountMode) async {
        print("[AppleAuthDebug] authError=\(message) accountMode=\(accountMode.rawValue)")
        print("[AppleAuthDebug] authFailureReason=\(message)")
        presentAppleAuthMessage(
            "Could not sign in with Apple. Please try again.",
            accountMode: accountMode,
            isError: true,
            autoClearAfterSeconds: 8
        )
    }

    func signInWithAppleIdentityToken(
        _ identityToken: String,
        rawNonce: String,
        email: String?,
        fullName: PersonNameComponents?,
        accountMode: AppleAuthAccountMode,
        entryPoint: AppleAuthEntryPoint = .signIn
    ) async {
        let isSignupEntry = entryPoint == .fanSignup || entryPoint == .businessSignup
        if isSignupEntry {
            guard await requireAgeAccessForSignUp() else {
                if AgeAccessGateService.shared.latestState.isBlockingUnder13 {
                    AgeAccessDebugLog.event("blocked")
                }
                return
            }
        }

        let method: SafeLoginMethod = accountMode == .fan ? .appleFan : .appleBusiness
        let generationOrNil = await MainActor.run {
            beginSafeLogin(method: method, source: "apple:\(entryPoint.rawValue)")
        }
        guard let generation = generationOrNil else { return }

        do {
            print("[AppleAuthDebug] supabaseSignInRequestStart=true accountMode=\(accountMode.rawValue) entryPoint=\(entryPoint.rawValue) identityTokenLength=\(identityToken.count) rawNonceLength=\(rawNonce.count) appleEmailProvided=\(email != nil)")
            Self.logAppleIdentityTokenClaims(identityToken, rawNonce: rawNonce)
            if entryPoint == .fanSignup {
                print("[FanSignupDebug] appleSupabaseSignInStart=true")
            }
            if entryPoint == .businessSignup {
                print("[BusinessSignup] appleSupabaseSignInStart=true")
            }
            await MainActor.run {
                clearEmailVerificationPending(clearFanDraft: true)
                clearAppleAuthMessage(accountMode: accountMode, reason: "authorizationStarted")
            }

            let session = try await supabase.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(
                    provider: .apple,
                    idToken: identityToken,
                    nonce: rawNonce
                )
            )

            guard await MainActor.run(body: { isActiveSafeLoginGeneration(generation) }) else {
                SafeLoginDebug.log("stale previous-session result ignored phase=applePostSignIn")
                return
            }

            await MainActor.run {
                markSafeLoginPreparingSession(generation: generation)
                // Fails closed unless this exact UUID was server-confirmed this session.
                // A sign-up grant is consumed later, once the profile row exists.
                AgeAccessGateService.shared.bindAuthenticatedUser(session.user.id, reason: .login)
            }

            print("[AppleAuthDebug] supabaseSignInSucceeded=true")
            print("[AppleAuthDebug] currentAuthUserId=\(session.user.id.uuidString.lowercased())")
            print("[AppleAuthDebug] currentAuthUserEmail=\(session.user.email ?? "nil")")
            if entryPoint == .fanSignup {
                print("[FanSignupDebug] appleSupabaseSignInSucceeded=true userId=\(session.user.id.uuidString.lowercased()) email=\(session.user.email ?? "nil")")
            }

            let sessionEmail = OwnerBusinessEmail.normalized(session.user.email ?? email ?? "")
            if sessionEmail.lowercased().contains("privaterelay.appleid.com") {
                print("[AppleAuthDebug] relayEmailUsed=true")
            }

            if await refreshActiveBanGate(reason: "appleLogin") {
                clearExplicitLogoutMarkerAfterManualAuthSucceeded()
                await MainActor.run {
                    clearSafeLoginProgress(generation: generation, reason: "appleBanGate")
                }
                return
            }

            switch accountMode {
            case .fan:
                await finishAppleFanSignIn(
                    session: session,
                    sessionEmail: sessionEmail,
                    fullName: fullName,
                    entryPoint: entryPoint,
                    loginGeneration: generation
                )
            case .business:
                await finishAppleBusinessSignIn(
                    session: session,
                    sessionEmail: sessionEmail,
                    fullName: fullName,
                    entryPoint: entryPoint,
                    loginGeneration: generation
                )
            }

            await MainActor.run {
                if isActiveSafeLoginGeneration(generation) {
                    let succeeded = accountMode == .fan ? isLoggedIn : isVenueOwnerLoggedIn
                    if succeeded {
                        completeSafeLoginSuccess(
                            generation: generation,
                            accountKind: accountMode == .fan ? "fan" : "business"
                        )
                    } else if isAppleFanSignupOnboardingActive || businessEmailVerifiedNeedsVenueSetup {
                        clearSafeLoginProgress(generation: generation, reason: "appleOnboardingHandoff")
                    } else {
                        let message = accountMode == .fan
                            ? (authErrorMessage.isEmpty ? appleAuthFanMessage : authErrorMessage)
                            : (venueAuthErrorMessage.isEmpty ? appleAuthBusinessMessage : venueAuthErrorMessage)
                        failSafeLogin(
                            generation: generation,
                            message: message,
                            accountMode: accountMode,
                            failurePhase: "appleFinishIncomplete"
                        )
                    }
                }
            }
        } catch {
            let nsError = error as NSError
            print("[AppleAuthDebug] supabaseSignInFailed=true domain=\(nsError.domain) code=\(nsError.code) localized=\(error.localizedDescription) raw=\(String(reflecting: error)) userInfo=\(nsError.userInfo)")
            print("[AppleAuthDebug] authError=\(error.localizedDescription)")
            print("[AppleAuthDebug] authFailureReason=\(String(reflecting: error))")
            if entryPoint == .fanSignup {
                print("[FanSignupDebug] appleSupabaseSignInFailed=true localized=\(error.localizedDescription) raw=\(String(reflecting: error))")
            }
            presentAppleAuthMessage(
                "Could not sign in with Apple. Please try again.",
                accountMode: accountMode,
                isError: true,
                autoClearAfterSeconds: 8
            )
            await MainActor.run {
                failSafeLogin(
                    generation: generation,
                    message: "Could not sign in with Apple. Please try again.",
                    accountMode: accountMode,
                    failurePhase: "appleSignInError"
                )
            }
        }
    }

    private func finishAppleFanSignIn(
        session: Session,
        sessionEmail: String,
        fullName: PersonNameComponents?,
        entryPoint: AppleAuthEntryPoint,
        loginGeneration: UInt64
    ) async {
        guard await MainActor.run(body: { isActiveSafeLoginGeneration(loginGeneration) }) else {
            SafeLoginDebug.log("stale previous-session result ignored phase=appleFanFinish")
            return
        }
        guard OwnerBusinessEmail.isValidStrict(sessionEmail) else {
            await forceLogout(reason: "appleFanMissingEmail", source: "MapViewModel.finishAppleFanSignIn")
            presentAppleAuthMessage(
                "Apple did not return a usable email address.",
                accountMode: .fan,
                isError: true,
                autoClearAfterSeconds: 8
            )
            return
        }

        if await businessAccountExistsForOwnerEmailOrUserId(email: sessionEmail, userId: session.user.id) {
            await undoPartialSupabaseSessionAfterAccountTypeMismatch()
            await MainActor.run { authErrorMessage = Self.fanLoginBlockedBecauseBusinessMessage }
            return
        }

        if await appleFanProfileConflictExists(email: sessionEmail, currentUserId: session.user.id) {
            return
        }

        guard await claimAccountIdentity(.fan, context: "appleFanSignIn") else {
            await MainActor.run {
                appleAuthFanMessage = authErrorMessage
                appleAuthFanMessageIsError = true
            }
            return
        }

#if DEBUG
        print("[DeletedAccountLoginDebug] appleCredentialReceived userId=\(session.user.id.uuidString.lowercased())")
#endif

        let lifecycle = await resolveFanProfileLifecycleState(userId: session.user.id)
        switch lifecycle {
        case .deleted:
#if DEBUG
            print("[DeletedAccountLoginDebug] lifecycleState=deleted")
            print("[DeletedAccountLoginDebug] onboardingRoutePrevented reason=deleted_account")
#endif
            _ = await enforceDeletedFanAccountLoginGate(
                userId: session.user.id,
                sessionEmail: sessionEmail,
                source: "appleFanSignIn"
            )
            return

        case .disabled:
            await handleDisabledCurrentUser()
            return

        case .missing:
            await routeAppleFanMissingProfileOnboarding(
                session: session,
                sessionEmail: sessionEmail,
                fullName: fullName
            )
            return

        case .active:
            break

        case .unknown:
            if await enforceDeletedFanAccountLoginGate(
                userId: session.user.id,
                sessionEmail: sessionEmail,
                source: "appleFanSignInUnknownLifecycle"
            ) {
                return
            }
            presentAppleAuthMessage(
                "Could not verify your FanGeo profile. Please try again.",
                accountMode: .fan,
                isError: true,
                autoClearAfterSeconds: 8
            )
            return

        case .suspended, .business:
            presentAppleAuthMessage(
                "This Apple account cannot be used for fan sign-in.",
                accountMode: .fan,
                isError: true,
                autoClearAfterSeconds: 8
            )
            return
        }

        guard await appleEnsureFanProfileExists(session: session, email: sessionEmail, fullName: fullName) else {
            if await MainActor.run(body: { isDeletedAccountLoginBlocked }) {
                return
            }
            return
        }

        guard await checkCurrentUserAdminStatus() else {
            await logAppleDeletedAccountBlockIfNeeded()
            return
        }

        await MainActor.run {
            beginFanLoginSession(
                userId: session.user.id,
                reason: "appleFanSignIn",
                email: sessionEmail,
                displayName: Self.appleDisplayName(from: fullName)
            ) {
                isLoggedIn = true
                isVenueOwnerLoggedIn = false
                venueOwnerMode = false
                authSessionState = .signedIn
                authErrorMessage = ""
                bumpCurrentUserAvatarDisplayRefresh()
            }
            FanGeoStartupGuidePreferences.migrateLegacyGlobalPreferenceIfNeeded(for: session.user.id)
        }

        guard await checkCurrentUserAdminStatus() else {
            await logAppleDeletedAccountBlockIfNeeded()
            return
        }

        await persistAccountModeForActiveAuthSession(.fanUser)
        clearExplicitLogoutMarkerAfterManualAuthSucceeded()
        await registerFanActiveSessionOnLogin()
        Task {
            await loadFavoriteTeamsFromSupabase(forceRefresh: true)
            await refreshUserPersonalizationInBackground()
        }
    }

    private func finishAppleBusinessSignIn(
        session: Session,
        sessionEmail: String,
        fullName: PersonNameComponents?,
        entryPoint: AppleAuthEntryPoint,
        loginGeneration: UInt64
    ) async {
        guard await MainActor.run(body: { isActiveSafeLoginGeneration(loginGeneration) }) else {
            SafeLoginDebug.log("stale previous-session result ignored phase=appleBusinessFinish")
            return
        }
        guard OwnerBusinessEmail.isValidStrict(sessionEmail) else {
            await forceLogout(reason: "appleBusinessMissingEmail", source: "MapViewModel.finishAppleBusinessSignIn")
            presentAppleAuthMessage(
                "Apple did not return a usable email address.",
                accountMode: .business,
                isError: true,
                autoClearAfterSeconds: 8
            )
            return
        }

        if await businessBanGuardBlocks(
            path: "businessLogin",
            action: "appleBusiness",
            ownerEmail: sessionEmail,
            ownerUserId: session.user.id
        ) {
            clearExplicitLogoutMarkerAfterManualAuthSucceeded()
            return
        }

        if await activeFanUserProfileExistsForEmail(sessionEmail) {
            await undoPartialSupabaseSessionAfterAccountTypeMismatch()
            await MainActor.run { venueAuthErrorMessage = Self.businessLoginBlockedBecauseFanMessage }
            return
        }

        if await shouldBlockBusinessOwnerLogin(sessionEmail: sessionEmail, userId: session.user.id) {
            await undoPartialSupabaseSessionAfterAccountTypeMismatch()
            await MainActor.run { venueAuthErrorMessage = Self.businessLoginBlockedBecauseFanMessage }
            return
        }

        guard await claimAccountIdentity(.business, context: "appleBusinessSignIn") else {
            await MainActor.run {
                appleAuthBusinessMessage = venueAuthErrorMessage
                appleAuthBusinessMessageIsError = true
            }
            return
        }

        let businessLifecycle = await resolveBusinessProfileLifecycleState()
        switch businessLifecycle {
        case .deleted, .archived, .disabled, .unknown:
            _ = await enforceBusinessLifecycleGate(
                userId: session.user.id,
                sessionEmail: sessionEmail,
                source: "finishAppleBusinessSignIn"
            )
            clearExplicitLogoutMarkerAfterManualAuthSucceeded()
            return
        case .active, .missing:
            break
        }

        if entryPoint == .businessSignup,
           businessLifecycle == .missing {
            let businessDisplayName = Self.appleBusinessDisplayName(email: sessionEmail, fullName: fullName)
            await MainActor.run {
                applePendingBusinessSignupEmail = sessionEmail
                applePendingBusinessSignupDisplayName = businessDisplayName
                venueOwnerEmail = sessionEmail
                currentUserAuthId = session.user.id
                venueAuthErrorMessage = ""
            }
            print("[AppleAuthDebug] applePendingBusinessSignup=true email=\(sessionEmail) displayNameProvided=\(!businessDisplayName.isEmpty)")
            presentAppleAuthMessage(
                "Signed in with Apple. Continue setting up your business.",
                accountMode: .business,
                isError: false,
                autoClearAfterSeconds: nil
            )
            return
        }

        guard await appleEnsureBusinessProfileExists(session: session, email: sessionEmail, fullName: fullName) else {
            return
        }

        await MainActor.run {
            clearAuthenticatedSessionCaches()
            isVenueOwnerLoggedIn = true
            venueOwnerMode = true
            venueOwnerEmail = sessionEmail
            isLoggedIn = false
            currentUserEmail = ""
            venueAuthErrorMessage = ""
            venueOwnerJustCompletedRegistration = false
            currentUserAuthId = session.user.id
            authSessionState = .signedIn
        }

        await persistAccountModeForActiveAuthSession(.businessOwner)
        clearExplicitLogoutMarkerAfterManualAuthSucceeded()
        await registerFanActiveSessionOnLogin()
        await refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
        _ = await ensureBusinessOwnerSessionFlagsIfPossible(context: "after_apple_business_login")

        Task {
            await loadFavoriteVenuesFromSupabase()
            await refreshFollowingTabDataGlobally()
        }
    }

    private func presentAppleAuthMessage(
        _ message: String,
        accountMode: AppleAuthAccountMode,
        isError: Bool,
        autoClearAfterSeconds: UInt64?
    ) {
        switch accountMode {
        case .fan:
            appleAuthFanMessageAutoClearTask?.cancel()
            appleAuthFanMessage = message
            appleAuthFanMessageIsError = isError
        case .business:
            appleAuthBusinessMessageAutoClearTask?.cancel()
            appleAuthBusinessMessage = message
            appleAuthBusinessMessageIsError = isError
        }

        print("[AppleAuthDebug] errorPresented=\(isError)")

        guard let seconds = autoClearAfterSeconds else { return }
        print("[AppleAuthDebug] errorAutoClearScheduled=\(seconds)")
        let nanos = seconds * 1_000_000_000

        switch accountMode {
        case .fan:
            appleAuthFanMessageAutoClearTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: nanos)
                await MainActor.run {
                    guard let self, self.appleAuthFanMessage == message else { return }
                    self.clearAppleAuthMessage(accountMode: .fan, reason: "autoClear")
                }
            }
        case .business:
            appleAuthBusinessMessageAutoClearTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: nanos)
                await MainActor.run {
                    guard let self, self.appleAuthBusinessMessage == message else { return }
                    self.clearAppleAuthMessage(accountMode: .business, reason: "autoClear")
                }
            }
        }
    }

    private func routeAppleFanMissingProfileOnboarding(
        session: Session,
        sessionEmail: String,
        fullName: PersonNameComponents?
    ) async {
#if DEBUG
        print("[DeletedAccountLoginDebug] missingProfileOnboardingAllowed userId=\(session.user.id.uuidString.lowercased())")
        print("[DeletedAccountLoginDebug] lifecycleState=missing")
#endif
        let displayName = Self.appleDisplayName(from: fullName)
        await MainActor.run {
            applePendingFanSignupEmail = sessionEmail
            applePendingFanSignupDisplayName = displayName
            appleFanOnboardingPasswordBypassActive = true
            currentUserAuthId = session.user.id
            currentUserEmail = sessionEmail
            authErrorMessage = ""
        }
        print("[AppleAuthDebug] appleFanOnboardingPasswordBypassActive=true source=pendingProfileCreation")
        print("[AppleAuthDebug] profileMissing=true")
        print("[AppleAuthDebug] enteringPendingProfileCreation=true email=\(sessionEmail) userId=\(session.user.id.uuidString.lowercased())")
        print("[AppleAuthDebug] routedToOnboarding=true")
        print("[FanSignupDebug] applePendingProfileCreation=true email=\(sessionEmail) userId=\(session.user.id.uuidString.lowercased()) displayNameProvided=\(!displayName.isEmpty)")
        presentAppleAuthMessage(
            "Signed in with Apple. Finish setting up your FanGeo profile.",
            accountMode: .fan,
            isError: false,
            autoClearAfterSeconds: nil
        )
    }

    private func appleEnsureFanProfileExists(
        session: Session,
        email: String,
        fullName: PersonNameComponents?
    ) async -> Bool {
        let lifecycle = await resolveFanProfileLifecycleState(userId: session.user.id)
        switch lifecycle {
        case .active:
            print("[AppleAuthDebug] existingProfileFound=true")
            return true
        case .deleted:
            print("[AppleAuthDebug] accountBlockedDeleted=true")
            _ = await enforceDeletedFanAccountLoginGate(
                userId: session.user.id,
                sessionEmail: email,
                source: "appleEnsureFanProfileExists"
            )
            return false
        case .disabled:
            await handleDisabledCurrentUser()
            return false
        case .missing:
            break
        case .unknown:
            if await enforceDeletedFanAccountLoginGate(
                userId: session.user.id,
                sessionEmail: email,
                source: "appleEnsureFanProfileExistsUnknownLifecycle"
            ) {
                return false
            }
            return false
        case .suspended, .business:
            return false
        }

        print("[AppleAuthDebug] existingProfileFound=false")
        print("[AppleAuthDebug] profileMissing=true")
        print("[AppleAuthDebug] creatingNewProfile=true")

        do {
            let row = UserProfileBootstrapInsert(
                id: session.user.id,
                email: email,
                display_name: Self.appleDisplayName(from: fullName),
                username: nil,
                bio: nil,
                avatar_url: "",
                avatar_thumbnail_url: nil,
                live_visibility_enabled: true,
                live_visibility_mode: LiveVisibilityMode.allFriends.rawValue,
                selected_live_visibility_friend_ids: [],
                discoverable_by_fans: true
            )

            try await supabase
                .from("user_profiles")
                .insert(row)
                .execute()

            print("[AppleAuthDebug] newAppleProfileCreated=true")
            print("[AppleAuthDebug] profileCreationSucceeded=true")
            return true
        } catch {
            print("[AppleAuthDebug] profileCreationFailed=\(error.localizedDescription)")
            print("[AppleAuthDebug] onboardingRequired=true")
            print("[AppleAuthDebug] routedToOnboarding=true")
            await forceLogout(reason: "appleFanProfileCreationFailed", source: "MapViewModel.appleEnsureFanProfileExists")
            presentAppleAuthMessage(
                "We found your Apple account. Finish setting up your FanGeo profile.",
                accountMode: .fan,
                isError: false,
                autoClearAfterSeconds: nil
            )
            return false
        }
    }

    private func appleCurrentBusinessProfileExists(session: Session) async -> Bool {
        let lifecycle = await resolveBusinessProfileLifecycleState()
        let exists = lifecycle == .active
        print("[AppleAuthDebug] existingProfileFound=\(exists) lifecycle=\(lifecycle.rawValue)")
        return exists
    }

    private func appleEnsureBusinessProfileExists(
        session: Session,
        email: String,
        fullName: PersonNameComponents?
    ) async -> Bool {
        let lifecycle = await resolveBusinessProfileLifecycleState()
        switch lifecycle {
        case .active:
            print("[AppleAuthDebug] existingProfileFound=true")
            return true
        case .deleted, .archived, .disabled, .unknown:
            print("[AppleAuthDebug] businessProfileCreationBlocked=true lifecycle=\(lifecycle.rawValue)")
            _ = await enforceBusinessLifecycleGate(
                userId: session.user.id,
                sessionEmail: email,
                source: "appleEnsureBusinessProfileExists"
            )
            return false
        case .missing:
            break
        }

        guard await enforceBusinessCreationAllowed(
            userId: session.user.id,
            sessionEmail: email,
            source: "appleEnsureBusinessProfileExists"
        ) else {
            return false
        }

        print("[AppleAuthDebug] existingProfileFound=false")
        print("[AppleAuthDebug] profileMissing=true")
        print("[AppleAuthDebug] creatingNewProfile=true")

        do {
            let payload = BusinessInsertPayload(
                display_name: Self.appleBusinessDisplayName(email: email, fullName: fullName),
                business_handle: nil,
                owner_email: email,
                owner_user_id: session.user.id,
                admin_status: "active"
            )

            try await supabase
                .from("businesses")
                .insert(payload)
                .execute()

            print("[AppleAuthDebug] newAppleProfileCreated=true")
            print("[AppleAuthDebug] profileCreationSucceeded=true")
            return true
        } catch {
            print("[AppleAuthDebug] profileCreationFailed=\(error.localizedDescription)")
            print("[AppleAuthDebug] onboardingRequired=true")
            print("[AppleAuthDebug] routedToOnboarding=true")
            await forceLogout(reason: "appleBusinessProfileCreationFailed", source: "MapViewModel.appleEnsureBusinessProfileExists")
            presentAppleAuthMessage(
                "Finish creating your account.",
                accountMode: .business,
                isError: false,
                autoClearAfterSeconds: nil
            )
            return false
        }
    }

    private func logAppleDeletedAccountBlockIfNeeded() async {
        let message = await MainActor.run { authErrorMessage }
        if message.localizedCaseInsensitiveContains("account has been deleted") {
            print("[AppleAuthDebug] accountBlockedDeleted=true")
        }
    }

    func appleFanProfileConflictExists(email: String, currentUserId: UUID) async -> Bool {
        do {
            let rows: [AppleExistingFanProfileRow] = try await supabase
                .from("user_profiles")
                .select("id,is_deleted,admin_status")
                .eq("email", value: email)
                .limit(5)
                .execute()
                .value

            for row in rows {
                guard row.id != currentUserId else { continue }

                if row.is_deleted == true {
                    _ = await enforceDeletedFanAccountLoginGate(
                        userId: currentUserId,
                        sessionEmail: email,
                        source: "appleFanProfileConflictExists"
                    )
                    print("[AppleAuthDebug] accountBlockedDeleted=true")
                    return true
                }

                let status = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if status == nil || status == "active" {
                    await forceLogout(reason: "appleFanDuplicateProfileEmail", source: "MapViewModel.appleFanProfileConflictExists")
                    await MainActor.run {
                        authErrorMessage = "A FanGeo account already exists for this email. Please sign in with that account first."
                    }
                    return true
                }
            }
        } catch {
            print("[AppleAuthDebug] authError=\(error.localizedDescription)")
        }

        return false
    }

    private static func appleDisplayName(from fullName: PersonNameComponents?) -> String {
        guard let fullName else { return "" }
        let formatter = PersonNameComponentsFormatter()
        let value = formatter.string(from: fullName).trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }

    private static func appleBusinessDisplayName(email: String, fullName: PersonNameComponents?) -> String {
        let name = appleDisplayName(from: fullName)
        if !name.isEmpty { return name }

        let prefix = email.split(separator: "@").first.map(String.init) ?? ""
        let cleaned = prefix
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Apple Business Account" : cleaned.capitalized
    }

    private static func logAppleIdentityTokenClaims(_ identityToken: String, rawNonce: String) {
        let parts = identityToken.split(separator: ".")
        guard parts.count >= 2,
              let payloadData = base64URLDecodedData(String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            print("[AppleAuthDebug] identityTokenClaimsDecoded=false")
            return
        }

        let issuer = json["iss"] as? String ?? "nil"
        let audience: String = {
            if let value = json["aud"] as? String { return value }
            if let values = json["aud"] as? [String] { return values.joined(separator: ",") }
            return "nil"
        }()
        let subjectPresent = ((json["sub"] as? String)?.isEmpty == false)
        let expiresAt = json["exp"].map { "\($0)" } ?? "nil"
        let nonce = json["nonce"] as? String
        let hashedNonce = sha256(rawNonce)
        let email = json["email"] as? String
        let isRelay = email?.localizedCaseInsensitiveContains("privaterelay.appleid.com") == true
        let emailVerified = json["email_verified"].map { "\($0)" } ?? "nil"
        let isPrivateEmail = json["is_private_email"].map { "\($0)" } ?? "nil"

        print("[AppleAuthDebug] identityTokenClaimsDecoded=true")
        print("[AppleAuthDebug] identityTokenIssuer=\(issuer)")
        print("[AppleAuthDebug] identityTokenAudience=\(audience)")
        print("[AppleAuthDebug] identityTokenSubjectPresent=\(subjectPresent)")
        print("[AppleAuthDebug] identityTokenExpiresAt=\(expiresAt)")
        print("[AppleAuthDebug] identityTokenNonceExists=\(nonce != nil)")
        print("[AppleAuthDebug] identityTokenNonceMatchesRequest=\(nonce == hashedNonce)")
        print("[AppleAuthDebug] identityTokenEmailExists=\(email != nil)")
        print("[AppleAuthDebug] identityTokenRelayEmail=\(isRelay)")
        print("[AppleAuthDebug] identityTokenEmailVerified=\(emailVerified)")
        print("[AppleAuthDebug] identityTokenIsPrivateEmail=\(isPrivateEmail)")
    }

    private static func base64URLDecodedData(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    private static func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.map { String(format: "%02x", $0) }.joined()
    }
}
