import Foundation

// MARK: - Pure string utilities (never MainActor)

nonisolated enum FavoriteFollowingSearchNormalizer: Sendable {
    /// Shared normalization: trim, collapse whitespace, case/diacritic fold, unify punctuation/apostrophes/hyphens.
    /// Does not transliterate non-Latin scripts away — alphanumerics from those scripts remain.
    nonisolated static func normalize(_ value: String) -> String {
        let folded = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{02BC}", with: "'")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()

        var scalars: [Character] = []
        var previousWasSeparator = false
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                scalars.append(ch)
                previousWasSeparator = false
            } else if ch == "'" {
                previousWasSeparator = false
            } else {
                if !previousWasSeparator, !scalars.isEmpty {
                    scalars.append(" ")
                    previousWasSeparator = true
                }
            }
        }
        while scalars.last == " " {
            scalars.removeLast()
        }
        return String(scalars)
    }

    nonisolated static func tokens(_ normalized: String) -> [String] {
        normalized.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }
}

// MARK: - Ranked Following Search

/// Precomputed search haystacks for ``FavoriteTeamCatalog`` so keystrokes do not rebuild normalization work.
nonisolated enum FavoriteFollowingSearch {
    /// Sendable index row — stores team id, not MainActor-bound model references.
    struct IndexedEntry: Sendable {
        let teamID: String
        let canonicalName: String
        let shortCode: String
        let aliases: [String]
        let canonicalTokens: [String]
        let aliasTokens: [String]
        let leagueName: String
    }

    private static let lock = NSLock()
    private static var indexedCache: [IndexedEntry]?
    private static var byIDCache: [String: FavoriteTeam]?

    nonisolated static func normalize(_ value: String) -> String {
        FavoriteFollowingSearchNormalizer.normalize(value)
    }

    nonisolated private static func tokens(_ normalized: String) -> [String] {
        FavoriteFollowingSearchNormalizer.tokens(normalized)
    }

    private static func indexed() -> [IndexedEntry] {
        lock.lock()
        if let indexedCache {
            let cached = indexedCache
            lock.unlock()
            return cached
        }
        lock.unlock()

        let catalog = FavoriteTeamCatalog.all
        let built: [IndexedEntry] = catalog.compactMap { team in
            let id = team.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            let canonical = normalize(team.name)
            let short = normalize(team.shortCode ?? "")
            var aliasSource = ([team.shortCode ?? ""] + team.searchAliases)
            if team.kind.isProfessionalAthlete {
                aliasSource.append(team.region)
                aliasSource.append(team.league)
            }
            let aliases = aliasSource
                .map(normalize)
                .filter { !$0.isEmpty && $0 != canonical && $0 != short && $0 != "favorite players" }
            let uniqueAliases = Array(Set(aliases)).sorted()
            return IndexedEntry(
                teamID: id,
                canonicalName: canonical,
                shortCode: short,
                aliases: uniqueAliases,
                canonicalTokens: tokens(canonical),
                aliasTokens: uniqueAliases.flatMap(tokens),
                leagueName: normalize(team.league)
            )
        }
        lock.lock()
        indexedCache = built
        byIDCache = FavoriteFollowingCountryBrowse.dictionaryByUniqueID(catalog)
        lock.unlock()
        return built
    }

    static func invalidateCatalogIndex() {
        lock.lock()
        indexedCache = nil
        byIDCache = nil
        lock.unlock()
    }

    /// Empty query returns no unbounded dump (country browse / search handle browse mode).
    static func rankedResults(
        query raw: String,
        prioritizingSelectedIDs selectedIDs: Set<String> = []
    ) -> [FavoriteTeam] {
        let q = normalize(raw)
        guard !q.isEmpty else { return [] }

        let qTokens = tokens(q)
        var scored: [(teamID: String, rank: Int, selectedBoost: Int, name: String)] = []

        for entry in indexed() {
            guard let rank = bestRank(query: q, queryTokens: qTokens, entry: entry) else { continue }
            let selectedBoost = selectedIDs.contains(entry.teamID) ? 0 : 1
            scored.append(
                (
                    teamID: entry.teamID,
                    rank: rank,
                    selectedBoost: selectedBoost,
                    name: entry.canonicalName
                )
            )
        }

        scored.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.selectedBoost != rhs.selectedBoost { return lhs.selectedBoost < rhs.selectedBoost }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.teamID < rhs.teamID
        }

        return scored.compactMap { team(id: $0.teamID) }
    }

    static func team(id: String) -> FavoriteTeam? {
        _ = indexed()
        lock.lock()
        defer { lock.unlock() }
        return byIDCache?[id]
    }

    /// Rank 1...10 per product rules; nil = no match.
    nonisolated private static func bestRank(
        query q: String,
        queryTokens: [String],
        entry: IndexedEntry
    ) -> Int? {
        if !entry.canonicalName.isEmpty, entry.canonicalName == q { return 1 }
        if !entry.shortCode.isEmpty, entry.shortCode == q { return 2 }
        if entry.aliases.contains(q) { return 3 }
        if !entry.canonicalName.isEmpty, entry.canonicalName.hasPrefix(q) { return 4 }
        if !entry.shortCode.isEmpty, entry.shortCode.hasPrefix(q) { return 5 }
        if entry.aliases.contains(where: { $0.hasPrefix(q) }) { return 6 }
        if tokenPrefixMatch(queryTokens: queryTokens, haystackTokens: entry.canonicalTokens) { return 7 }
        if tokenPrefixMatch(queryTokens: queryTokens, haystackTokens: entry.aliasTokens) { return 8 }
        if !entry.canonicalName.isEmpty, entry.canonicalName.contains(q) { return 9 }
        if entry.aliases.contains(where: { $0.contains(q) }) { return 10 }
        if q.count >= 3, !entry.leagueName.isEmpty, entry.leagueName.contains(q) { return 11 }
        return nil
    }

    nonisolated private static func tokenPrefixMatch(
        queryTokens: [String],
        haystackTokens: [String]
    ) -> Bool {
        guard !queryTokens.isEmpty, !haystackTokens.isEmpty else { return false }
        return queryTokens.allSatisfy { qt in
            haystackTokens.contains { $0.hasPrefix(qt) }
        }
    }
}

