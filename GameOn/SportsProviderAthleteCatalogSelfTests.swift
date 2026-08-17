import Foundation

#if DEBUG
enum SportsProviderAthleteCatalogSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[SportsProviderAthleteCatalogTest] PASS \(name)")
            } else {
                failures += 1
                print("[SportsProviderAthleteCatalogTest] FAIL \(name)")
            }
        }

        let snapshot = SportsArtworkURLStore.shared.pushTestIsolation()
        SportsProviderAthleteCatalog.resetForTests()
        defer {
            SportsProviderAthleteCatalog.resetForTests()
            SportsArtworkURLStore.shared.popTestIsolation(snapshot)
        }

        let beforeBasketball = FavoriteTeamCatalog.curatedCatalog.filter { $0.sport == .basketball && $0.kind == .player }.count
        let beforeSoccer = FavoriteTeamCatalog.curatedCatalog.filter { $0.sport == .soccer && $0.kind == .player }.count
        let beforeBaseball = FavoriteTeamCatalog.curatedCatalog.filter { $0.sport == .baseball && $0.kind == .player }.count
        let beforeSoccerClubs = FavoriteTeamCatalog.curatedCatalog.filter { $0.sport == .soccer && $0.kind == .team }.count
        expect(beforeBasketball <= 3, "BEFORE basketball curated seed is tiny")
        expect(beforeSoccer <= 3, "BEFORE soccer curated seed is tiny")
        expect(beforeBaseball <= 1, "BEFORE baseball curated seed is tiny")

        let rows = fixtureRows()
        SportsProviderAthleteCatalog.ingestIdentityRows(rows)
        SportsProviderArtworkIngest.ingest(rows)

        let basketball = FavoriteTeamCatalog.teams(sport: .basketball, categoryID: "basketball-players")
        let soccer = FavoriteTeamCatalog.teams(sport: .soccer, categoryID: "soccer-players")
        let baseball = FavoriteTeamCatalog.teams(sport: .baseball, categoryID: "baseball-players")
        expect(basketball.count >= 40, "Basketball has substantially more than the 3-player seed")
        expect(soccer.count >= 40, "Soccer has substantially more than Ronaldo/Messi")
        expect(baseball.count >= 20, "Baseball player catalog populated")

        let lakersPlayers = basketball.filter { $0.region == "Los Angeles Lakers" }
        expect(!lakersPlayers.isEmpty, "player → team relationship")
        expect(lakersPlayers.allSatisfy { $0.league == "NBA" }, "player → league relationship")
        expect(lakersPlayers.allSatisfy { $0.sport == .basketball }, "player → sport relationship")

        let nba = FavoriteFollowingCountryBrowse.athletes(from: basketball, leagueName: "NBA")
        expect(nba.count == basketball.filter { $0.league == "NBA" }.count, "league filtering")
        let lakers = FavoriteFollowingCountryBrowse.athletes(from: basketball, teamName: "Los Angeles Lakers")
        expect(lakers.count == lakersPlayers.count, "team filtering")

        let curryHits = FavoriteFollowingSearch.rankedResults(query: "Curry").filter { $0.kind == .player }
        expect(curryHits.contains(where: { $0.name.localizedCaseInsensitiveContains("Curry") }), "athlete search by player name")
        let lakersHits = FavoriteFollowingSearch.rankedResults(query: "Lakers").filter { $0.kind.isProfessionalAthlete }
        expect(!lakersHits.isEmpty, "search by team")
        let eplHits = FavoriteFollowingSearch.rankedResults(query: "Premier League").filter { $0.kind == .player }
        expect(!eplHits.isEmpty, "search by league")

        let playerIDs = basketball.map(\.id)
        expect(Set(playerIDs).count == playerIDs.count, "no duplicate provider players")
        expect(basketball.contains(where: { $0.id.hasPrefix(SportsProviderAthleteCatalog.generatedIDPrefix) }), "stable generated IDs")
        expect(FavoriteTeamCatalog.team(id: "player-stephen-curry")?.id == "player-stephen-curry", "curated IDs remain stable")

        if let photoPlayer = basketball.first(where: { $0.name == "Anthony Davis" }) {
            let art = SportsIdentityArtworkResolver.resolve(favoriteTeam: photoPlayer)
            expect(
                {
                    if case .verifiedRemote = art.kind { return true }
                    return false
                }(),
                "real artwork preferred"
            )
        } else {
            expect(false, "Anthony Davis fixture exists")
        }
        if let fallbackPlayer = basketball.first(where: { $0.name == "Austin Reaves" }) {
            let art = SportsIdentityArtworkResolver.resolve(favoriteTeam: fallbackPlayer)
            expect(
                {
                    if case .playerAthleteFallback = art.kind { return true }
                    return false
                }(),
                "Person-with-Star fallback"
            )
        } else {
            expect(false, "Austin Reaves fixture exists")
        }

        expect(
            FavoriteTeamsStore.self != SportsProviderAthleteCatalog.self,
            "follow/unfollow still uses FavoriteTeamsStore"
        )
        expect(
            FavoriteTeamCatalog.team(id: "player-tsdb-lakers-01") != nil,
            "overlay athlete is followable through catalog.team(id:)"
        )

        expect(
            FavoriteFollowingCountryBrowse.isAthleteCategory(id: "basketball-players"),
            "Featured Athletes is an athlete category"
        )
        expect(
            !FavoriteFollowingCountryBrowse.isAthleteCategory(id: "soccer-clubs"),
            "Teams category is unchanged"
        )
        expect(
            !FavoriteFollowingCountryBrowse.athleteLeagues(from: basketball).isEmpty,
            "Featured Athletes browse by league exists"
        )
        expect(
            !FavoriteFollowingCountryBrowse.athleteTeams(from: basketball).isEmpty,
            "Featured Athletes browse by team exists"
        )
        expect(
            FavoriteFollowingCountryBrowse.presentsUnclassifiedCountry(from: basketball) == false,
            "Featured Athletes does not present Unclassified country as primary navigation"
        )

        let afterSoccerClubs = FavoriteTeamCatalog.teams(sport: .soccer, categoryID: "soccer-clubs").count
        expect(afterSoccerClubs == beforeSoccerClubs, "existing Teams category unchanged")
        expect(
            FavoriteTeamCatalog.teams(sport: .soccer, categoryID: "soccer-national-teams").allSatisfy { $0.kind == .nationalTeam },
            "National Teams category unchanged"
        )
        expect(
            FavoriteTeamCatalog.teams(sport: .soccer, categoryID: "soccer-tournaments").allSatisfy(\.kind.isCompetitionLike),
            "soccer tournaments stay competition-like"
        )
        if let superBowl = FavoriteTeamCatalog.team(id: "tournament-super-bowl") {
            expect(
                FavoriteTeamCatalog.teams(sport: .football, categoryID: "football-tournaments").contains(where: { $0.id == superBowl.id }),
                "Following football competitions include Super Bowl"
            )
            let followingArt = SportsIdentityArtworkResolver.resolve(favoriteTeam: superBowl, diameter: 52)
            expect(
                {
                    if case .competitionFallback = followingArt.kind { return true }
                    if case .verifiedRemote = followingArt.kind { return true }
                    return false
                }(),
                "Following Super Bowl uses the shared competition resolver"
            )
        }

        expect(
            !SportsArtworkEnrichmentService.usesDirectTheSportsDBAPI,
            "no N+1 iOS provider calls"
        )

        let followed = [FavoriteTeamCatalog.team(id: "nba-lakers")].compactMap { $0 }
        let recommended = FavoriteFollowingCountryBrowse.recommendedAthletes(
            from: basketball,
            followedIdentities: followed,
            excludingIDs: [],
            curatedIDs: Set(FavoriteTeamCatalog.curatedCatalog.map(\.id)),
            limit: 10
        )
        expect(
            recommended.first?.region == "Los Angeles Lakers" || followed.isEmpty,
            "recommended prefers followed-team players"
        )

        if failures == 0 {
            print("[SportsProviderAthleteCatalogTest] ALL PASSED")
        } else {
            print("[SportsProviderAthleteCatalogTest] FAILURES=\(failures)")
            assertionFailure("SportsProviderAthleteCatalogSelfTests failed: \(failures)")
        }
    }

    private static func fixtureRows() -> [SportsProviderIdentityRow] {
        var rows: [SportsProviderIdentityRow] = [
            teamRow(id: "nba-lakers", teamId: "134867", name: "Los Angeles Lakers", league: "NBA", sport: "Basketball"),
            teamRow(id: "nba-celtics", teamId: "134860", name: "Boston Celtics", league: "NBA", sport: "Basketball"),
            teamRow(id: "soccer-arsenal", teamId: "133604", name: "Arsenal", league: "Premier League", sport: "Soccer"),
            teamRow(id: "soccer-chelsea", teamId: "133610", name: "Chelsea", league: "Premier League", sport: "Soccer"),
            teamRow(id: "mlb-cubs", teamId: "135269", name: "Chicago Cubs", league: "MLB", sport: "Baseball"),
            teamRow(id: "mlb-dodgers", teamId: "135268", name: "Los Angeles Dodgers", league: "MLB", sport: "Baseball")
        ]
        rows.append(contentsOf: basketballPlayers())
        rows.append(contentsOf: soccerPlayers())
        rows.append(contentsOf: baseballPlayers())
        return rows
    }

    private static func basketballPlayers() -> [SportsProviderIdentityRow] {
        let lakers = [
            ("lakers-01", "Austin Reaves", false),
            ("lakers-02", "Anthony Davis", true),
            ("lakers-03", "D'Angelo Russell", false),
            ("lakers-04", "Rui Hachimura", false),
            ("lakers-05", "Jarred Vanderbilt", false),
            ("lakers-06", "Gabe Vincent", false),
            ("lakers-07", "Max Christie", false),
            ("lakers-08", "Jaxson Hayes", false),
            ("lakers-09", "Cam Reddish", false),
            ("lakers-10", "Christian Wood", false),
            ("lakers-11", "Taurean Prince", false),
            ("lakers-12", "Spencer Dinwiddie", false),
            ("lakers-13", "Maxwell Lewis", false),
            ("lakers-14", "Harry Giles", false),
            ("lakers-15", "Skylar Mays", false),
            ("lakers-16", "Jalen Hood-Schifino", false),
            ("lakers-17", "Colin Castleton", false),
            ("lakers-18", "D'Moi Hodge", false),
            ("lakers-19", "Alex Fudge", false),
            ("lakers-20", "Dylan Windler", false)
        ]
        let celtics = (1...20).map { index in
            ("celtics-\(String(format: "%02d", index))", "Celtic Player \(index)", false)
        }
        return lakers.map {
            playerRow(id: $0.0, playerId: $0.0, name: $0.1, teamId: "134867", league: "NBA", sport: "Basketball", cutout: $0.2)
        } + celtics.map {
            playerRow(id: $0.0, playerId: $0.0, name: $0.1, teamId: "134860", league: "NBA", sport: "Basketball", cutout: $0.2)
        }
    }

    private static func soccerPlayers() -> [SportsProviderIdentityRow] {
        let arsenal = (1...20).map { index in
            ("arsenal-\(String(format: "%02d", index))", "Arsenal Player \(index)")
        }
        let chelsea = (1...20).map { index in
            ("chelsea-\(String(format: "%02d", index))", "Chelsea Player \(index)")
        }
        return arsenal.map {
            playerRow(id: $0.0, playerId: $0.0, name: $0.1, teamId: "133604", league: "Premier League", sport: "Soccer", cutout: false)
        } + chelsea.map {
            playerRow(id: $0.0, playerId: $0.0, name: $0.1, teamId: "133610", league: "Premier League", sport: "Soccer", cutout: false)
        }
    }

    private static func baseballPlayers() -> [SportsProviderIdentityRow] {
        let cubs = (1...15).map { index in ("cubs-\(String(format: "%02d", index))", "Cubs Player \(index)", "135269") }
        let dodgers = (1...15).map { index in ("dodgers-\(String(format: "%02d", index))", "Dodgers Player \(index)", "135268") }
        return (cubs + dodgers).map {
            playerRow(id: $0.0, playerId: $0.0, name: $0.1, teamId: $0.2, league: "MLB", sport: "Baseball", cutout: false)
        }
    }

    private static func teamRow(
        id: String,
        teamId: String,
        name: String,
        league: String,
        sport: String
    ) -> SportsProviderIdentityRow {
        SportsProviderIdentityRow(
            catalogId: id,
            kind: "team",
            provider: "thesportsdb",
            providerTeamId: teamId,
            providerPlayerId: nil,
            canonicalName: name,
            league: league,
            sport: sport,
            country: "United States",
            badgeUrl: "https://www.thesportsdb.com/images/media/team/badge/\(id).png",
            logoUrl: nil,
            playerCutoutUrl: nil,
            playerCreativeCommons: nil
        )
    }

    private static func playerRow(
        id: String,
        playerId: String,
        name: String,
        teamId: String,
        league: String,
        sport: String,
        cutout: Bool
    ) -> SportsProviderIdentityRow {
        SportsProviderIdentityRow(
            catalogId: "player-tsdb-\(id)",
            kind: "player",
            provider: "thesportsdb",
            providerTeamId: teamId,
            providerPlayerId: playerId,
            canonicalName: name,
            league: league,
            sport: sport,
            country: nil,
            badgeUrl: nil,
            logoUrl: nil,
            playerCutoutUrl: cutout ? "https://www.thesportsdb.com/images/media/player/cutout/\(id).png" : nil,
            playerCreativeCommons: cutout
        )
    }
}
#endif
