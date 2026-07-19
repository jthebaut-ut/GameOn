import CoreLocation
import Foundation

/// Lightweight in-memory Discover search over already-loaded ``VenueEventRow`` data for the selected date.
enum DiscoverVenueEventSearch {
    static let suggestionLimit = 14
    static let perCategoryLimit = 4

    struct IndexedGame: Identifiable, Hashable, Sendable {
        let id: String
        let eventID: UUID?
        let venueID: UUID
        let matchupTitle: String
        let homeTeam: String
        let awayTeam: String
        let homeNormalized: String
        let awayNormalized: String
        let titleNormalized: String
        let sport: String
        let sportNormalized: String
        let league: String?
        let leagueNormalized: String
        let venueName: String
        let timeLabel: String
        let latitude: Double
        let longitude: Double
        let eventDateYMD: String

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        static func == (lhs: IndexedGame, rhs: IndexedGame) -> Bool {
            lhs.id == rhs.id
        }
    }

    struct Suggestion: Identifiable, Hashable, Sendable {
        enum Kind: String, Sendable {
            case game
            case team
            case sport
            case league
        }

        let kind: Kind
        let title: String
        let subtitle: String
        let sportToken: String?
        let leagueToken: String?
        let teamToken: String?
        let venueIDs: [UUID]
        let matchupTitle: String?
        let accessibilityLabel: String
        let rankScore: Int

        var id: String {
            switch kind {
            case .game:
                return "game|\(DiscoverVenueEventSearch.normalize(title))"
            case .team:
                return "team|\(DiscoverVenueEventSearch.normalize(teamToken ?? title))"
            case .sport:
                return "sport|\(DiscoverVenueEventSearch.normalize(sportToken ?? title))"
            case .league:
                return "league|\(DiscoverVenueEventSearch.normalize(leagueToken ?? title))"
            }
        }
    }

    struct Index: Sendable {
        let dayYMD: String
        let games: [IndexedGame]
        let sports: [String]
        let leagues: [String]
        /// Display name → normalized name for unique participating teams on the selected date.
        let teams: [(displayName: String, normalized: String)]
    }

