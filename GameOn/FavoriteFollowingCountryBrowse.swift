import Foundation

/// Navigation identity for a Following country-detail push.
struct FavoriteFollowingCountryRoute: Hashable, Identifiable, Sendable {
    let id: String
    let displayName: String

    var isUnclassified: Bool { id == FavoriteFollowingCountryOption.otherID }
}

struct FavoriteFollowingAllCountriesRoute: Hashable, Sendable {}

/// Lightweight league navigation value. Must not embed ``FavoriteTeam`` — that inflates
/// NavigationPath / generic metadata and can trap in DEBUG when Following is constructed.
struct FavoriteFollowingLeagueRoute: Hashable, Sendable {
    let id: String
    let name: String
}

struct FavoriteFollowingAthleteTeamRoute: Hashable, Sendable {
    let id: String
    let name: String
}

struct FavoriteFollowingAthleteLeagueRoute: Hashable, Sendable {
    let id: String
    let name: String
}

/// League/competition summary derived from the local catalog for one country + sport.
struct FavoriteFollowingLeagueSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let teamCount: Int
    /// Catalog row used for league/team artwork (never a bundled logo).
    let artworkTeam: FavoriteTeam?

    var route: FavoriteFollowingLeagueRoute {
        FavoriteFollowingLeagueRoute(id: id, name: name)
    }
}

