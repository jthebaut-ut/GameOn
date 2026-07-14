import Foundation
import Supabase

/// Business profile lifecycle classification for post-auth login gates.
enum BusinessProfileLifecycleState: String, Equatable {
    case active
    case deleted
    case archived
    case disabled
    case missing
    case unknown
}

extension MapViewModel {

    static let deletedBusinessLoginBlockedTitleKey = "business_account_deleted_title"
    static let deletedBusinessLoginBlockedMessageKey = "business_account_deleted_message"

    static var deletedBusinessLoginBlockedTitle: String {
        L10n.t(deletedBusinessLoginBlockedTitleKey)
    }

    static var deletedBusinessLoginBlockedMessage: String {
        L10n.t(deletedBusinessLoginBlockedMessageKey)
    }

    static let deletedBusinessSupportRecipient = "support@fangeosports.com"
    static let deletedBusinessSupportSubject = "Deleted business account support request"
    static let deletedBusinessSupportIssueType = "Deleted business account"

    static func deletedBusinessSupportMessageBody(
        attemptedLoginEmail: String,
        businessId: UUID?
    ) -> String {
        let normalized = OwnerBusinessEmail.normalized(attemptedLoginEmail)
        let emailLine = normalized.isEmpty ? "<enter your business account email>" : normalized
        let businessIdLine = businessId?.uuidString.lowercased() ?? "<unavailable>"
        return """
        Issue type: \(deletedBusinessSupportIssueType)
        Email: \(emailLine)
        Business ID: \(businessIdLine)
        Reason: I am requesting account reactivation for my deleted FanGeo business account.
        """
    }

    struct BusinessLifecycleSnapshot: Decodable {
        let business_id: UUID?
        let lifecycle_state: String?
        let is_deleted: Bool?
        let deleted_at: String?
        let anonymized_at: String?
        let deletion_requested_at: String?
        let admin_status: String?
    }

    @MainActor
    var isDeletedBusinessLoginBlocked: Bool {
        authSessionState == .deletedBusinessAccountConfirmed
    }

    static func shouldAllowDualFanFallbackAfterDeletedBusiness(source: String) -> Bool {
        let normalized = source
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let explicitBusinessIntentMarkers = [
            "loginvenueowner",
            "finishapplebusinesssignin",
            "appleensurebusinessprofileexists",
            "registerbusinessaccountonly",
            "registervenueowner",
            "resumependingbusinesssignup",
            "applyverifiedbusinesssignupsessionifallowed",
            "bootstrap_restore_business_owner",
            "bootstrapinactivedeletedbusiness",
            "completeapplepending",
            "pendingbusinessvenuesetup",
            "businesslogin",
            "venueowner",
            "businesssignup",
            "business_account",
            "businessdashboard",
            "business_account_access",
            "ensurebusinessowner",
        ]
        for marker in explicitBusinessIntentMarkers where normalized.contains(marker) {
            return false
        }
        return true
    }

    func classifyBusinessProfileLifecycle(_ snapshot: BusinessLifecycleSnapshot?) -> BusinessProfileLifecycleState {
        guard let snapshot else { return .unknown }

        if let raw = snapshot.lifecycle_state?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           let parsed = BusinessProfileLifecycleState(rawValue: raw) {
            return parsed
        }

        if snapshot.is_deleted == true {
            return .deleted
        }

        if Self.hasNonEmptyBusinessLifecycleTimestamp(snapshot.deleted_at)
            || Self.hasNonEmptyBusinessLifecycleTimestamp(snapshot.anonymized_at)
            || Self.hasNonEmptyBusinessLifecycleTimestamp(snapshot.deletion_requested_at) {
            return .deleted
        }

        let adminStatus = snapshot.admin_status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch adminStatus {
        case "archived":
            return .archived
        case "disabled":
            return .disabled
        case "active":
            return .active
        case "":
            return snapshot.business_id == nil ? .missing : .unknown
        default:
            return .unknown
        }
    }

    func fetchBusinessLifecycleSnapshot() async throws -> BusinessLifecycleSnapshot {
        let row: BusinessLifecycleSnapshot = try await supabase
            .rpc("get_my_business_lifecycle_state")
            .execute()
            .value
        return row
    }

    func resolveBusinessProfileLifecycleState() async -> BusinessProfileLifecycleState {
        do {
            let snapshot = try await fetchBusinessLifecycleSnapshot()
            await MainActor.run {
                lastResolvedBusinessLifecycleSnapshot = snapshot
            }
            let state = classifyBusinessProfileLifecycle(snapshot)
            logBusinessLifecycleDebug(snapshot: snapshot, state: state)
            if state == .deleted {
#if DEBUG
                print("[DeletedBusinessLoginDebug] deletedBusinessNeverTreatedAsMissing businessId=\(snapshot.business_id?.uuidString.lowercased() ?? "nil")")
#endif
            }
            return state
        } catch {
#if DEBUG
            print("[DeletedBusinessLoginDebug] lifecycleFetchFailed error=\(error.localizedDescription)")
            print("[DeletedBusinessLoginDebug] lifecycleState=unknown")
#endif
            return .unknown
        }
    }

