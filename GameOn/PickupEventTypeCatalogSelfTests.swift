import Foundation

enum PickupEventTypeCatalogSelfTests {
    static func runAll() {
        testTeamBallSoccerTypes()
        testRunningTypes()
        testCyclingTypes()
        testClimbingTypes()
        testAerialTypes()
        testDanceTypes()
        testNeverExposesTeamOnlyTypes()
        testEnsuringValidSelectionOnSportChange()
        testParticipantTerminology()
        testContextualDisplayTitles()
        testLegacyFormatsRemainDecodableAsPickup()
        testStandalonePickupHasNoVisibilityControl()
    }

    private static func testStandalonePickupHasNoVisibilityControl() {
        precondition(!PickupGameEditPrivacyPolicy.showsVisibilityControl(isTeamLinked: false))
        precondition(PickupGameEditPrivacyPolicy.showsVisibilityControl(isTeamLinked: true))
        precondition(PickupGameEditPrivacyPolicy.defaultIsPublicForNewGame(isTeamSourcedCreate: false) == true)
        precondition(PickupGameEditPrivacyPolicy.defaultIsPublicForNewGame(isTeamSourcedCreate: true) == false)
        precondition(
            PickupGameEditPrivacyPolicy.resolvedIsVisible(formIsPublic: false, isStandalonePickup: true)
        )
        precondition(
            PickupGameEditPrivacyPolicy.resolvedIsVisible(formIsPublic: false, isStandalonePickup: false) == false
        )
    }

    private static func testTeamBallSoccerTypes() {
        let types = PickupEventTypeCatalog.availableTypes(for: "Soccer")
        precondition(types == [.pickup, .practice, .scrimmage, .league_game, .clinic, .other])
        precondition(PickupEventTypeCatalog.sportFamily(forSport: "Soccer") == .teamBall)
        precondition(PickupEventTypeCatalog.sportFamily(forSport: "NBA") == .teamBall)
    }

    private static func testRunningTypes() {
        let types = PickupEventTypeCatalog.availableTypes(for: "Running")
        precondition(types == [.pickup, .practice, .tournament_game, .other])
        precondition(!types.contains(.scrimmage))
        precondition(!types.contains(.league_game))
    }

    private static func testCyclingTypes() {
        let types = PickupEventTypeCatalog.availableTypes(for: "Cycling")
        precondition(types == [.pickup, .practice, .tournament_game, .other])
    }

    private static func testClimbingTypes() {
        let types = PickupEventTypeCatalog.availableTypes(for: "Climbing")
        precondition(types == [.pickup, .practice, .tournament_game, .other])
    }

    private static func testAerialTypes() {
        precondition(PickupEventTypeCatalog.sportFamily(forSport: "Skydiving") == .aerial)
        precondition(PickupEventTypeCatalog.sportFamily(forSport: "paragliding") == .aerial)
        let types = PickupEventTypeCatalog.availableTypes(for: "Skydiving")
        precondition(types == [.pickup, .practice, .tournament_game, .other])
    }

    private static func testDanceTypes() {
        let types = PickupEventTypeCatalog.availableTypes(for: "Ballet")
        precondition(types.contains(.practice))
        precondition(types.contains(.pickup))
        precondition(types.contains(.clinic))
        precondition(types.contains(.tournament_game))
        precondition(types.contains(.other))
        precondition(!types.contains(.scrimmage))
    }

    private static func testNeverExposesTeamOnlyTypes() {
        for sport in ["Soccer", "Running", "Cycling", "Climbing", "Skydiving", "Ballet", "NBA"] {
            let types = PickupEventTypeCatalog.availableTypes(for: sport)
            precondition(!types.contains(.announcement), "Announcement must not appear for \(sport)")
            precondition(!types.contains(.team_meeting), "Team Meeting must not appear for \(sport)")
        }
    }

    private static func testEnsuringValidSelectionOnSportChange() {
        // Scrimmage is team-ball only — snap when switching to Running.
        let snapped = PickupEventTypeCatalog.ensuringValidSelection(.scrimmage, sport: "Running")
        precondition(snapped == .practice || snapped == .pickup)
        precondition(PickupEventTypeCatalog.availableTypes(for: "Running").contains(snapped))

        let keep = PickupEventTypeCatalog.ensuringValidSelection(.pickup, sport: "Soccer")
        precondition(keep == .pickup)

        let match = PickupEventTypeCatalog.ensuringValidSelection(.match, sport: "Soccer")
        precondition(match == .league_game)
    }

    private static func testParticipantTerminology() {
        precondition(PickupEventTypeCatalog.usesParticipantTerminology(for: "Running"))
        precondition(PickupEventTypeCatalog.usesParticipantTerminology(for: "Cycling"))
        precondition(PickupEventTypeCatalog.usesParticipantTerminology(for: "Climbing"))
        precondition(PickupEventTypeCatalog.usesParticipantTerminology(for: "Skydiving"))
        precondition(PickupEventTypeCatalog.usesParticipantTerminology(for: "Ballet"))
        precondition(PickupEventTypeCatalog.usesParticipantTerminology(for: "Electric Scooter"))
        precondition(PickupEventTypeCatalog.usesParticipantTerminology(for: "Inline Skating"))
        precondition(!PickupEventTypeCatalog.usesParticipantTerminology(for: "Soccer"))
        precondition(!PickupEventTypeCatalog.usesParticipantTerminology(for: "NBA"))
    }

    private static func testContextualDisplayTitles() {
        let soccerMatch = PickupEventTypeCatalog.displayTitle(
            for: .league_game,
            sport: "Soccer",
            languageCode: "en"
        )
        precondition(soccerMatch == "Match", "expected Match, got \(soccerMatch)")

        let groupRun = PickupEventTypeCatalog.displayTitle(
            for: .pickup,
            sport: "Running",
            languageCode: "en"
        )
        precondition(groupRun.lowercased().contains("run") || groupRun.lowercased().contains("activity"))

        // Team display path unchanged when using GameType.displayTitle directly.
        let teamLeague = GameType.league_game.displayTitle(languageCode: "en")
        precondition(teamLeague.localizedCaseInsensitiveContains("league"))
    }

    private static func testLegacyFormatsRemainDecodableAsPickup() {
        for raw in ["pickup", "practice", "scrimmage", "league_game", "tournament_game", "tryout", "clinic", "other", "match"] {
            precondition(GameType.parse(raw) != nil, "must parse \(raw)")
            precondition(
                PickupEventTypeCatalog.isStandalonePickupPersistedFormat(GameType.parse(raw)!),
                "\(raw) must remain a valid standalone Pickup format"
            )
        }
        precondition(!PickupEventTypeCatalog.isStandalonePickupPersistedFormat(.announcement))
        precondition(!PickupEventTypeCatalog.isStandalonePickupPersistedFormat(.team_meeting))
        precondition(GameType.pickupOrganizerCases.contains(.other))
    }
}