// MARK: - Catalog Integrity

nonisolated enum FavoriteCatalogValidation {
    struct Report: Equatable {
        var duplicateIDs: [String] = []
        var duplicateIdentities: [String] = []
        var emptyNames: [String] = []
        var missingSportOrKind: [String] = []
        var missingInitialsOrSymbol: [String] = []
        var aliasCollisions: [String] = []
        var totalCount: Int = 0
        var countsBySport: [String: Int] = [:]
        var countsByKind: [String: Int] = [:]

        var isClean: Bool {
            duplicateIDs.isEmpty
                && duplicateIdentities.isEmpty
                && emptyNames.isEmpty
                && missingSportOrKind.isEmpty
                && missingInitialsOrSymbol.isEmpty
                && aliasCollisions.isEmpty
        }
    }

    static func validate(_ teams: [FavoriteTeam] = FavoriteTeamCatalog.all) -> Report {
        var report = Report()
        report.totalCount = teams.count

        var seenIDs = Set<String>()
        var identityOwners: [String: String] = [:]
        var aliasOwners: [String: (id: String, sport: FavoriteTeamSport, kind: FavoriteTeamKind)] = [:]

        for team in teams {
            report.countsBySport[team.sport.rawValue, default: 0] += 1
            report.countsByKind[team.kind.rawValue, default: 0] += 1

            if !seenIDs.insert(team.id).inserted {
                report.duplicateIDs.append(team.id)
            }
            if team.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                report.emptyNames.append(team.id)
            }
            if team.initials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               team.fallbackSymbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                report.missingInitialsOrSymbol.append(team.id)
            }

            let identity = [
                FavoriteFollowingSearchNormalizer.normalize(team.sport.rawValue),
                FavoriteFollowingSearchNormalizer.normalize(team.kind.rawValue),
                FavoriteFollowingSearchNormalizer.normalize(team.name)
            ].joined(separator: "|")
            if let owner = identityOwners[identity], owner != team.id {
                report.duplicateIdentities.append("\(identity) => \(owner) vs \(team.id)")
            } else {
                identityOwners[identity] = team.id
            }

            let aliasKeys = ([team.name, team.shortCode ?? ""] + team.searchAliases)
                .map(FavoriteFollowingSearchNormalizer.normalize)
                .filter { $0.count >= 3 }
            for key in Set(aliasKeys) {
                if let owner = aliasOwners[key], owner.id != team.id {
                    if owner.sport != team.sport || owner.kind != team.kind {
                        report.aliasCollisions.append("\(key) => \(owner.id) vs \(team.id)")
                    }
                } else {
                    aliasOwners[key] = (team.id, team.sport, team.kind)
                }
            }
        }
        return report
    }
}
