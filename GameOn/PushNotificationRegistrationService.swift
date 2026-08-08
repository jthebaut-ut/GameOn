import Foundation
import Supabase
import UserNotifications

#if canImport(UIKit)
import UIKit
#endif

#if DEBUG
private func pushTokenDebugLog(_ message: @autoclosure () -> String) {
    print(message())
}
#else
private func pushTokenDebugLog(_ message: @autoclosure () -> String) {}
#endif

/// Identity of one push-token registration: a change to any component is genuinely new work.
nonisolated private struct PushTokenUpsertIdentity: Hashable {
    let userID: String
    let token: String
    let environment: String
}

/// Single-flight + freshness gate for token upserts.
///
/// Launch fans out the same registration from several triggers (app launch, auth id change,
/// already-authorized permission check, APNs token delivery). They all describe the same row, so
/// only the first performs the write; the rest observe it or skip while it is still fresh.
private actor PushTokenUpsertCoalescer {
    enum Outcome {
        case performed
        case coalesced
        case skippedFresh
    }

    private var inFlight: [PushTokenUpsertIdentity: Task<Bool, Never>] = [:]
    private var lastSucceededAt: [PushTokenUpsertIdentity: Date] = [:]
    private let freshnessWindow: TimeInterval = 60

    func run(
        identity: PushTokenUpsertIdentity,
        operation: @escaping @Sendable () async -> Bool
    ) async -> Outcome {
        if let existing = inFlight[identity] {
            _ = await existing.value
            return .coalesced
        }
        if let succeededAt = lastSucceededAt[identity],
           Date().timeIntervalSince(succeededAt) < freshnessWindow {
            return .skippedFresh
        }

        let task = Task { await operation() }
        inFlight[identity] = task
        let succeeded = await task.value
        inFlight[identity] = nil
        if succeeded {
            lastSucceededAt[identity] = Date()
        }
        return .performed
    }

    /// Logout/token removal must let the next sign-in write the row again immediately.
    func invalidateFreshness() {
        lastSucceededAt.removeAll()
    }
}

final class PushNotificationRegistrationService {
    static let shared = PushNotificationRegistrationService()

    private static let deviceTokenDefaultsKey = "gameon.apnsDeviceToken.v1"
    private static let environmentDefaultsKey = "gameon.apnsEnvironment.v1"

    /// Skips duplicate foreground lifecycle refresh after launch/foreground already ran this process.
    private var didCompleteLifecyclePushTokenRefresh = false
    private let upsertCoalescer = PushTokenUpsertCoalescer()

    private init() {}

    func refreshPushTokenRegistration(reason: String) async {
        if reason == "foreground", didCompleteLifecyclePushTokenRefresh {
            pushTokenDebugLog("[PushTokenDebug] refreshSkipped reason=foreground alreadyRefreshedThisSession=true")
            return
        }

        await upsertCurrentTokenIfPossible(reason: reason)
        await registerForRemoteNotificationsIfAuthorized(reason: reason)

        if reason == "appLaunch" || reason == "foreground" {
            didCompleteLifecyclePushTokenRefresh = true
        }
    }

