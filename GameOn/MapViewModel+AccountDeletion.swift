import Foundation
import Supabase

// Fan account deletion via Phase 2 job flow:
// start_account_deletion_job → execute_delete_user_account_db → finalize-account-deletion Edge Function.

extension MapViewModel {

    struct AccountDeletionPreview: Decodable, Equatable {
        let ok: Bool
        let blocked: Bool
        let blockReason: String?
        let targetUserId: UUID?
        let normalizedEmail: String?
        let deletionMode: String?
        let authUsersDeleted: Bool?
        let accountIdentitiesDeleted: Bool?
        let emailReleased: Bool?
        let estimatedCounts: [String: Int]
        let avatarStoragePaths: [String]

        enum CodingKeys: String, CodingKey {
            case ok
            case blocked
            case blockReason = "block_reason"
            case targetUserId = "target_user_id"
            case normalizedEmail = "normalized_email"
            case deletionMode = "deletion_mode"
            case authUsersDeleted = "auth_users_deleted"
            case accountIdentitiesDeleted = "account_identities_deleted"
            case emailReleased = "email_released"
            case estimatedCounts = "estimated_counts"
            case avatarStoragePaths = "avatar_storage_paths"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ok = try container.decode(Bool.self, forKey: .ok)
            blocked = try container.decodeIfPresent(Bool.self, forKey: .blocked) ?? false
            blockReason = try container.decodeIfPresent(String.self, forKey: .blockReason)
            targetUserId = try container.decodeIfPresent(UUID.self, forKey: .targetUserId)
            normalizedEmail = try container.decodeIfPresent(String.self, forKey: .normalizedEmail)
            deletionMode = try container.decodeIfPresent(String.self, forKey: .deletionMode)
            authUsersDeleted = try container.decodeIfPresent(Bool.self, forKey: .authUsersDeleted)
            accountIdentitiesDeleted = try container.decodeIfPresent(Bool.self, forKey: .accountIdentitiesDeleted)
            emailReleased = try container.decodeIfPresent(Bool.self, forKey: .emailReleased)
            estimatedCounts = (try? container.decodeIfPresent([String: Int].self, forKey: .estimatedCounts)) ?? [:]
            avatarStoragePaths = (try? container.decodeIfPresent([String].self, forKey: .avatarStoragePaths)) ?? []
        }
    }

    struct AccountDeletionJobStart: Decodable, Equatable {
        let ok: Bool
        let jobId: UUID?
        let status: String?
        let stage: String?
        let reused: Bool?

        enum CodingKeys: String, CodingKey {
            case ok
            case jobId = "job_id"
            case status
            case stage
            case reused
        }
    }

    struct AccountDeletionJobExecute: Decodable, Equatable {
        let ok: Bool
        let jobId: UUID?
        let status: String?
        let stage: String?
        let deletedUserId: UUID?
        let normalizedEmail: String?
        let affectedCounts: [String: Int]
        let avatarStoragePaths: [String]
        let authUsersDeleted: Bool?
        let accountIdentitiesDeleted: Bool?
        let idempotentReplay: Bool?
        let errorCode: String?
        let errorDetail: String?

        enum CodingKeys: String, CodingKey {
            case ok
            case jobId = "job_id"
            case status
            case stage
            case deletedUserId = "deleted_user_id"
            case normalizedEmail = "normalized_email"
            case affectedCounts = "affected_counts"
            case avatarStoragePaths = "avatar_storage_paths"
            case authUsersDeleted = "auth_users_deleted"
            case accountIdentitiesDeleted = "account_identities_deleted"
            case idempotentReplay = "idempotent_replay"
            case errorCode = "error_code"
            case errorDetail = "error_detail"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ok = try container.decode(Bool.self, forKey: .ok)
            jobId = try container.decodeIfPresent(UUID.self, forKey: .jobId)
            status = try container.decodeIfPresent(String.self, forKey: .status)
            stage = try container.decodeIfPresent(String.self, forKey: .stage)
            deletedUserId = try container.decodeIfPresent(UUID.self, forKey: .deletedUserId)
            normalizedEmail = try container.decodeIfPresent(String.self, forKey: .normalizedEmail)
            affectedCounts = (try? container.decodeIfPresent([String: Int].self, forKey: .affectedCounts)) ?? [:]
            avatarStoragePaths = (try? container.decodeIfPresent([String].self, forKey: .avatarStoragePaths)) ?? []
            authUsersDeleted = try container.decodeIfPresent(Bool.self, forKey: .authUsersDeleted)
            accountIdentitiesDeleted = try container.decodeIfPresent(Bool.self, forKey: .accountIdentitiesDeleted)
            idempotentReplay = try container.decodeIfPresent(Bool.self, forKey: .idempotentReplay)
            errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
            errorDetail = try container.decodeIfPresent(String.self, forKey: .errorDetail)
        }
    }

    struct AccountDeletionFinalizeResponse: Decodable, Equatable {
        let ok: Bool
        let jobId: UUID?
        let status: String?
        let stage: String?
        let authUsersDeleted: Bool?

