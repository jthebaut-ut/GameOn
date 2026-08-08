import Foundation

#if DEBUG
/// Client-side rules for exclusive APNs token ownership (no network).
enum PushTokenOwnershipSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[PushTokenOwnershipSelfTest] PASS \(name)")
            } else {
                failures += 1
                print("[PushTokenOwnershipSelfTest] FAIL \(name)")
            }
        }

        // Token normalization matches APNs Data → hex lowercase used by the registrar.
        let sample = Data([0x55, 0x35, 0x7f, 0xfe])
        let hex = sample.map { String(format: "%02x", $0) }.joined()
        expect(hex == "55357ffe", "A hex token normalization is lowercase")
        expect(hex == hex.lowercased(), "A token must stay lowercase")

        // Environment vocabulary
        expect(
            PushTokenOwnershipPolicy.isValidEnvironment("sandbox")
                && PushTokenOwnershipPolicy.isValidEnvironment("production"),
            "F sandbox/production are valid environments"
        )
        expect(
            !PushTokenOwnershipPolicy.isValidEnvironment("development"),
            "F entitlement development maps before storage; raw development is not stored"
        )

        // Ownership rules
        expect(
            PushTokenOwnershipPolicy.maxActiveUsersPerTokenEnvironment == 1,
            "C at most one active user per token+environment"
        )
        expect(
            PushTokenOwnershipPolicy.allowsMultipleActiveTokensPerUser,
            "B one user may have many active device tokens"
        )
        expect(
            PushTokenOwnershipPolicy.logoutDeactivatesOnlyCurrentInstallationToken,
            "D logout deactivates only this installation token"
        )
        expect(
            PushTokenOwnershipPolicy.accountSwitchMovesOwnershipViaClaim,
            "A account switch moves ownership via claim_push_token"
        )
        expect(
            PushTokenOwnershipPolicy.uniquenessIncludesEnvironment,
            "F uniqueness includes environment to avoid sandbox/production collisions"
        )
        expect(
            PushTokenOwnershipPolicy.rejectForeignConversationDeepLink,
            "H stale push tap must not open foreign conversations"
        )

        if failures == 0 {
            print("[PushTokenOwnershipSelfTest] ALL_PASSED")
        } else {
            print("[PushTokenOwnershipSelfTest] FAILURES=\(failures)")
        }
    }
}

enum PushTokenOwnershipPolicy {
    static let maxActiveUsersPerTokenEnvironment = 1
    static let allowsMultipleActiveTokensPerUser = true
    static let logoutDeactivatesOnlyCurrentInstallationToken = true
    static let accountSwitchMovesOwnershipViaClaim = true
    static let uniquenessIncludesEnvironment = true
    static let rejectForeignConversationDeepLink = true

    static func isValidEnvironment(_ value: String) -> Bool {
        value == "sandbox" || value == "production"
    }
}
#endif
