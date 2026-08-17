import Foundation

extension Notification.Name {
    static let sportsProviderAthleteCatalogDidChange = Notification.Name(
        "sportsProviderAthleteCatalogDidChange"
    )
}

/// Overlay of roster-backed professional athletes from `sports_provider_identities`.
/// Curated ``FavoriteTeamCatalog`` IDs always win. Never calls TheSportsDB.
nonisolated enum SportsProviderAthleteCatalog {
    private static let lock = NSLock()
    private static var overlay: [FavoriteTeam] = []
    private static var overlayByID: [String: FavoriteTeam] = [:]
    private static var mergedCache: [FavoriteTeam]?
    private static var persistedLoaded = false
    private static let persistKey = "fangeo.sportsProviderAthletes.v1"

    static let generatedIDPrefix = "player-tsdb-"

    private struct PersistedAthlete: Codable, Sendable {
        var id: String
        var name: String
        var sport: String
        var league: String
        var region: String
        var kind: String
        var shortCode: String?
        var aliases: [String]
        var badgeRed: Double
        var badgeGreen: Double
        var badgeBlue: Double
    }

    static func loadPersistedIfNeeded() {
        lock.lock()
        if persistedLoaded {
            lock.unlock()
            return
        }
        persistedLoaded = true
        lock.unlock()
        guard let data = UserDefaults.standard.data(forKey: persistKey),
              let rows = try? JSONDecoder().decode([PersistedAthlete].self, from: data) else {
            return
        }
        let athletes = rows.compactMap(favoriteTeam(from:))
        replaceOverlay(athletes, persist: false, notify: false)
    }

    static func replaceOverlay(_ athletes: [FavoriteTeam], persist: Bool = true, notify: Bool = true) {
        let uniqued = uniquedAthletes(athletes)
        lock.lock()
        overlay = uniqued
        overlayByID = Dictionary(uniqueKeysWithValues: uniqued.map { ($0.id, $0) })
        mergedCache = nil
        persistedLoaded = true
        lock.unlock()
        if persist {
            persistOverlay(uniqued)
        }
        FavoriteFollowingSearch.invalidateCatalogIndex()
        if notify {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .sportsProviderAthleteCatalogDidChange, object: nil)
            }
        }
    }

    static func resetForTests() {
        lock.lock()
        overlay = []
        overlayByID = [:]
        mergedCache = nil
        persistedLoaded = true
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: persistKey)
        FavoriteFollowingSearch.invalidateCatalogIndex()
    }

    static func currentOverlay() -> [FavoriteTeam] {
        loadPersistedIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return overlay
    }

    static func athlete(id: String) -> FavoriteTeam? {
        loadPersistedIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return overlayByID[id]
    }

    static func merged(with curated: [FavoriteTeam]) -> [FavoriteTeam] {
        loadPersistedIfNeeded()
        lock.lock()
        if let mergedCache {
            let cached = mergedCache
            lock.unlock()
            return cached
        }
        let overlayCopy = overlay
        lock.unlock()

        var seenIDs = Set<String>()
        var nameKeys = Set<String>()
        var merged: [FavoriteTeam] = []
        merged.reserveCapacity(curated.count + overlayCopy.count)
        for team in curated {
            let id = team.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seenIDs.insert(id).inserted else { continue }
            merged.append(team)
            if team.kind.isProfessionalAthlete {
                nameKeys.insert(identityKey(sport: team.sport, name: team.name))
            }
        }
        for athlete in overlayCopy {
            let id = athlete.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seenIDs.insert(id).inserted else { continue }
            let key = identityKey(sport: athlete.sport, name: athlete.name)
            guard nameKeys.insert(key).inserted else { continue }
            merged.append(athlete)
        }
        lock.lock()
        mergedCache = merged
        lock.unlock()
        return merged
    }

    static func ingestIdentityRows(_ rows: [SportsProviderIdentityRow]) {
        let teamNameByProviderID = Dictionary(
            rows.compactMap { row -> (String, String)? in
                guard row.kind == "team" || row.kind == "national_team",
                      let teamID = normalized(row.providerTeamId),
                      !row.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return (teamID, row.canonicalName)
            },
            uniquingKeysWith: { first, _ in first }
        )
        var athletes: [FavoriteTeam] = []
        var seenPlayerIDs = Set<String>()
        for row in rows where row.kind == "player" {
            if let providerID = normalized(row.providerPlayerId), !seenPlayerIDs.insert(providerID).inserted {
                continue
            }
            let teamName = teamNameByProviderID[normalized(row.providerTeamId) ?? ""]
            if let athlete = favoriteTeam(from: row, teamName: teamName) {
                athletes.append(athlete)
            }
        }
        replaceOverlay(athletes)
    }

    static func associatedCatalogTeamIDs(forPlayerID id: String, curated: [FavoriteTeam]) -> [String] {
        guard let athlete = athlete(id: id) else { return [] }
        let wanted = FavoriteFollowingSearchNormalizer.normalize(athlete.region)
        guard !wanted.isEmpty, wanted != "favorite players" else { return [] }
        return curated.compactMap { team in
            guard team.kind == .team, team.sport == athlete.sport else { return nil }
            let names = [team.name] + team.searchAliases
            let hit = names.contains {
                FavoriteFollowingSearchNormalizer.normalize($0) == wanted
            }
            return hit ? team.id : nil
        }
    }

    static func displayLeagueName(_ raw: String) -> String {
        let key = FavoriteFollowingSearchNormalizer.normalize(raw)
        switch key {
        case "english premier league": return "Premier League"
        case "spanish la liga": return "La Liga"
        case "italian serie a": return "Serie A"
        case "german bundesliga": return "Bundesliga"
        case "french ligue 1": return "Ligue 1"
        case "american major league soccer": return "MLS"
        case "mexican primera league": return "Liga MX"
        case "portuguese primeira liga": return "Primeira Liga"
        case "dutch eredivisie": return "Eredivisie"
        case "scottish premier league": return "Scottish Premiership"
        default: return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func mapSport(_ raw: String?) -> FavoriteTeamSport? {
        let key = FavoriteFollowingSearchNormalizer.normalize(raw ?? "")
        switch key {
        case "soccer": return .soccer
        case "basketball": return .basketball
        case "american football", "nfl", "football": return .football
        case "baseball", "mlb": return .baseball
        case "ice hockey", "hockey", "nhl": return .hockey
        case "tennis": return .tennis
        case "golf": return .golf
        case "badminton": return .badminton
        default: return FavoriteTeamSport(rawValue: raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
    }

    private static func favoriteTeam(from row: SportsProviderIdentityRow, teamName: String?) -> FavoriteTeam? {
        let name = row.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard let sport = mapSport(row.sport) else { return nil }
        let club = (teamName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let league = displayLeagueName(row.league ?? "")
        let rgb = SportsIdentityArtworkResolver.deterministicBadgeRGB(entityKey: row.catalogId)
        var aliases = [club, league].filter { !$0.isEmpty && $0.localizedCaseInsensitiveCompare(name) != .orderedSame }
        if let last = name.split(separator: " ").last, last.count >= 4 {
            aliases.append(String(last))
        }
        return FavoriteTeam(
            id: row.catalogId,
            name: name,
            sport: sport,
            league: league.isEmpty ? sport.rawValue : league,
            region: club.isEmpty ? "Featured Players" : club,
            kind: .player,
            shortCode: SportsIdentityArtworkResolver.monogram(from: name, shortCode: nil),
            searchAliases: Array(Set(aliases)),
            fallbackSymbol: "person.fill",
            badgeRed: rgb.red,
            badgeGreen: rgb.green,
            badgeBlue: rgb.blue
        )
    }

    private static func favoriteTeam(from row: PersistedAthlete) -> FavoriteTeam? {
        guard let sport = mapSport(row.sport),
              let kind = FavoriteTeamKind(rawValue: row.kind) else { return nil }
        let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return FavoriteTeam(
            id: row.id,
            name: name,
            sport: sport,
            league: row.league,
            region: row.region,
            kind: kind,
            shortCode: row.shortCode,
            searchAliases: row.aliases,
            fallbackSymbol: "person.fill",
            badgeRed: row.badgeRed,
            badgeGreen: row.badgeGreen,
            badgeBlue: row.badgeBlue
        )
    }

    private static func persistOverlay(_ athletes: [FavoriteTeam]) {
        let rows = athletes.prefix(8000).map { team in
            PersistedAthlete(
                id: team.id,
                name: team.name,
                sport: team.sport.rawValue,
                league: team.league,
                region: team.region,
                kind: team.kind.rawValue,
                shortCode: team.shortCode,
                aliases: team.searchAliases,
                badgeRed: team.badgeRed,
                badgeGreen: team.badgeGreen,
                badgeBlue: team.badgeBlue
            )
        }
        if let data = try? JSONEncoder().encode(Array(rows)) {
            UserDefaults.standard.set(data, forKey: persistKey)
        }
    }

    private static func uniquedAthletes(_ athletes: [FavoriteTeam]) -> [FavoriteTeam] {
        var seenIDs = Set<String>()
        var seenPlayers = Set<String>()
        var out: [FavoriteTeam] = []
        for athlete in athletes {
            let id = athlete.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seenIDs.insert(id).inserted else { continue }
            let key = identityKey(sport: athlete.sport, name: athlete.name)
            guard seenPlayers.insert(key).inserted else { continue }
            out.append(athlete)
        }
        return out
    }

    private static func identityKey(sport: FavoriteTeamSport, name: String) -> String {
        sport.rawValue + "|" + FavoriteFollowingSearchNormalizer.normalize(name)
    }

    private static func normalized(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
