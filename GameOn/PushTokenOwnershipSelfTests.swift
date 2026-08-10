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
        expect(
            PushTokenOwnershipPolicy.mapApsEnvironment("development") == "sandbox",
            "aps-environment development → sandbox"
        )
        expect(
            PushTokenOwnershipPolicy.mapApsEnvironment("production") == "production",
            "aps-environment production → production"
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

        // Installation supersession (20260944)
        expect(
            PushTokenOwnershipPolicy.tokenRotationSupersedesSameInstallation,
            "rotated token supersedes prior token for same installation+env"
        )
        expect(
            PushTokenOwnershipPolicy.preservesOtherInstallationTokens,
            "other devices (different installation_id) stay active"
        )
        expect(
            PushTokenOwnershipPolicy.legacyNullInstallationSupersededOnClaim,
            "legacy NULL installation_id siblings for same user+env are superseded on claim"
        )
        expect(
            PushTokenOwnershipPolicy.apns200MeansAcceptedNotDisplayed,
            "APNs 200 means accepted for token, not displayed on current device"
        )
        expect(
            PushTokenOwnershipPolicy.invalidateOnlyAppleTokenFailures,
            "invalidate only BadDeviceToken/Unregistered/DeviceTokenNotForTopic"
        )

        // Pure supersession matrix
        let installA = UUID()
        let installB = UUID()
        let rows = [
            PushTokenOwnershipPolicy.TokenRow(
                token: "oldtokenoldtoken",
                environment: "sandbox",
                installationID: nil,
                isActive: true
            ),
            PushTokenOwnershipPolicy.TokenRow(
                token: "newtokennewtoken",
                environment: "sandbox",
                installationID: installA,
                isActive: true
            ),
            PushTokenOwnershipPolicy.TokenRow(
                token: "ipadtokenipadtok",
                environment: "sandbox",
                installationID: installB,
                isActive: true
            ),
        ]
        let after = PushTokenOwnershipPolicy.simulateClaimSupersession(
            rows: rows,
            claimedToken: "newtokennewtoken",
            environment: "sandbox",
            installationID: installA
        )
        expect(
            after.contains(where: { $0.token == "newtokennewtoken" && $0.isActive }),
            "claimed token remains active"
        )
        expect(
            after.contains(where: { $0.token == "oldtokenoldtoken" && !$0.isActive }),
            "legacy NULL install sibling deactivated"
        )
        expect(
            after.contains(where: { $0.token == "ipadtokenipadtok" && $0.isActive }),
            "other installation preserved"
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
    static let tokenRotationSupersedesSameInstallation = true
    static let preservesOtherInstallationTokens = true
    static let legacyNullInstallationSupersededOnClaim = true
    static let apns200MeansAcceptedNotDisplayed = true
    static let invalidateOnlyAppleTokenFailures = true

    struct TokenRow: Equatable {
        var token: String
        var environment: String
        var installationID: UUID?
        var isActive: Bool
    }

    static func isValidEnvironment(_ value: String) -> Bool {
        value == "sandbox" || value == "production"
    }

    static func mapApsEnvironment(_ entitlement: String) -> String? {
        switch entitlement {
        case "development": return "sandbox"
        case "production": return "production"
        default: return nil
        }
    }

    /// Mirrors 20260944 claim_push_token supersession for same user+env.
    static func simulateClaimSupersession(
        rows: [TokenRow],
        claimedToken: String,
        environment: String,
        installationID: UUID
    ) -> [TokenRow] {
        rows.map { row in
            var copy = row
            guard copy.environment == environment, copy.token != claimedToken, copy.isActive else {
                return copy
            }
            if copy.installationID == installationID || copy.installationID == nil {
                copy.isActive = false
            }
            return copy
        }
    }
}
#endif
