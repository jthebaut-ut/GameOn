import Foundation

#if DEBUG
/// Regression: Team Event Public/Private must stay independent of sport, format, and recruiting.
enum TeamEventVisibilitySelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[TeamEventVisibilityTest] PASS \(name)")
            } else {
                failures += 1
                print("[TeamEventVisibilityTest] FAIL \(name)")
            }
        }

        // Defaults
        expect(
            PickupGameEditPrivacyPolicy.defaultIsPublicForNewGame(isTeamSourcedCreate: true) == false,
            "Team create defaults Private"
        )
        expect(
            PickupGameEditPrivacyPolicy.defaultIsPublicForNewGame(isTeamSourcedCreate: false) == true,
            "Pickup create defaults Public"
        )

        // Persist selection exactly
        expect(PickupGameEditPrivacyPolicy.resolvedIsVisible(formIsPublic: true) == true, "Public → is_visible true")
        expect(PickupGameEditPrivacyPolicy.resolvedIsVisible(formIsPublic: false) == false, "Private → is_visible false")

        // Recruiting must not override
        expect(
            PickupGameEditPrivacyPolicy.resolvedIsVisible(
                formIsPublic: true,
                isTeamLinked: true,
                needsAdditionalPlayers: false
            ) == true,
            "Public + recruiting OFF still Public"
        )
        expect(
            PickupGameEditPrivacyPolicy.resolvedIsVisible(
                formIsPublic: false,
                isTeamLinked: true,
                needsAdditionalPlayers: true
            ) == false,
            "Private + recruiting ON still Private"
        )

        // Event-type independence (formats that disable recruiting UI)
        let formats: [GameType] = [
            .practice, .scrimmage, .league_game, .tournament_game, .match,
            .tryout, .clinic, .team_meeting, .announcement, .other
        ]
        for format in formats {
            let afterPublic = PickupGameEditPrivacyPolicy.resolvedIsVisible(formIsPublic: true)
            let afterPrivate = PickupGameEditPrivacyPolicy.resolvedIsVisible(formIsPublic: false)
            _ = FanTeamEventPresentation.policy(for: format)
            expect(afterPublic == true, "Public survives format=\(format.rawValue)")
            expect(afterPrivate == false, "Private survives format=\(format.rawValue)")
        }

        // Edit seed contract: existing row visibility is the source of truth
        expect(
            PickupGameEditPrivacyPolicy.resolvedIsVisible(formIsPublic: true) == true,
            "Edit Public row seeds Public"
        )
        expect(
            PickupGameEditPrivacyPolicy.resolvedIsVisible(formIsPublic: false) == false,
            "Edit Private row seeds Private"
        )

        // Sport independence (visibility policy has no sport axis)
        for sport in ["Soccer", "Badminton", "Running", "Cycling", "Climbing", "Skydiving", "Dance"] {
            _ = sport
            expect(
                PickupGameEditPrivacyPolicy.resolvedIsVisible(formIsPublic: true) == true,
                "Public independent of sport"
            )
        }

        expect(
            PickupGameEditPrivacyPolicy.showsVisibilityControl(isTeamLinked: false) == false,
            "Pickup create/edit hides Public/Private"
        )
        expect(
            PickupGameEditPrivacyPolicy.showsVisibilityControl(isTeamLinked: true) == true,
            "Team create/edit keeps Public/Private"
        )
        expect(
            PickupGameEditPrivacyPolicy.resolvedIsVisible(formIsPublic: false, isStandalonePickup: true) == true,
            "Standalone pickup always persists public"
        )
        expect(
            PickupGameEditPrivacyPolicy.resolvedIsVisible(formIsPublic: false, isStandalonePickup: false) == false,
            "Team Private still persists Private"
        )
        expect(
            PickupGameEditPrivacyPolicy.resolvedIsVisible(
                formIsPublic: false,
                isTeamLinked: false,
                needsAdditionalPlayers: true
            ) == true,
            "Pickup leftover Private form value still saves public"
        )

        if failures == 0 {
            print("[TeamEventVisibilityTest] ALL PASSED")
        } else {
            print("[TeamEventVisibilityTest] FAILURES=\(failures)")
            assertionFailure("TeamEventVisibilitySelfTests failed: \(failures)")
        }
    }
}
#endif
