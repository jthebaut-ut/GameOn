import SwiftUI

// MARK: - Models

nonisolated enum FavoriteTeamSport: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case soccer = "Soccer"
    case basketball = "Basketball"
    case football = "Football"
    case tennis = "Tennis"
    case badminton = "Badminton"
    case baseball = "Baseball"
    case hockey = "Hockey"
    case golf = "Golf"
    case combat = "Combat Sports"
    case racing = "Racing"
    case dance = "Dance"
    case ncaa = "NCAA"
    case cricket = "Cricket"
    case rugby = "Rugby"
    case olympics = "Olympics"

    var id: String { rawValue }

    var chipTitle: String {
        switch self {
        case .racing: return "Racing"
        case .combat: return "Combat"
        case .ncaa: return "NCAA"
        case .olympics: return "Olympics"
        default: return rawValue
        }
    }

    var catalogSymbol: String {
        switch self {
        case .soccer: return "soccerball"
        case .basketball: return "basketball.fill"
        case .football: return "football.fill"
        case .tennis: return "tennisball.fill"
        case .badminton: return "sportscourt.fill"
        case .baseball: return "baseball.fill"
        case .hockey: return "hockey.puck.fill"
        case .golf: return "figure.golf"
        case .combat: return "figure.boxing"
        case .racing: return "flag.checkered.2.crossed.fill"
        case .dance: return "figure.dance"
        case .ncaa: return "building.columns.fill"
        case .cricket: return "sportscourt.fill"
        case .rugby: return "sportscourt.fill"
        case .olympics: return "medal.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .soccer: return Color(red: 0.2, green: 0.72, blue: 0.42)
        case .basketball: return Color(red: 0.95, green: 0.55, blue: 0.12)
        case .football: return Color(red: 0.55, green: 0.38, blue: 0.22)
        case .tennis: return Color(red: 0.62, green: 0.82, blue: 0.18)
        case .badminton: return Color(red: 0.52, green: 0.72, blue: 0.18)
        case .baseball: return Color(red: 0.78, green: 0.18, blue: 0.22)
        case .hockey: return Color(red: 0.18, green: 0.72, blue: 0.92)
        case .golf: return Color(red: 0.18, green: 0.62, blue: 0.32)
        case .combat: return Color(red: 0.62, green: 0.18, blue: 0.18)
        case .racing: return Color(red: 0.88, green: 0.12, blue: 0.16)
        case .dance: return Color(red: 0.72, green: 0.28, blue: 0.78)
        case .ncaa: return Color(red: 0.52, green: 0.14, blue: 0.22)
        case .cricket: return Color(red: 0.10, green: 0.68, blue: 0.54)
        case .rugby: return Color(red: 0.48, green: 0.18, blue: 0.13)
        case .olympics: return Color(red: 0.12, green: 0.42, blue: 0.72)
        }
    }

    var discoverSportToken: String {
        switch self {
        case .basketball: return "NBA"
        case .football: return "NFL"
        case .hockey: return "NHL"
        case .combat: return "UFC"
        case .racing: return "Formula 1"
        case .badminton: return "badminton"
        case .dance: return "Break Dance"
        case .cricket: return "Cricket"
        case .rugby: return "Rugby"
        case .olympics: return "Olympics"
        default: return chipTitle
        }
    }
}

nonisolated private extension FavoriteTeamSport {
    init?(teamPickerSport: TeamPickerSport) {
        switch teamPickerSport {
        case .soccer:
            self = .soccer
        case .basketball:
            self = .basketball
        case .baseball:
            self = .baseball
        case .hockey:
            self = .hockey
        case .football:
            self = .football
        case .other:
            return nil
        }
    }
}

func sportIcon(for sportName: String) -> String {
    let normalized = sportName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.contains("soccer") || normalized.contains("mls") || normalized.contains("premier") {
        return "⚽️"
    }
    if normalized.contains("basketball") || normalized.contains("nba") {
        return "🏀"
    }
    if normalized.contains("football") || normalized.contains("nfl") {
        return "🏈"
    }
    if normalized.contains("baseball") || normalized.contains("mlb") {
        return "⚾️"
    }
    if normalized.contains("hockey") || normalized.contains("nhl") {
        return "🏒"
    }
    if normalized.contains("tennis") {
        return "🎾"
    }
    if normalized.contains("badminton") || normalized.contains("shuttlecock") {
        return "🏸"
    }
    if normalized.contains("golf") {
        return "⛳️"
    }
    if normalized.contains("combat") || normalized.contains("mma") || normalized.contains("ufc") || normalized.contains("boxing") {
        return "🥊"
    }
    if normalized.contains("racing") || normalized.contains("formula") || normalized.contains("f1") {
        return "🏎️"
    }
    if normalized.contains("ballet") {
        return "🩰"
    }
    if normalized.contains("dance") || normalized.contains("breakdance") || normalized.contains("breaking") {
        return "💃"
    }
    if normalized.contains("volleyball") {
        return "🏐"
    }
    if normalized.contains("cricket") {
        return "🏏"
    }
    if normalized.contains("rugby") {
        return "🏉"
    }
    return "🏟️"
}

func sportAccentColor(for sportName: String) -> Color {
    let normalized = sportName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.contains("soccer") || normalized.contains("mls") || normalized.contains("premier") {
        return Color(red: 0.18, green: 0.74, blue: 0.38)
    }
    if normalized.contains("basketball") || normalized.contains("nba") {
        return Color(red: 0.96, green: 0.48, blue: 0.12)
    }
    if normalized.contains("football") || normalized.contains("nfl") {
        return Color(red: 0.68, green: 0.46, blue: 0.20)
    }
    if normalized.contains("baseball") || normalized.contains("mlb") {
        return Color(red: 0.82, green: 0.16, blue: 0.22)
    }
    if normalized.contains("hockey") || normalized.contains("nhl") {
        return Color(red: 0.20, green: 0.78, blue: 0.96)
    }
    if normalized.contains("golf") {
        return Color(red: 0.05, green: 0.62, blue: 0.35)
    }
    if normalized.contains("tennis") {
        return Color(red: 0.72, green: 0.90, blue: 0.14)
    }
    if normalized.contains("badminton") || normalized.contains("shuttlecock") {
        return Color(red: 0.52, green: 0.72, blue: 0.18)
    }
    if normalized.contains("combat") || normalized.contains("mma") || normalized.contains("ufc") || normalized.contains("boxing") {
        return Color(red: 0.76, green: 0.12, blue: 0.14)
    }
    if normalized.contains("racing") || normalized.contains("formula") || normalized.contains("f1") {
        return Color(red: 0.92, green: 0.10, blue: 0.14)
    }
    if normalized.contains("ballet") {
        return Color(red: 0.86, green: 0.42, blue: 0.72)
    }
    if normalized.contains("dance") || normalized.contains("breakdance") || normalized.contains("breaking") {
        return Color(red: 0.72, green: 0.28, blue: 0.78)
    }
    if normalized.contains("volleyball") {
        return Color(red: 0.94, green: 0.34, blue: 0.28)
    }
    if normalized.contains("cricket") {
        return Color(red: 0.10, green: 0.68, blue: 0.54)
    }
    if normalized.contains("rugby") {
        return Color(red: 0.48, green: 0.18, blue: 0.13)
    }
    return Color(red: 0.12, green: 0.64, blue: 0.72)
}

nonisolated enum FavoriteTeamKind: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case team = "team"
    case nationalTeam = "national_team"
    case player = "player"
    case tournament = "tournament"
    case league = "league"
    case competition = "competition"
    case driver = "driver"
    case fighter = "fighter"
    case interest = "interest"

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .team: return "Team"
        case .nationalTeam: return "National Team"
        case .player: return "Featured Athlete"
        case .tournament: return "Tournament"
        case .league: return "League"
        case .competition: return "Competition"
        case .driver: return "Driver"
        case .fighter: return "Fighter"
        case .interest: return "Interest"
        }
    }

    var isCompetitionLike: Bool {
        switch self {
        case .tournament, .league, .competition: return true
        default: return false
        }
    }

    /// Catalog player / driver / fighter — not a FanGeo user and not a club/national team.
    var isProfessionalAthlete: Bool {
        switch self {
        case .player, .driver, .fighter: return true
        default: return false
        }
    }
}

nonisolated struct FavoriteTeamCategory: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
}

/// Local catalog entry. Professional artwork is resolved at display time via ``SportsIdentityArtworkResolver`` (TheSportsDB URLs when cached). Logos are never bundled into Assets.
nonisolated struct FavoriteTeam: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let sport: FavoriteTeamSport
    let league: String
    let region: String
    let kind: FavoriteTeamKind
    let shortCode: String?
    let searchAliases: [String]
    /// SF Symbol when initials are not used.
    let fallbackSymbol: String
    let badgeRed: Double
    let badgeGreen: Double
    let badgeBlue: Double

    var initials: String {
        if let shortCode, !shortCode.isEmpty {
            return shortCode
        }
        let parts = name.split(separator: " ").filter { !$0.isEmpty }
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    var badgeColor: Color {
        Color(red: badgeRed, green: badgeGreen, blue: badgeBlue)
    }

    var identityStyle: FanGeoTeamIdentityStyle {
        FanGeoTeamIdentityStyle.forSport(sport)
    }

    /// Explicit CURRENT team catalog IDs used for game discovery (club / national).
    /// Empty for ordinary teams and for athletes without a mapped relationship.
    /// Resolved from ``FavoritePlayerTeamRelationships`` — never stored on user favorites.
    var associatedTeamIDs: [String] {
        FavoritePlayerTeamRelationships.associatedTeamIDs(forFavoriteID: id)
    }

    /// True when this favorite expands into team identities for Live/Going matching.
    var expandsToAssociatedTeamsForGameMatching: Bool {
        switch kind {
        case .player, .driver, .fighter:
            return !associatedTeamIDs.isEmpty
        default:
            return false
        }
    }
}

