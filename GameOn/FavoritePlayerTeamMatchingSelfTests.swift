import Foundation

#if DEBUG
/// Verifies player favorites expand to explicit associated teams for Going/Live matching.
/// Emits `[FavoritePlayerTeamsTest]`.
enum FavoritePlayerTeamMatchingSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[FavoritePlayerTeamsTest] PASS \(name)")
            } else {
                failures += 1
                print("[FavoritePlayerTeamsTest] FAIL \(name)")
            }
        }

        // Completeness: every authoritative `.player` catalog id is classified.
        let catalogPlayers = FavoriteTeamCatalog.curatedCatalog.filter { $0.kind == .player }
        expect(
            Set(catalogPlayers.map(\.id)) == Set(FavoritePlayerTeamRelationships.allCatalogPlayerIDs),
            "inventoryMatchesCatalogPlayerCount_\(catalogPlayers.count)"
        )
        for player in catalogPlayers.sorted(by: { $0.id < $1.id }) {
            let kind = FavoritePlayerTeamRelationships.resolutionKind(for: player)
            let teams = player.associatedTeamIDs
            print(
                "[FavoritePlayerTeamsAudit] player=\(player.id) sport=\(player.sport.rawValue) "
                    + "status=\(kind.rawValue) teams=\(teams.joined(separator: "+"))"
            )
            switch kind {
            case .teamSport:
                expect(!teams.isEmpty, "teamSportHasMapping_\(player.id)")
                for teamID in teams {
                    expect(FavoriteTeamCatalog.team(id: teamID) != nil, "mappedTeamExists_\(player.id)_\(teamID)")
                }
            case .individual:
                expect(teams.isEmpty, "individualHasNoTeamMapping_\(player.id)")
                expect(
                    !FavoritePlayerTeamRelationships.suppressesGameDiscovery(for: player),
                    "individualNotSuppressed_\(player.id)"
                )
            case .retired:
                expect(teams.isEmpty, "retiredHasNoTeamMapping_\(player.id)")
                expect(
                    FavoritePlayerTeamRelationships.suppressesGameDiscovery(for: player),
                    "retiredSuppressed_\(player.id)"
                )
            case .unmapped:
                expect(teams.isEmpty, "unmappedHasNoTeamMapping_\(player.id)")
                expect(
                    FavoritePlayerTeamRelationships.suppressesGameDiscovery(for: player),
                    "unmappedSuppressed_\(player.id)"
                )
                // Fail the audit if any team-sport player is still unmapped.
                expect(
                    !FavoritePlayerTeamRelationships.isTeamSportPlayerSport(player.sport),
                    "noUnmappedTeamSportPlayer_\(player.id)"
                )
            }
        }

        guard let mbappe = FavoriteTeamCatalog.team(id: "player-kylian-mbappe"),
              let messi = FavoriteTeamCatalog.team(id: "player-lionel-messi"),
              let ronaldo = FavoriteTeamCatalog.team(id: "player-cristiano-ronaldo"),
              let lebron = FavoriteTeamCatalog.team(id: "player-lebron-james"),
              let clark = FavoriteTeamCatalog.team(id: "player-caitlin-clark"),
              let alcaraz = FavoriteTeamCatalog.team(id: "tennis-carlos-alcaraz"),
              let serena = FavoriteTeamCatalog.team(id: "tennis-serena-williams"),
              let nadal = FavoriteTeamCatalog.team(id: "tennis-rafael-nadal"),
              let realMadrid = FavoriteTeamCatalog.team(id: "soccer-real-madrid"),
              let france = FavoriteTeamCatalog.team(id: "soccer-france"),
              let psg = FavoriteTeamCatalog.team(id: "soccer-psg"),
              let fever = FavoriteTeamCatalog.team(id: "wnba-fever") else {
            print("[FavoritePlayerTeamsTest] FAIL catalogMissingRequiredTeams")
            return
        }

        expect(
            Set(mbappe.associatedTeamIDs) == Set(["soccer-real-madrid", "soccer-france"]),
            "A_mbappeAssociatedTeams"
        )
        expect(
            Set(messi.associatedTeamIDs) == Set(["soccer-inter-miami", "soccer-argentina"]),
            "B_messiAssociatedTeams"
        )
        expect(
            Set(ronaldo.associatedTeamIDs) == Set(["soccer-al-nassr", "soccer-portugal"]),
            "C_ronaldoAssociatedTeams"
        )
        expect(lebron.associatedTeamIDs == ["nba-lakers"], "D_lebronCurrentTeamOnly")
        expect(clark.associatedTeamIDs == ["wnba-fever"], "clarkMappedToFever")
        expect(fever.name == "Indiana Fever", "feverCatalogPresent")

        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let matches: [LiveMatch] = [
            match(id: "rm-barca", home: "Real Madrid", away: "Barcelona", league: "La Liga", sport: "Soccer", start: start),
            match(id: "fra-ger", home: "France", away: "Germany", league: "International", sport: "Soccer", start: start),
            match(id: "psg-lyon", home: "Paris Saint-Germain", away: "Lyon", league: "Ligue 1", sport: "Soccer", start: start),
            match(id: "mia-nyc", home: "Inter Miami", away: "NYCFC", league: "MLS", sport: "Soccer", start: start),
            match(id: "arg-bra", home: "Argentina", away: "Brazil", league: "International", sport: "Soccer", start: start),
            match(id: "nas-hil", home: "Al Nassr", away: "Al Hilal", league: "Saudi Pro League", sport: "Soccer", start: start),
            match(id: "por-esp", home: "Portugal", away: "Spain", league: "International", sport: "Soccer", start: start),
            match(id: "lal-bos", home: "Los Angeles Lakers", away: "Boston Celtics", league: "NBA", sport: "Basketball", start: start),
            match(id: "ind-nya", home: "Indiana Fever", away: "New York Liberty", league: "WNBA", sport: "Basketball", start: start),
            match(id: "alc-sin", home: "Carlos Alcaraz", away: "Jannik Sinner", league: "ATP", sport: "Tennis", start: start),
            match(id: "ser-iga", home: "Serena Williams", away: "Iga Swiatek", league: "WTA", sport: "Tennis", start: start),
            match(id: "unrelated", home: "Arsenal", away: "Chelsea", league: "Premier League", sport: "Soccer", start: start)
        ]

        // A. Mbappé → Real Madrid + France
        let mbappeOnly = MapViewModel.favoriteTeamProGames(from: matches, favoriteTeams: [mbappe])
        expect(
            Set(mbappeOnly.map(\.game.stableKey)) == Set([
                SavedProGame.stableKey(for: matches[0]),
                SavedProGame.stableKey(for: matches[1])
            ]),
            "A_mbappeMatchesClubAndNational"
        )
        expect(!mbappeOnly.contains { $0.game.homeTeam == "Paris Saint-Germain" }, "A_mbappeNoFormerClub")

        // B. Messi → Inter Miami + Argentina
        let messiOnly = MapViewModel.favoriteTeamProGames(from: matches, favoriteTeams: [messi])
        expect(
            Set(messiOnly.map(\.game.stableKey)) == Set([
                SavedProGame.stableKey(for: matches[3]),
                SavedProGame.stableKey(for: matches[4])
            ]),
            "B_messiMatchesClubAndNational"
        )

        // C. Ronaldo → Al Nassr + Portugal
        let ronaldoOnly = MapViewModel.favoriteTeamProGames(from: matches, favoriteTeams: [ronaldo])
        expect(
            Set(ronaldoOnly.map(\.game.stableKey)) == Set([
                SavedProGame.stableKey(for: matches[5]),
                SavedProGame.stableKey(for: matches[6])
            ]),
            "C_ronaldoMatchesClubAndNational"
        )

        // D. LeBron → Lakers only
        let lebronOnly = MapViewModel.favoriteTeamProGames(from: matches, favoriteTeams: [lebron])
        expect(lebronOnly.count == 1, "D_lebronOneMatch")
        expect(lebronOnly.first?.game.homeTeam == "Los Angeles Lakers", "D_lebronLakers")

        // E. Active tennis → self fixture
        let alcarazOnly = MapViewModel.favoriteTeamProGames(from: matches, favoriteTeams: [alcaraz])
        expect(alcarazOnly.count == 1, "E_alcarazSelfMatch")
        expect(alcarazOnly.first?.game.homeTeam == "Carlos Alcaraz", "E_alcarazParticipant")
        expect(
            FavoritePlayerTeamRelationships.resolutionKind(for: alcaraz) == .individual,
            "E_alcarazIndividualKind"
        )

        // F. Retired Serena / Nadal → zero relationships / matches
        expect(FavoritePlayerTeamRelationships.resolutionKind(for: serena) == .retired, "F_serenaRetired")
        expect(FavoritePlayerTeamRelationships.resolutionKind(for: nadal) == .retired, "F_nadalRetired")
        let serenaOnly = MapViewModel.favoriteTeamProGames(from: matches, favoriteTeams: [serena])
        expect(serenaOnly.isEmpty, "F_serenaNoGames")
        let nadalOnly = MapViewModel.favoriteTeamProGames(from: matches, favoriteTeams: [nadal])
        expect(nadalOnly.isEmpty, "F_nadalNoGames")
        // Michael Jordan is not in the catalog — retired example covered by Serena/Nadal.
        expect(FavoriteTeamCatalog.team(id: "player-michael-jordan") == nil, "F_jordanNotInCatalog")

        // G. Unmapped team-sport override → no fake match
        FavoritePlayerTeamRelationships.withOverride(
            favoriteID: "player-kylian-mbappe",
            teamIDs: []
        ) {
            let unmapped = MapViewModel.favoriteTeamProGames(from: matches, favoriteTeams: [mbappe])
            expect(unmapped.isEmpty, "G_unmappedPlayerNoFakeMatches")
            expect(
                FavoritePlayerTeamRelationships.resolutionKind(for: mbappe) == .unmapped,
                "G_unmappedKind"
            )
        }

        // H. Player + team duplicate → one row, direct team preferred
        let both = MapViewModel.favoriteTeamProGames(from: matches, favoriteTeams: [mbappe, realMadrid])
        let rmRows = both.filter { $0.game.stableKey == SavedProGame.stableKey(for: matches[0]) }
        expect(rmRows.count == 1, "H_mbappePlusMadridDeduped")
        expect(rmRows.first?.favoriteTeamID == realMadrid.id, "H_directTeamPreferred")

        let withFrance = MapViewModel.favoriteTeamProGames(from: matches, favoriteTeams: [mbappe, france])
        let fraRows = withFrance.filter { $0.game.stableKey == SavedProGame.stableKey(for: matches[1]) }
        expect(fraRows.count == 1, "H_mbappePlusFranceDeduped")
        expect(fraRows.first?.favoriteTeamID == france.id, "H_franceDirectPreferred")

        // I. Transfer override: Real Madrid → PSG
        FavoritePlayerTeamRelationships.withOverride(
            favoriteID: "player-kylian-mbappe",
            teamIDs: ["soccer-psg", "soccer-france"]
        ) {
            let transferred = MapViewModel.favoriteTeamProGames(from: matches, favoriteTeams: [mbappe])
            let keys = Set(transferred.map(\.game.stableKey))
            expect(!keys.contains(SavedProGame.stableKey(for: matches[0])), "I_transferDropsOldClub")
            expect(keys.contains(SavedProGame.stableKey(for: matches[2])), "I_transferMatchesNewClub")
            expect(keys.contains(SavedProGame.stableKey(for: matches[1])), "I_transferKeepsNational")
        }

        // Clark → Fever
        let clarkOnly = MapViewModel.favoriteTeamProGames(from: matches, favoriteTeams: [clark])
        expect(clarkOnly.count == 1, "clarkFeverMatchCount")
        expect(clarkOnly.first?.game.homeTeam == "Indiana Fever", "clarkFeverMatch")

        _ = psg
        if failures == 0 {
            print("[FavoritePlayerTeamsTest] ALL_PASSED count=\(catalogPlayers.count)")
        } else {
            print("[FavoritePlayerTeamsTest] FAILURES=\(failures)")
        }
    }

    private static func match(
        id: String,
        home: String,
        away: String,
        league: String,
        sport: String,
        start: Date
    ) -> LiveMatch {
        LiveMatch(
            id: id,
            source: "test",
            externalId: id,
            sport: sport,
            homeTeam: home,
            awayTeam: away,
            scoreHome: 0,
            scoreAway: 0,
            scoresAreAvailable: false,
            matchStatus: .scheduled,
            rawMatchStatus: nil,
            minute: nil,
            liveClockText: nil,
            league: league,
            sourceLeagueName: nil,
            eventName: nil,
            leagueAlternate: nil,
            sourceSportName: nil,
            startTime: start,
            venueName: nil,
            venueCity: nil,
            venueLatitude: nil,
            venueLongitude: nil,
            leagueCountry: nil,
            tvBroadcasts: [],
            timelineEvents: [],
            featuredEventSlug: nil,
            homeTeamBadgeURL: nil,
            awayTeamBadgeURL: nil
        )
    }
}
#endif