    func businessOnboardingAllowed(for lifecycle: BusinessProfileLifecycleState) -> Bool {
        lifecycle == .missing
    }

    /// Returns `true` when business access must stop (deleted/archived/disabled/unknown fail-closed).
    @discardableResult
    func enforceBusinessLifecycleGate(
        userId: UUID,
        sessionEmail: String,
        source: String,
        allowDualFanFallback: Bool? = nil
    ) async -> Bool {
        let resolvedDualFanFallback = allowDualFanFallback
            ?? Self.shouldAllowDualFanFallbackAfterDeletedBusiness(source: source)
#if DEBUG
        print("[DeletedBusinessLoginDebug] authSucceeded userId=\(userId.uuidString.lowercased())")
        print("[DeletedBusinessLoginDebug] lifecycleFetchStarted userId=\(userId.uuidString.lowercased()) source=\(source)")
#endif

        let lifecycle = await resolveBusinessProfileLifecycleState()
        return await handleBusinessLifecycleGateResult(
            lifecycle: lifecycle,
            userId: userId,
            sessionEmail: sessionEmail,
            source: source,
            allowDualFanFallback: resolvedDualFanFallback
        )
    }

    /// Prevents business row creation unless lifecycle is genuinely missing.
    func enforceBusinessCreationAllowed(
        userId: UUID,
        sessionEmail: String,
        source: String
    ) async -> Bool {
        let lifecycle = await resolveBusinessProfileLifecycleState()
        guard businessOnboardingAllowed(for: lifecycle) else {
#if DEBUG
            print("[DeletedBusinessLoginDebug] businessCreationPrevented reason=\(lifecycle.rawValue) source=\(source)")
#endif
            _ = await handleBusinessLifecycleGateResult(
                lifecycle: lifecycle,
                userId: userId,
                sessionEmail: sessionEmail,
                source: source,
                allowDualFanFallback: false
            )
            return false
        }
#if DEBUG
        print("[DeletedBusinessLoginDebug] businessOnboardingAllowed reason=missing source=\(source)")
#endif
        return true
    }

    @discardableResult
    private func handleBusinessLifecycleGateResult(
        lifecycle: BusinessProfileLifecycleState,
        userId: UUID,
        sessionEmail: String,
        source: String,
        allowDualFanFallback: Bool
    ) async -> Bool {
        switch lifecycle {
        case .active, .missing:
            return false
        case .deleted:
#if DEBUG
            print("[DeletedBusinessLoginDebug] lifecycleState=deleted")
            print("[DeletedBusinessLoginDebug] loginBlocked source=\(source)")
            print("[DeletedBusinessLoginDebug] businessOnboardingPrevented reason=deleted source=\(source)")
            print("[DeletedBusinessLoginDebug] dashboardEntryBlocked source=\(source)")
#endif
            if allowDualFanFallback,
               await resolveFanProfileLifecycleState(userId: userId) == .active {
                await routeDualFanModeAfterDeletedBusiness(context: source)
                return true
            }
            await blockDeletedBusinessLogin(userId: userId, sessionEmail: sessionEmail, source: source)
            return true
        case .archived, .disabled:
            await handleAdminLifecycleBlockedBusiness(status: lifecycle.rawValue, context: source)
            return true
        case .unknown:
#if DEBUG
            print("[DeletedBusinessLoginDebug] businessCreationPrevented reason=unknown source=\(source)")
            print("[DeletedBusinessLoginDebug] dashboardEntryBlocked source=\(source)")
#endif
            await blockUnknownBusinessLifecycle(userId: userId, sessionEmail: sessionEmail, source: source)
            return true
        }
    }

    @MainActor
    private func clearPendingBusinessSignupState(reason: String) {
        applePendingBusinessSignupEmail = ""
        applePendingBusinessSignupDisplayName = ""
        clearPendingBusinessEmailSignupState()
        isBusinessOwnerSessionRestorePending = false
#if DEBUG
        print("[DeletedBusinessLoginDebug] pendingBusinessSignupCleared reason=\(reason)")
#endif
    }

    func routeDualFanModeAfterDeletedBusiness(context: String) async {
#if DEBUG
        print("[DeletedBusinessLoginDebug] dualFanFallback=true context=\(context)")
#endif
        await MainActor.run {
            clearPendingBusinessSignupState(reason: "deleted_business_dual_fan")
            isVenueOwnerLoggedIn = false
            venueOwnerMode = false
            venueOwnerEmail = ""
            currentUserIsBusinessAccount = false
            clearVenueOwnerOwnedBusinessCaches()
            ownerVenueDatabaseId = nil
            isBusinessOwnerSessionRestorePending = false
        }
        await persistAccountModeForActiveAuthSession(.fanUser)
    }