/// Authoritative player/driver → CURRENT club + national-team relationships for game matching.
/// Update this table when a transfer or roster change occurs; user favorite IDs stay unchanged.
nonisolated enum FavoritePlayerTeamRelationships {
    /// How a catalog `.player` participates in Live/Going game discovery.
    enum ResolutionKind: String, Sendable {
        case teamSport
        case individual
        case retired
        case unmapped
    }

    struct TeamAliasSeed: Sendable {
        let id: String
        let name: String
        let shortCode: String?
        let aliases: [String]
    }

    static func associatedTeamIDs(forFavoriteID id: String) -> [String] {
        if let mapped = table[id], !mapped.isEmpty { return mapped }
        return SportsProviderAthleteCatalog.associatedCatalogTeamIDs(
            forPlayerID: id,
            curated: FavoriteTeamCatalog.curatedCatalog
        )
    }

    /// Nonisolated alias seeds for associated teams (mirrors catalog entries).
    /// Lets game discovery expand player favorites without MainActor catalog lookup.
    static func associatedTeamAliasSeeds(forFavoriteID id: String) -> [TeamAliasSeed] {
        associatedTeamIDs(forFavoriteID: id).compactMap { teamAliasSeedsByID[$0] }
    }

    static func isRetiredPlayer(favoriteID id: String) -> Bool {
        retiredPlayerIDs.contains(id)
    }

    static func isTeamSportPlayerSport(_ sport: FavoriteTeamSport) -> Bool {
        switch sport {
        case .soccer, .basketball, .football, .baseball, .hockey:
            return true
        default:
            return false
        }
    }

    static func isIndividualPlayerSport(_ sport: FavoriteTeamSport) -> Bool {
        switch sport {
        case .tennis, .golf, .badminton, .combat:
            return true
        default:
            return false
        }
    }

    /// Classification for audit / resolver branching (`.player` entries).
    static func resolutionKind(for player: FavoriteTeam) -> ResolutionKind {
        guard player.kind == .player else { return .unmapped }
        if isRetiredPlayer(favoriteID: player.id) { return .retired }
        if isTeamSportPlayerSport(player.sport) {
            return associatedTeamIDs(forFavoriteID: player.id).isEmpty ? .unmapped : .teamSport
        }
        if isIndividualPlayerSport(player.sport) {
            return .individual
        }
        return associatedTeamIDs(forFavoriteID: player.id).isEmpty ? .unmapped : .teamSport
    }

    /// True when this favorite must not contribute match identities (retired / unmapped team-sport).
    static func suppressesGameDiscovery(for favorite: FavoriteTeam) -> Bool {
        guard favorite.kind == .player else { return false }
        switch resolutionKind(for: favorite) {
        case .retired, .unmapped:
            return true
        case .teamSport, .individual:
            return false
        }
    }

#if DEBUG
    /// Test seam: temporarily override a relationship (restored when `perform` returns).
    static func withOverride(
        favoriteID: String,
        teamIDs: [String],
        perform: () -> Void
    ) {
        let previous = debugOverrides[favoriteID]
        debugOverrides[favoriteID] = teamIDs
        defer {
            if let previous {
                debugOverrides[favoriteID] = previous
            } else {
                debugOverrides.removeValue(forKey: favoriteID)
            }
        }
        perform()
    }

    private static var debugOverrides: [String: [String]] = [:]

    /// Every catalog `.player` id (for completeness self-tests).
    static var allCatalogPlayerIDs: [String] {
        [
            "golf-scottie-scheffler",
            "golf-rory-mcilroy",
            "golf-tiger-woods",
            "golf-nelly-korda",
            "golf-lydia-ko",
            "tennis-carlos-alcaraz",
            "tennis-novak-djokovic",
            "tennis-jannik-sinner",
            "tennis-iga-swiatek",
            "tennis-aryna-sabalenka",
            "tennis-coco-gauff",
            "tennis-naomi-osaka",
            "tennis-rafael-nadal",
            "tennis-serena-williams",
            "badminton-viktor-axelsen",
            "badminton-an-se-young",
            "badminton-pv-sindhu",
            "badminton-carolina-marin",
            "badminton-tai-tzu-ying",
            "badminton-lee-zii-jia",
            "player-lionel-messi",
            "player-cristiano-ronaldo",
            "player-kylian-mbappe",
            "player-lebron-james",
            "player-stephen-curry",
            "player-caitlin-clark",
            "player-patrick-mahomes",
            "player-shohei-ohtani"
        ]
    }
#endif

    private static var table: [String: [String]] {
#if DEBUG
        if !debugOverrides.isEmpty {
            return baseTable.merging(debugOverrides) { _, new in new }
        }
#endif
        return baseTable
    }

    /// Explicitly retired / inactive players — keep as favorites, never map to former clubs,
    /// and do not invent upcoming games from historical affiliation.
    private static let retiredPlayerIDs: Set<String> = [
        "tennis-serena-williams",
        "tennis-rafael-nadal"
    ]

    /// Current club + national team only — no former clubs.
    private static let baseTable: [String: [String]] = [
        // Soccer
        "player-kylian-mbappe": ["soccer-real-madrid", "soccer-france"],
        "player-lionel-messi": ["soccer-inter-miami", "soccer-argentina"],
        "player-cristiano-ronaldo": ["soccer-al-nassr", "soccer-portugal"],
        // Basketball
        "player-lebron-james": ["nba-lakers"],
        "player-stephen-curry": ["nba-warriors"],
        "player-caitlin-clark": ["wnba-fever"],
        // American football
        "player-patrick-mahomes": ["nfl-chiefs"],
        // Baseball
        "player-shohei-ohtani": ["mlb-dodgers"]
        // Individual-sport athletes (tennis/golf/badminton) intentionally omitted —
        // active players match Live home/away by their own name aliases.
        // Retired players are listed in ``retiredPlayerIDs`` (no self / team matching).
    ]

    /// Keep in sync with ``FavoriteTeamCatalog`` entries referenced by ``baseTable``.
    private static let teamAliasSeedsByID: [String: TeamAliasSeed] = [
        "soccer-real-madrid": .init(
            id: "soccer-real-madrid",
            name: "Real Madrid",
            shortCode: "RMA",
            aliases: ["Real Madrid CF"]
        ),
        "soccer-france": .init(
            id: "soccer-france",
            name: "France",
            shortCode: "FRA",
            aliases: ["France National Team", "French National Team", "Les Bleus", "French"]
        ),
        "soccer-inter-miami": .init(
            id: "soccer-inter-miami",
            name: "Inter Miami",
            shortCode: "MIA",
            aliases: ["Inter Miami CF", "Club Internacional de Fútbol Miami"]
        ),
        "soccer-argentina": .init(
            id: "soccer-argentina",
            name: "Argentina",
            shortCode: "ARG",
            aliases: ["Argentina National Team", "Albiceleste", "La Albiceleste"]
        ),
        "soccer-al-nassr": .init(
            id: "soccer-al-nassr",
            name: "Al Nassr",
            shortCode: "NAS",
            aliases: ["Al-Nassr", "Al Nassr FC"]
        ),
        "soccer-portugal": .init(
            id: "soccer-portugal",
            name: "Portugal",
            shortCode: "POR",
            aliases: ["Portugal National Team", "A Selecao", "A Seleção"]
        ),
        "soccer-psg": .init(
            id: "soccer-psg",
            name: "Paris Saint-Germain",
            shortCode: "PSG",
            aliases: ["PSG", "Paris SG", "Paris Saint Germain", "Paris Saint-Germain FC"]
        ),
        "nba-lakers": .init(id: "nba-lakers", name: "Los Angeles Lakers", shortCode: nil, aliases: []),
        "nba-warriors": .init(id: "nba-warriors", name: "Golden State Warriors", shortCode: nil, aliases: []),
        "wnba-fever": .init(
            id: "wnba-fever",
            name: "Indiana Fever",
            shortCode: "IND",
            aliases: ["Fever"]
        ),
        "nfl-chiefs": .init(id: "nfl-chiefs", name: "Kansas City Chiefs", shortCode: nil, aliases: []),
        "mlb-dodgers": .init(id: "mlb-dodgers", name: "Los Angeles Dodgers", shortCode: nil, aliases: [])
    ]
}

// MARK: - Catalog