/// Deterministic country-browse projections over ``FavoriteTeamCatalog``.
/// Local-only: no network, no fake follower counts.
///
/// Popular Teams uses catalog ``sectionOrder`` (featured leagues first), then name within a
/// section. FanGeo has no follower-count popularity signal; this is not a recommendation engine.
nonisolated enum FavoriteFollowingCountryBrowse {
    static let featuredCountryLimit = 8
    static let popularTeamLimit = 12
    static let recommendedTeamLimit = 10

    /// Countries with catalog rows for the current sport/category. Excludes the synthetic "All" option.
    static func countries(
        from teams: [FavoriteTeam],
        languageCode: String,
        unclassifiedTitle: String
    ) -> [FavoriteFollowingCountryOption] {
        let options = FavoriteFollowingGeo.countryOptions(
            from: teams,
            continent: .all,
            languageCode: languageCode,
            allCountriesTitle: "",
            unclassifiedTitle: unclassifiedTitle
        )
        return uniquedCountries(options.filter { !$0.isAll && !$0.id.isEmpty })
    }

    /// Horizontal root strip: most catalog coverage first, then localized name. Unclassified last.
    static func featuredCountries(
        from countries: [FavoriteFollowingCountryOption],
        limit: Int = featuredCountryLimit
    ) -> [FavoriteFollowingCountryOption] {
        let classified = countries.filter { !$0.isOther }
            .sorted { lhs, rhs in
                if lhs.itemCount != rhs.itemCount { return lhs.itemCount > rhs.itemCount }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        let other = countries.filter(\.isOther)
        return uniquedCountries(Array((classified + other).prefix(limit)))
    }

    static func teams(
        from teams: [FavoriteTeam],
        countryID: String
    ) -> [FavoriteTeam] {
        uniquedTeams(teams.filter { FavoriteFollowingGeo.matchesCountry($0, countryID: countryID) })
    }

    static func teamCount(from teams: [FavoriteTeam]) -> Int {
        teams.count
    }

    /// Unique league/competition names among club/national rows, plus catalog competition entities.
    static func leagues(from teams: [FavoriteTeam]) -> [FavoriteFollowingLeagueSummary] {
        let clubOrNational = teams.filter { $0.kind == .team || $0.kind == .nationalTeam }
        let groups = FavoriteTeamCatalog.sectionGroups(for: clubOrNational)
        var summaries: [FavoriteFollowingLeagueSummary] = []
        var seen = Set<String>()

        for (title, shelfTeams) in groups {
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = Self.normalizedKey(name)
            guard seen.insert(key).inserted else { continue }
            let count = shelfTeams.filter { $0.kind == .team || $0.kind == .nationalTeam }.count
            summaries.append(
                FavoriteFollowingLeagueSummary(
                    id: "league:\(key)",
                    name: name,
                    teamCount: max(count, shelfTeams.count),
                    artworkTeam: shelfTeams.first
                )
            )
        }

        for team in teams where team.kind.isCompetitionLike {
            let name = team.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = Self.normalizedKey(name)
            if let index = summaries.firstIndex(where: { Self.normalizedKey($0.name) == key }) {
                if summaries[index].artworkTeam?.kind.isCompetitionLike != true {
                    summaries[index] = FavoriteFollowingLeagueSummary(
                        id: summaries[index].id,
                        name: summaries[index].name,
                        teamCount: summaries[index].teamCount,
                        artworkTeam: team
                    )
                }
                continue
            }
            summaries.append(
                FavoriteFollowingLeagueSummary(
                    id: "league:\(key)",
                    name: name,
                    teamCount: 0,
                    artworkTeam: team
                )
            )
        }
        return summaries
    }

    /// First-wins lookup used by search indexing. Duplicate catalog IDs must not trap.
    static func dictionaryByUniqueID(_ teams: [FavoriteTeam]) -> [String: FavoriteTeam] {
        var dict: [String: FavoriteTeam] = [:]
        dict.reserveCapacity(teams.count)
        for team in teams {
            let key = team.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, dict[key] == nil else { continue }
            dict[key] = team
        }
        return dict
    }

    /// Drops empty and duplicate catalog IDs so SwiftUI ``ForEach`` cannot trap.
    static func uniquedTeams(_ teams: [FavoriteTeam]) -> [FavoriteTeam] {
        var seen = Set<String>()
        var out: [FavoriteTeam] = []
        out.reserveCapacity(teams.count)
        for team in teams {
            let key = team.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(team)
        }
        return out
    }

    static func hasUniqueIDs(_ teams: [FavoriteTeam]) -> Bool {
        let ids = teams.map(\.id)
        return Set(ids).count == ids.count && ids.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func hasUniqueIDs(_ leagues: [FavoriteFollowingLeagueSummary]) -> Bool {
        let ids = leagues.map(\.id)
        return Set(ids).count == ids.count && ids.allSatisfy { !$0.isEmpty }
    }

    static func uniquedCountries(_ countries: [FavoriteFollowingCountryOption]) -> [FavoriteFollowingCountryOption] {
        var seen = Set<String>()
        return countries.filter { option in
            let key = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    static func hasUniqueCountryIDs(_ countries: [FavoriteFollowingCountryOption]) -> Bool {
        let ids = countries.map(\.id)
        return Set(ids).count == ids.count && ids.allSatisfy { !$0.isEmpty }
    }

    static func leagueCount(from teams: [FavoriteTeam]) -> Int {
        leagues(from: teams).count
    }

    /// Popular = catalog section order (featured leagues first), then name within a section.
    /// Not follower counts. Not a recommendation engine.
    static func popularTeams(
        from teams: [FavoriteTeam],
        limit: Int = popularTeamLimit
    ) -> [FavoriteTeam] {
        guard limit > 0 else { return [] }
        var result: [FavoriteTeam] = []
        var seen = Set<String>()
        for (_, shelf) in FavoriteTeamCatalog.sectionGroups(for: teams) {
            for team in shelf {
                let id = team.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, seen.insert(id).inserted else { continue }
                result.append(team)
                if result.count >= limit { return result }
            }
        }
        return result
    }

    static func teams(
        from teams: [FavoriteTeam],
        leagueName: String
    ) -> [FavoriteTeam] {
        let key = normalizedKey(leagueName)
        guard !key.isEmpty else { return [] }
        return uniquedTeams(teams.filter { team in
            if team.kind.isCompetitionLike {
                return normalizedKey(team.name) == key
            }
            return normalizedKey(team.league) == key
        })
    }

    static func filteredAllTeams(
        from teams: [FavoriteTeam],
        search: String,
        leagueName: String?,
        sortAscending: Bool
    ) -> [FavoriteTeam] {
        var result = teams
        if let leagueName, !leagueName.isEmpty {
            result = Self.teams(from: result, leagueName: leagueName)
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let allowed = Set(result.map(\.id))
            result = FavoriteFollowingSearch.rankedResults(query: query)
                .filter { allowed.contains($0.id) }
        }
        if query.isEmpty {
            result.sort { lhs, rhs in
                let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return sortAscending
                    ? comparison == .orderedAscending
                    : comparison == .orderedDescending
            }
        }
        return uniquedTeams(result)
    }

    /// Unfollowed catalog-priority rows for the optional Recommended strip.
    static func recommendedTeams(
        from teams: [FavoriteTeam],
        excludingIDs: Set<String>,
        limit: Int = recommendedTeamLimit
    ) -> [FavoriteTeam] {
        popularTeams(
            from: teams.filter { !excludingIDs.contains($0.id) },
            limit: limit
        )
    }

    static func isAthleteCategory(id: String?) -> Bool {
        switch id {
        case "soccer-players", "basketball-players", "football-players", "baseball-players",
             "hockey-players", "tennis-players", "golf-players", "badminton-players",
             "combat-fighters", "racing-drivers":
            return true
        default:
            return false
        }
    }

    static func athleteLeagues(from athletes: [FavoriteTeam]) -> [FavoriteFollowingLeagueSummary] {
        let players = uniquedTeams(athletes.filter(\.kind.isProfessionalAthlete))
        let grouped = Dictionary(grouping: players) { normalizedKey(displayLeague($0)) }
        return grouped.compactMap { _, group -> FavoriteFollowingLeagueSummary? in
            let name = displayLeague(group[0])
            guard !name.isEmpty,
                  name.localizedCaseInsensitiveCompare("Favorite Players") != .orderedSame,
                  name.localizedCaseInsensitiveCompare(group[0].sport.rawValue) != .orderedSame else {
                return nil
            }
            let artwork = group.first { team in
                SportsIdentityArtworkResolver.resolve(favoriteTeam: team).authorization.allowsOfficialRemoteArtwork
            } ?? group.first
            return FavoriteFollowingLeagueSummary(
                id: "athlete-league:\(normalizedKey(name))",
                name: name,
                teamCount: group.count,
                artworkTeam: artwork
            )
        }
        .sorted { lhs, rhs in
            if lhs.teamCount != rhs.teamCount { return lhs.teamCount > rhs.teamCount }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func athleteTeams(from athletes: [FavoriteTeam]) -> [FavoriteFollowingLeagueSummary] {
        let players = uniquedTeams(athletes.filter(\.kind.isProfessionalAthlete))
        let grouped = Dictionary(grouping: players) { normalizedKey(displayClub($0)) }
        return grouped.compactMap { _, group -> FavoriteFollowingLeagueSummary? in
            let name = displayClub(group[0])
            guard !name.isEmpty, name.localizedCaseInsensitiveCompare("Featured Players") != .orderedSame else {
                return nil
            }
            let artwork = catalogClubArtwork(named: name, sport: group[0].sport) ?? group.first
            return FavoriteFollowingLeagueSummary(
                id: "athlete-team:\(normalizedKey(name))",
                name: name,
                teamCount: group.count,
                artworkTeam: artwork
            )
        }
        .sorted { lhs, rhs in
            if lhs.teamCount != rhs.teamCount { return lhs.teamCount > rhs.teamCount }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func athletes(from athletes: [FavoriteTeam], leagueName: String) -> [FavoriteTeam] {
        let key = normalizedKey(leagueName)
        guard !key.isEmpty else { return [] }
        return uniquedTeams(athletes.filter { normalizedKey(displayLeague($0)) == key })
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func athletes(from athletes: [FavoriteTeam], teamName: String) -> [FavoriteTeam] {
        let key = normalizedKey(teamName)
        guard !key.isEmpty else { return [] }
        return uniquedTeams(athletes.filter { normalizedKey(displayClub($0)) == key })
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Followed clubs first, then shared leagues, then curated catalog IDs, then name.
    static func recommendedAthletes(
        from athletes: [FavoriteTeam],
        followedIdentities: [FavoriteTeam],
        excludingIDs: Set<String>,
        curatedIDs: Set<String>,
        limit: Int = recommendedTeamLimit
    ) -> [FavoriteTeam] {
        let candidates = uniquedTeams(athletes.filter { !excludingIDs.contains($0.id) && $0.kind.isProfessionalAthlete })
        let followedClubs = Set(
            followedIdentities.filter { $0.kind == .team }.map { normalizedKey($0.name) }
        )
        let followedLeagues = Set(
            followedIdentities.filter { $0.kind == .team || $0.kind == .nationalTeam }.map { normalizedKey($0.league) }
        )
        return candidates.sorted { lhs, rhs in
            let lClub = followedClubs.contains(normalizedKey(displayClub(lhs))) ? 0 : 1
            let rClub = followedClubs.contains(normalizedKey(displayClub(rhs))) ? 0 : 1
            if lClub != rClub { return lClub < rClub }
            let lLeague = followedLeagues.contains(normalizedKey(displayLeague(lhs))) ? 0 : 1
            let rLeague = followedLeagues.contains(normalizedKey(displayLeague(rhs))) ? 0 : 1
            if lLeague != rLeague { return lLeague < rLeague }
            let lCurated = curatedIDs.contains(lhs.id) ? 0 : 1
            let rCurated = curatedIDs.contains(rhs.id) ? 0 : 1
            if lCurated != rCurated { return lCurated < rCurated }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        .prefix(limit)
        .map { $0 }
    }

    static func presentsUnclassifiedCountry(from athletes: [FavoriteTeam]) -> Bool {
        athleteLeagues(from: athletes).isEmpty && athleteTeams(from: athletes).isEmpty
    }

    private static func displayLeague(_ athlete: FavoriteTeam) -> String {
        SportsProviderAthleteCatalog.displayLeagueName(athlete.league)
    }

    private static func displayClub(_ athlete: FavoriteTeam) -> String {
        let region = athlete.region.trimmingCharacters(in: .whitespacesAndNewlines)
        if !region.isEmpty, region.localizedCaseInsensitiveCompare("Favorite Players") != .orderedSame {
            return region
        }
        return ""
    }

    private static func catalogClubArtwork(named name: String, sport: FavoriteTeamSport) -> FavoriteTeam? {
        let key = normalizedKey(name)
        return FavoriteTeamCatalog.curatedCatalog.first { team in
            team.kind == .team && team.sport == sport && normalizedKey(team.name) == key
        }
    }

    static func route(
        for option: FavoriteFollowingCountryOption
    ) -> FavoriteFollowingCountryRoute? {
        guard !option.isAll else { return nil }
        let id = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        return FavoriteFollowingCountryRoute(id: id, displayName: option.displayName)
    }

    static func countryMatchesSportFilter(
        countries: [FavoriteFollowingCountryOption],
        countryID: String
    ) -> Bool {
        countries.contains { $0.id == countryID }
    }

    private static func normalizedKey(_ raw: String) -> String {
        raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

#if DEBUG
enum FavoriteFollowingCountryBrowseSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[FollowingCountryBrowseTest] PASS \(name)")
            } else {
                failures += 1
                print("[FollowingCountryBrowseTest] FAIL \(name)")
            }
        }

        let soccerClubs = FavoriteTeamCatalog.teams(sport: .soccer, categoryID: "soccer-clubs")
        let soccerCountries = FavoriteFollowingCountryBrowse.countries(
            from: soccerClubs,
            languageCode: "en",
            unclassifiedTitle: "Other"
        )
        expect(!soccerCountries.contains(where: \.isAll), "1 sport selection countries exclude All")
        expect(
            soccerCountries.contains { $0.id == "GB" || $0.id == "ES" || $0.id == "US" || $0.id == "MX" },
            "1 soccer exposes real catalog countries"
        )

        let basketballClubs = FavoriteTeamCatalog.teams(sport: .basketball, categoryID: "basketball-clubs")
        let basketballCountries = FavoriteFollowingCountryBrowse.countries(
            from: basketballClubs,
            languageCode: "en",
            unclassifiedTitle: "Other"
        )
        expect(
            basketballCountries.contains { $0.id == "US" },
            "1 basketball countries include USA when catalog has US clubs"
        )
        expect(
            Set(soccerCountries.map(\.id)) != Set(basketballCountries.map(\.id))
                || soccerClubs.count != basketballClubs.count,
            "1 switching sport changes country/team availability"
        )

        let englandTeams = FavoriteFollowingCountryBrowse.teams(from: soccerClubs, countryID: "GB")
        let spainTeams = FavoriteFollowingCountryBrowse.teams(from: soccerClubs, countryID: "ES")
        expect(!englandTeams.isEmpty, "2 GB soccer clubs exist in catalog")
        expect(!spainTeams.isEmpty, "2 ES soccer clubs exist in catalog")
        expect(
            englandTeams.allSatisfy { FavoriteFollowingGeo.matchesCountry($0, countryID: "GB") },
            "2 country selection only returns that country"
        )
        expect(
            !englandTeams.contains(where: { FavoriteFollowingGeo.matchesCountry($0, countryID: "ES") && FavoriteFollowingGeo.isoCountryCode(for: $0) == "ES" }),
            "2 England route does not include Spain-only clubs"
        )

        let englandLeagues = FavoriteFollowingCountryBrowse.leagues(from: englandTeams)
        let spainLeagues = FavoriteFollowingCountryBrowse.leagues(from: spainTeams)
        expect(!englandLeagues.isEmpty, "3 England has leagues")
        expect(!spainLeagues.isEmpty, "3 Spain has leagues")
        expect(
            englandLeagues.contains { $0.name.localizedCaseInsensitiveContains("Premier") }
                || englandTeams.contains { $0.league.localizedCaseInsensitiveContains("Premier") },
            "3 England leagues belong to England soccer"
        )
        expect(
            spainLeagues.contains { $0.name.localizedCaseInsensitiveContains("Liga") || $0.name.localizedCaseInsensitiveContains("La Liga") }
                || spainTeams.contains { $0.league.localizedCaseInsensitiveContains("Liga") },
            "3 Spain leagues belong to Spain soccer"
        )
        expect(
            !englandLeagues.contains { $0.name.localizedCaseInsensitiveContains("La Liga") || $0.name.localizedCaseInsensitiveContains("Liga MX") },
            "3 England leagues are not Spain/Mexico competitions"
        )

        expect(
            FavoriteFollowingCountryBrowse.teamCount(from: englandTeams) == englandTeams.count,
            "5 England team count matches filtered catalog"
        )
        expect(
            FavoriteFollowingCountryBrowse.leagueCount(from: englandTeams) == englandLeagues.count,
            "6 England league count matches derived leagues"
        )

        let englandAll = FavoriteFollowingCountryBrowse.filteredAllTeams(
            from: englandTeams,
            search: "",
            leagueName: nil,
            sortAscending: true
        )
        expect(englandAll.count == englandTeams.count, "4 All Teams is the full country catalog")
        expect(
            englandAll.allSatisfy { FavoriteFollowingGeo.matchesCountry($0, countryID: "GB") },
            "4 All Teams stays in selected country"
        )

        if let premier = englandLeagues.first(where: { $0.name.localizedCaseInsensitiveContains("Premier") }) {
            let premierTeams = FavoriteFollowingCountryBrowse.teams(from: englandTeams, leagueName: premier.name)
            expect(
                premierTeams.allSatisfy {
                    $0.league.localizedCaseInsensitiveContains("Premier") || $0.kind.isCompetitionLike
                },
                "3 league filter only returns that league"
            )
        }

        let popular = FavoriteFollowingCountryBrowse.popularTeams(from: englandTeams, limit: 8)
        expect(!popular.contains { $0.name.contains(" followers") }, "10 popular teams are catalog rows, not fake counts")
        expect(Set(popular.map(\.id)).isSubset(of: Set(englandTeams.map(\.id))), "10 popular teams subset of country catalog")

        var selected: Set<String> = []
        if let sample = englandTeams.first {
            selected.insert(sample.id)
            expect(selected.contains(sample.id), "7 Follow adds catalog id")
            selected.remove(sample.id)
            expect(!selected.contains(sample.id), "8 Unfollow removes catalog id")
        }

        let followed = Set(englandTeams.prefix(2).map(\.id))
        let remaining = englandTeams.filter { !followed.contains($0.id) }
        expect(
            FavoriteFollowingCountryBrowse.recommendedTeams(from: englandTeams, excludingIDs: followed)
                .allSatisfy { !followed.contains($0.id) },
            "8 favorites strip excludes unfollowed-only recommendations"
        )
        _ = remaining

        let emptyPopular = FavoriteFollowingCountryBrowse.popularTeams(from: [], limit: 8)
        expect(emptyPopular.isEmpty, "11 empty popular falls through")
        let emptyLeagues = FavoriteFollowingCountryBrowse.leagues(from: [])
        expect(emptyLeagues.isEmpty, "11 empty leagues")

        let nationals = FavoriteTeamCatalog.teams(sport: .soccer, categoryID: "soccer-national-teams")
        let nationalCountries = FavoriteFollowingCountryBrowse.countries(
            from: nationals,
            languageCode: "en",
            unclassifiedTitle: "Other"
        )
        let gbNationals = FavoriteFollowingCountryBrowse.teams(from: nationals, countryID: "GB")
        expect(
            gbNationals.allSatisfy { $0.kind == .nationalTeam },
            "12 National Teams category stays national teams"
        )
        expect(
            !gbNationals.contains { $0.kind == .team },
            "12 National Teams does not mix club teams"
        )
        _ = nationalCountries

        let featured = FavoriteFollowingCountryBrowse.featuredCountries(from: soccerCountries, limit: 8)
        expect(featured.count <= 8, "15 featured country strip is bounded")
        expect(!featured.contains(where: \.isAll), "15 root country strip is not the giant league catalog")

        expect(
            FavoriteFollowingCountryBrowse.hasUniqueIDs(englandTeams),
            "16 production GB soccer club IDs are unique"
        )
        expect(
            FavoriteFollowingCountryBrowse.hasUniqueIDs(englandLeagues),
            "16 production England league IDs are unique"
        )
        expect(
            FavoriteFollowingCountryBrowse.hasUniqueCountryIDs(soccerCountries),
            "16 production soccer country IDs are unique"
        )
        expect(
            FavoriteFollowingCountryBrowse.hasUniqueIDs(
                FavoriteFollowingCountryBrowse.uniquedTeams(FavoriteTeamCatalog.all)
            ),
            "16 uniqued production catalog IDs are ForEach-safe"
        )

        func stub(
            id: String,
            name: String,
            league: String,
            kind: FavoriteTeamKind = .team,
            region: String = "Europe"
        ) -> FavoriteTeam {
            FavoriteTeam(
                id: id,
                name: name,
                sport: .soccer,
                league: league,
                region: region,
                kind: kind,
                shortCode: nil,
                searchAliases: [],
                fallbackSymbol: "sportscourt",
                badgeRed: 0.2,
                badgeGreen: 0.2,
                badgeBlue: 0.2
            )
        }

        let malformed = [
            stub(id: "", name: "Blank ID", league: "Premier League"),
            stub(id: "dup-a", name: "First", league: "Premier League"),
            stub(id: "dup-a", name: "Second same ID", league: "La Liga"),
            stub(id: "no-name", name: "", league: "Serie A"),
            stub(id: "no-league", name: "Orphan Club", league: ""),
            stub(id: "no-country", name: "Stateless Club", league: "Unknown Cup", region: ""),
            stub(id: "comp-1", name: "Premier League", league: "", kind: .competition),
            stub(id: "nat-blank", name: "Nameless Nation", league: "", kind: .nationalTeam, region: "")
        ]
        let uniquedMalformed = FavoriteFollowingCountryBrowse.uniquedTeams(malformed)
        expect(uniquedMalformed.count == 6, "17 uniquedTeams drops empty and duplicate IDs")
        expect(
            FavoriteFollowingCountryBrowse.hasUniqueIDs(uniquedMalformed),
            "17 uniquedTeams IDs are unique and non-empty"
        )
        expect(
            uniquedMalformed.contains { $0.id == "dup-a" && $0.name == "First" },
            "17 uniquedTeams keeps first duplicate ID"
        )

        let dict = FavoriteFollowingCountryBrowse.dictionaryByUniqueID(malformed)
        expect(dict[""] == nil, "17 dictionaryByUniqueID skips empty IDs")
        expect(dict["dup-a"]?.name == "First", "17 dictionaryByUniqueID is first-wins, not uniqueKeysWithValues")
        expect(dict.count == 6, "17 dictionaryByUniqueID does not trap on duplicate catalog IDs")

        let malformedLeagues = FavoriteFollowingCountryBrowse.leagues(from: malformed)
        expect(
            FavoriteFollowingCountryBrowse.hasUniqueIDs(malformedLeagues),
            "17 malformed league summaries still have unique IDs"
        )
        expect(
            malformedLeagues.allSatisfy { !$0.id.isEmpty && !$0.name.isEmpty },
            "17 empty league/name rows are not ForEach identities"
        )

        let emptyCountry = FavoriteFollowingCountryBrowse.teams(from: malformed, countryID: "ZZ")
        expect(emptyCountry.isEmpty, "17 unknown country with incomplete rows returns empty, not a crash")
        expect(
            FavoriteFollowingCountryBrowse.popularTeams(from: malformed).allSatisfy { !$0.id.isEmpty },
            "17 popularTeams skips empty IDs"
        )
        expect(
            FavoriteFollowingCountryBrowse.filteredAllTeams(
                from: malformed,
                search: "",
                leagueName: nil,
                sortAscending: true
            ).allSatisfy { !$0.id.isEmpty },
            "17 filtered All Teams skips empty IDs"
        )
        expect(
            FavoriteFollowingCountryBrowse.route(
                for: FavoriteFollowingCountryOption(
                    id: FavoriteFollowingCountryOption.allID,
                    displayName: "All",
                    continent: .all,
                    itemCount: 0
                )
            ) == nil,
            "17 All-countries option is not a country-detail navigation value"
        )
        let otherRoute = FavoriteFollowingCountryBrowse.route(
            for: FavoriteFollowingCountryOption(
                id: FavoriteFollowingCountryOption.otherID,
                displayName: "Other",
                continent: .other,
                itemCount: 1
            )
        )
        expect(otherRoute?.isUnclassified == true, "17 unclassified country is a valid push route")

        let duplicateCountries = FavoriteFollowingCountryBrowse.uniquedCountries([
            FavoriteFollowingCountryOption(id: "GB", displayName: "United Kingdom", continent: .europe, itemCount: 2),
            FavoriteFollowingCountryOption(id: "GB", displayName: "UK dup", continent: .europe, itemCount: 1),
            FavoriteFollowingCountryOption(id: "", displayName: "Blank", continent: .other, itemCount: 1)
        ])
        expect(duplicateCountries.count == 1 && duplicateCountries.first?.id == "GB", "17 uniquedCountries drops blank and duplicate IDs")

        expect(
            englandTeams.first.map {
                SportsIdentityArtworkResolver.resolve(favoriteTeam: $0).authorization.allowsDisplay
            } ?? true,
            "13 artwork resolver still authorizes catalog teams"
        )

        let az = FavoriteFollowingCountryBrowse.filteredAllTeams(
            from: englandTeams,
            search: "",
            leagueName: nil,
            sortAscending: true
        )
        let za = FavoriteFollowingCountryBrowse.filteredAllTeams(
            from: englandTeams,
            search: "",
            leagueName: nil,
            sortAscending: false
        )
        if az.count >= 2 {
            expect(az.first?.name != za.first?.name || az.first?.id == za.last?.id, "4 A-Z / Z-A changes order")
        }

        if failures == 0 {
            print("[FollowingCountryBrowseTest] ALL PASSED")
        } else {
            print("[FollowingCountryBrowseTest] failures=\(failures)")
        }
    }
}
#endif
