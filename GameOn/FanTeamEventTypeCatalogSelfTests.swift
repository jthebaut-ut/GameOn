import Foundation

enum FanTeamEventTypeCatalogSelfTests {
    static func runAll() {
        testSoccerTaxonomyAndScoring()
        testRunningNoForcedScoreOrOpponent()
        testCyclingClimbingAerialDance()
        testMeetingAnnouncementOther()
        testResultCapabilityReservedCases()
        testEnsuringValidSelectionOnSportChange()
        testGenericEventChrome()
        testDisplayTitles()
        testMenuNeverIncludesPickupByDefault()
    }

    private static func testSoccerTaxonomyAndScoring() {
        let types = FanTeamEventTypeCatalog.availableTypes(for: "Soccer", canPublishAnnouncements: true)
        precondition(types.contains(.practice))
        precondition(types.contains(.league_game))
        precondition(types.contains(.scrimmage))
        precondition(types.contains(.tournament_game))
        precondition(types.contains(.tryout))
        precondition(types.contains(.clinic))
        precondition(types.contains(.team_meeting))
        precondition(types.contains(.other))
        precondition(types.contains(.announcement))
        precondition(!types.contains(.pickup))

        let practice = FanTeamEventTypeCatalog.capabilities(for: .practice, sport: "Soccer")
        precondition(practice.result == .none)
        precondition(!practice.requiresOpponent)

        let match = FanTeamEventTypeCatalog.capabilities(for: .league_game, sport: "Soccer")
        precondition(match.result == .headToHeadScore)
        precondition(match.requiresOpponent)
        precondition(match.supportsLiveScoring)

        let scrimmage = FanTeamEventTypeCatalog.capabilities(for: .scrimmage, sport: "Soccer")
        precondition(scrimmage.result == .headToHeadScore)
        precondition(scrimmage.requiresOpponent)

        let tournament = FanTeamEventTypeCatalog.capabilities(for: .tournament_game, sport: "Soccer")
        precondition(tournament.result == .headToHeadScore)
        precondition(tournament.requiresOpponent)
    }

    private static func testRunningNoForcedScoreOrOpponent() {
        let types = FanTeamEventTypeCatalog.availableTypes(for: "Running", canPublishAnnouncements: false)
        precondition(types.contains(.practice))
        precondition(types.contains(.clinic))
        precondition(types.contains(.tournament_game))
        precondition(types.contains(.league_game))
        precondition(!types.contains(.scrimmage))
        precondition(!types.contains(.announcement))

        let training = FanTeamEventTypeCatalog.capabilities(for: .practice, sport: "Running")
        precondition(training.result == .none)
        precondition(!training.requiresOpponent)

        let group = FanTeamEventTypeCatalog.capabilities(for: .clinic, sport: "Running")
        precondition(group.result == .none)

        let race = FanTeamEventTypeCatalog.capabilities(for: .tournament_game, sport: "Running")
        precondition(race.result == .none, "Race/Meet must not force H2H score")
        precondition(!race.requiresOpponent, "Race/Meet must not require a single opponent")

        let competition = FanTeamEventTypeCatalog.capabilities(for: .league_game, sport: "Running")
        precondition(competition.result == .none)
        precondition(!competition.requiresOpponent)
    }

    private static func testCyclingClimbingAerialDance() {
        let climbComp = FanTeamEventTypeCatalog.capabilities(for: .tournament_game, sport: "Climbing")
        precondition(climbComp.result == .none)
        precondition(!climbComp.requiresOpponent)

        let skySession = FanTeamEventTypeCatalog.capabilities(for: .clinic, sport: "Skydiving")
        precondition(skySession.result == .none)

        let dancePractice = FanTeamEventTypeCatalog.capabilities(for: .practice, sport: "Ballet")
        precondition(dancePractice.result == .none)

        let danceComp = FanTeamEventTypeCatalog.capabilities(for: .tournament_game, sport: "Ballet")
        precondition(danceComp.result == .none)
        precondition(!danceComp.requiresOpponent)

        let cyclingRace = FanTeamEventTypeCatalog.capabilities(for: .tournament_game, sport: "Cycling")
        precondition(cyclingRace.result == .none)
        precondition(!cyclingRace.requiresOpponent)
    }

    private static func testMeetingAnnouncementOther() {
        for format in [GameType.team_meeting, .announcement, .other] as [GameType] {
            let caps = FanTeamEventTypeCatalog.capabilities(for: format, sport: "Soccer")
            precondition(caps.result == .none)
            precondition(!caps.requiresOpponent)
            precondition(!caps.supportsLiveScoring)
        }
    }

    private static func testResultCapabilityReservedCases() {
        precondition(FanTeamEventResultCapability.placement.effectiveForCurrentProduct == .none)
        precondition(FanTeamEventResultCapability.time.effectiveForCurrentProduct == .none)
        precondition(FanTeamEventResultCapability.points.effectiveForCurrentProduct == .none)
        precondition(FanTeamEventResultCapability.headToHeadScore.effectiveForCurrentProduct == .headToHeadScore)
        precondition(FanTeamEventResultCapability.implementedCases == [.none, .headToHeadScore])
    }

    private static func testEnsuringValidSelectionOnSportChange() {
        let snapped = FanTeamEventTypeCatalog.ensuringValidSelection(
            .scrimmage,
            sport: "Running",
            canPublishAnnouncements: true
        )
        precondition(snapped != .scrimmage)
        precondition(
            FanTeamEventTypeCatalog.availableTypes(for: "Running", canPublishAnnouncements: true)
                .contains(snapped)
        )
    }

    private static func testGenericEventChrome() {
        precondition(
            FanTeamEventTypeCatalog.usesGenericEventChrome(format: .practice, sport: "Running")
        )
        precondition(
            !FanTeamEventTypeCatalog.usesGenericEventChrome(format: .league_game, sport: "Soccer")
        )
        precondition(
            FanTeamEventTypeCatalog.usesGenericEventChrome(format: .team_meeting, sport: "Soccer")
        )
    }

    private static func testDisplayTitles() {
        let soccerMatch = FanTeamEventTypeCatalog.displayTitle(
            for: .league_game,
            sport: "Soccer",
            languageCode: "en"
        )
        precondition(soccerMatch == "Game / Match", "got \(soccerMatch)")

        let race = FanTeamEventTypeCatalog.displayTitle(
            for: .tournament_game,
            sport: "Running",
            languageCode: "en"
        )
        precondition(race.lowercased().contains("race") || race.lowercased().contains("meet"))

        // Persisted display path for Team list filters remains GameType labels when catalog unused.
        let legacy = GameType.league_game.displayTitle(languageCode: "en")
        precondition(legacy.localizedCaseInsensitiveContains("league"))
    }

    private static func testMenuNeverIncludesPickupByDefault() {
        let menu = FanTeamEventTypeCatalog.menuTypes(
            for: "Soccer",
            current: .practice,
            canPublishAnnouncements: true
        )
        precondition(!menu.contains(.pickup))
    }
}