    func blockDeletedBusinessLogin(userId: UUID, sessionEmail: String, source: String) async {
        let normalizedEmail = OwnerBusinessEmail.normalized(sessionEmail)
        await MainActor.run {
            clearPendingBusinessSignupState(reason: "deleted_business")
            let generation = bumpAccountProfileGeneration(reason: "deletedBusinessLoginBlocked", accountId: userId)
            clearAuthenticatedSessionCaches(expectedGeneration: generation, logoutAccountId: userId)
            blockedDeletedBusinessAttemptEmail = normalizedEmail
            blockedDeletedBusinessAttemptBusinessId = lastResolvedBusinessLifecycleSnapshot?.business_id
            isVenueOwnerLoggedIn = false
            venueOwnerMode = false
            venueOwnerEmail = ""
            currentUserIsBusinessAccount = false
            isBusinessOwnerSessionRestorePending = false
            clearVenueOwnerOwnedBusinessCaches()
            ownerVenueDatabaseId = nil
        }

        await forceLogout(reason: "deletedBusinessAccountConfirmed", source: "MapViewModel.\(source)")
        await MainActor.run {
            transitionAuthSessionState(.deletedBusinessAccountConfirmed, reason: source)
            venueAuthErrorMessage = Self.deletedBusinessLoginBlockedMessage
        }
#if DEBUG
        print("[DeletedBusinessLoginDebug] deletedBusinessSessionSignedOut userId=\(userId.uuidString.lowercased()) source=\(source)")
        print("[DeletedBusinessLoginDebug] deletedSessionBlocked source=\(source)")
#endif
    }

    private func blockUnknownBusinessLifecycle(userId: UUID, sessionEmail: String, source: String) async {
        await MainActor.run {
            clearPendingBusinessSignupState(reason: "unknown_business_lifecycle")
            isVenueOwnerLoggedIn = false
            venueOwnerMode = false
            isBusinessOwnerSessionRestorePending = false
        }
        if await resolveFanProfileLifecycleState(userId: userId) == .active {
            await routeDualFanModeAfterDeletedBusiness(context: source)
            return
        }
        await blockDeletedBusinessLogin(userId: userId, sessionEmail: sessionEmail, source: source)
    }

    func handleAdminLifecycleBlockedBusiness(status: String, context: String) async {
        logDeletedAccountRestoreDebug("businessLifecycleBlocked status=\(status) context=\(context)")
        await forceLogout(reason: "disabledAccountConfirmed", source: "MapViewModel.\(context)")
        await MainActor.run {
            clearPendingBusinessSignupState(reason: "admin_\(status)")
            resetProfilePresentationLoadStateForNewAuth()
            transitionAuthSessionState(.deletedAccountConfirmed, reason: "\(context)_businessStatus_\(status)")
            authErrorMessage = "This business account is no longer active.\nContact support if you believe this was a mistake."
            venueAuthErrorMessage = authErrorMessage
        }
    }

    func acknowledgeDeletedBusinessLoginBlock() {
#if DEBUG
        print("[DeletedBusinessLoginDebug] blockClosed")
#endif
        Task {
            await forceLogout(reason: "acknowledgeDeletedBusinessLoginBlock", source: "MapViewModel.acknowledgeDeletedBusinessLoginBlock")
            await MainActor.run {
                blockedDeletedBusinessAttemptEmail = ""
                blockedDeletedBusinessAttemptBusinessId = nil
                lastResolvedBusinessLifecycleSnapshot = nil
                clearPendingBusinessSignupState(reason: "acknowledgeDeletedBusinessLoginBlock")
                isVenueOwnerLoggedIn = false
                venueOwnerMode = false
                venueOwnerEmail = ""
                currentUserIsBusinessAccount = false
                isBusinessOwnerSessionRestorePending = false
                transitionAuthSessionState(.signedOut, reason: "acknowledgeDeletedBusinessLoginBlock")
                venueAuthErrorMessage = ""
            }
        }
    }

    private func logBusinessLifecycleDebug(
        snapshot: BusinessLifecycleSnapshot,
        state: BusinessProfileLifecycleState
    ) {
#if DEBUG
        print("[DeletedBusinessLoginDebug] lifecycleState=\(state.rawValue)")
        print("[DeletedBusinessLoginDebug] isDeleted=\(snapshot.is_deleted == true)")
        print("[DeletedBusinessLoginDebug] deletedAt=\(snapshot.deleted_at ?? "nil")")
        print("[DeletedBusinessLoginDebug] anonymizedAt=\(snapshot.anonymized_at ?? "nil")")
        print("[DeletedBusinessLoginDebug] adminStatus=\(snapshot.admin_status ?? "nil")")
#endif
    }

    private static func hasNonEmptyBusinessLifecycleTimestamp(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