        enum CodingKeys: String, CodingKey {
            case ok
            case jobId = "job_id"
            case status
            case stage
            case authUsersDeleted = "auth_users_deleted"
        }
    }

    struct AccountDeletionResult: Decodable, Equatable {
        let ok: Bool
        let deletedUserId: UUID?
        let normalizedEmail: String?
        let affectedCounts: [String: Int]
        let avatarStoragePaths: [String]
        let jobId: UUID?
        let status: String?

        enum CodingKeys: String, CodingKey {
            case ok
            case deletedUserId = "deleted_user_id"
            case normalizedEmail = "normalized_email"
            case affectedCounts = "affected_counts"
            case avatarStoragePaths = "avatar_storage_paths"
            case jobId = "job_id"
            case status
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ok = try container.decode(Bool.self, forKey: .ok)
            deletedUserId = try container.decodeIfPresent(UUID.self, forKey: .deletedUserId)
            normalizedEmail = try container.decodeIfPresent(String.self, forKey: .normalizedEmail)
            affectedCounts = (try? container.decodeIfPresent([String: Int].self, forKey: .affectedCounts)) ?? [:]
            avatarStoragePaths = (try? container.decodeIfPresent([String].self, forKey: .avatarStoragePaths)) ?? []
            jobId = try container.decodeIfPresent(UUID.self, forKey: .jobId)
            status = try container.decodeIfPresent(String.self, forKey: .status)
        }

        init(
            ok: Bool,
            deletedUserId: UUID?,
            normalizedEmail: String?,
            affectedCounts: [String: Int],
            avatarStoragePaths: [String],
            jobId: UUID?,
            status: String?
        ) {
            self.ok = ok
            self.deletedUserId = deletedUserId
            self.normalizedEmail = normalizedEmail
            self.affectedCounts = affectedCounts
            self.avatarStoragePaths = avatarStoragePaths
            self.jobId = jobId
            self.status = status
        }
    }