nonisolated enum FavoriteTeamCatalog {
    /// Canonical merged catalog: curated local + global expansion + business picker entities.
    /// Dedupes by sport|kind|normalized name while preserving every unique persisted ID.
    private static let localCatalog: [FavoriteTeam] =
        soccer + basketball + football + baseball + hockey + golf + racing + tennis + badminton
        + combat + dance + ncaa + favoritePlayers + favoriteTournaments + expandedGlobalEntities
    private static let businessGameManagementCatalog = businessGameManagementFavorites(excluding: localCatalog)

    /// Curated bundled catalog (no roster overlay). Tests that audit seed IDs should use this.
    static let curatedCatalog: [FavoriteTeam] = localCatalog + businessGameManagementCatalog

    /// Single access layer for Following / favorites. Screens must not merge picker arrays independently.
    /// Includes curated locals + ``expandedGlobalEntities`` + business picker extras + roster athletes.
    static var all: [FavoriteTeam] {
        SportsProviderAthleteCatalog.merged(with: curatedCatalog)
    }

    /// Canonical expanded Following catalog alias — same collection as ``all``.
    /// Prefer this name in new call sites to make the worldwide source explicit.
    static var allEntities: [FavoriteTeam] { all }

    /// Sports that currently have at least one followable entity (empty sports are hidden).
    static var selectorSports: [FavoriteTeamSport] {
        let preferredOrder: [FavoriteTeamSport] = [
            .soccer, .basketball, .football, .baseball, .hockey, .tennis, .golf, .cricket, .rugby,
            .racing, .combat, .badminton, .olympics, .dance
        ]
        return preferredOrder.filter { !categories(for: $0).isEmpty }
    }

    static var defaultSport: FavoriteTeamSport {
        selectorSports.first ?? .soccer
    }

    static func defaultCategoryID(for sport: FavoriteTeamSport) -> String? {
        categories(for: sport).first?.id
    }

    static func team(id: String) -> FavoriteTeam? {
        FavoriteFollowingSearch.team(id: id) ?? all.first { $0.id == id }
    }

    /// Soccer national side first when a country has multiple sport entries.
    static func nationalTeam(matchingCountryName name: String) -> FavoriteTeam? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let matches = all.filter { team in
            guard team.kind == .nationalTeam else { return false }
            if team.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame {
                return true
            }
            return team.searchAliases.contains {
                $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
            }
        }
        return matches.first(where: { $0.sport == .soccer }) ?? matches.first
    }

    static func teams(
        sport: FavoriteTeamSport?,
        search: String,
        region: String? = nil,
        kind: FavoriteTeamKind? = nil
    ) -> [FavoriteTeam] {
        let q = normalizeSearch(search)
        return all.filter { team in
            if let sport, team.sport != sport { return false }
            if let region, !filterMatches(team, filter: region) { return false }
            if let kind, team.kind != kind { return false }
            if q.isEmpty { return true }
            return matchesSearch(team, query: q)
        }
    }

    static func teams(
        sport: FavoriteTeamSport,
        categoryID: String?,
        region: String? = nil,
        search: String = ""
    ) -> [FavoriteTeam] {
        let q = normalizeSearch(search)
        return all.filter { team in
            guard sportMatches(team, selectedSport: sport) else { return false }
            if let categoryID, !categoryMatches(team, categoryID: categoryID) { return false }
            if let region, !filterMatches(team, filter: region) { return false }
            if q.isEmpty { return true }
            return matchesSearch(team, query: q)
        }
    }

    static func searchTeams(_ search: String, prioritizingSelectedIDs selectedIDs: Set<String> = []) -> [FavoriteTeam] {
        FavoriteFollowingSearch.rankedResults(query: search, prioritizingSelectedIDs: selectedIDs)
    }

    static func regions(for sport: FavoriteTeamSport?) -> [String] {
        let teams = all.filter { team in
            if let sport {
                return team.sport == sport
            }
            return true
        }
        return Array(Set(teams.map(\.region))).sorted()
    }

    static func regions(for sport: FavoriteTeamSport, categoryID: String?) -> [String] {
        let teams = teams(sport: sport, categoryID: categoryID)
        let ordered = [
            "Europe",
            "North America",
            "South America",
            "Africa",
            "Asia",
            "Oceania",
            "MLS",
            "Liga MX",
            "Premier League",
            "La Liga",
            "Serie A",
            "Bundesliga",
            "Ligue 1",
            "Primeira Liga",
            "Eredivisie",
            "Scottish Premiership",
            "NBA",
            "WNBA",
            "College Basketball",
            "MLB",
            "NHL",
            "NFL",
            "College Football"
        ]
        let available = Set(teams.flatMap { [$0.region, $0.league] }.filter { !$0.isEmpty })
        var result = ordered.filter { available.contains($0) }
        let remaining = available
            .filter { !result.contains($0) && $0 != "Favorite Players" && $0 != "Leagues & Tournaments" }
            .sorted()
        result.append(contentsOf: remaining)
        return result
    }

    static func categories(for sport: FavoriteTeamSport) -> [FavoriteTeamCategory] {
        categoryDefinitions(for: sport).filter { category in
            all.contains { team in
                sportMatches(team, selectedSport: sport) && categoryMatches(team, categoryID: category.id)
            }
        }
    }

    static func sectionGroups(for teams: [FavoriteTeam]) -> [(title: String, teams: [FavoriteTeam])] {
        let grouped = Dictionary(grouping: teams) { team in
            sectionTitle(for: team)
        }
        return grouped
            .map { title, teams in
                (title: title, teams: teams.sorted { $0.name < $1.name })
            }
            .sorted { lhs, rhs in
                let order = sectionOrder
                let left = order.firstIndex(of: lhs.title) ?? Int.max
                let right = order.firstIndex(of: rhs.title) ?? Int.max
                if left != right { return left < right }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    private static func sportMatches(_ team: FavoriteTeam, selectedSport: FavoriteTeamSport) -> Bool {
        if selectedSport == .basketball, team.sport == .ncaa { return true }
        return team.sport == selectedSport
    }

    private static func categoryDefinitions(for sport: FavoriteTeamSport) -> [FavoriteTeamCategory] {
        switch sport {
        case .soccer:
            return [
                FavoriteTeamCategory(id: "soccer-clubs", title: "Teams"),
                FavoriteTeamCategory(id: "soccer-national-teams", title: "National Teams"),
                FavoriteTeamCategory(id: "soccer-players", title: "Featured Athletes"),
                FavoriteTeamCategory(id: "soccer-tournaments", title: "Competitions & Tournaments")
            ]
        case .basketball:
            return [
                FavoriteTeamCategory(id: "basketball-clubs", title: "Teams"),
                FavoriteTeamCategory(id: "basketball-national-teams", title: "National Teams"),
                FavoriteTeamCategory(id: "basketball-players", title: "Featured Athletes"),
                FavoriteTeamCategory(id: "basketball-tournaments", title: "Competitions & Tournaments")
            ]
        case .football:
            return [
                FavoriteTeamCategory(id: "football-clubs", title: "Teams"),
                FavoriteTeamCategory(id: "football-players", title: "Featured Athletes"),
                FavoriteTeamCategory(id: "football-tournaments", title: "Competitions & Tournaments")
            ]
        case .tennis:
            return [
                FavoriteTeamCategory(id: "tennis-players", title: "Featured Athletes"),
                FavoriteTeamCategory(id: "tennis-tournaments", title: "Competitions & Tournaments")
            ]
        case .badminton:
            return [
                FavoriteTeamCategory(id: "badminton-players", title: "Featured Athletes"),
                FavoriteTeamCategory(id: "badminton-tournaments", title: "Competitions & Tournaments")
            ]
        case .baseball:
            return [
                FavoriteTeamCategory(id: "baseball-clubs", title: "Teams"),
                FavoriteTeamCategory(id: "baseball-national-teams", title: "National Teams"),
                FavoriteTeamCategory(id: "baseball-players", title: "Featured Athletes"),
                FavoriteTeamCategory(id: "baseball-tournaments", title: "Competitions & Tournaments")
            ]
        case .hockey:
            return [
                FavoriteTeamCategory(id: "hockey-clubs", title: "Teams"),
                FavoriteTeamCategory(id: "hockey-national-teams", title: "National Teams"),
                FavoriteTeamCategory(id: "hockey-players", title: "Featured Athletes"),
                FavoriteTeamCategory(id: "hockey-tournaments", title: "Competitions & Tournaments")
            ]
        case .golf:
            return [
                FavoriteTeamCategory(id: "golf-players", title: "Featured Athletes"),
                FavoriteTeamCategory(id: "golf-tournaments", title: "Competitions & Tournaments")
            ]
        case .combat:
            return [
                FavoriteTeamCategory(id: "combat-fighters", title: "Fighters"),
                FavoriteTeamCategory(id: "combat-promotions", title: "Competitions & Tournaments")
            ]
        case .racing:
            return [
                FavoriteTeamCategory(id: "racing-teams", title: "Teams"),
                FavoriteTeamCategory(id: "racing-drivers", title: "Drivers"),
                FavoriteTeamCategory(id: "racing-series", title: "Competitions & Tournaments")
            ]
        case .dance:
            return [
                FavoriteTeamCategory(id: "dance-urban", title: "Dance / Urban Sports"),
                FavoriteTeamCategory(id: "dance-performing", title: "Dance / Performing Arts")
            ]
        case .ncaa:
            return [
                FavoriteTeamCategory(id: "basketball-ncaa", title: "NCAA")
            ]
        case .cricket:
            return [
                FavoriteTeamCategory(id: "cricket-tournaments", title: "Competitions & Tournaments")
            ]
        case .rugby:
            return [
                FavoriteTeamCategory(id: "rugby-tournaments", title: "Competitions & Tournaments")
            ]
        case .olympics:
            return [
                FavoriteTeamCategory(id: "olympics-tournaments", title: "Competitions & Tournaments")
            ]
        }
    }

    private static func categoryMatches(_ team: FavoriteTeam, categoryID: String) -> Bool {
        switch categoryID {
        case "soccer-clubs":
            return team.sport == .soccer && team.kind == .team
        case "soccer-national-teams":
            return team.sport == .soccer && team.kind == .nationalTeam
        case "soccer-players":
            return team.sport == .soccer && team.kind == .player
        case "soccer-tournaments":
            return team.sport == .soccer && team.kind.isCompetitionLike
        case "basketball-nba":
            return team.sport == .basketball && (team.league == "NBA" || team.id == "league-nba")
        case "basketball-ncaa":
            return team.sport == .ncaa
        case "basketball-clubs":
            return team.kind == .team
                && (
                    team.sport == .basketball
                    || (team.sport == .ncaa && team.league.localizedCaseInsensitiveContains("Basketball"))
                )
        case "basketball-national-teams":
            return team.sport == .basketball && team.kind == .nationalTeam
        case "basketball-players":
            return team.sport == .basketball && team.kind == .player
        case "basketball-tournaments":
            return (team.sport == .basketball || team.sport == .ncaa) && team.kind.isCompetitionLike
        case "football-nfl":
            return team.sport == .football && team.kind == .team
        case "football-clubs":
            return team.sport == .football && team.kind == .team
        case "football-players":
            return team.sport == .football && team.kind == .player
        case "football-tournaments":
            return (team.sport == .football || (team.sport == .ncaa && team.league.localizedCaseInsensitiveContains("Football")))
                && team.kind.isCompetitionLike
        case "tennis-players":
            return team.sport == .tennis && team.kind == .player
        case "tennis-tournaments":
            return team.sport == .tennis && team.kind.isCompetitionLike
        case "badminton-players":
            return team.sport == .badminton && team.kind == .player
        case "badminton-tournaments":
            return team.sport == .badminton && team.kind.isCompetitionLike
        case "baseball-mlb":
            return team.sport == .baseball && team.kind == .team
        case "baseball-clubs":
            return team.sport == .baseball && team.kind == .team
        case "baseball-national-teams":
            return team.sport == .baseball && team.kind == .nationalTeam
        case "baseball-players":
            return team.sport == .baseball && team.kind == .player
        case "baseball-tournaments":
            return team.sport == .baseball && team.kind.isCompetitionLike
        case "hockey-teams":
            return team.sport == .hockey
        case "hockey-clubs":
            return team.sport == .hockey && team.kind == .team
        case "hockey-national-teams":
            return team.sport == .hockey && team.kind == .nationalTeam
        case "hockey-players":
            return team.sport == .hockey && team.kind == .player
        case "hockey-tournaments":
            return team.sport == .hockey && team.kind.isCompetitionLike
        case "golf-players":
            return team.sport == .golf && team.kind == .player
        case "golf-tournaments":
            return team.sport == .golf && team.kind.isCompetitionLike
        case "combat-fighters":
            return team.sport == .combat && team.kind == .fighter
        case "combat-promotions":
            return team.sport == .combat && team.kind.isCompetitionLike
        case "racing-teams":
            return team.sport == .racing && team.kind == .team
        case "racing-drivers":
            return team.sport == .racing && team.kind == .driver
        case "racing-series":
            return team.sport == .racing && team.kind.isCompetitionLike
        case "cricket-tournaments":
            return team.sport == .cricket && team.kind.isCompetitionLike
        case "rugby-tournaments":
            return team.sport == .rugby && team.kind.isCompetitionLike
        case "olympics-tournaments":
            return team.sport == .olympics && team.kind.isCompetitionLike
        case "dance-urban":
            return team.sport == .dance && team.region == "Dance / Urban Sports"
        case "dance-performing":
            return team.sport == .dance && team.region == "Dance / Performing Arts"
        default:
            return false
        }
    }

    private static func matchesSearch(_ team: FavoriteTeam, query q: String) -> Bool {
        let haystack = [
            team.name,
            team.league,
            team.region,
            team.kind.rawValue,
            team.kind.displayTitle,
            team.shortCode ?? "",
            team.sport.rawValue,
            team.sport.chipTitle
        ] + team.searchAliases + categorySearchTerms(for: team)
        return haystack.contains { normalizeSearch($0).contains(q) }
    }

    private static func categorySearchTerms(for team: FavoriteTeam) -> [String] {
        var terms: [String] = []
        for sport in selectorSports where sportMatches(team, selectedSport: sport) {
            for category in categoryDefinitions(for: sport) where categoryMatches(team, categoryID: category.id) {
                terms.append(category.title)
            }
        }
        return terms
    }

    private static func filterMatches(_ team: FavoriteTeam, filter: String) -> Bool {
        normalizeSearch(team.region) == normalizeSearch(filter)
            || normalizeSearch(team.league) == normalizeSearch(filter)
    }

    private static func sectionTitle(for team: FavoriteTeam) -> String {
        switch team.kind {
        case .team, .nationalTeam:
            return team.league
        case .tournament, .league, .competition:
            return team.region == "Leagues & Tournaments" ? "Competitions & Tournaments" : team.region
        case .player, .driver, .fighter, .interest:
            return team.region
        }
    }

    private static let sectionOrder = [
        "MLS",
        "Liga MX",
        "CONCACAF national teams",
        "Premier League",
        "La Liga",
        "Serie A",
        "Bundesliga",
        "Ligue 1",
        "Primeira Liga",
        "Eredivisie",
        "Scottish Premiership",
        "UEFA national teams",
        "Brazil Serie A",
        "Argentina Primera Division",
        "CONMEBOL national teams",
        "CAF national teams",
        "J1 League",
        "Saudi Pro League",
        "K League",
        "Asian national teams",
        "OFC national teams",
        "NBA",
        "WNBA",
        "College Basketball",
        "MLB",
        "NHL",
        "NFL",
        "College Football",
        "Badminton",
        "Dance / Urban Sports",
        "Dance / Performing Arts",
        "Favorite Players",
        "Featured Athletes",
        "Women's National Teams",
        "Drivers",
        "Fighters",
        "Competitions & Tournaments",
        "Tournaments"
    ]

    nonisolated private static func normalizeSearch(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    nonisolated private static func duplicateKey(for team: FavoriteTeam) -> String {
        [
            team.sport.rawValue,
            team.kind.rawValue,
            team.name
        ]
            .map(normalizeSearch)
            .joined(separator: "|")
    }

    private static func businessGameManagementFavorites(excluding existing: [FavoriteTeam]) -> [FavoriteTeam] {
        var seen = Set(existing.map(duplicateKey(for:)))
        return SportsTeamPickerData.favoriteCatalogOptions.compactMap { option in
            guard let sport = FavoriteTeamSport(teamPickerSport: option.sport) else { return nil }
            let kind: FavoriteTeamKind = option.mode == .countries ? .nationalTeam : .team
            let candidate = FavoriteTeam(
                id: option.id,
                name: option.displayName,
                sport: sport,
                league: option.leagueGroup,
                region: option.region,
                kind: kind,
                shortCode: option.shortName,
                searchAliases: businessFavoriteAliases(for: option),
                fallbackSymbol: businessFavoriteSymbol(for: option, sport: sport),
                badgeRed: businessFavoriteColor(for: sport).r,
                badgeGreen: businessFavoriteColor(for: sport).g,
                badgeBlue: businessFavoriteColor(for: sport).b
            )
            guard seen.insert(duplicateKey(for: candidate)).inserted else { return nil }
            return candidate
        }
    }

    private static func businessFavoriteAliases(for option: TeamPickerOption) -> [String] {
        var aliases = [option.shortName, option.themeHint, option.emoji].compactMap { $0 }
        aliases.append(option.leagueGroup)
        aliases.append(option.region)
        if let slug = option.id.split(separator: "-").last.map(String.init),
           slug.count >= 4 {
            aliases.append(slug)
        }
        if option.mode == .countries {
            aliases.append("\(option.displayName) national team")
        }
        return aliases
    }

    private static func businessFavoriteSymbol(for option: TeamPickerOption, sport: FavoriteTeamSport) -> String {
        if option.mode == .countries { return "flag.fill" }
        return sport.catalogSymbol
    }

    private static func businessFavoriteColor(for sport: FavoriteTeamSport) -> (r: Double, g: Double, b: Double) {
        switch sport {
        case .soccer: return (0.18, 0.62, 0.34)
        case .basketball: return (0.92, 0.42, 0.12)
        case .football: return (0.56, 0.36, 0.18)
        case .baseball: return (0.74, 0.16, 0.22)
        case .hockey: return (0.16, 0.62, 0.82)
        case .tennis: return (0.62, 0.82, 0.18)
        case .badminton: return (0.52, 0.72, 0.18)
        case .golf: return (0.16, 0.56, 0.28)
        case .combat: return (0.62, 0.16, 0.16)
        case .racing: return (0.84, 0.12, 0.16)
        case .dance: return (0.72, 0.28, 0.78)
        case .ncaa: return (0.48, 0.16, 0.52)
        case .cricket: return (0.10, 0.68, 0.54)
        case .rugby: return (0.48, 0.18, 0.13)
        case .olympics: return (0.12, 0.42, 0.72)
        }
    }

    // MARK: Soccer (54)

    private static let soccer: [FavoriteTeam] = [
        team("soccer-juventus", "Juventus", .soccer, "Serie A", "soccerball", 0.18, 0.18, 0.18, region: "Europe", kind: .team, shortCode: "JUV", aliases: ["Juventus FC"]),
        team("soccer-milan", "AC Milan", .soccer, "Serie A", "soccerball", 0.78, 0.12, 0.14, region: "Europe", kind: .team, shortCode: "ACM", aliases: ["Milan"]),
        team("soccer-inter", "Inter Milan", .soccer, "Serie A", "soccerball", 0.12, 0.42, 0.72, region: "Europe", kind: .team, shortCode: "INT", aliases: ["Inter"]),
        team("soccer-napoli", "Napoli", .soccer, "Serie A", "soccerball", 0.12, 0.42, 0.82, region: "Europe", kind: .team, shortCode: "NAP"),
        team("soccer-roma", "Roma", .soccer, "Serie A", "soccerball", 0.72, 0.18, 0.18, region: "Europe", kind: .team, shortCode: "ROM"),
        team("soccer-real-madrid", "Real Madrid", .soccer, "La Liga", "soccerball", 0.95, 0.82, 0.22, region: "Europe", kind: .team, shortCode: "RMA", aliases: ["Real Madrid CF"]),
        team("soccer-barcelona", "Barcelona", .soccer, "La Liga", "soccerball", 0.72, 0.12, 0.28, region: "Europe", kind: .team, shortCode: "BAR", aliases: ["FC Barcelona", "Barça", "Barca"]),
        team("soccer-atletico-madrid", "Atlético Madrid", .soccer, "La Liga", "soccerball", 0.78, 0.12, 0.18, region: "Europe", kind: .team, shortCode: "ATM", aliases: ["Atletico Madrid"]),
        team("soccer-man-utd", "Manchester United", .soccer, "Premier League", "soccerball", 0.78, 0.12, 0.16, region: "Europe", kind: .team, shortCode: "MUN", aliases: ["Man United", "Man Utd", "Man U"]),
        team("soccer-man-city", "Manchester City", .soccer, "Premier League", "soccerball", 0.32, 0.66, 0.88, region: "Europe", kind: .team, shortCode: "MCI", aliases: ["Man City"]),
        team("soccer-liverpool", "Liverpool", .soccer, "Premier League", "soccerball", 0.78, 0.14, 0.18, region: "Europe", kind: .team, shortCode: "LIV"),
        team("soccer-chelsea", "Chelsea", .soccer, "Premier League", "soccerball", 0.12, 0.35, 0.72, region: "Europe", kind: .team, shortCode: "CHE"),
        team("soccer-arsenal", "Arsenal", .soccer, "Premier League", "soccerball", 0.78, 0.12, 0.14, region: "Europe", kind: .team, shortCode: "ARS", aliases: ["Arsenal FC"]),
        team("soccer-tottenham", "Tottenham", .soccer, "Premier League", "soccerball", 0.12, 0.22, 0.52, region: "Europe", kind: .team, shortCode: "TOT", aliases: ["Spurs"]),
        team("soccer-bayern", "Bayern Munich", .soccer, "Bundesliga", "soccerball", 0.78, 0.12, 0.22, region: "Europe", kind: .team, shortCode: "BAY", aliases: ["Bayern München", "FC Bayern Munich", "FC Bayern"]),
        team("soccer-dortmund", "Borussia Dortmund", .soccer, "Bundesliga", "soccerball", 0.92, 0.72, 0.12, region: "Europe", kind: .team, shortCode: "BVB", aliases: ["Dortmund"]),
        team("soccer-psg", "Paris Saint-Germain", .soccer, "Ligue 1", "soccerball", 0.12, 0.22, 0.48, region: "Europe", kind: .team, shortCode: "PSG", aliases: ["PSG", "Paris SG", "Paris Saint Germain", "Paris Saint-Germain FC"]),
        team("soccer-marseille", "Marseille", .soccer, "Ligue 1", "soccerball", 0.12, 0.52, 0.76, region: "Europe", kind: .team, shortCode: "OM"),
        team("soccer-benfica", "Benfica", .soccer, "Primeira Liga", "soccerball", 0.78, 0.12, 0.16, region: "Europe", kind: .team, shortCode: "BEN"),
        team("soccer-porto", "Porto", .soccer, "Primeira Liga", "soccerball", 0.12, 0.32, 0.72, region: "Europe", kind: .team, shortCode: "POR"),
        team("soccer-ajax", "Ajax", .soccer, "Eredivisie", "soccerball", 0.78, 0.12, 0.16, region: "Europe", kind: .team, shortCode: "AJX"),
        team("soccer-lafc", "LAFC", .soccer, "MLS", "soccerball", 0.16, 0.16, 0.16, region: "North America", kind: .team, shortCode: "LAFC", aliases: ["Los Angeles FC"]),
        team("soccer-galaxy", "LA Galaxy", .soccer, "MLS", "soccerball", 0.12, 0.32, 0.62, region: "North America", kind: .team, shortCode: "LAG"),
        team("soccer-inter-miami", "Inter Miami", .soccer, "MLS", "soccerball", 0.92, 0.42, 0.62, region: "North America", kind: .team, shortCode: "MIA", aliases: ["Inter Miami CF", "Club Internacional de Fútbol Miami"]),
        team("soccer-nycfc", "New York City FC", .soccer, "MLS", "soccerball", 0.12, 0.48, 0.82, region: "North America", kind: .team, shortCode: "NYC", aliases: ["NYCFC"]),
        team("soccer-atlanta", "Atlanta United", .soccer, "MLS", "soccerball", 0.78, 0.18, 0.22, region: "North America", kind: .team, shortCode: "ATL"),
        team("soccer-seattle", "Seattle Sounders", .soccer, "MLS", "soccerball", 0.12, 0.52, 0.28, region: "North America", kind: .team, shortCode: "SEA"),
        team("soccer-toronto", "Toronto FC", .soccer, "MLS", "soccerball", 0.78, 0.12, 0.16, region: "North America", kind: .team, shortCode: "TOR"),
        team("soccer-cf-montreal", "CF Montréal", .soccer, "MLS", "soccerball", 0.12, 0.22, 0.52, region: "North America", kind: .team, shortCode: "MTL", aliases: ["CF Montreal", "Montreal"]),
        team("soccer-club-america", "Club América", .soccer, "Liga MX", "soccerball", 0.92, 0.78, 0.16, region: "North America", kind: .team, shortCode: "AME", aliases: ["Club America", "America"]),
        team("soccer-chivas", "Chivas", .soccer, "Liga MX", "soccerball", 0.78, 0.12, 0.18, region: "North America", kind: .team, shortCode: "GDL", aliases: ["Guadalajara"]),
        team("soccer-tigres", "Tigres", .soccer, "Liga MX", "soccerball", 0.92, 0.72, 0.12, region: "North America", kind: .team, shortCode: "TIG"),
        team("soccer-monterrey", "Monterrey", .soccer, "Liga MX", "soccerball", 0.12, 0.32, 0.62, region: "North America", kind: .team, shortCode: "MTY"),
        team("soccer-pumas", "Pumas", .soccer, "Liga MX", "soccerball", 0.12, 0.22, 0.52, region: "North America", kind: .team, shortCode: "PUM"),
        team("soccer-france", "France", .soccer, "National Team", "soccerball", 0.12, 0.28, 0.68, region: "National Teams", kind: .nationalTeam, shortCode: "FRA", aliases: ["France National Team", "French National Team", "Les Bleus", "French"]),
        team("soccer-usa", "United States", .soccer, "National Team", "soccerball", 0.12, 0.32, 0.72, region: "National Teams", kind: .nationalTeam, shortCode: "USA", aliases: ["USA", "USMNT", "United States of America", "United States National Team", "US Men's National Team"]),
        team("soccer-mexico", "Mexico", .soccer, "National Team", "soccerball", 0.12, 0.52, 0.28, region: "National Teams", kind: .nationalTeam, shortCode: "MEX", aliases: ["Mexico National Team", "Mexican National Team", "El Tri"]),
        team("soccer-canada", "Canada", .soccer, "National Team", "soccerball", 0.78, 0.12, 0.16, region: "National Teams", kind: .nationalTeam, shortCode: "CAN"),
        team("soccer-argentina", "Argentina", .soccer, "National Team", "soccerball", 0.32, 0.64, 0.88, region: "National Teams", kind: .nationalTeam, shortCode: "ARG", aliases: ["Argentina National Team", "Albiceleste", "La Albiceleste"]),
        team("soccer-brazil", "Brazil", .soccer, "National Team", "soccerball", 0.12, 0.52, 0.28, region: "National Teams", kind: .nationalTeam, shortCode: "BRA", aliases: ["Brasil", "Selecao", "Seleção", "Brazil National Team"]),
        team("soccer-england", "England", .soccer, "National Team", "soccerball", 0.72, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "ENG", aliases: ["England National Team", "Three Lions", "The Three Lions"]),
        team("soccer-spain", "Spain", .soccer, "National Team", "soccerball", 0.78, 0.18, 0.12, region: "National Teams", kind: .nationalTeam, shortCode: "ESP", aliases: ["España", "Espana", "Spain National Team", "La Roja"]),
        team("soccer-germany", "Germany", .soccer, "National Team", "soccerball", 0.18, 0.18, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "GER", aliases: ["Deutschland", "Germany National Team", "Die Mannschaft"]),
        team("soccer-italy", "Italy", .soccer, "National Team", "soccerball", 0.12, 0.32, 0.72, region: "National Teams", kind: .nationalTeam, shortCode: "ITA"),
        team("soccer-portugal", "Portugal", .soccer, "National Team", "soccerball", 0.72, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "POR", aliases: ["Portugal National Team", "A Selecao", "A Seleção"]),
        team("soccer-netherlands", "Netherlands", .soccer, "National Team", "soccerball", 0.92, 0.42, 0.12, region: "National Teams", kind: .nationalTeam, shortCode: "NED", aliases: ["Holland"]),
        team("soccer-japan", "Japan", .soccer, "National Team", "soccerball", 0.78, 0.12, 0.16, region: "National Teams", kind: .nationalTeam, shortCode: "JPN"),
        team("soccer-south-korea", "South Korea", .soccer, "National Team", "soccerball", 0.12, 0.28, 0.68, region: "National Teams", kind: .nationalTeam, shortCode: "KOR", aliases: ["Korea"]),
        team("soccer-australia", "Australia", .soccer, "National Team", "soccerball", 0.12, 0.42, 0.22, region: "National Teams", kind: .nationalTeam, shortCode: "AUS"),
        team("soccer-morocco", "Morocco", .soccer, "National Team", "soccerball", 0.72, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "MAR")
    ]

    // MARK: Basketball (12)

    private static let basketball: [FavoriteTeam] = [
        team("nba-lakers", "Los Angeles Lakers", .basketball, "NBA", "basketball.fill", 0.42, 0.18, 0.62, region: "North America"),
        team("nba-celtics", "Boston Celtics", .basketball, "NBA", "basketball.fill", 0.12, 0.48, 0.28, region: "North America"),
        team("nba-warriors", "Golden State Warriors", .basketball, "NBA", "basketball.fill", 0.22, 0.42, 0.72, region: "North America"),
        team("nba-bulls", "Chicago Bulls", .basketball, "NBA", "basketball.fill", 0.78, 0.12, 0.18, region: "North America", aliases: ["Bulls"]),
        team("nba-heat", "Miami Heat", .basketball, "NBA", "basketball.fill", 0.78, 0.32, 0.18, region: "North America"),
        team("nba-knicks", "New York Knicks", .basketball, "NBA", "basketball.fill", 0.22, 0.42, 0.72, region: "North America"),
        team("nba-mavericks", "Dallas Mavericks", .basketball, "NBA", "basketball.fill", 0.12, 0.42, 0.62, region: "North America"),
        team("nba-nuggets", "Denver Nuggets", .basketball, "NBA", "basketball.fill", 0.22, 0.32, 0.52, region: "North America"),
        team("nba-suns", "Phoenix Suns", .basketball, "NBA", "basketball.fill", 0.92, 0.42, 0.12, region: "North America"),
        team("nba-bucks", "Milwaukee Bucks", .basketball, "NBA", "basketball.fill", 0.12, 0.48, 0.32, region: "North America"),
        team("nba-nets", "Brooklyn Nets", .basketball, "NBA", "basketball.fill", 0.12, 0.12, 0.12, region: "North America"),
        team("nba-spurs", "San Antonio Spurs", .basketball, "NBA", "basketball.fill", 0.32, 0.32, 0.38, region: "North America")
    ]

    // MARK: Football (12)

    private static let football: [FavoriteTeam] = [
        team("nfl-chiefs", "Kansas City Chiefs", .football, "NFL", "football.fill", 0.78, 0.18, 0.22, region: "North America"),
        team("nfl-eagles", "Philadelphia Eagles", .football, "NFL", "football.fill", 0.12, 0.42, 0.32, region: "North America"),
        team("nfl-cowboys", "Dallas Cowboys", .football, "NFL", "football.fill", 0.12, 0.22, 0.48, region: "North America"),
        team("nfl-49ers", "San Francisco 49ers", .football, "NFL", "football.fill", 0.78, 0.22, 0.18, region: "North America"),
        team("nfl-bills", "Buffalo Bills", .football, "NFL", "football.fill", 0.12, 0.32, 0.62, region: "North America"),
        team("nfl-ravens", "Baltimore Ravens", .football, "NFL", "football.fill", 0.18, 0.12, 0.42, region: "North America"),
        team("nfl-dolphins", "Miami Dolphins", .football, "NFL", "football.fill", 0.12, 0.52, 0.62, region: "North America"),
        team("nfl-packers", "Green Bay Packers", .football, "NFL", "football.fill", 0.12, 0.42, 0.22, region: "North America"),
        team("nfl-steelers", "Pittsburgh Steelers", .football, "NFL", "football.fill", 0.22, 0.22, 0.22, region: "North America"),
        team("nfl-bengals", "Cincinnati Bengals", .football, "NFL", "football.fill", 0.78, 0.22, 0.12, region: "North America"),
        team("nfl-lions", "Detroit Lions", .football, "NFL", "football.fill", 0.12, 0.42, 0.62, region: "North America"),
        team("nfl-jets", "New York Jets", .football, "NFL", "football.fill", 0.12, 0.32, 0.22, region: "North America")
    ]

    // MARK: Baseball (12)

    private static let baseball: [FavoriteTeam] = [
        team("mlb-yankees", "New York Yankees", .baseball, "MLB", "baseball.fill", 0.12, 0.22, 0.42, region: "North America"),
        team("mlb-red-sox", "Boston Red Sox", .baseball, "MLB", "baseball.fill", 0.78, 0.12, 0.18, region: "North America"),
        team("mlb-dodgers", "Los Angeles Dodgers", .baseball, "MLB", "baseball.fill", 0.12, 0.32, 0.62, region: "North America"),
        team("mlb-cubs", "Chicago Cubs", .baseball, "MLB", "baseball.fill", 0.12, 0.38, 0.72, region: "North America"),
        team("mlb-braves", "Atlanta Braves", .baseball, "MLB", "baseball.fill", 0.78, 0.12, 0.22, region: "North America"),
        team("mlb-astros", "Houston Astros", .baseball, "MLB", "baseball.fill", 0.78, 0.42, 0.18, region: "North America"),
        team("mlb-phillies", "Philadelphia Phillies", .baseball, "MLB", "baseball.fill", 0.78, 0.12, 0.28, region: "North America"),
        team("mlb-mets", "New York Mets", .baseball, "MLB", "baseball.fill", 0.18, 0.42, 0.72, region: "North America"),
        team("mlb-cardinals", "St. Louis Cardinals", .baseball, "MLB", "baseball.fill", 0.78, 0.12, 0.16, region: "North America"),
        team("mlb-giants", "San Francisco Giants", .baseball, "MLB", "baseball.fill", 0.78, 0.32, 0.18, region: "North America"),
        team("mlb-padres", "San Diego Padres", .baseball, "MLB", "baseball.fill", 0.78, 0.52, 0.22, region: "North America"),
        team("mlb-mariners", "Seattle Mariners", .baseball, "MLB", "baseball.fill", 0.12, 0.42, 0.58, region: "North America")
    ]

    // MARK: Hockey (12) — generic city + sport names, color-inspired only

    private static let hockey: [FavoriteTeam] = [
        team("nhl-vegas-hockey", "Vegas Hockey", .hockey, "Pro Hockey", "hockey.puck.fill", 0.78, 0.62, 0.18, region: "North America"),
        team("nhl-dallas-hockey", "Dallas Hockey", .hockey, "Pro Hockey", "hockey.puck.fill", 0.12, 0.42, 0.62, region: "North America"),
        team("nhl-boston-hockey", "Boston Hockey", .hockey, "Pro Hockey", "hockey.puck.fill", 0.78, 0.18, 0.22, region: "North America"),
        team("nhl-detroit-hockey", "Detroit Hockey", .hockey, "Pro Hockey", "hockey.puck.fill", 0.78, 0.12, 0.18, region: "North America"),
        team("nhl-tampa-hockey", "Tampa Hockey", .hockey, "Pro Hockey", "hockey.puck.fill", 0.12, 0.38, 0.72, region: "North America"),
        team("nhl-colorado-hockey", "Colorado Hockey", .hockey, "Pro Hockey", "hockey.puck.fill", 0.52, 0.22, 0.62, region: "North America"),
        team("nhl-chicago-hockey", "Chicago Hockey", .hockey, "Pro Hockey", "hockey.puck.fill", 0.78, 0.18, 0.22, region: "North America"),
        team("nhl-toronto-hockey", "Toronto Hockey", .hockey, "Pro Hockey", "hockey.puck.fill", 0.12, 0.12, 0.12, region: "North America"),
        team("nhl-edmonton-hockey", "Edmonton Hockey", .hockey, "Pro Hockey", "hockey.puck.fill", 0.22, 0.42, 0.72, region: "North America"),
        team("nhl-montreal-hockey", "Montreal Hockey", .hockey, "Pro Hockey", "hockey.puck.fill", 0.78, 0.12, 0.22, region: "North America"),
        team("nhl-pittsburgh-hockey", "Pittsburgh Hockey", .hockey, "Pro Hockey", "hockey.puck.fill", 0.78, 0.52, 0.12, region: "North America"),
        team("nhl-seattle-hockey", "Seattle Hockey", .hockey, "Pro Hockey", "hockey.puck.fill", 0.18, 0.52, 0.58, region: "North America")
    ]

    // MARK: Golf (players and tournaments; text-only identities)

    private static let golf: [FavoriteTeam] = [
        team("golf-scottie-scheffler", "Scottie Scheffler", .golf, "Golf", "figure.golf", 0.18, 0.62, 0.32, region: "Favorite Players", kind: .player, shortCode: "SS", aliases: ["Scheffler"]),
        team("golf-rory-mcilroy", "Rory McIlroy", .golf, "Golf", "figure.golf", 0.12, 0.42, 0.72, region: "Favorite Players", kind: .player, shortCode: "RM", aliases: ["McIlroy"]),
        team("golf-tiger-woods", "Tiger Woods", .golf, "Golf", "figure.golf", 0.18, 0.18, 0.18, region: "Favorite Players", kind: .player, shortCode: "TW", aliases: ["Tiger"]),
        team("golf-nelly-korda", "Nelly Korda", .golf, "Golf", "figure.golf", 0.78, 0.32, 0.52, region: "Favorite Players", kind: .player, shortCode: "NK", aliases: ["Korda"]),
        team("golf-lydia-ko", "Lydia Ko", .golf, "Golf", "figure.golf", 0.42, 0.18, 0.62, region: "Favorite Players", kind: .player, shortCode: "LK", aliases: ["Ko"]),
        team("golf-masters", "The Masters", .golf, "Golf Major", "figure.golf", 0.12, 0.48, 0.28, region: "Tournaments", kind: .tournament, shortCode: "MAS", aliases: ["Masters", "Masters Tournament"]),
        team("golf-us-open", "U.S. Open Golf", .golf, "Golf Major", "figure.golf", 0.12, 0.32, 0.72, region: "Tournaments", kind: .tournament, shortCode: "USO", aliases: ["US Open Golf", "U.S. Open"]),
        team("golf-the-open", "The Open", .golf, "Golf Major", "figure.golf", 0.22, 0.42, 0.32, region: "Tournaments", kind: .tournament, shortCode: "OPEN", aliases: ["British Open", "Open Championship", "The Open Championship"]),
        team("golf-ryder-cup", "Ryder Cup", .golf, "Golf Tournament", "figure.golf", 0.78, 0.18, 0.22, region: "Tournaments", kind: .tournament, shortCode: "RC")
    ]

    // MARK: Racing (12) — country / region inspired, no team trademarks

    private static let racing: [FavoriteTeam] = [
        team("f1-italian-racing", "Italian Racing", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.78, 0.12, 0.16),
        team("f1-british-racing", "British Racing", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.12, 0.22, 0.48),
        team("f1-german-racing", "German Racing", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.22, 0.22, 0.22),
        team("f1-spanish-racing", "Spanish Racing", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.78, 0.22, 0.12),
        team("f1-monaco-racing", "Monaco Racing", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.78, 0.12, 0.18),
        team("f1-japanese-racing", "Japanese Racing", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.78, 0.12, 0.14),
        team("f1-american-racing", "American Racing", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.12, 0.32, 0.62),
        team("f1-french-racing", "French Racing", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.12, 0.38, 0.72),
        team("f1-dutch-racing", "Dutch Racing", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.92, 0.42, 0.12),
        team("f1-austrian-racing", "Austrian Racing", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.78, 0.18, 0.22),
        team("f1-brazilian-racing", "Brazilian Racing", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.12, 0.48, 0.28),
        team("f1-australian-racing", "Australian Racing", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.12, 0.42, 0.22)
    ]

    // MARK: NCAA (12) — collegiate-style names, palette only

    private static let ncaa: [FavoriteTeam] = [
        team("ncaa-utah-cfb", "Utah College Football", .ncaa, "College Football", "building.columns.fill", 0.78, 0.22, 0.12),
        team("ncaa-alabama-cfb", "Alabama College Football", .ncaa, "College Football", "building.columns.fill", 0.78, 0.12, 0.18),
        team("ncaa-ohio-cfb", "Ohio College Football", .ncaa, "College Football", "building.columns.fill", 0.78, 0.12, 0.16),
        team("ncaa-michigan-cfb", "Michigan College Football", .ncaa, "College Football", "building.columns.fill", 0.12, 0.22, 0.62),
        team("ncaa-texas-cfb", "Texas College Football", .ncaa, "College Football", "building.columns.fill", 0.52, 0.14, 0.22),
        team("ncaa-georgia-cfb", "Georgia College Football", .ncaa, "College Football", "building.columns.fill", 0.78, 0.12, 0.18),
        team("ncaa-oregon-cfb", "Oregon College Football", .ncaa, "College Football", "building.columns.fill", 0.12, 0.42, 0.22),
        team("ncaa-la-cbb", "Los Angeles College Basketball", .ncaa, "College Basketball", "building.columns.fill", 0.52, 0.14, 0.62),
        team("ncaa-duke-cbb", "Durham College Basketball", .ncaa, "College Basketball", "building.columns.fill", 0.12, 0.22, 0.48),
        team("ncaa-kansas-cbb", "Kansas College Basketball", .ncaa, "College Basketball", "building.columns.fill", 0.12, 0.32, 0.72),
        team("ncaa-kentucky-cbb", "Kentucky College Basketball", .ncaa, "College Basketball", "building.columns.fill", 0.12, 0.22, 0.48),
        team("ncaa-gonzaga-cbb", "Spokane College Basketball", .ncaa, "College Basketball", "building.columns.fill", 0.78, 0.12, 0.22)
    ]

    // MARK: Tennis (players and tournaments; text-only identities)

    private static let tennis: [FavoriteTeam] = [
        team("tennis-carlos-alcaraz", "Carlos Alcaraz", .tennis, "Tennis", "tennisball.fill", 0.62, 0.82, 0.18, region: "Favorite Players", kind: .player, shortCode: "CA", aliases: ["Alcaraz"]),
        team("tennis-novak-djokovic", "Novak Djokovic", .tennis, "Tennis", "tennisball.fill", 0.22, 0.42, 0.72, region: "Favorite Players", kind: .player, shortCode: "ND", aliases: ["Djokovic"]),
        team("tennis-jannik-sinner", "Jannik Sinner", .tennis, "Tennis", "tennisball.fill", 0.92, 0.42, 0.12, region: "Favorite Players", kind: .player, shortCode: "JS", aliases: ["Sinner"]),
        team("tennis-iga-swiatek", "Iga Swiatek", .tennis, "Tennis", "tennisball.fill", 0.78, 0.18, 0.22, region: "Favorite Players", kind: .player, shortCode: "IS", aliases: ["Swiatek"]),
        team("tennis-aryna-sabalenka", "Aryna Sabalenka", .tennis, "Tennis", "tennisball.fill", 0.52, 0.22, 0.72, region: "Favorite Players", kind: .player, shortCode: "AS", aliases: ["Sabalenka"]),
        team("tennis-coco-gauff", "Coco Gauff", .tennis, "Tennis", "tennisball.fill", 0.12, 0.52, 0.42, region: "Favorite Players", kind: .player, shortCode: "CG", aliases: ["Gauff"]),
        team("tennis-naomi-osaka", "Naomi Osaka", .tennis, "Tennis", "tennisball.fill", 0.78, 0.32, 0.52, region: "Favorite Players", kind: .player, shortCode: "NO", aliases: ["Osaka"]),
        team("tennis-rafael-nadal", "Rafael Nadal", .tennis, "Tennis", "tennisball.fill", 0.78, 0.32, 0.12, region: "Favorite Players", kind: .player, shortCode: "RN", aliases: ["Nadal"]),
        team("tennis-serena-williams", "Serena Williams", .tennis, "Tennis", "tennisball.fill", 0.42, 0.18, 0.62, region: "Favorite Players", kind: .player, shortCode: "SW", aliases: ["Serena"]),
        team("tennis-australian-open", "Australian Open", .tennis, "Tennis Major", "tennisball.fill", 0.12, 0.48, 0.82, region: "Tournaments", kind: .tournament, shortCode: "AO"),
        team("tennis-roland-garros", "Roland Garros", .tennis, "Tennis Major", "tennisball.fill", 0.82, 0.36, 0.14, region: "Tournaments", kind: .tournament, shortCode: "RG", aliases: ["French Open"]),
        team("tennis-wimbledon", "Wimbledon", .tennis, "Tennis Major", "tennisball.fill", 0.24, 0.52, 0.28, region: "Tournaments", kind: .tournament, shortCode: "WIM"),
        team("tennis-us-open", "US Open Tennis", .tennis, "Tennis Major", "tennisball.fill", 0.12, 0.28, 0.68, region: "Tournaments", kind: .tournament, shortCode: "USO", aliases: ["U.S. Open"])
    ]

    // MARK: Badminton (players and tournaments; text-only identities)

    private static let badminton: [FavoriteTeam] = [
        team("badminton-viktor-axelsen", "Viktor Axelsen", .badminton, "Badminton", "sportscourt.fill", 0.52, 0.72, 0.18, region: "Favorite Players", kind: .player, shortCode: "VA", aliases: ["Axelsen"]),
        team("badminton-an-se-young", "An Se-young", .badminton, "Badminton", "sportscourt.fill", 0.18, 0.58, 0.72, region: "Favorite Players", kind: .player, shortCode: "ASY", aliases: ["An Seyoung"]),
        team("badminton-pv-sindhu", "P. V. Sindhu", .badminton, "Badminton", "sportscourt.fill", 0.82, 0.42, 0.18, region: "Favorite Players", kind: .player, shortCode: "PVS", aliases: ["PV Sindhu", "Sindhu"]),
        team("badminton-carolina-marin", "Carolina Marin", .badminton, "Badminton", "sportscourt.fill", 0.76, 0.18, 0.24, region: "Favorite Players", kind: .player, shortCode: "CM", aliases: ["Marin"]),
        team("badminton-tai-tzu-ying", "Tai Tzu-ying", .badminton, "Badminton", "sportscourt.fill", 0.46, 0.26, 0.72, region: "Favorite Players", kind: .player, shortCode: "TTY", aliases: ["Tai Tzuying"]),
        team("badminton-lee-zii-jia", "Lee Zii Jia", .badminton, "Badminton", "sportscourt.fill", 0.18, 0.46, 0.72, region: "Favorite Players", kind: .player, shortCode: "LZJ", aliases: ["Lee Zii Jia"]),
        team("badminton-world-championships", "BWF World Championships", .badminton, "Badminton", "sportscourt.fill", 0.52, 0.72, 0.18, region: "Tournaments", kind: .tournament, shortCode: "BWF", aliases: ["Badminton World Championships"]),
        team("badminton-thomas-cup", "Thomas Cup", .badminton, "Badminton", "sportscourt.fill", 0.24, 0.52, 0.30, region: "Tournaments", kind: .tournament, shortCode: "TC"),
        team("badminton-uber-cup", "Uber Cup", .badminton, "Badminton", "sportscourt.fill", 0.72, 0.32, 0.52, region: "Tournaments", kind: .tournament, shortCode: "UC")
    ]

    // MARK: Combat Sports (fighters; text-only identities)

    private static let combat: [FavoriteTeam] = [
        team("fighter-jon-jones", "Jon Jones", .combat, "Combat Sports", "figure.boxing", 0.28, 0.28, 0.32, region: "Fighters", kind: .fighter, shortCode: "JJ"),
        team("fighter-amanda-nunes", "Amanda Nunes", .combat, "Combat Sports", "figure.boxing", 0.78, 0.42, 0.18, region: "Fighters", kind: .fighter, shortCode: "AN"),
        team("fighter-islam-makhachev", "Islam Makhachev", .combat, "Combat Sports", "figure.boxing", 0.12, 0.42, 0.32, region: "Fighters", kind: .fighter, shortCode: "IM"),
        team("fighter-alex-pereira", "Alex Pereira", .combat, "Combat Sports", "figure.boxing", 0.72, 0.18, 0.18, region: "Fighters", kind: .fighter, shortCode: "AP"),
        team("fighter-katie-taylor", "Katie Taylor", .combat, "Combat Sports", "figure.boxing", 0.12, 0.48, 0.36, region: "Fighters", kind: .fighter, shortCode: "KT"),
        team("fighter-claressa-shields", "Claressa Shields", .combat, "Combat Sports", "figure.boxing", 0.42, 0.18, 0.62, region: "Fighters", kind: .fighter, shortCode: "CS")
    ]

    // MARK: Dance (interests; text-only identities)

    private static let dance: [FavoriteTeam] = [
        team("dance-break-dance", "Break Dance", .dance, "Dance / Urban Sports", "figure.dance", 0.58, 0.28, 0.90, region: "Dance / Urban Sports", kind: .interest, shortCode: "BD", aliases: ["breakdance", "breaking", "break dancing", "urban dance", "dance"]),
        team("dance-ballet", "Ballet", .dance, "Dance / Performing Arts", "figure.dance", 0.86, 0.42, 0.72, region: "Dance / Performing Arts", kind: .interest, shortCode: "BAL", aliases: ["classical ballet", "performing arts", "dance"])
    ]

    // MARK: Favorite Players / Drivers (text-only identities)

    private static let favoritePlayers: [FavoriteTeam] = [
        team("player-lionel-messi", "Lionel Messi", .soccer, "Soccer", "person.fill", 0.32, 0.64, 0.88, region: "Favorite Players", kind: .player, shortCode: "LM", aliases: ["Messi"]),
        team("player-cristiano-ronaldo", "Cristiano Ronaldo", .soccer, "Soccer", "person.fill", 0.72, 0.12, 0.18, region: "Favorite Players", kind: .player, shortCode: "CR", aliases: ["Ronaldo", "CR7"]),
        team("player-kylian-mbappe", "Kylian Mbappe", .soccer, "Soccer", "person.fill", 0.12, 0.28, 0.68, region: "Favorite Players", kind: .player, shortCode: "KM", aliases: ["Mbappe"]),
        team("player-lebron-james", "LeBron James", .basketball, "Basketball", "person.fill", 0.42, 0.18, 0.62, region: "Favorite Players", kind: .player, shortCode: "LJ", aliases: ["LeBron"]),
        team("player-stephen-curry", "Stephen Curry", .basketball, "Basketball", "person.fill", 0.22, 0.42, 0.72, region: "Favorite Players", kind: .player, shortCode: "SC", aliases: ["Steph Curry", "Curry"]),
        team("player-caitlin-clark", "Caitlin Clark", .basketball, "Basketball", "person.fill", 0.78, 0.32, 0.12, region: "Favorite Players", kind: .player, shortCode: "CC", aliases: ["Clark"]),
        team("player-patrick-mahomes", "Patrick Mahomes", .football, "Football", "person.fill", 0.78, 0.18, 0.22, region: "Favorite Players", kind: .player, shortCode: "PM", aliases: ["Mahomes"]),
        team("player-shohei-ohtani", "Shohei Ohtani", .baseball, "Baseball", "person.fill", 0.12, 0.32, 0.62, region: "Favorite Players", kind: .player, shortCode: "SO", aliases: ["Ohtani"]),
        team("driver-max-verstappen", "Max Verstappen", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.12, 0.22, 0.48, region: "Drivers", kind: .driver, shortCode: "MV", aliases: ["Verstappen"]),
        team("driver-lewis-hamilton", "Lewis Hamilton", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.62, 0.22, 0.72, region: "Drivers", kind: .driver, shortCode: "LH", aliases: ["Hamilton"]),
        team("driver-charles-leclerc", "Charles Leclerc", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.78, 0.12, 0.16, region: "Drivers", kind: .driver, shortCode: "CL", aliases: ["Leclerc"]),
        team("driver-lando-norris", "Lando Norris", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.92, 0.42, 0.12, region: "Drivers", kind: .driver, shortCode: "LN", aliases: ["Norris"])
    ]

    // MARK: Leagues / Tournaments (text-only identities)

    private static let favoriteTournaments: [FavoriteTeam] = [
        team("league-nba", "NBA", .basketball, "Basketball League", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .league, shortCode: "NBA", aliases: ["National Basketball Association"]),
        team("league-nfl", "NFL", .football, "Football League", "football.fill", 0.12, 0.32, 0.62, region: "Leagues & Tournaments", kind: .league, shortCode: "NFL", aliases: ["National Football League"]),
        team("league-mlb", "MLB", .baseball, "Baseball League", "baseball.fill", 0.78, 0.12, 0.18, region: "Leagues & Tournaments", kind: .league, shortCode: "MLB", aliases: ["Major League Baseball"]),
        team("league-mls", "MLS", .soccer, "Soccer League", "soccerball", 0.12, 0.48, 0.82, region: "Leagues & Tournaments", kind: .league, shortCode: "MLS", aliases: ["Major League Soccer"]),
        team("league-premier-league", "Premier League", .soccer, "Soccer League", "soccerball", 0.42, 0.18, 0.62, region: "Leagues & Tournaments", kind: .league, shortCode: "PL", aliases: ["EPL", "English Premier League"]),
        team("tournament-world-cup", "FIFA World Cup", .soccer, "Soccer Tournament", "soccerball", 0.12, 0.52, 0.28, region: "Leagues & Tournaments", kind: .competition, shortCode: "FWC", aliases: ["World Cup"]),
        team("tournament-champions-league", "Champions League", .soccer, "Soccer Tournament", "soccerball", 0.12, 0.22, 0.48, region: "Leagues & Tournaments", kind: .competition, shortCode: "UCL", aliases: ["UEFA Champions League", "UCL"]),
        team("league-formula-one", "Formula 1", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.78, 0.12, 0.16, region: "Leagues & Tournaments", kind: .competition, shortCode: "F1", aliases: ["F1", "Formula 1 World Championship", "Formula One"]),
        team("tournament-march-madness", "March Madness", .ncaa, "College Basketball Tournament", "building.columns.fill", 0.12, 0.32, 0.72, region: "Leagues & Tournaments", kind: .competition, shortCode: "MM", aliases: ["NCAA Men's Tournament", "NCAA Tournament", "Big Dance"]),
        team("tournament-college-football-playoff", "College Football Playoff", .ncaa, "College Football Tournament", "building.columns.fill", 0.78, 0.42, 0.18, region: "Leagues & Tournaments", kind: .competition, shortCode: "CFP")
    ]

    private static func team(
        _ id: String,
        _ name: String,
        _ sport: FavoriteTeamSport,
        _ league: String,
        _ symbol: String,
        _ r: Double,
        _ g: Double,
        _ b: Double,
        region: String? = nil,
        kind: FavoriteTeamKind = .team,
        shortCode: String? = nil,
        aliases: [String] = []
    ) -> FavoriteTeam {
        FavoriteTeam(
            id: id,
            name: name,
            sport: sport,
            league: league,
            region: region ?? league,
            kind: kind,
            shortCode: shortCode,
            searchAliases: aliases,
            fallbackSymbol: symbol,
            badgeRed: r,
            badgeGreen: g,
            badgeBlue: b
        )
    }
}

// MARK: - Live tab team matching

nonisolated enum LiveMatchTeamSide: Sendable {
    case home
    case away
}

/// Pure string/alias matching for Live + Going favorite-team cards.
/// Explicitly nonisolated so snapshot index builds can stay off MainActor.
nonisolated enum FavoriteTeamLiveMatcher {
    private static let genericTokens: Set<String> = [
        "club",
        "city",
        "football",
        "basketball",
        "hockey",
        "racing",
        "sport",
        "sports",
        "college",
        "united",
        "real",
        "inter",
        "atletico",
        "athletic",
        "sporting",
        "national",
        "team"
    ]

    /// Normalized aliases for matching live feed home/away names (catalog entries only).
    static func matchAliases(for team: FavoriteTeam) -> [String] {
        var unique: [String] = []
        func add(_ raw: String) {
            let normalized = normalizedSearchText(raw)
            guard !normalized.isEmpty, !unique.contains(normalized) else { return }
            unique.append(normalized)
        }

        add(team.name)
        if let shortCode = team.shortCode {
            add(shortCode)
        }
        for alias in team.searchAliases {
            add(alias)
        }

        return unique.sorted { $0.count > $1.count }
    }

    /// Artwork-only aliases: catalog names plus the last significant token
    /// ("Lakers" from "Los Angeles Lakers") so live payload names match favorites.
    /// Does not expand players to clubs and does not affect game discovery.
    static func artworkMatchAliases(for team: FavoriteTeam) -> [String] {
        var unique = matchAliases(for: team)
        func add(_ raw: String) {
            let normalized = normalizedSearchText(raw)
            guard !normalized.isEmpty, !unique.contains(normalized) else { return }
            unique.append(normalized)
        }
        let parts = team.name.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        if parts.count >= 2 {
            let last = parts[parts.count - 1]
            let token = normalizedSearchText(last)
            if token.count >= 4, !genericTokens.contains(token) {
                add(last)
            }
        }
        return unique.sorted { $0.count > $1.count }
    }

    /// Which side of a live row matches this favorite identity, if any.
    static func matchingSide(for team: FavoriteTeam, match: LiveMatch) -> LiveMatchTeamSide? {
        let aliases = artworkMatchAliases(for: team)
        guard !aliases.isEmpty else { return nil }
        let home = normalizedParticipantName(match.homeTeam)
        let away = normalizedParticipantName(match.awayTeam)
        if aliases.contains(where: { matchesNormalizedAlias($0, inParticipantName: home) }) {
            return .home
        }
        if aliases.contains(where: { matchesNormalizedAlias($0, inParticipantName: away) }) {
            return .away
        }
        return nil
    }

    /// Aliases used for Live/Going game discovery.
    /// Player/driver favorites with explicit relationships expand to associated team aliases only
    /// (never invent clubs; never match on unrelated player-name text in club fixtures).
    static func matchAliasesForGameDiscovery(for favorite: FavoriteTeam) -> [String] {
        if FavoritePlayerTeamRelationships.suppressesGameDiscovery(for: favorite) {
#if DEBUG
            print(
                "[FavoritePlayerTeams] gameDiscoverySuppressed favorite=\(favorite.id) "
                    + "kind=\(FavoritePlayerTeamRelationships.resolutionKind(for: favorite).rawValue)"
            )
#endif
            return []
        }
        guard favorite.expandsToAssociatedTeamsForGameMatching else {
            return matchAliases(for: favorite)
        }
        var unique: [String] = []
        func add(_ raw: String) {
            let normalized = normalizedSearchText(raw)
            guard !normalized.isEmpty, !unique.contains(normalized) else { return }
            unique.append(normalized)
        }
        let seeds = FavoritePlayerTeamRelationships.associatedTeamAliasSeeds(forFavoriteID: favorite.id)
        for seed in seeds {
            add(seed.name)
            if let shortCode = seed.shortCode {
                add(shortCode)
            }
            for alias in seed.aliases {
                add(alias)
            }
        }
#if DEBUG
        if seeds.isEmpty {
            print("[FavoritePlayerTeams] noResolvableTeams favorite=\(favorite.id)")
        }
#endif
        return unique.sorted { $0.count > $1.count }
    }

    static func matchesLiveMatch(_ team: FavoriteTeam, homeTeam: String, awayTeam: String) -> Bool {
        matchesLiveMatch(
            aliases: matchAliasesForGameDiscovery(for: team),
            normalizedHome: normalizedSearchText(homeTeam),
            normalizedAway: normalizedSearchText(awayTeam)
        )
    }

    /// Same semantics as ``matchesLiveMatch(_:homeTeam:awayTeam:)`` using pre-normalized names
    /// (avoids re-folding participant strings inside a Live snapshot scan).
    static func matchesLiveMatch(
        aliases: [String],
        normalizedHome: String,
        normalizedAway: String
    ) -> Bool {
        guard !aliases.isEmpty else { return false }
        return aliases.contains { alias in
            matchesNormalizedAlias(alias, inParticipantName: normalizedHome)
                || matchesNormalizedAlias(alias, inParticipantName: normalizedAway)
        }
    }

    static func matchesVenueEventTitle(_ team: FavoriteTeam, title: String) -> Bool {
        let normalizedTitle = normalizedSearchText(title)
        guard !normalizedTitle.isEmpty else { return false }
        return matchAliasesForGameDiscovery(for: team).contains { alias in
            matchesNormalizedAlias(alias, inParticipantName: normalizedTitle)
        }
    }

    /// Public so snapshot indexes can reuse alias phrase rules without re-normalizing.
    static func matchesNormalizedAlias(_ alias: String, inParticipantName normalizedParticipant: String) -> Bool {
        guard !normalizedParticipant.isEmpty else { return false }

        if alias.count <= 2 { return false }
        if genericTokens.contains(alias) { return false }

        if normalizedParticipant == alias {
            return true
        }

        if alias.contains(" ") {
            return containsPhrase(alias, in: normalizedParticipant)
        }

        if alias.count <= 4 {
            return normalizedParticipant
                .split(separator: " ")
                .map(String.init)
                .contains(alias)
        }

        return containsPhrase(alias, in: normalizedParticipant)
    }

    static func normalizedParticipantName(_ raw: String) -> String {
        normalizedSearchText(raw)
    }

    private static func containsPhrase(_ phrase: String, in text: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        if text == phrase { return true }
        if text.hasPrefix("\(phrase) ") { return true }
        if text.hasSuffix(" \(phrase)") { return true }
        return text.contains(" \(phrase) ")
    }

    private static func normalizedSearchText(_ raw: String) -> String {
        raw
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Resolves favorites (teams + players) into a deduplicated set of matchable team identities
/// for Live/Going game discovery. Attribution prefers a directly favorited club/national team
/// over a player that expands to the same club.
///
/// Called from MainActor Going/Live refresh paths that already own catalog access.
enum FavoriteTeamMatchIdentityResolver {
    struct Identity: Sendable {
        /// Catalog team whose aliases are used against home/away.
        let matchTeam: FavoriteTeam
        /// Original favorite used for Going/Live attribution (player or team).
        let sourceFavorite: FavoriteTeam
    }

    static func resolve(from favorites: [FavoriteTeam]) -> [Identity] {
        guard !favorites.isEmpty else { return [] }

        var matchTeamToSource: [String: FavoriteTeam] = [:]
        var orderedMatchTeams: [FavoriteTeam] = []

        func prefers(_ candidate: FavoriteTeam, over existing: FavoriteTeam) -> Bool {
            let candidateIsDirectTeam = candidate.kind == .team || candidate.kind == .nationalTeam
            let existingIsDirectTeam = existing.kind == .team || existing.kind == .nationalTeam
            if candidateIsDirectTeam && !existingIsDirectTeam { return true }
            return false
        }

        func register(matchTeam: FavoriteTeam, source: FavoriteTeam) {
            if let existing = matchTeamToSource[matchTeam.id] {
                if prefers(source, over: existing) {
                    matchTeamToSource[matchTeam.id] = source
                }
                return
            }
            matchTeamToSource[matchTeam.id] = source
            orderedMatchTeams.append(matchTeam)
        }

        for favorite in favorites {
            if FavoritePlayerTeamRelationships.suppressesGameDiscovery(for: favorite) {
#if DEBUG
                print(
                    "[FavoritePlayerTeams] identitySkipped favorite=\(favorite.id) "
                        + "kind=\(FavoritePlayerTeamRelationships.resolutionKind(for: favorite).rawValue)"
                )
#endif
                continue
            }

            if favorite.expandsToAssociatedTeamsForGameMatching {
                var resolvedAny = false
                for teamID in favorite.associatedTeamIDs {
                    guard let team = FavoriteTeamCatalog.team(id: teamID) else {
#if DEBUG
                        print("[FavoritePlayerTeams] missingAssociatedTeam favorite=\(favorite.id) teamId=\(teamID)")
#endif
                        continue
                    }
                    resolvedAny = true
                    register(matchTeam: team, source: favorite)
                }
#if DEBUG
                if !resolvedAny {
                    print("[FavoritePlayerTeams] unmappedPlayerFavorite favorite=\(favorite.id) — no team games")
                }
#endif
                continue
            }

            // Clubs, national teams, competitions, and active individual-sport athletes (name match).
            register(matchTeam: favorite, source: favorite)
        }

        return orderedMatchTeams.compactMap { matchTeam in
            guard let source = matchTeamToSource[matchTeam.id] else { return nil }
            return Identity(matchTeam: matchTeam, sourceFavorite: source)
        }
    }
}

/// One Live snapshot → O(rows) normalized participant names for favorite-team lookups.
/// Preserves ``FavoriteTeamLiveMatcher`` alias / phrase semantics; callers still apply
/// live-or-soon / country / ranking filters on the returned rows.
nonisolated struct FavoriteTeamLiveSnapshotIndex {
    private let matches: [LiveMatch]
    private let normalizedHome: [String]
    private let normalizedAway: [String]
    let buildMs: Double
    let sourceCount: Int
    let sourceSignature: Int

    static let empty = FavoriteTeamLiveSnapshotIndex(
        matches: [],
        normalizedHome: [],
        normalizedAway: [],
        buildMs: 0,
        sourceCount: 0,
        sourceSignature: LiveMatchHydrationIndex.signature(of: [])
    )

    static func build(from matches: [LiveMatch]) -> FavoriteTeamLiveSnapshotIndex {
        let started = CFAbsoluteTimeGetCurrent()
        var homes: [String] = []
        var aways: [String] = []
        homes.reserveCapacity(matches.count)
        aways.reserveCapacity(matches.count)
        for match in matches {
            homes.append(FavoriteTeamLiveMatcher.normalizedParticipantName(match.homeTeam))
            aways.append(FavoriteTeamLiveMatcher.normalizedParticipantName(match.awayTeam))
        }
        return FavoriteTeamLiveSnapshotIndex(
            matches: matches,
            normalizedHome: homes,
            normalizedAway: aways,
            buildMs: (CFAbsoluteTimeGetCurrent() - started) * 1000,
            sourceCount: matches.count,
            sourceSignature: LiveMatchHydrationIndex.signature(of: matches)
        )
    }

    func isValid(for matches: [LiveMatch]) -> Bool {
        matches.count == sourceCount && LiveMatchHydrationIndex.signature(of: matches) == sourceSignature
    }

    func matchingMatches(for team: FavoriteTeam) -> [LiveMatch] {
        matchingMatches(aliases: FavoriteTeamLiveMatcher.matchAliases(for: team))
    }

    func matchingMatches(aliases: [String]) -> [LiveMatch] {
        guard !aliases.isEmpty, !matches.isEmpty else { return [] }
        var result: [LiveMatch] = []
        result.reserveCapacity(min(8, matches.count))
        for index in matches.indices {
            if FavoriteTeamLiveMatcher.matchesLiveMatch(
                aliases: aliases,
                normalizedHome: normalizedHome[index],
                normalizedAway: normalizedAway[index]
            ) {
                result.append(matches[index])
            }
        }
        return result
    }

    /// First favorite team that matches a row (array order preserved — same as prior `first(where:)`).
    func firstMatchingTeam(in teams: [(team: FavoriteTeam, aliases: [String])], at matchIndex: Int) -> FavoriteTeam? {
        guard matches.indices.contains(matchIndex) else { return nil }
        let home = normalizedHome[matchIndex]
        let away = normalizedAway[matchIndex]
        for entry in teams {
            if FavoriteTeamLiveMatcher.matchesLiveMatch(
                aliases: entry.aliases,
                normalizedHome: home,
                normalizedAway: away
            ) {
                return entry.team
            }
        }
        return nil
    }
}

// MARK: - Local persistence (AppStorage)

nonisolated enum FavoriteTeamsStore {
    static let appStorageKey = "gameon.profile.favoriteTeamIDs"
    static let primaryTeamIDAppStorageKey = "gameon.profile.primaryFavoriteTeamID"

    static func decodeIDs(from raw: String) -> [String] {
        uniquedIDs(
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ",")
                .map { String($0) }
        )
    }

    static func encodeIDs(_ ids: [String]) -> String {
        uniquedIDs(ids).joined(separator: ",")
    }

    /// Stable follow order: first-seen ID wins. Never `Set`/`Dictionary` iteration.
    static func uniquedIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        out.reserveCapacity(ids.count)
        for raw in ids {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            out.append(id)
        }
        return out
    }

    static func adding(_ id: String, to ids: [String]) -> [String] {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return uniquedIDs(ids) }
        var out = uniquedIDs(ids)
        if !out.contains(trimmed) {
            out.append(trimmed)
        }
        return out
    }

    static func removing(_ id: String, from ids: [String]) -> [String] {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return uniquedIDs(ids) }
        return uniquedIDs(ids).filter { $0 != trimmed }
    }

    static func toggling(_ id: String, in ids: [String]) -> [String] {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return uniquedIDs(ids) }
        if uniquedIDs(ids).contains(trimmed) {
            return removing(trimmed, from: ids)
        }
        return adding(trimmed, to: ids)
    }

    /// Keep local follow order when the ID set is unchanged. Append newly followed IDs; drop removed ones.
    static func mergedRemoteIDs(local: [String], remote: [String]) -> [String] {
        let localIDs = uniquedIDs(local)
        let remoteIDs = uniquedIDs(remote)
        let remoteSet = Set(remoteIDs)
        var out = localIDs.filter { remoteSet.contains($0) }
        let seen = Set(out)
        for id in remoteIDs where !seen.contains(id) {
            out.append(id)
        }
        return out
    }

    static func resolvedTeams(from raw: String) -> [FavoriteTeam] {
        resolvedTeams(fromIDs: decodeIDs(from: raw))
    }

    /// Hydrate catalog rows in persisted follow order. Lookup is by ID; never rebuild from catalog/provider iteration.
    static func resolvedTeams(fromIDs ids: [String]) -> [FavoriteTeam] {
        var seen = Set<String>()
        var out: [FavoriteTeam] = []
        out.reserveCapacity(ids.count)
        for id in ids {
            guard seen.insert(id).inserted else { continue }
            if let team = FavoriteTeamCatalog.team(id: id) {
                out.append(team)
            }
        }
        return out
    }

    static func writeToAppStorage(_ ids: [String]) {
        UserDefaults.standard.set(encodeIDs(ids), forKey: appStorageKey)
    }

    /// Display-only: returns the stored primary only when it is still among favorites.
    /// Does **not** invent a Favorite Team from favorite ordering.
    static func explicitPrimaryTeamID(_ raw: String?, within ids: [String]) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, ids.contains(trimmed), FavoriteTeamCatalog.team(id: trimmed) != nil else {
            return nil
        }
        return trimmed
    }

    /// Persistence helper after remove / sync: keeps an explicit primary when valid,
    /// otherwise falls back to the first catalog-valid favorite (existing product rule).
    static func normalizedPrimaryTeamID(_ raw: String?, within ids: [String]) -> String? {
        if let explicit = explicitPrimaryTeamID(raw, within: ids) {
            return explicit
        }
        return ids.first { FavoriteTeamCatalog.team(id: $0) != nil }
    }

    static func writePrimaryTeamIDToAppStorage(_ teamID: String?) {
        let trimmed = teamID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: primaryTeamIDAppStorageKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: primaryTeamIDAppStorageKey)
        }
    }

    static func clearAppStorage() {
        UserDefaults.standard.removeObject(forKey: appStorageKey)
        UserDefaults.standard.removeObject(forKey: primaryTeamIDAppStorageKey)
    }
}
