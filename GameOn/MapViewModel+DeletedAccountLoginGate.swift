import Foundation
import Supabase

/// Fan profile lifecycle classification for post-auth login gates.
enum FanProfileLifecycleState: String, Equatable {
    case active
    case deleted
    case missing
    case disabled
    case suspended
    case business
    case unknown
}

extension MapViewModel {

    static let deletedAccountLoginBlockedTitle = "Account deleted"
    static let deletedAccountLoginBlockedMessage =
        "This FanGeo account has been permanently deleted and cannot be used. Contact FanGeo Support if you believe this was a mistake."

    struct FanProfileLifecycleSnapshot: Decodable {
        let id: UUID?
        let is_deleted: Bool?
        let deleted_at: String?
        let anonymized_at: String?
        let email: String?
        let admin_status: String?
        let is_business_account: Bool?
    }

    @MainActor
    var isDeletedAccountLoginBlocked: Bool {
        authSessionState == .deletedAccountConfirmed
    }

    func classifyFanProfileLifecycle(_ snapshot: FanProfileLifecycleSnapshot?) -> FanProfileLifecycleState {
        guard let snapshot else { return .missing }

        if snapshot.is_deleted == true {
            return .deleted
        }

        let normalizedEmail = OwnerBusinessEmail.normalized(snapshot.email ?? "")
        if normalizedEmail.hasSuffix("@deleted.fangeo.local") {
            return .deleted
        }

        if Self.hasNonEmptyLifecycleTimestamp(snapshot.deleted_at) {
            return .deleted
        }

        if Self.hasNonEmptyLifecycleTimestamp(snapshot.anonymized_at) {
            return .deleted
        }

        if snapshot.is_business_account == true {
            return .business
        }

        let adminStatus = snapshot.admin_status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if adminStatus == "disabled" {
            return .disabled
        }

        return .active
    }

    func fetchFanProfileLifecycleSnapshot(userId: UUID) async throws -> FanProfileLifecycleSnapshot? {
        let rows: [FanProfileLifecycleSnapshot] = try await supabase
            .from("user_profiles")
            .select("id,is_deleted,deleted_at,anonymized_at,email,admin_status,is_business_account")
            .eq("id", value: userId)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    func resolveFanProfileLifecycleState(userId: UUID) async -> FanProfileLifecycleState {
        do {
            let snapshot = try await fetchFanProfileLifecycleSnapshot(userId: userId)
            let state = classifyFanProfileLifecycle(snapshot)
            logFanProfileLifecycleDebug(snapshot: snapshot, state: state, userId: userId)
            if state == .deleted {
#if DEBUG
                print("[DeletedAccountLoginDebug] deletedProfileNeverTreatedAsMissing userId=\(userId.uuidString.lowercased())")
#endif
            }
            return state
        } catch {
#if DEBUG
            print("[DeletedAccountLoginDebug] lifecycleFetchFailed userId=\(userId.uuidString.lowercased()) error=\(error.localizedDescription)")
            print("[DeletedAccountLoginDebug] lifecycleState=unknown")
#endif
            return .unknown
        }
    }

    /// Returns `true` when login must be blocked (deleted/disabled tombstone profile).
    @discardableResult
    func enforceDeletedFanAccountLoginGate(
        userId: UUID,
        sessionEmail: String,
        source: String
    ) async -> Bool {
#if DEBUG
        print("[DeletedAccountLoginDebug] authSucceeded userId=\(userId.uuidString.lowercased())")
        print("[DeletedAccountLoginDebug] lifecycleFetchStarted userId=\(userId.uuidString.lowercased()) source=\(source)")
#endif

        do {
            let snapshot = try await fetchFanProfileLifecycleSnapshot(userId: userId)
            let state = classifyFanProfileLifecycle(snapshot)
            logFanProfileLifecycleDebug(snapshot: snapshot, state: state)

            switch state {
            case .deleted:
                await blockDeletedFanLogin(userId: userId, sessionEmail: sessionEmail, source: source)
                return true
            case .disabled:
#if DEBUG
                print("[DeletedAccountLoginDebug] mainAppEntryBlocked reason=disabled_account")
#endif
                await handleDisabledCurrentUser()
                return true
            case .missing, .active, .suspended, .business, .unknown:
                return false
            }
        } catch {
#if DEBUG
            print("[DeletedAccountLoginDebug] lifecycleFetchFailed userId=\(userId.uuidString.lowercased()) error=\(error.localizedDescription)")
            print("[DeletedAccountLoginDebug] lifecycleState=unknown")
#endif
            return false
        }
    }

    private func blockDeletedFanLogin(userId: UUID, sessionEmail: String, source: String) async {
#if DEBUG
        print("[DeletedAccountLoginDebug] mainAppEntryBlocked reason=deleted_account source=\(source)")
        print("[DeletedAccountLoginDebug] profileCreationPrevented reason=deleted_account")
#endif
        let normalizedEmail = OwnerBusinessEmail.normalized(sessionEmail)
        await MainActor.run {
            clearPendingAppleFanSignupState(reason: "deleted_account")
            let generation = bumpAccountProfileGeneration(reason: "deletedAccountLoginBlocked", accountId: userId)
            clearAuthenticatedSessionCaches(expectedGeneration: generation, logoutAccountId: userId)
            clearCurrentUserProfileLocalCache()
            blockedDeletedAccountAttemptEmail = normalizedEmail
            isLoggedIn = false
            isVenueOwnerLoggedIn = false
            venueOwnerMode = false
            currentUserAuthId = nil
            resetProfilePresentationLoadStateForNewAuth()
        }

        await handleDeletedCurrentUser()
#if DEBUG
        print("[DeletedAccountLoginDebug] deletedSessionSignedOut userId=\(userId.uuidString.lowercased())")
#endif
    }

    private func logFanProfileLifecycleDebug(
        snapshot: FanProfileLifecycleSnapshot?,
        state: FanProfileLifecycleState,
        userId: UUID? = nil
    ) {
#if DEBUG
        let normalizedEmail = OwnerBusinessEmail.normalized(snapshot?.email ?? "")
        let tombstoneEmail = normalizedEmail.hasSuffix("@deleted.fangeo.local")
        if let userId {
            print("[DeletedAccountLoginDebug] lifecycleResolved userId=\(userId.uuidString.lowercased())")
        }
        print("[DeletedAccountLoginDebug] lifecycleState=\(state.rawValue)")
        print("[DeletedAccountLoginDebug] isDeleted=\(snapshot?.is_deleted == true)")
        print("[DeletedAccountLoginDebug] deletedAt=\(snapshot?.deleted_at ?? "nil")")
        print("[DeletedAccountLoginDebug] anonymizedAt=\(snapshot?.anonymized_at ?? "nil")")
        print("[DeletedAccountLoginDebug] tombstoneEmail=\(tombstoneEmail)")
#endif
    }

    private static func hasNonEmptyLifecycleTimestamp(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isDeletedAccountLoginBlockMessage(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("permanently deleted")
            || normalized.contains("account has been deleted")
    }
}