    enum AccountDeletionError: LocalizedError {
        case notSignedIn
        case venueOwnerMustUseVenueFlow
        case blocked(String)
        case missingJobId
        case server(String, detail: String?)
        case serverFailure(code: String?, detail: String?)
        case unexpectedResponse

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Sign in as a fan to delete your account."
            case .venueOwnerMustUseVenueFlow:
                return "Business accounts must use Delete Business Account in venue settings."
            case let .blocked(reason):
                return blockedDeletionMessage(for: reason)
            case .missingJobId:
                return "Account deletion could not start. Please try again."
            case let .server(code, detail):
                if let detail, !detail.isEmpty {
                    return "Could not delete account (\(code)): \(detail)"
                }
                return "Could not delete account (\(code))."
            case let .serverFailure(code, detail):
                return serverFailureUserMessage(code: code, detail: detail)
            case .unexpectedResponse:
                return "Unexpected response from account deletion service."
            }
        }

        private func blockedDeletionMessage(for reason: String) -> String {
            switch reason {
            case "active_business_ownership", "business_account_type", "business_profile_flag",
                 "business_ownership", "business_email_ownership":
                return "Business accounts must use Delete Business Account in venue settings."
            case "venue_ownership", "pending_venue_claim":
                return "Venue ownership or a pending venue claim must be resolved before deleting this account."
            case "already_deleted":
                return "This account has already been deleted."
            default:
                return "Account deletion is blocked (\(reason))."
            }
        }

        private func serverFailureUserMessage(code: String?, detail: String?) -> String {
            let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
            let normalizedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

            if normalizedCode == "42501"
                || normalizedDetail.contains("fan profile email must match the authenticated user email")
                || normalizedDetail.contains("fan profile auth user mismatch") {
                return "Account deletion could not be completed. Please try again or contact FanGeo Support."
            }

            return "Account deletion could not be completed. Please try again or contact FanGeo Support."
        }
    }

    private struct AccountDeletionJobIdParams: Encodable {
        let pJobId: UUID

        enum CodingKeys: String, CodingKey {
            case pJobId = "p_job_id"
        }
    }

    private struct AccountDeletionFinalizePayload: Encodable {
        let jobId: UUID

        enum CodingKeys: String, CodingKey {
            case jobId = "job_id"
        }
    }

    /// Phase 2 job flow: preview blockers (server), start job, execute DB soft-delete, finalize storage via Edge Function.
    func requestPermanentAccountDeletion() async throws {
#if DEBUG
        print("[AccountDeletionDebug] started=true flow=phase2_job")
#endif
        guard isLoggedIn, !currentUserEmail.isEmpty else {
#if DEBUG
            print("[AccountDeletionDebug] error=notSignedIn")
#endif
            throw AccountDeletionError.notSignedIn
        }
        guard !isVenueOwnerLoggedIn else {
#if DEBUG
            print("[AccountDeletionDebug] error=venueOwnerMustUseVenueFlow")
#endif
            throw AccountDeletionError.venueOwnerMustUseVenueFlow
        }

        let originalEmail = OwnerBusinessEmail.normalized(currentUserEmail)

        let preview: AccountDeletionPreview
        do {
            preview = try await supabase
                .rpc("preview_delete_user_account")
                .execute()
                .value
        } catch {
#if DEBUG
            print("[AccountDeletionDebug] error=previewFailed \(error.localizedDescription)")
#endif
            throw mapAccountDeletionRPCError(error)
        }

        if preview.blocked, let reason = preview.blockReason, !reason.isEmpty {
#if DEBUG
            print("[AccountDeletionDebug] error=blocked reason=\(reason)")
#endif
            throw AccountDeletionError.blocked(reason)
        }

        let start: AccountDeletionJobStart
        do {
            start = try await supabase
                .rpc("start_account_deletion_job")
                .execute()
                .value
        } catch {
#if DEBUG
            print("[AccountDeletionDebug] error=startJobFailed \(error.localizedDescription)")
#endif
            throw mapAccountDeletionRPCError(error)
        }

        guard start.ok, let jobId = start.jobId else {
            throw AccountDeletionError.missingJobId
        }

#if DEBUG
        print("[AccountDeletionDebug] jobStarted id=\(jobId.uuidString.lowercased()) reused=\(start.reused ?? false)")
#endif

        let execute: AccountDeletionJobExecute
        do {
            execute = try await supabase
                .rpc("execute_delete_user_account_db", params: AccountDeletionJobIdParams(pJobId: jobId))
                .execute()
                .value
        } catch {
#if DEBUG
            print("[AccountDeletionDebug] error=executeDbFailed \(error.localizedDescription)")
#endif
            throw mapAccountDeletionRPCError(error)
        }

#if DEBUG
        print("[AccountDeletionDebug] executeOk=\(execute.ok)")
        print("[AccountDeletionDebug] executeStatus=\(execute.status ?? "nil")")
        print("[AccountDeletionDebug] executeStage=\(execute.stage ?? "nil")")
        print("[AccountDeletionDebug] executeErrorCode=\(execute.errorCode ?? "nil")")
        print("[AccountDeletionDebug] executeErrorDetail=\(execute.errorDetail ?? "nil")")
#endif

        guard execute.ok else {
            throw AccountDeletionError.serverFailure(code: execute.errorCode, detail: execute.errorDetail)
        }

#if DEBUG
        print("[AccountDeletionDebug] dbCommitted=true job=\(jobId.uuidString.lowercased())")
        print("[AccountDeletionDebug] affectedCounts=\(execute.affectedCounts)")
#endif

        anonymizeLoadedFanChatAuthorLocally(
            originalEmail: execute.normalizedEmail ?? preview.normalizedEmail ?? originalEmail,
            deletedUserId: execute.deletedUserId
        )

        do {
            let finalize: AccountDeletionFinalizeResponse = try await supabase.functions.invoke(
                "finalize-account-deletion",
                options: FunctionInvokeOptions(body: AccountDeletionFinalizePayload(jobId: jobId))
            )
#if DEBUG
            print("[AccountDeletionDebug] finalizeSuccess=\(finalize.ok) status=\(finalize.status ?? "nil")")
#endif
        } catch {
            // DB soft-delete already committed; storage finalize is best-effort and retriable server-side.
#if DEBUG
            print("[AccountDeletionDebug] warning=finalizeFailed \(error.localizedDescription)")
#endif
        }

#if DEBUG
        print("[AccountDeletionDebug] signOutStarted=true")
#endif
        await forceLogout(reason: "accountDeletionCompleted", source: "MapViewModel.requestPermanentAccountDeletion")
#if DEBUG
        print("[AccountDeletionDebug] completed=true")
#endif
    }

    private func mapAccountDeletionRPCError(_ error: Error) -> Error {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("active_business_ownership")
            || message.localizedCaseInsensitiveContains("business_account_type")
            || message.localizedCaseInsensitiveContains("business_profile_flag")
            || message.localizedCaseInsensitiveContains("business_ownership")
            || message.localizedCaseInsensitiveContains("business_email_ownership")
            || message.localizedCaseInsensitiveContains("venue_ownership")
            || message.localizedCaseInsensitiveContains("pending_venue_claim") {
            return AccountDeletionError.blocked(extractDeletionBlockReason(from: message) ?? "business_account_type")
        }
        if message.localizedCaseInsensitiveContains("already_deleted") {
            return AccountDeletionError.blocked("already_deleted")
        }
        return error
    }

    private func extractDeletionBlockReason(from message: String) -> String? {
        let markers = [
            "active_business_ownership",
            "business_account_type",
            "business_profile_flag",
            "business_ownership",
            "business_email_ownership",
            "venue_ownership",
            "pending_venue_claim",
            "already_deleted",
        ]
        for marker in markers where message.localizedCaseInsensitiveContains(marker) {
            return marker
        }
        return nil
    }
}
