import Foundation
import Security
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
    let installationID: String
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
    private static let installationIDKeychainAccount = "gameon.apnsInstallationId.v1"

    /// Skips duplicate foreground lifecycle refresh after launch/foreground already ran this process.
    private var didCompleteLifecyclePushTokenRefresh = false
    private let upsertCoalescer = PushTokenUpsertCoalescer()

    private init() {}

    func refreshPushTokenRegistration(reason: String) async {
        if reason == "foreground", didCompleteLifecyclePushTokenRefresh {
            pushTokenDebugLog("[PushToken] refreshSkipped reason=foreground alreadyRefreshedThisSession=true")
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
            pushTokenDebugLog("[PushToken] registerSkipped reason=\(reason) permission=\(Self.authorizationStatusDescription(settings.authorizationStatus))")
            return
        }

#if canImport(UIKit)
        await MainActor.run {
            pushTokenDebugLog("[PushToken] registerForRemoteNotifications reason=\(reason)")
            UIApplication.shared.registerForRemoteNotifications()
        }
#endif
    }

    func handleDeviceToken(_ deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let environment = Self.resolvedEnvironment()
        let previousToken = Self.storedToken
        let previousEnvironment = Self.storedEnvironmentOrNil

        pushTokenDebugLog(
            "[PushToken] registered environment=\(environment) tokenPrefix=\(String(token.prefix(8))) " +
            "installationPrefix=\(String(Self.installationID.uuidString.prefix(8)))"
        )

        // Token rotation: deactivate the prior install token before swapping UserDefaults.
        // Multi-device safe — only the previous token string known to this install is touched.
        if let previousToken, !previousToken.isEmpty,
           previousToken != token || (previousEnvironment != nil && previousEnvironment != environment) {
            let envToDeactivate = previousEnvironment ?? environment
            pushTokenDebugLog(
                "[PushToken] supersedePrevious tokenPrefix=\(String(previousToken.prefix(8))) environment=\(envToDeactivate)"
            )
            Task {
                await Self.deactivateToken(
                    token: previousToken,
                    environment: envToDeactivate,
                    installationID: Self.installationID,
                    reason: "tokenRotated"
                )
            }
        }

        UserDefaults.standard.set(token, forKey: Self.deviceTokenDefaultsKey)
        UserDefaults.standard.set(environment, forKey: Self.environmentDefaultsKey)
        Task { await upsertCurrentTokenIfPossible(reason: "didRegisterForRemoteNotifications") }
    }

    func handleRegistrationFailure(_ error: Error) {
        pushTokenDebugLog("[PushToken] registrationFailed error=\(error.localizedDescription)")
    }

    func upsertCurrentTokenIfPossible(reason: String) async {
        guard let token = Self.storedToken, !token.isEmpty else {
            pushTokenDebugLog("[PushToken] upsertSkipped reason=\(reason) missingToken=true")
            return
        }
        guard let session = try? await supabase.auth.session else {
            pushTokenDebugLog("[PushToken] upsertSkipped reason=\(reason) missingSession=true")
            return
        }
        let userID = session.user.id
        let environment = Self.resolvedEnvironment()
        UserDefaults.standard.set(environment, forKey: Self.environmentDefaultsKey)
        let installationID = Self.installationID

        pushTokenDebugLog(
            "[PushToken] upsertStart reason=\(reason) user=\(userID.uuidString.lowercased()) " +
            "environment=\(environment) tokenPrefix=\(String(token.prefix(8))) " +
            "installationPrefix=\(String(installationID.uuidString.prefix(8)))"
        )

        let identity = PushTokenUpsertIdentity(
            userID: userID.uuidString.lowercased(),
            token: token,
            environment: environment,
            installationID: installationID.uuidString.lowercased()
        )

        let outcome = await upsertCoalescer.run(identity: identity) {
            await Self.performTokenClaim(identity: identity, reason: reason)
        }

        switch outcome {
        case .performed:
            break
        case .coalesced:
            pushTokenDebugLog("[PushToken] duplicateCoalesced=true reason=\(reason)")
        case .skippedFresh:
            pushTokenDebugLog("[PushToken] duplicateSkipped=true reason=\(reason)")
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
            let p_installation_id: UUID
        }

        guard let installationUUID = UUID(uuidString: identity.installationID) else {
            pushTokenDebugLog("[PushToken] claimAborted invalidInstallationId reason=\(reason)")
            return false
        }

        do {
            let rowId: UUID = try await supabase
                .rpc(
                    "claim_push_token",
                    params: Params(
                        p_token: identity.token,
                        p_environment: identity.environment,
                        p_platform: "ios",
                        p_installation_id: installationUUID
                    )
                )
                .execute()
                .value
            pushTokenDebugLog(
                "[PushToken] claimSucceeded user=\(identity.userID) environment=\(identity.environment) " +
                "tokenPrefix=\(String(identity.token.prefix(8))) rowId=\(rowId.uuidString.lowercased()) " +
                "installationPrefix=\(String(identity.installationID.prefix(8))) reason=\(reason)"
            )
            return true
        } catch {
            // Fallback for environments that have not applied the installation_id RPC yet.
            pushTokenDebugLog(
                "[PushToken] claimRpcFailed fallingBack reason=\(reason) error=\(error.localizedDescription)"
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
            installation_id: identity.installationID,
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
                "[PushToken] legacyUpsertSucceeded user=\(row.user_id) environment=\(row.environment) " +
                "tokenPrefix=\(String(identity.token.prefix(8))) reason=\(reason)"
            )
            return true
        } catch {
            // Retry without installation_id if column not yet migrated.
            do {
                let legacyRow = UserPushTokenUpsertRowLegacy(
                    user_id: identity.userID,
                    token: identity.token,
                    environment: identity.environment,
                    last_seen_at: lastSeenAt
                )
                try await supabase
                    .from("user_push_tokens")
                    .upsert(legacyRow, onConflict: "user_id,token,environment")
                    .execute()
                pushTokenDebugLog(
                    "[PushToken] legacyUpsertSucceededWithoutInstallId user=\(identity.userID) reason=\(reason)"
                )
                return true
            } catch {
                pushTokenDebugLog("[PushToken] upsertFailed reason=\(reason) error=\(error.localizedDescription)")
                return false
            }
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
        await Self.deactivateToken(
            token: token,
            environment: Self.storedEnvironment,
            installationID: Self.installationID,
            reason: reason,
            knownUserId: knownUserId
        )
    }

    private static func deactivateToken(
        token: String,
        environment: String,
        installationID: UUID,
        reason: String,
        knownUserId: UUID? = nil
    ) async {
        struct DeactivateParams: Encodable {
            let p_token: String
            let p_environment: String
            let p_installation_id: UUID
        }

        do {
            let deactivated: Bool = try await supabase
                .rpc(
                    "deactivate_current_push_token",
                    params: DeactivateParams(
                        p_token: token,
                        p_environment: environment,
                        p_installation_id: installationID
                    )
                )
                .execute()
                .value
            pushTokenDebugLog(
                "[PushToken] deactivateSucceeded viaRpc=\(deactivated) reason=\(reason) " +
                "tokenPrefix=\(String(token.prefix(8))) environment=\(environment)"
            )
            return
        } catch {
            pushTokenDebugLog(
                "[PushToken] deactivateRpcFailed fallingBack reason=\(reason) error=\(error.localizedDescription)"
            )
        }

        // Fallback: try 2-arg RPC (pre-20260944), then RLS update.
        struct DeactivateParamsLegacy: Encodable {
            let p_token: String
            let p_environment: String
        }
        do {
            let deactivated: Bool = try await supabase
                .rpc(
                    "deactivate_current_push_token",
                    params: DeactivateParamsLegacy(p_token: token, p_environment: environment)
                )
                .execute()
                .value
            pushTokenDebugLog(
                "[PushToken] deactivateSucceeded viaLegacyRpc=\(deactivated) reason=\(reason) " +
                "tokenPrefix=\(String(token.prefix(8)))"
            )
            return
        } catch {
            pushTokenDebugLog(
                "[PushToken] deactivateLegacyRpcFailed reason=\(reason) error=\(error.localizedDescription)"
            )
        }

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
                "[PushToken] deactivateSucceeded viaUpdate user=\(userID.uuidString.lowercased()) reason=\(reason)"
            )
        } catch {
            pushTokenDebugLog("[PushToken] deactivateFailed reason=\(reason) error=\(error.localizedDescription)")
        }
    }

    private static var storedToken: String? {
        UserDefaults.standard.string(forKey: deviceTokenDefaultsKey)
    }

    /// Prefer the environment stored with the token (registration-time), not a live re-resolve.
    private static var storedEnvironment: String {
        if let stored = storedEnvironmentOrNil {
            return stored
        }
        return resolvedEnvironment()
    }

    private static var storedEnvironmentOrNil: String? {
        guard let stored = UserDefaults.standard.string(forKey: environmentDefaultsKey) else { return nil }
        let normalized = stored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized == "sandbox" || normalized == "production" else { return nil }
        return normalized
    }

    /// Stable per-install UUID (Keychain). Survives app updates; new install gets a new id.
    static var installationID: UUID {
        if let existing = readInstallationIDFromKeychain() {
            return existing
        }
        let created = UUID()
        writeInstallationIDToKeychain(created)
        return created
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

    /// Maps `aps-environment` entitlement/profile to stored DB environment.
    /// `development` → sandbox, `production` → production. Fallback: DEBUG/RELEASE only when unread.
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

        pushTokenDebugLog("[PushToken] buildConfiguration=\(buildConfiguration)")
        pushTokenDebugLog("[PushToken] apsEnvironmentEntitlement=\(entitlement ?? "nil")")
        pushTokenDebugLog("[PushToken] storingEnvironment=\(environment)")
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
            pushTokenDebugLog("[PushToken] invalidatedMismatchedEnvironmentRows user=\(userID) storingEnvironment=\(storingEnvironment) reason=\(reason)")
        } catch {
            pushTokenDebugLog("[PushToken] invalidateMismatchedEnvironmentRowsFailed reason=\(reason) error=\(error.localizedDescription)")
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

    // MARK: - Keychain installation id

    private static func readInstallationIDFromKeychain() -> UUID? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "com.jt.fangio",
            kSecAttrAccount as String: installationIDKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8),
              let uuid = UUID(uuidString: string) else {
            return nil
        }
        return uuid
    }

    private static func writeInstallationIDToKeychain(_ id: UUID) {
        let service = Bundle.main.bundleIdentifier ?? "com.jt.fangio"
        let data = Data(id.uuidString.utf8)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: installationIDKeychainAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: installationIDKeychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}

private struct UserPushTokenUpsertRow: Encodable {
    let user_id: String
    let token: String
    let platform: String = "ios"
    let environment: String
    let installation_id: String
    let is_active: Bool = true
    let invalidated_at: String? = nil
    let last_seen_at: String
}

private struct UserPushTokenUpsertRowLegacy: Encodable {
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
