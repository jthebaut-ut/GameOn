import Foundation

#if DEBUG
enum FanXPSelfTests {
    static func runAll() {
        testExistingAmountsUnchanged()
        testTeamAmounts()
        testCatalogMatchesCanonicalAmounts()
        testCatalogSections()
        testAnnouncementIsNotACatalogRow()
        testAntiFarmingCaps()
        testJoinPlayerTransitionPolicy()
        testSameTeamDoesNotDoubleAwardConceptually()
        testLocalizationKeysPresent()
    }

    private static func testExistingAmountsUnchanged() {
        assert(FanXPSource.expectedAmount(for: FanXPSource.favoriteVenue) == 2)
        assert(FanXPSource.expectedAmount(for: FanXPSource.venueEventInterest) == 5)
        assert(FanXPSource.expectedAmount(for: FanXPSource.pickupCreate) == 20)
        assert(FanXPSource.expectedAmount(for: FanXPSource.pickupJoinApproved) == 10)
        assert(FanXPSource.expectedAmount(for: FanXPSource.pickupComplete) == 15)
        assert(FanXPSource.expectedAmount(for: FanXPSource.friendConnected) == 5)
    }

    private static func testTeamAmounts() {
        assert(FanXPSource.expectedAmount(for: FanXPSource.teamCreated) == 20)
        assert(FanXPSource.expectedAmount(for: FanXPSource.teamJoinPlayer) == 10)
        assert(FanXPSource.expectedAmount(for: FanXPSource.teamEventCreated) == 5)
        assert(FanXPSource.expectedAmount(for: FanXPSource.teamEventCompletedPlayer) == 10)
        assert(FanXPSource.expectedAmount(for: FanXPSource.teamEventCompletedOrganizer) == 15)
        assert(FanXPSource.expectedAmount(for: "announcement") == 0)
    }

    private static func testCatalogMatchesCanonicalAmounts() {
        for rule in FanXpCatalog.implementedRules {
            let canonical = FanXPSource.expectedAmount(for: rule.id)
            assert(canonical > 0, "catalog id \(rule.id) missing canonical amount")
            assert(rule.points == canonical, "help table drifted from FanXPSource for \(rule.id)")
        }
        let ids = Set(FanXpCatalog.implementedRules.map(\.id))
        assert(ids.contains(FanXPSource.pickupCreate))
        assert(ids.contains(FanXPSource.teamCreated))
        assert(ids.contains(FanXPSource.teamJoinPlayer))
        assert(ids.contains(FanXPSource.teamEventCreated))
        assert(ids.contains(FanXPSource.teamEventCompletedPlayer))
        assert(ids.contains(FanXPSource.teamEventCompletedOrganizer))
    }

    private static func testCatalogSections() {
        let general = FanXpCatalog.rules(in: .general).map(\.id)
        assert(general == [
            FanXPSource.favoriteVenue,
            FanXPSource.venueEventInterest,
            FanXPSource.friendConnected
        ])
        let pickup = FanXpCatalog.rules(in: .pickup).map(\.id)
        assert(pickup == [
            FanXPSource.pickupCreate,
            FanXPSource.pickupJoinApproved,
            FanXPSource.pickupComplete
        ])
        let teams = FanXpCatalog.rules(in: .teams).map(\.id)
        assert(teams == [
            FanXPSource.teamCreated,
            FanXPSource.teamJoinPlayer,
            FanXPSource.teamEventCreated,
            FanXPSource.teamEventCompletedPlayer,
            FanXPSource.teamEventCompletedOrganizer
        ])
    }

    private static func testAnnouncementIsNotACatalogRow() {
        assert(!FanXpCatalog.implementedRules.contains(where: { $0.id == "announcement" }))
    }

    private static func testAntiFarmingCaps() {
        assert(FanXPTeamAwardPolicy.teamCreatedLifetimeCap == 5)
        assert(FanXPTeamAwardPolicy.teamEventCreatedDailyCap == 8)
        assert(FanXPTeamAwardPolicy.backfillsExistingPlayers == false)
        assert(FanXPTeamAwardPolicy.teamCreatedLifetimeCap * 20 == 100)
        assert(FanXPTeamAwardPolicy.teamEventCreatedDailyCap * 5 == 40)
        let createRule = FanXpCatalog.implementedRules.first { $0.id == FanXPSource.teamCreated }
        let eventRule = FanXpCatalog.implementedRules.first { $0.id == FanXPSource.teamEventCreated }
        assert(createRule?.frequencyKey == "fan_xp_freq_once_per_team_created")
        assert(eventRule?.frequencyKey == "fan_xp_freq_per_valid_team_event")
        let enCreate = L10n.t("fan_xp_freq_once_per_team_created", languageCode: "en")
        let enEvent = L10n.t("fan_xp_freq_per_valid_team_event", languageCode: "en")
        assert(enCreate.contains("5"))
        assert(enEvent.contains("8"))
    }

    private static func testJoinPlayerTransitionPolicy() {
        assert(
            FanXPTeamAwardPolicy.shouldAwardJoinPlayer(
                isInsert: true,
                wasEligibleAccountPlayer: false,
                isEligibleAccountPlayer: true,
                isManagedPlayerSeat: false
            )
        )
        assert(
            !FanXPTeamAwardPolicy.shouldAwardJoinPlayer(
                isInsert: false,
                wasEligibleAccountPlayer: true,
                isEligibleAccountPlayer: true,
                isManagedPlayerSeat: false
            ),
            "already-active player must not earn +10 on unrelated UPDATE"
        )
        assert(
            FanXPTeamAwardPolicy.shouldAwardJoinPlayer(
                isInsert: false,
                wasEligibleAccountPlayer: false,
                isEligibleAccountPlayer: true,
                isManagedPlayerSeat: false
            ),
            "false → true player transition earns once"
        )
        assert(
            !FanXPTeamAwardPolicy.shouldAwardJoinPlayer(
                isInsert: true,
                wasEligibleAccountPlayer: false,
                isEligibleAccountPlayer: true,
                isManagedPlayerSeat: true
            ),
            "managed player must not award guardian"
        )
        assert(
            !FanXPTeamAwardPolicy.shouldAwardJoinPlayer(
                isInsert: false,
                wasEligibleAccountPlayer: false,
                isEligibleAccountPlayer: false,
                isManagedPlayerSeat: false
            )
        )
    }

    private static func testSameTeamDoesNotDoubleAwardConceptually() {
        // Ledger unique key is (user_id, source, source_id). Same Team UUID
        // cannot insert a second team_created / team_join_player row.
        // Delete/recreate uses a new UUID and is stopped by the lifetime cap.
        assert(FanXPSource.teamCreated != FanXPSource.teamJoinPlayer)
        assert(FanXPSource.pickupCreate != FanXPSource.teamEventCreated)
        assert(FanXPSource.pickupComplete != FanXPSource.teamEventCompletedPlayer)
        assert(FanXPSource.pickupComplete != FanXPSource.teamEventCompletedOrganizer)
    }

    private static func testLocalizationKeysPresent() {
        let languages = [
            "en", "es", "fr", "pt", "de", "it", "pl", "ru", "sq", "zh-Hans", "nl"
        ]
        let keys = FanXpCatalog.implementedRules.flatMap { rule in
            [rule.titleKey, rule.frequencyKey]
        } + FanXpRule.Section.allCases.map(\.titleKey)
        for language in languages {
            for key in keys {
                let value = L10n.t(key, languageCode: language)
                assert(value != key, "missing \(language) localization for \(key)")
                assert(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
#endif
