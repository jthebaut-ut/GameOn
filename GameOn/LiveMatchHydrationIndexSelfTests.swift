import Foundation

#if DEBUG
/// Verifies that ``LiveMatchHydrationIndex`` resolves saved Pro Games to exactly the same
/// `LiveMatch` (and `matchedBy` tier) as the original per-tier linear scan.
/// Emits `[LiveHydrationIndexTest]`.
enum LiveMatchHydrationIndexSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[LiveHydrationIndexTest] PASS \(name)")
            } else {
                failures += 1
                print("[LiveHydrationIndexTest] FAIL \(name)")
            }
        }

        let base = Date(timeIntervalSince1970: 1_800_000_000)

        let matches: [LiveMatch] = [
            match(id: "thesportsdb:1001", source: "thesportsdb", externalId: "1001",
                  home: "Real Madrid", away: "Barcelona", league: "La Liga", sport: "Soccer", start: base),
            match(id: "2002", source: "TheSportsDB", externalId: "2002",
                  home: "Lakers", away: "Celtics", league: "NBA", sport: "Basketball", start: base),
            match(id: "", source: "provider", externalId: "3003",
                  home: "Yankees", away: "Red Sox", league: "MLB", sport: "Baseball", start: base),
            match(id: "dup-a", source: "thesportsdb", externalId: "4004",
                  home: "Chiefs", away: "Broncos", league: "NFL", sport: "American Football", start: base),
            match(id: "dup-b", source: "thesportsdb", externalId: "4004",
                  home: "Chiefs", away: "Broncos", league: "NFL", sport: "American Football", start: base),
            match(id: "5005", source: nil, externalId: nil,
                  home: "Oilers", away: "Flames", league: "NHL", sport: "Hockey", start: base),
            match(id: "6006", source: nil, externalId: nil,
                  home: "Oilers", away: "Flames", league: "AHL", sport: "Hockey",
                  start: base.addingTimeInterval(20 * 60 * 60)),
            match(id: "7007", source: "thesportsdb", externalId: "7007",
                  home: "Fury", away: "Usyk", league: "Boxing", sport: "Fighting", start: base)
        ]

        let savedGames: [SavedProGame] = [
            // directId via saved.id
            saved(id: "thesportsdb:1001", source: "thesportsdb", externalId: "1001",
                  home: "Real Madrid", away: "Barcelona", league: "La Liga", sport: "Soccer", start: base),
            // case-insensitive source + provider external id
            saved(id: "local-2002", source: "thesportsdb", externalId: "2002",
                  home: "Lakers", away: "Celtics", league: "NBA", sport: "Basketball", start: base),
            // stableKey fallback (empty match id → "source:external")
            saved(id: "", source: "provider", externalId: "3003",
                  home: "Yankees", away: "Red Sox", league: "MLB", sport: "Baseball", start: base),
            // duplicate provider ids: first row in array order must win
            saved(id: "local-4004", source: "thesportsdb", externalId: "4004",
                  home: "Chiefs", away: "Broncos", league: "NFL", sport: "American Football", start: base),
            // teams+date fallback with an ambiguous same-teams pair → must stay unmatched
            saved(id: "local-oilers", source: nil, externalId: nil,
                  home: "Oilers", away: "Flames", league: "NHL", sport: "Hockey",
                  start: base.addingTimeInterval(60 * 60)),
            // no candidate at all
            saved(id: "local-missing", source: "other", externalId: "9999",
                  home: "Nobody", away: "Nowhere", league: "None", sport: "Soccer", start: base),
            // teams+date fallback with a single qualifying row
            saved(id: "local-boxing", source: nil, externalId: nil,
                  home: "Fury", away: "Usyk", league: "Boxing", sport: "Fighting",
                  start: base.addingTimeInterval(30 * 60))
        ]

        let index = LiveMatchHydrationIndex.build(from: matches)
        for savedGame in savedGames {
            let reference = referenceFreshestLiveMatch(for: savedGame, in: matches)
            let indexed = index.firstMatch(for: savedGame, in: matches)
            let name = "saved=\(savedGame.id.isEmpty ? savedGame.stableKey : savedGame.id)"
            expect(reference?.match.id == indexed?.match.id, "\(name) matchId")
            expect(reference?.matchedBy == indexed?.matchedBy, "\(name) matchedBy")
        }

        expect(index.isValid(for: matches), "indexValidForSameSnapshot")
        expect(!index.isValid(for: Array(matches.dropLast())), "indexInvalidAfterRowRemoved")

        var mutated = matches
        mutated[0] = match(id: "thesportsdb:1001", source: "thesportsdb", externalId: "1001",
                           home: "Real Madrid", away: "Barcelona", league: "La Liga", sport: "Soccer",
                           start: base, scoreHome: 3, scoreAway: 1)
        expect(!index.isValid(for: mutated), "indexInvalidAfterScoreChange")

        runScaleBenchmark(liveRows: 680, savedGames: 25, unmatchedRatio: 0.8)

        print("[LiveHydrationIndexTest] completed failures=\(failures)")
    }

    /// Reproduces the device-scale batch (≈680 Live rows) so the linear-scan cost and the indexed
    /// cost can be compared directly in the console.
    private static func runScaleBenchmark(liveRows: Int, savedGames: Int, unmatchedRatio: Double) {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var matches: [LiveMatch] = []
        matches.reserveCapacity(liveRows)
        for row in 0..<liveRows {
            matches.append(
                match(
                    id: "thesportsdb:\(100_000 + row)",
                    source: "thesportsdb",
                    externalId: "\(100_000 + row)",
                    home: "Home Team \(row)",
                    away: "Away Team \(row)",
                    league: "League \(row % 40)",
                    sport: row % 2 == 0 ? "Soccer" : "Basketball",
                    start: base.addingTimeInterval(Double(row) * 600)
                )
            )
        }

        let unmatchedCount = Int(Double(savedGames) * unmatchedRatio)
        var saveds: [SavedProGame] = []
        saveds.reserveCapacity(savedGames)
        for slot in 0..<savedGames {
            if slot < unmatchedCount {
                // Worst case: falls through every tier, exactly like an old final saved game.
                saveds.append(
                    saved(
                        id: "archive:\(slot)",
                        source: "archive",
                        externalId: "\(900_000 + slot)",
                        home: "Retired Home \(slot)",
                        away: "Retired Away \(slot)",
                        league: "Archive",
                        sport: "Soccer",
                        start: base.addingTimeInterval(Double(-slot) * 86_400)
                    )
                )
            } else {
                let row = (slot * 37) % liveRows
                saveds.append(
                    saved(
                        id: "thesportsdb:\(100_000 + row)",
                        source: "thesportsdb",
                        externalId: "\(100_000 + row)",
                        home: "Home Team \(row)",
                        away: "Away Team \(row)",
                        league: "League \(row % 40)",
                        sport: row % 2 == 0 ? "Soccer" : "Basketball",
                        start: base.addingTimeInterval(Double(row) * 600)
                    )
                )
            }
        }

        let linearStartedAt = CFAbsoluteTimeGetCurrent()
        var linearMatched = 0
        for savedGame in saveds where referenceFreshestLiveMatch(for: savedGame, in: matches) != nil {
            linearMatched += 1
        }
        let linearMs = (CFAbsoluteTimeGetCurrent() - linearStartedAt) * 1000

        let indexedStartedAt = CFAbsoluteTimeGetCurrent()
        let index = LiveMatchHydrationIndex.build(from: matches)
        var indexedMatched = 0
        for savedGame in saveds where index.firstMatch(for: savedGame, in: matches) != nil {
            indexedMatched += 1
        }
        let indexedMs = (CFAbsoluteTimeGetCurrent() - indexedStartedAt) * 1000

        print(
            "[LiveHydrationIndexTest] benchmark liveRows=\(liveRows) savedGames=\(savedGames) "
                + "linearScanMs=\(String(format: "%.2f", linearMs)) "
                + "indexedMs=\(String(format: "%.2f", indexedMs)) "
                + "indexBuildMs=\(String(format: "%.2f", index.buildMs)) "
                + "linearMatched=\(linearMatched) indexedMatched=\(indexedMatched)"
        )
    }

    // MARK: - Reference implementation (pre-index linear scan)

    private static func referenceFreshestLiveMatch(
        for saved: SavedProGame,
        in candidateMatches: [LiveMatch]
    ) -> (match: LiveMatch, matchedBy: String)? {
        let savedId = SavedProGame.normalizedHydrationToken(saved.id)
        let savedStableKey = SavedProGame.normalizedHydrationToken(saved.stableKey)
        if let direct = candidateMatches.first(where: { match in
            let matchId = SavedProGame.normalizedHydrationToken(match.id)
            return !matchId.isEmpty && (matchId == savedId || matchId == savedStableKey)
        }) {
            return (direct, "directId")
        }

        if let source = saved.source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty,
           let externalId = saved.resolvedProviderExternalId,
           let externalMatch = candidateMatches.first(where: { match in
               guard match.source?.caseInsensitiveCompare(source) == .orderedSame else { return false }
               let matchExternal = SavedProGame.normalizedHydrationToken(match.externalId)
               return matchExternal == SavedProGame.normalizedHydrationToken(externalId)
           }) {
            return (externalMatch, "directExternalId")
        }

        if let providerId = saved.resolvedProviderExternalId,
           let externalMatch = candidateMatches.first(where: { match in
               SavedProGame.normalizedHydrationToken(match.externalId) == SavedProGame.normalizedHydrationToken(providerId)
           }) {
            return (externalMatch, "directExternalId")
        }

        if let exact = candidateMatches.first(where: { SavedProGame.stableKey(for: $0) == saved.stableKey }) {
            return (exact, "stableKey")
        }

        if let source = saved.source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty,
           let externalId = saved.externalId?.trimmingCharacters(in: .whitespacesAndNewlines), !externalId.isEmpty,
           let externalMatch = candidateMatches.first(where: { match in
               match.source?.caseInsensitiveCompare(source) == .orderedSame
                   && match.externalId?.caseInsensitiveCompare(externalId) == .orderedSame
           }) {
            return (externalMatch, "source+externalId")
        }

        let savedIdentifiers = LiveMatchHydrationIndex.hydrationIdentifiers(
            id: saved.id,
            externalId: saved.externalId,
            source: saved.source
        )
        if !savedIdentifiers.isEmpty,
           let providerMatch = candidateMatches.first(where: { match in
               !savedIdentifiers.isDisjoint(with: LiveMatchHydrationIndex.hydrationIdentifiers(
                   id: match.id,
                   externalId: match.externalId,
                   source: match.source
               ))
           }) {
            return (providerMatch, "providerId")
        }

        let savedAway = LiveMatchFilters.normalizedSearchText(saved.awayTeam)
        let savedHome = LiveMatchFilters.normalizedSearchText(saved.homeTeam)
        let savedLeague = LiveMatchFilters.normalizedSearchText(saved.league)
        let savedSport = LiveSportVisualType.normalize(saved.sport)
        guard !savedAway.isEmpty, !savedHome.isEmpty else { return nil }

        let fallbackMatches = candidateMatches.filter { match in
            let matchAway = LiveMatchFilters.normalizedSearchText(match.awayTeam)
            let matchHome = LiveMatchFilters.normalizedSearchText(match.homeTeam)
            guard matchAway == savedAway, matchHome == savedHome else { return false }

            let startsNearSavedTime = abs(match.startTime.timeIntervalSince(saved.startTime)) <= 6 * 60 * 60
            let sameDay = Calendar.current.isDate(match.startTime, inSameDayAs: saved.startTime)
            guard startsNearSavedTime || sameDay else { return false }

            guard savedSport == LiveSportVisualType.normalize(match.sport) else { return false }

            let matchLeague = LiveMatchFilters.normalizedSearchText(match.league)
            if !savedLeague.isEmpty, !matchLeague.isEmpty, savedLeague != matchLeague {
                return startsNearSavedTime
            }
            return true
        }
        guard fallbackMatches.count == 1, let fallback = fallbackMatches.first else { return nil }
        return (fallback, "teams+date")
    }

    // MARK: - Fixtures

    private static func match(
        id: String,
        source: String?,
        externalId: String?,
        home: String,
        away: String,
        league: String,
        sport: String,
        start: Date,
        scoreHome: Int = 0,
        scoreAway: Int = 0
    ) -> LiveMatch {
        LiveMatch(
            id: id,
            source: source,
            externalId: externalId,
            sport: sport,
            homeTeam: home,
            awayTeam: away,
            scoreHome: scoreHome,
            scoreAway: scoreAway,
            scoresAreAvailable: true,
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

    private static func saved(
        id: String,
        source: String?,
        externalId: String?,
        home: String,
        away: String,
        league: String,
        sport: String,
        start: Date
    ) -> SavedProGame {
        SavedProGame(
            id: id,
            source: source,
            externalId: externalId,
            homeTeam: home,
            awayTeam: away,
            league: league,
            sport: sport,
            startTime: start,
            matchStatus: .scheduled,
            scoreHome: 0,
            scoreAway: 0,
            featuredEventSlug: nil,
            tvSummary: nil,
            savedAt: start
        )
    }
}
#endif
