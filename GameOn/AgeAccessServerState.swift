import Foundation
import Supabase

/// Authoritative server age-access record for exactly one auth UUID.
///
/// The server is the only authority for social eligibility. A local
/// `UserDefaults` cache may never substitute for this snapshot.
struct AgeAccessServerSnapshot: Equatable, Sendable {
    let userId: UUID
    let status: AgeAccessState
    let policyVersion: String?
    let checkedAt: Date?
    /// Authoritative policy version reported by `public.age_access_current_policy_version()`.
    let serverPolicyVersion: String
    /// False when `user_profiles` has no row for this UUID yet (mid-signup).
    let profileRowExists: Bool

    /// Strict client-side rule, intentionally independent of the server
    /// `age_access_enforcement.mode` rollout switch: while the server still runs
    /// `block_under_13_only`, `unknown` must still fail closed in the app.
    var isEligibleForCurrentPolicy: Bool {
        guard profileRowExists, status == .eligible13Plus else { return false }
        guard let policyVersion, !policyVersion.isEmpty else { return false }
        guard policyVersion == serverPolicyVersion else { return false }
        return checkedAt != nil
    }

    var isBlockedUnder13: Bool { status == .under13 }

    /// Coarse reason for DEBUG logs. Never contains age, range, or birth date.
    var resolutionReason: String {
        if !profileRowExists { return "profile_row_missing" }
        if status == .under13 { return "blocked_under_13" }
        if status != .eligible13Plus { return "status_unresolved" }
        if (policyVersion ?? "").isEmpty { return "policy_version_missing" }
        if policyVersion != serverPolicyVersion { return "policy_version_stale" }
        if checkedAt == nil { return "checked_at_missing" }
        return "eligible"
    }
}

/// Result of hydrating the authoritative record. `unavailable` is never treated as eligible.
enum AgeAccessServerLoadOutcome: Sendable {
    case loaded(AgeAccessServerSnapshot)
    case unavailable(reason: String)
}

/// Injection seam so the gate can be driven deterministically by self-tests
/// without a second age-gate implementation.
struct AgeAccessServerGateway: Sendable {
    var loadState: @Sendable (UUID) async -> AgeAccessServerLoadOutcome
    var recordResult: @Sendable (UUID, AgeAccessState) async -> Bool

    static let live = AgeAccessServerGateway(
        loadState: { await AgeAccessServerStateLoader.load(userId: $0) },
        recordResult: { await AgeAccessServerStateLoader.record(userId: $0, state: $1) }
    )
}

private struct AgeAccessProfileAgeRow: Decodable {
    let ageAccessStatus: String?
    let agePolicyVersion: String?
    let ageCheckedAt: String?

    enum CodingKeys: String, CodingKey {
        case ageAccessStatus = "age_access_status"
        case agePolicyVersion = "age_policy_version"
        case ageCheckedAt = "age_checked_at"
    }
}

/// Live Supabase implementation of the authoritative age-access record.
enum AgeAccessServerStateLoader {
    static func load(userId: UUID) async -> AgeAccessServerLoadOutcome {
        let serverPolicyVersion = await currentPolicyVersion()
        do {
            let rows: [AgeAccessProfileAgeRow] = try await supabase
                .from("user_profiles")
                .select("age_access_status,age_policy_version,age_checked_at")
                .eq("id", value: userId)
                .limit(1)
                .execute()
                .value

            guard let row = rows.first else {
                return .loaded(
                    AgeAccessServerSnapshot(
                        userId: userId,
                        status: .unknown,
                        policyVersion: nil,
                        checkedAt: nil,
                        serverPolicyVersion: serverPolicyVersion,
                        profileRowExists: false
                    )
                )
            }

            let policyVersion = row.agePolicyVersion?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let checkedAt = row.ageCheckedAt.flatMap(SupabaseTimestampParsing.parseTimestamptz)

            return .loaded(
                AgeAccessServerSnapshot(
                    userId: userId,
                    status: AgeAccessState.fromServerStatus(row.ageAccessStatus),
                    policyVersion: (policyVersion?.isEmpty ?? true) ? nil : policyVersion,
                    checkedAt: checkedAt,
                    serverPolicyVersion: serverPolicyVersion,
                    profileRowExists: true
                )
            )
        } catch {
            return .unavailable(reason: "profile_read_failed")
        }
    }

    static func record(userId: UUID, state: AgeAccessState) async -> Bool {
        // Trust boundary: Apple Declared Age Range is evaluated on-device. The RPC
        // binds to auth.uid(), stamps the authoritative policy version + now(), and
        // refuses to clear a sticky blocked_under_13. There is no cryptographic
        // server-side verification of Apple's response.
        do {
            try await supabase
                .rpc("record_user_age_access_result", params: ["p_status": state.serverStatus])
                .execute()
            return true
        } catch {
            return false
        }
    }

    /// Reads the authoritative policy version. Scalar RPC bodies are returned as raw
    /// JSON fragments, so the payload is unwrapped textually instead of via `Decodable`.
    private static func currentPolicyVersion() async -> String {
        do {
            let response = try await supabase
                .rpc("age_access_current_policy_version")
                .execute()
            let raw = String(decoding: response.data, as: UTF8.self)
            let cleaned = raw.trimmingCharacters(
                in: CharacterSet(charactersIn: "\"[] \n\r\t")
            )
            return cleaned.isEmpty ? AgeAccessPolicy.policyVersion : cleaned
        } catch {
            return AgeAccessPolicy.policyVersion
        }
    }
}