    static func dayString(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: calendar.startOfDay(for: date))
    }

    /// Pure string normalization for search matching (safe off the main actor).
    nonisolated static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "[“”\"'`]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[‐‑‒–—―]", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    /// Build a selected-date index from already-loaded venue events and venue coordinates.
    static func buildIndex(
        rows: [VenueEventRow],
        bars: [BarVenue],
        selectedDate: Date,
        calendar: Calendar = .current
    ) -> Index {
        let dayYMD = dayString(for: selectedDate, calendar: calendar)
        let barsByID = Dictionary(uniqueKeysWithValues: bars.map { ($0.id, $0) })
        var games: [IndexedGame] = []
        games.reserveCapacity(min(rows.count, 256))
        var sportSet = Set<String>()
        var leagueSet = Set<String>()
        var seenGameKeys = Set<String>()

        for row in rows {
            let status = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if !status.isEmpty, status != "active" { continue }
            guard let eventDate = row.event_date?.trimmingCharacters(in: .whitespacesAndNewlines),
                  eventDate == dayYMD else {
                continue
            }
            guard let venueID = row.venue_id, let bar = barsByID[venueID] else { continue }
            let coordinate = bar.coordinate
            guard CLLocationCoordinate2DIsValid(coordinate),
                  abs(coordinate.latitude) > 1e-5 || abs(coordinate.longitude) > 1e-5 else {
                continue
            }

            let home = row.home_team?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let away = row.away_team?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let sport = row.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let league = row.external_league?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = VenueGameCompetitorDisplay.publicTitle(
                eventTitle: row.event_title,
                sport: sport,
                homeTeam: home,
                awayTeam: away
            )
            guard !title.isEmpty else { continue }

            let dedupeKey = [
                venueID.uuidString.lowercased(),
                normalize(title),
                eventDate,
                normalize(sport)
            ].joined(separator: "|")
            guard seenGameKeys.insert(dedupeKey).inserted else { continue }

            if !sport.isEmpty { sportSet.insert(sport) }
            if let league, !league.isEmpty { leagueSet.insert(league) }

            games.append(
                IndexedGame(
                    id: dedupeKey,
                    eventID: row.id,
                    venueID: venueID,
                    matchupTitle: title,
                    homeTeam: home,
                    awayTeam: away,
                    homeNormalized: normalize(home),
                    awayNormalized: normalize(away),
                    titleNormalized: normalize(title),
                    sport: sport,
                    sportNormalized: normalize(sport),
                    league: league,
                    leagueNormalized: normalize(league ?? ""),
                    venueName: bar.name,
                    timeLabel: row.event_time?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    eventDateYMD: eventDate
                )
            )
        }

        games.sort {
            if $0.matchupTitle.localizedCaseInsensitiveCompare($1.matchupTitle) != .orderedSame {
                return $0.matchupTitle.localizedCaseInsensitiveCompare($1.matchupTitle) == .orderedAscending
            }
            return $0.venueName.localizedCaseInsensitiveCompare($1.venueName) == .orderedAscending
        }

        var teamOrder: [String] = []
        var teamDisplayByNormalized: [String: String] = [:]
        for game in games {
            for (raw, normalized) in [(game.homeTeam, game.homeNormalized), (game.awayTeam, game.awayNormalized)] {
                guard !normalized.isEmpty else { continue }
                if teamDisplayByNormalized[normalized] == nil {
                    teamOrder.append(normalized)
                    teamDisplayByNormalized[normalized] = raw
                }
            }
        }
        let teams = teamOrder.compactMap { key -> (displayName: String, normalized: String)? in
            guard let display = teamDisplayByNormalized[key] else { return nil }
            return (display, key)
        }

        return Index(
            dayYMD: dayYMD,
            games: games,
            sports: sportSet.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
            leagues: leagueSet.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
            teams: teams
        )
    }

    static func suggestions(
        query: String,
        index: Index,
        selectedDateLabel: String,
        languageCode: String,
        limit: Int = suggestionLimit,
        perCategoryLimit: Int = DiscoverVenueEventSearch.perCategoryLimit
    ) -> [Suggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let normalizedQuery = normalize(trimmed)
        guard !normalizedQuery.isEmpty else { return [] }

        let teamTokens = matchupTeamTokens(fromNormalizedQuery: normalizedQuery)
        let isExplicitMatchupQuery = teamTokens.count >= 2

        var gamesOut: [Suggestion] = []
        var teamsOut: [Suggestion] = []
        var leaguesOut: [Suggestion] = []
        var sportsOut: [Suggestion] = []

        let matchupGames = matchingGames(queryNormalized: normalizedQuery, rawQuery: trimmed, index: index)
        var emittedGameKeys = Set<String>()
        for group in groupedGamesByMatchup(matchupGames) {
            guard gamesOut.count < perCategoryLimit else { break }
            let key = normalize(group.title)
            guard emittedGameKeys.insert(key).inserted else { continue }
            let venueNames = Array(Set(group.games.map(\.venueName))).sorted()
            let sport = group.games.first?.sport ?? ""
            let time = group.games.first(where: { !$0.timeLabel.isEmpty })?.timeLabel ?? ""
            let secondaryParts = [venueNames.first, time, sport].compactMap { value -> String? in
                let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmedValue.isEmpty ? nil : trimmedValue
            }
            let subtitle = secondaryParts.joined(separator: " • ")
            let a11y = [
                group.title.replacingOccurrences(of: " vs ", with: " versus "),
                L10n.t("discover_search_kind_game", languageCode: languageCode),
                sport
            ]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: ". ")
            let score = group.games.map { titleScore($0, query: normalizedQuery) }.max() ?? 0
            let exactTitle = key == normalizedQuery || (isExplicitMatchupQuery && matchupPairMatches(
                group.games[0],
                teamA: teamTokens[0],
                teamB: teamTokens[1]
            ))
            gamesOut.append(
                Suggestion(
                    kind: .game,
                    title: group.title,
                    subtitle: subtitle,
                    sportToken: sport.isEmpty ? nil : sport,
                    leagueToken: group.games.first?.league,
                    teamToken: nil,
                    venueIDs: Array(Set(group.games.map(\.venueID))),
                    matchupTitle: group.title,
                    accessibilityLabel: a11y,
                    rankScore: exactTitle ? 1_000 + score : 800 + score
                )
            )
        }

        // Prefer exact matchups over single-team game lists for two-token queries.
        if isExplicitMatchupQuery {
            gamesOut.sort { $0.rankScore > $1.rankScore }
        }

        var emittedTeamKeys = Set<String>()
        for team in index.teams {
            guard teamsOut.count < perCategoryLimit else { break }
            let score = scoreTokenMatch(query: normalizedQuery, candidate: team.normalized)
            guard score > 0 else { continue }
            // For explicit matchups, skip emitting each side as a standalone team unless exact.
            if isExplicitMatchupQuery, score < 100 { continue }
            guard emittedTeamKeys.insert(team.normalized).inserted else { continue }
            let venueIDs = Array(Set(
                index.games
                    .filter { $0.homeNormalized == team.normalized || $0.awayNormalized == team.normalized }
                    .map(\.venueID)
            ))
            let catalogHit = FavoriteTeamCatalog.searchTeams(team.displayName).first {
                normalize($0.name) == team.normalized
            }
            let subtitleKey = catalogHit?.kind == .nationalTeam
                ? "discover_search_team_national_subtitle"
                : "discover_search_team_subtitle"
            teamsOut.append(
                Suggestion(
                    kind: .team,
                    title: team.displayName,
                    subtitle: L10n.t(subtitleKey, languageCode: languageCode),
                    sportToken: nil,
                    leagueToken: nil,
                    teamToken: team.displayName,
                    venueIDs: venueIDs,
                    matchupTitle: nil,
                    accessibilityLabel: [
                        team.displayName,
                        L10n.t("discover_search_kind_team", languageCode: languageCode)
                    ].joined(separator: ". "),
                    rankScore: score == 100 ? 900 : 500 + score
                )
            )
        }

        // Catalog teams (e.g. France) even when not present in today's loaded events.
        if !isExplicitMatchupQuery {
            for catalogTeam in FavoriteTeamCatalog.searchTeams(trimmed).prefix(6) {
                guard teamsOut.count < perCategoryLimit else { break }
                let nameNorm = normalize(catalogTeam.name)
                guard scoreTokenMatch(query: normalizedQuery, candidate: nameNorm) > 0 else { continue }
                guard emittedTeamKeys.insert(nameNorm).inserted else { continue }
                let venueIDs = Array(Set(
                    index.games
                        .filter {
                            scoreTokenMatch(query: nameNorm, candidate: $0.homeNormalized) > 0
                                || scoreTokenMatch(query: nameNorm, candidate: $0.awayNormalized) > 0
                        }
                        .map(\.venueID)
                ))
                let subtitleKey = catalogTeam.kind == .nationalTeam
                    ? "discover_search_team_national_subtitle"
                    : "discover_search_team_subtitle"
                let score = scoreTokenMatch(query: normalizedQuery, candidate: nameNorm)
                teamsOut.append(
                    Suggestion(
                        kind: .team,
                        title: catalogTeam.name,
                        subtitle: L10n.t(subtitleKey, languageCode: languageCode),
                        sportToken: nil,
                        leagueToken: nil,
                        teamToken: catalogTeam.name,
                        venueIDs: venueIDs,
                        matchupTitle: nil,
                        accessibilityLabel: [
                            catalogTeam.name,
                            L10n.t("discover_search_kind_team", languageCode: languageCode)
                        ].joined(separator: ". "),
                        rankScore: score == 100 ? 900 : 480 + score
                    )
                )
            }
        }

        for league in index.leagues {
            guard leaguesOut.count < perCategoryLimit else { break }
            let leagueNorm = normalize(league)
            let score = scoreTokenMatch(query: normalizedQuery, candidate: leagueNorm)
            guard score > 0 else { continue }
            leaguesOut.append(
                Suggestion(
                    kind: .league,
                    title: league,
                    subtitle: L10n.t("discover_search_league_subtitle", languageCode: languageCode),
                    sportToken: nil,
                    leagueToken: league,
                    teamToken: nil,
                    venueIDs: Array(Set(index.games.filter { $0.leagueNormalized == leagueNorm }.map(\.venueID))),
                    matchupTitle: league,
                    accessibilityLabel: String(
                        format: L10n.t("discover_search_league_a11y_format", languageCode: languageCode),
                        locale: Locale(identifier: languageCode),
                        league,
                        selectedDateLabel
                    ),
                    rankScore: score == 100 ? 850 : 450 + score
                )
            )
        }

        var emittedSportKeys = Set<String>()
        func appendSport(token: String, label: String, score: Int) {
            guard sportsOut.count < perCategoryLimit else { return }
            let sportNorm = normalize(token)
            let labelNorm = normalize(label)
            let key = sportNorm.isEmpty ? labelNorm : sportNorm
            guard emittedSportKeys.insert(key).inserted else { return }
            let venueIDs = Array(Set(
                index.games.filter {
                    $0.sportNormalized == sportNorm
                        || normalize(AppSportCatalog.displayLabel(forSportToken: $0.sport)) == labelNorm
                }.map(\.venueID)
            ))
            sportsOut.append(
                Suggestion(
                    kind: .sport,
                    title: label,
                    subtitle: L10n.t("discover_search_sport_subtitle", languageCode: languageCode),
                    sportToken: token,
                    leagueToken: nil,
                    teamToken: nil,
                    venueIDs: venueIDs,
                    matchupTitle: nil,
                    accessibilityLabel: String(
                        format: L10n.t("discover_search_sport_a11y_format", languageCode: languageCode),
                        locale: Locale(identifier: languageCode),
                        label,
                        selectedDateLabel
                    ),
                    rankScore: score == 100 ? 820 : 420 + score
                )
            )
        }

        for sport in index.sports {
            let label = AppSportCatalog.displayLabel(forSportToken: sport)
            let score = max(
                scoreTokenMatch(query: normalizedQuery, candidate: normalize(sport)),
                scoreTokenMatch(query: normalizedQuery, candidate: normalize(label))
            )
            guard score > 0 else { continue }
            appendSport(token: sport, label: label, score: score)
        }

        // Known catalog sports (Hockey/Tennis/…) even when absent from today's loaded rows.
        if !isExplicitMatchupQuery {
            for token in AppSportCatalog.sportsExcludingAll {
                let label = AppSportCatalog.displayLabel(forSportToken: token)
                let score = max(
                    scoreTokenMatch(query: normalizedQuery, candidate: normalize(token)),
                    scoreTokenMatch(query: normalizedQuery, candidate: normalize(label))
                )
                guard score >= 80 else { continue }
                appendSport(token: token, label: label, score: score)
            }
            for pair in AppSportCatalog.discoverMapDefaultPopularPairs {
                let score = max(
                    scoreTokenMatch(query: normalizedQuery, candidate: normalize(pair.selection)),
                    scoreTokenMatch(query: normalizedQuery, candidate: normalize(pair.display))
                )
                guard score >= 80 else { continue }
                appendSport(token: pair.selection, label: pair.display, score: score)
            }
        }

        gamesOut.sort { $0.rankScore > $1.rankScore }
        teamsOut.sort { $0.rankScore > $1.rankScore }
        leaguesOut.sort { $0.rankScore > $1.rankScore }
        sportsOut.sort { $0.rankScore > $1.rankScore }

        var out: [Suggestion] = []
        out.reserveCapacity(limit)
        for bucket in [gamesOut, teamsOut, leaguesOut, sportsOut] {
            for item in bucket {
                guard out.count < limit else { break }
                out.append(item)
            }
            if out.count >= limit { break }
        }
        return out
    }

    static func venuesShowingMatchup(title: String, index: Index) -> [IndexedGame] {
        let key = normalize(title)
        return index.games.filter { $0.titleNormalized == key }
    }

    static func venuesShowingTeam(team: String, index: Index) -> [IndexedGame] {
        let key = normalize(team)
        return index.games.filter {
            scoreTokenMatch(query: key, candidate: $0.homeNormalized) > 0
                || scoreTokenMatch(query: key, candidate: $0.awayNormalized) > 0
        }
    }

    static func venuesShowingSport(sport: String, index: Index) -> [IndexedGame] {
        let key = normalize(sport)
        return index.games.filter {
            $0.sportNormalized == key || normalize(AppSportCatalog.displayLabel(forSportToken: $0.sport)) == key
        }
    }

    static func venuesShowingLeague(league: String, index: Index) -> [IndexedGame] {
        let key = normalize(league)
        return index.games.filter { $0.leagueNormalized == key }
    }

    // MARK: - Matching

    private struct MatchupGroup {
        let title: String
        let games: [IndexedGame]
    }

    private static func groupedGamesByMatchup(_ games: [IndexedGame]) -> [MatchupGroup] {
        var order: [String] = []
        var buckets: [String: [IndexedGame]] = [:]
        for game in games {
            let key = game.titleNormalized
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key, default: []].append(game)
        }
        return order.compactMap { key in
            guard let games = buckets[key], let title = games.first?.matchupTitle else { return nil }
            return MatchupGroup(title: title, games: games)
        }
    }

    private static func matchingGames(queryNormalized: String, rawQuery: String, index: Index) -> [IndexedGame] {
        let teamTokens = matchupTeamTokens(fromNormalizedQuery: queryNormalized)
        if teamTokens.count >= 2 {
            let a = teamTokens[0]
            let b = teamTokens[1]
            return index.games.filter { game in
                matchupPairMatches(game, teamA: a, teamB: b)
            }.sorted { lhs, rhs in
                let ls = matchupPairScore(lhs, teamA: a, teamB: b)
                let rs = matchupPairScore(rhs, teamA: a, teamB: b)
                if ls != rs { return ls > rs }
                return lhs.matchupTitle.localizedCaseInsensitiveCompare(rhs.matchupTitle) == .orderedAscending
            }
        }

        if teamTokens.count == 1 {
            let token = teamTokens[0]
            return index.games.filter { game in
                scoreTokenMatch(query: token, candidate: game.homeNormalized) > 0
                    || scoreTokenMatch(query: token, candidate: game.awayNormalized) > 0
                    || scoreTokenMatch(query: token, candidate: game.titleNormalized) > 0
            }.sorted {
                singleTeamScore($0, token: token) > singleTeamScore($1, token: token)
            }
        }

        // Title / league / sport contains fallback for queries without clear team split.
        return index.games.filter { game in
            scoreTokenMatch(query: queryNormalized, candidate: game.titleNormalized) > 0
                || scoreTokenMatch(query: queryNormalized, candidate: game.leagueNormalized) > 0
                || scoreTokenMatch(query: queryNormalized, candidate: game.sportNormalized) > 0
        }.sorted {
            titleScore($0, query: queryNormalized) > titleScore($1, query: queryNormalized)
        }
    }

    /// Splits normalized queries like `france vs spain`, `france-spain`, `france spain`.
    private static func matchupTeamTokens(fromNormalizedQuery query: String) -> [String] {
        let separators = [" vs ", " v ", " - ", "-", " – ", " — "]
        for separator in separators {
            if query.contains(separator) {
                let parts = query
                    .components(separatedBy: separator)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if parts.count >= 2 {
                    return Array(parts.prefix(2))
                }
            }
        }

        let words = query.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        if words.count == 2 {
            return words
        }
        if words.count == 1 {
            return words
        }
        // Multi-word single team names: keep as one token unless an explicit separator was used.
        if words.count >= 3 {
            return [query]
        }
        return words
    }

    private static func matchupPairMatches(_ game: IndexedGame, teamA: String, teamB: String) -> Bool {
        let home = game.homeNormalized
        let away = game.awayNormalized
        if !home.isEmpty, !away.isEmpty {
            let direct = scoreTokenMatch(query: teamA, candidate: home) > 0
                && scoreTokenMatch(query: teamB, candidate: away) > 0
            let flipped = scoreTokenMatch(query: teamA, candidate: away) > 0
                && scoreTokenMatch(query: teamB, candidate: home) > 0
            if direct || flipped { return true }
        }
        // Title fallback when structured teams missing.
        return scoreTokenMatch(query: teamA, candidate: game.titleNormalized) > 0
            && scoreTokenMatch(query: teamB, candidate: game.titleNormalized) > 0
    }

    private static func matchupPairScore(_ game: IndexedGame, teamA: String, teamB: String) -> Int {
        let home = game.homeNormalized
        let away = game.awayNormalized
        var score = 0
        if !home.isEmpty, !away.isEmpty {
            score += scoreTokenMatch(query: teamA, candidate: home)
            score += scoreTokenMatch(query: teamB, candidate: away)
            score = max(
                score,
                scoreTokenMatch(query: teamA, candidate: away) + scoreTokenMatch(query: teamB, candidate: home)
            )
        }
        score += min(4, scoreTokenMatch(query: teamA, candidate: game.titleNormalized))
        score += min(4, scoreTokenMatch(query: teamB, candidate: game.titleNormalized))
        return score
    }

    private static func singleTeamScore(_ game: IndexedGame, token: String) -> Int {
        max(
            scoreTokenMatch(query: token, candidate: game.homeNormalized),
            scoreTokenMatch(query: token, candidate: game.awayNormalized),
            scoreTokenMatch(query: token, candidate: game.titleNormalized)
        )
    }

    private static func titleScore(_ game: IndexedGame, query: String) -> Int {
        max(
            scoreTokenMatch(query: query, candidate: game.titleNormalized),
            scoreTokenMatch(query: query, candidate: game.leagueNormalized),
            scoreTokenMatch(query: query, candidate: game.sportNormalized)
        )
    }

    /// Exact > prefix > controlled contains. Returns 0 when unmatched.
    private static func scoreTokenMatch(query: String, candidate: String) -> Int {
        guard !query.isEmpty, !candidate.isEmpty else { return 0 }
        if candidate == query { return 100 }
        if candidate.hasPrefix(query) { return 80 }
        // Avoid weak contains for very short queries (e.g. "us" inside unrelated words).
        if query.count >= 3, candidate.contains(query) {
            // Prefer token-boundary-ish contains.
            let parts = candidate.split(separator: " ").map(String.init)
            if parts.contains(where: { $0 == query || $0.hasPrefix(query) }) {
                return 60
            }
            return 40
        }
        return 0
    }
}