    func registerForRemoteNotificationsIfAuthorized(reason: String) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard Self.canRegisterRemoteNotifications(status: settings.authorizationStatus) else {
            pushTokenDebugLog("[PushTokenDebug] registerSkipped reason=\(reason) permission=\(Self.authorizationStatusDescription(settings.authorizationStatus))")
            return
        }

#if canImport(UIKit)
        await MainActor.run {
            pushTokenDebugLog("[PushTokenDebug] registerForRemoteNotifications reason=\(reason)")
            UIApplication.shared.registerForRemoteNotifications()
        }
#endif
    }

    func handleDeviceToken(_ deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let environment = Self.resolvedEnvironment()
        UserDefaults.standard.set(token, forKey: Self.deviceTokenDefaultsKey)
        UserDefaults.standard.set(environment, forKey: Self.environmentDefaultsKey)
        pushTokenDebugLog("[PushTokenDebug] didRegister tokenPrefix=\(String(token.prefix(12))) environment=\(environment)")
        Task { await upsertCurrentTokenIfPossible(reason: "didRegisterForRemoteNotifications") }
    }

    func handleRegistrationFailure(_ error: Error) {
        pushTokenDebugLog("[PushTokenDebug] registrationFailed error=\(error.localizedDescription)")
    }

    func upsertCurrentTokenIfPossible(reason: String) async {
        guard let token = Self.storedToken, !token.isEmpty else {
            pushTokenDebugLog("[PushTokenDebug] upsertSkipped reason=\(reason) missingToken=true")
            return
        }
        guard let session = try? await supabase.auth.session else {
            pushTokenDebugLog("[PushTokenDebug] upsertSkipped reason=\(reason) missingSession=true")
            return
        }
        let userID = session.user.id
        let environment = Self.resolvedEnvironment()
        UserDefaults.standard.set(environment, forKey: Self.environmentDefaultsKey)

        let identity = PushTokenUpsertIdentity(
            userID: userID.uuidString.lowercased(),
            token: token,
            environment: environment
        )

        let outcome = await upsertCoalescer.run(identity: identity) {
            await Self.performTokenClaim(identity: identity, reason: reason)
        }

        switch outcome {
        case .performed:
            break
        case .coalesced:
            pushTokenDebugLog("[PushTokenPerf] duplicateCoalesced=true reason=\(reason)")
        case .skippedFresh:
            pushTokenDebugLog("[PushTokenPerf] duplicateSkipped=true reason=\(reason)")
        }
    }

    /// Claims the installation token exclusively for `auth.uid()` via SECURITY DEFINER RPC.
    private static func performTokenClaim(
        identity: PushTokenUpsertIdentity,
        reason: String
    ) async -> Bool {
        struct Params: Encodable {
            let p_token: String
            let p_environment: String
            let p_platform: String
        }

        do {
            let rowId: UUID = try await supabase
                .rpc(
                    "claim_push_token",
                    params: Params(
                        p_token: identity.token,
                        p_environment: identity.environment,
                        p_platform: "ios"
                    )
                )
                .execute()
                .value
            pushTokenDebugLog(
                "[PushTokenDebug] claimSucceeded userId=\(identity.userID) environment=\(identity.environment) " +
                "tokenPrefix=\(String(identity.token.prefix(12))) rowId=\(rowId.uuidString.lowercased()) reason=\(reason)"
            )
            return true
        } catch {
            // Fallback for environments that have not applied the claim RPC yet.
            pushTokenDebugLog(
                "[PushTokenDebug] claimRpcFailed fallingBackToLegacyUpsert reason=\(reason) error=\(error.localizedDescription)"
            )
            return await performLegacyTokenUpsert(identity: identity, reason: reason)
        }
    }

    /// Legacy path: upsert own row only (cannot steal other users' rows under RLS).
    private static func performLegacyTokenUpsert(
        identity: PushTokenUpsertIdentity,
        reason: String
    ) async -> Bool {
        let lastSeenAt = SupabaseTimestampParsing.encodeTimestamptz(Date())
        let row = UserPushTokenUpsertRow(
            user_id: identity.userID,
            token: identity.token,
            environment: identity.environment,
            last_seen_at: lastSeenAt
        )

        do {
            await invalidateMismatchedEnvironmentRows(
                userID: row.user_id,
                token: identity.token,
                storingEnvironment: identity.environment,
                reason: reason
            )
            try await supabase
                .from("user_push_tokens")
                .upsert(row, onConflict: "user_id,token,environment")
                .execute()
            try await supabase
                .from("user_push_tokens")
                .update(
                    PushTokenReactivationPatch(
                        is_active: true,
                        last_seen_at: lastSeenAt
                    )
                )
                .eq("user_id", value: row.user_id)
                .eq("token", value: identity.token)
                .eq("environment", value: identity.environment)
                .execute()
            pushTokenDebugLog(
                "[PushTokenDebug] legacyUpsertSucceeded userId=\(row.user_id) environment=\(row.environment) " +
                "tokenPrefix=\(String(identity.token.prefix(12))) reason=\(reason)"
            )
            return true
        } catch {
            pushTokenDebugLog("[PushTokenDebug] upsertFailed reason=\(reason) error=\(error.localizedDescription)")
            return false
        }
    }

    /// Deactivates only this installation's token for the outgoing session (multi-device safe).
    /// Prefer calling while JWT is still valid so `deactivate_current_push_token` can run.
    func deleteCurrentTokenForCurrentSession(reason: String, knownUserId: UUID? = nil) async {
        await deactivateCurrentTokenForCurrentSession(reason: reason, knownUserId: knownUserId)
    }

    func deactivateCurrentTokenForCurrentSession(reason: String, knownUserId: UUID? = nil) async {
        didCompleteLifecyclePushTokenRefresh = false
        await upsertCoalescer.invalidateFreshness()
        guard let token = Self.storedToken, !token.isEmpty else { return }

        let environment = Self.storedEnvironment

        struct DeactivateParams: Encodable {
            let p_token: String
            let p_environment: String
        }

        do {
            let deactivated: Bool = try await supabase
                .rpc(
                    "deactivate_current_push_token",
                    params: DeactivateParams(p_token: token, p_environment: environment)
                )
                .execute()
                .value
            pushTokenDebugLog(
                "[PushTokenDebug] deactivateSucceeded viaRpc=\(deactivated) reason=\(reason) " +
                "tokenPrefix=\(String(token.prefix(12)))"
            )
            return
        } catch {
            pushTokenDebugLog(
                "[PushTokenDebug] deactivateRpcFailed fallingBack reason=\(reason) error=\(error.localizedDescription)"
            )
        }

        // Fallback under RLS: deactivate own row only (requires live session matching knownUserId).
        let userID: UUID
        if let knownUserId {
            userID = knownUserId
        } else if let session = try? await supabase.auth.session {
            userID = session.user.id
        } else {
            return
        }

        do {
            try await supabase
                .from("user_push_tokens")
                .update(
                    PushTokenInvalidationPatch(
                        is_active: false,
                        invalidated_at: SupabaseTimestampParsing.encodeTimestamptz(Date())
                    )
                )
                .eq("user_id", value: userID.uuidString.lowercased())
                .eq("token", value: token)
                .eq("environment", value: environment)
                .eq("is_active", value: true)
                .execute()
            pushTokenDebugLog(
                "[PushTokenDebug] deactivateSucceeded viaUpdate userId=\(userID.uuidString.lowercased()) reason=\(reason)"
            )
        } catch {
            pushTokenDebugLog("[PushTokenDebug] deactivateFailed reason=\(reason) error=\(error.localizedDescription)")
        }
    }

    private static var storedToken: String? {
        UserDefaults.standard.string(forKey: deviceTokenDefaultsKey)
    }

    private static var storedEnvironment: String {
        resolvedEnvironment()
    }

    private static var buildConfiguration: String {
#if DEBUG
        return "Debug"
#else
        return "Release"
#endif
    }

    private static var buildConfigurationDefaultEnvironment: String {
#if DEBUG
        return "sandbox"
#else
        return "production"
#endif
    }

    private static func resolvedEnvironment() -> String {
        let entitlement = apsEnvironmentEntitlement()
        let environment: String
        switch entitlement {
        case "development":
            environment = "sandbox"
        case "production":
            environment = "production"
        default:
            environment = buildConfigurationDefaultEnvironment
        }

        pushTokenDebugLog("[PushTokenDebug] buildConfiguration=\(buildConfiguration)")
        pushTokenDebugLog("[PushTokenDebug] apsEnvironmentEntitlement=\(entitlement ?? "nil")")
        pushTokenDebugLog("[PushTokenDebug] storingEnvironment=\(environment)")
        return environment
    }

    private static func apsEnvironmentEntitlement() -> String? {
        guard let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: profileURL),
              let profile = String(data: data, encoding: .ascii) ?? String(data: data, encoding: .utf8),
              let keyRange = profile.range(of: "<key>aps-environment</key>") else {
            return nil
        }
        let suffix = profile[keyRange.upperBound...]
        guard let valueStart = suffix.range(of: "<string>")?.upperBound,
              let valueEnd = suffix[valueStart...].range(of: "</string>")?.lowerBound else {
            return nil
        }
        return String(suffix[valueStart..<valueEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func invalidateMismatchedEnvironmentRows(
        userID: String,
        token: String,
        storingEnvironment: String,
        reason: String
    ) async {
        do {
            try await supabase
                .from("user_push_tokens")
                .update(PushTokenInvalidationPatch(
                    is_active: false,
                    invalidated_at: SupabaseTimestampParsing.encodeTimestamptz(Date())
                ))
                .eq("user_id", value: userID)
                .eq("token", value: token)
                .neq("environment", value: storingEnvironment)
                .execute()
            pushTokenDebugLog("[PushTokenDebug] invalidatedMismatchedEnvironmentRows userId=\(userID) storingEnvironment=\(storingEnvironment) reason=\(reason)")
        } catch {
            pushTokenDebugLog("[PushTokenDebug] invalidateMismatchedEnvironmentRowsFailed reason=\(reason) error=\(error.localizedDescription)")
        }
    }

    private static func canRegisterRemoteNotifications(status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    private static func authorizationStatusDescription(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }
}

private struct UserPushTokenUpsertRow: Encodable {
    let user_id: String
    let token: String
    let platform: String = "ios"
    let environment: String
    let is_active: Bool = true
    let invalidated_at: String? = nil
    let last_seen_at: String
}

private struct PushTokenReactivationPatch: Encodable {
    let is_active: Bool
    let last_seen_at: String

    enum CodingKeys: String, CodingKey {
        case is_active
        case invalidated_at
        case last_seen_at
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(is_active, forKey: .is_active)
        try container.encodeNil(forKey: .invalidated_at)
        try container.encode(last_seen_at, forKey: .last_seen_at)
    }
}

private struct PushTokenInvalidationPatch: Encodable {
    let is_active: Bool
    let invalidated_at: String
}
