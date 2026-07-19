import Combine
import Foundation

// MARK: - Sendable catalog alias source (extracted on MainActor, used off MainActor)

struct DiscoverProGameCatalogAliasSource: Sendable {
    let name: String
    let shortCode: String?
    let searchAliases: [String]
    let league: String
    let isCompetitionLike: Bool
}

/// Precomputed FavoriteTeamCatalog tokens for Discover pro-game search.
/// Immutable value type; safe to read from background work after construction.
struct DiscoverProGameCatalogAliasLookup: Sendable {
    let strongTokens: Set<String>
    let prefixableTokens: [String]
    private let aliasesByName: [String: Set<String>]

    nonisolated func aliases(forTeamOrLeagueName raw: String) -> Set<String> {
        let normalized = LiveMatchFilters.normalizedSearchText(raw)
        guard normalized.count >= 2 else { return [] }
        return aliasesByName[normalized] ?? []
    }

    nonisolated func isStrongSportsQuery(_ normalizedQuery: String) -> Bool {
        guard !normalizedQuery.isEmpty else { return false }
        if strongTokens.contains(normalizedQuery) { return true }
        guard normalizedQuery.count >= 4 else { return false }
        for token in prefixableTokens where token.hasPrefix(normalizedQuery) {
            return true
        }
        return false
    }

    nonisolated static func build(from sources: [DiscoverProGameCatalogAliasSource]) -> DiscoverProGameCatalogAliasLookup {
        var aliasesByName: [String: Set<String>] = [:]
        var strongTokens = Set<String>()

        for entry in sources {
            let name = LiveMatchFilters.normalizedSearchText(entry.name)
            guard !name.isEmpty else { continue }
            var aliases = Set<String>()
            if let code = entry.shortCode {
                let codeNorm = LiveMatchFilters.normalizedSearchText(code)
                if !codeNorm.isEmpty { aliases.insert(codeNorm) }
            }
            for alias in entry.searchAliases {
                let aliasNorm = LiveMatchFilters.normalizedSearchText(alias)
                if !aliasNorm.isEmpty { aliases.insert(aliasNorm) }
            }
            if entry.isCompetitionLike {
                let league = LiveMatchFilters.normalizedSearchText(entry.league)
                if !league.isEmpty {
                    aliases.insert(league)
                }
            }
            aliasesByName[name, default: []].formUnion(aliases)
            strongTokens.insert(name)
            strongTokens.formUnion(aliases)
        }

        for extra in ["epl", "ucl", "uel", "uecl", "mls", "afcon", "wwc", "wsl", "nwsl", "f1", "ipl", "wbc"] {
            strongTokens.insert(extra)
        }

        let prefixable = strongTokens.filter { $0.count >= 4 }.sorted()
#if DEBUG
        print("[DiscoverProGameSearch] aliasLookup tokens=\(strongTokens.count) prefixable=\(prefixable.count)")
#endif
        return DiscoverProGameCatalogAliasLookup(
            strongTokens: strongTokens,
            prefixableTokens: prefixable,
            aliasesByName: aliasesByName
        )
    }
}

// MARK: - Lightweight search document (no full LiveMatch payload)

struct DiscoverProGameSearchDoc: Sendable {
    let stableKey: String
    let startTime: Date
    let isLive: Bool
    let isFinal: Bool
    let home: String
    let away: String
    let homeAliases: Set<String>
    let awayAliases: Set<String>
    let league: String
    let leagueAliases: Set<String>

    nonisolated static func make(
        match: LiveMatch,
        stableKey: String,
        lookup: DiscoverProGameCatalogAliasLookup
    ) -> DiscoverProGameSearchDoc {
        let home = LiveMatchFilters.normalizedSearchText(match.homeTeam)
        let away = LiveMatchFilters.normalizedSearchText(match.awayTeam)
        let league = LiveMatchFilters.normalizedSearchText(match.league)
        let leagueAlt = LiveMatchFilters.normalizedSearchText(match.leagueAlternate ?? "")
        let sourceLeague = LiveMatchFilters.normalizedSearchText(match.sourceLeagueName ?? "")

        var leagueAliases = lookup.aliases(forTeamOrLeagueName: match.league)
        leagueAliases.formUnion(lookup.aliases(forTeamOrLeagueName: match.leagueAlternate ?? ""))
        leagueAliases.formUnion(lookup.aliases(forTeamOrLeagueName: match.sourceLeagueName ?? ""))
        if !leagueAlt.isEmpty { leagueAliases.insert(leagueAlt) }
        if !sourceLeague.isEmpty { leagueAliases.insert(sourceLeague) }
        leagueAliases.remove(league)

        return DiscoverProGameSearchDoc(
            stableKey: stableKey,
            startTime: match.startTime,
            isLive: match.matchStatus.isHappeningNow,
            isFinal: match.matchStatus == .fullTime,
            home: home,
            away: away,
            homeAliases: lookup.aliases(forTeamOrLeagueName: match.homeTeam),
            awayAliases: lookup.aliases(forTeamOrLeagueName: match.awayTeam),
            league: league,
            leagueAliases: leagueAliases
        )
    }
}

/// Immutable index payload produced entirely off the Main Actor.
struct DiscoverProGameBuiltIndex: Sendable {
    let documents: [DiscoverProGameSearchDoc]
    let matchesByKey: [String: LiveMatch]
}

enum DiscoverProGameIndexBuilder {
    nonisolated static func build(
        inventory: [LiveMatch],
        lookup: DiscoverProGameCatalogAliasLookup
    ) -> DiscoverProGameBuiltIndex {
        var documents: [DiscoverProGameSearchDoc] = []
        var matchesByKey: [String: LiveMatch] = [:]
        documents.reserveCapacity(inventory.count)
        matchesByKey.reserveCapacity(inventory.count)
        for match in inventory {
            let key = SavedProGame.stableKey(for: match)
            matchesByKey[key] = match
            documents.append(
                DiscoverProGameSearchDoc.make(match: match, stableKey: key, lookup: lookup)
            )
        }
        return DiscoverProGameBuiltIndex(documents: documents, matchesByKey: matchesByKey)
    }
}

// MARK: - Controller

/// Debounced in-memory professional-game search over ``MapViewModel/liveMatches``.
/// Index rebuilds only when inventory revision changes; queries never call FavoriteTeamCatalog.searchTeams.
@MainActor
final class DiscoverProGameSearchController: ObservableObject {
    @Published private(set) var results: [LiveMatch] = []
    /// Kept for API compatibility; never drives UI spinners (always false).
    @Published private(set) var isLoading = false
    @Published private(set) var activeNormalizedQuery: String = ""

    private var searchTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var resultCache: [String: [LiveMatch]] = [:]
    private var docs: [DiscoverProGameSearchDoc] = []
    private var matchesByKey: [String: LiveMatch] = [:]
    private var inventoryRevision = ""
    private var favoriteAliasTokens: Set<String> = []
    private var favoriteRevision = ""
    private var aliasLookupCache: DiscoverProGameCatalogAliasLookup?
    private let cacheLimit = 32
    private let debounceMilliseconds: UInt64 = 200
    private let resultLimit = 5

#if DEBUG
    private var lastQueryStartedAt: CFAbsoluteTime = 0
#endif

    func match(forStableKey key: String) -> LiveMatch? {
        matchesByKey[key] ?? results.first(where: { SavedProGame.stableKey(for: $0) == key })
    }

    func refresh(
        query: String,
        inventory: [LiveMatch],
        isFocused: Bool,
        favoriteTeamIDs: [String] = []
    ) {
#if DEBUG
        let t0 = CFAbsoluteTimeGetCurrent()
#endif
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("@") {
            cancelInFlight(clearResults: true)
            return
        }

        let lookup = resolvedAliasLookup()
        let normalized = Self.normalizeQuery(trimmed)
        activeNormalizedQuery = normalized
        updateFavoriteAliasesIfNeeded(favoriteTeamIDs, lookup: lookup)
        scheduleIndexRebuildIfNeeded(inventory, lookup: lookup)

        guard isFocused else {
            cancelInFlight(clearResults: true)
            return
        }

        guard Self.isEligibleQuery(
            normalized,
            favoriteTokens: favoriteAliasTokens,
            lookup: lookup
        ) else {
            cancelInFlight(clearResults: true)
            return
        }

        guard !docs.isEmpty || !inventory.isEmpty else {
            cancelInFlight(clearResults: true)
            return
        }

        let cacheKey = "\(inventoryRevision)|\(favoriteRevision)|\(normalized)"
        if let cached = resultCache[cacheKey] {
            publish(cached, for: normalized)
#if DEBUG
            print("[DiscoverProGameSearch] cacheHit query=\(normalized) ms=\(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))")
#endif
            return
        }

        searchTask?.cancel()
        generation &+= 1
        let token = generation
        let docsSnapshot = docs
        let favorites = favoriteAliasTokens
#if DEBUG
        lastQueryStartedAt = CFAbsoluteTimeGetCurrent()
#endif
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: debounceMilliseconds * 1_000_000)
            guard !Task.isCancelled, token == generation else { return }

            if docsSnapshot.isEmpty, !inventory.isEmpty {
                await waitForIndex(timeoutMs: 80)
            }
            guard !Task.isCancelled, token == generation else { return }
            let latestDocs = self.docs
            guard !latestDocs.isEmpty else {
                self.publish([], for: normalized)
                return
            }

            let rankedKeys = Self.rankMatches(
                docs: latestDocs,
                query: normalized,
                favoriteTokens: favorites,
                limit: self.resultLimit
            )
            let matches = rankedKeys.compactMap { self.matchesByKey[$0] }
            guard !Task.isCancelled, token == self.generation, self.activeNormalizedQuery == normalized else { return }
            self.storeCache(key: cacheKey, rows: matches)
            self.publish(matches, for: normalized)
#if DEBUG
            let ms = Int((CFAbsoluteTimeGetCurrent() - self.lastQueryStartedAt) * 1000)
            print("[DiscoverProGameSearch] query=\(normalized) inventory=\(latestDocs.count) hits=\(matches.count) matchMs=\(ms)")
#endif
        }
    }

    func clear() {
        cancelInFlight(clearResults: true)
    }

    private func resolvedAliasLookup() -> DiscoverProGameCatalogAliasLookup {
        if let aliasLookupCache { return aliasLookupCache }
        let sources = FavoriteTeamCatalog.all.map {
            DiscoverProGameCatalogAliasSource(
                name: $0.name,
                shortCode: $0.shortCode,
                searchAliases: $0.searchAliases,
                league: $0.league,
                isCompetitionLike: $0.kind.isCompetitionLike
            )
        }
        let built = DiscoverProGameCatalogAliasLookup.build(from: sources)
        aliasLookupCache = built
        return built
    }

    private func publish(_ rows: [LiveMatch], for normalized: String) {
        results = rows
        isLoading = false
        activeNormalizedQuery = normalized
    }

    private func cancelInFlight(clearResults: Bool) {
        searchTask?.cancel()
        searchTask = nil
        generation &+= 1
        isLoading = false
        if clearResults {
            results = []
            activeNormalizedQuery = ""
        }
    }

    private func updateFavoriteAliasesIfNeeded(
        _ favoriteTeamIDs: [String],
        lookup: DiscoverProGameCatalogAliasLookup
    ) {
        let revision = favoriteTeamIDs.joined(separator: ",")
        guard revision != favoriteRevision else { return }
        favoriteRevision = revision
        var tokens = Set<String>()
        for id in favoriteTeamIDs {
            guard let team = FavoriteTeamCatalog.team(id: id) else { continue }
            let name = LiveMatchFilters.normalizedSearchText(team.name)
            if !name.isEmpty { tokens.insert(name) }
            tokens.formUnion(lookup.aliases(forTeamOrLeagueName: team.name))
            if let code = team.shortCode {
                let codeNorm = LiveMatchFilters.normalizedSearchText(code)
                if !codeNorm.isEmpty { tokens.insert(codeNorm) }
            }
            for alias in team.searchAliases {
                let aliasNorm = LiveMatchFilters.normalizedSearchText(alias)
                if !aliasNorm.isEmpty { tokens.insert(aliasNorm) }
            }
        }
        favoriteAliasTokens = tokens
    }

    private func scheduleIndexRebuildIfNeeded(
        _ inventory: [LiveMatch],
        lookup: DiscoverProGameCatalogAliasLookup
    ) {
        let revision = Self.inventoryRevision(for: inventory)
        guard revision != inventoryRevision else { return }

        inventoryRevision = revision
        resultCache.removeAll(keepingCapacity: true)
        indexTask?.cancel()

        let captured = inventory
#if DEBUG
        let buildStarted = CFAbsoluteTimeGetCurrent()
#endif
        indexTask = Task.detached(priority: .utility) {
            let built = DiscoverProGameIndexBuilder.build(inventory: captured, lookup: lookup)
            await MainActor.run {
                guard revision == self.inventoryRevision else { return }
                self.docs = built.documents
                self.matchesByKey = built.matchesByKey
#if DEBUG
                let ms = Int((CFAbsoluteTimeGetCurrent() - buildStarted) * 1000)
                print("[DiscoverProGameSearch] indexRebuild count=\(built.documents.count) ms=\(ms)")
#endif
            }
        }
    }

    private func waitForIndex(timeoutMs: UInt64) async {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while docs.isEmpty, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func storeCache(key: String, rows: [LiveMatch]) {
        resultCache[key] = rows
        if resultCache.count > cacheLimit {
            let overflow = resultCache.count - cacheLimit
            for stale in resultCache.keys.prefix(overflow) {
                resultCache.removeValue(forKey: stale)
            }
        }
    }

    nonisolated private static func inventoryRevision(for inventory: [LiveMatch]) -> String {
        guard !inventory.isEmpty else { return "0" }
        let first = SavedProGame.stableKey(for: inventory[0])
        let last = SavedProGame.stableKey(for: inventory[inventory.count - 1])
        let mid = SavedProGame.stableKey(for: inventory[inventory.count / 2])
        return "\(inventory.count)|\(first)|\(mid)|\(last)"
    }

    nonisolated static func normalizeQuery(_ raw: String) -> String {
        LiveMatchFilters.normalizedSearchText(raw)
    }

    nonisolated static func isEligibleQuery(
        _ normalized: String,
        favoriteTokens: Set<String>,
        lookup: DiscoverProGameCatalogAliasLookup
    ) -> Bool {
        guard !normalized.isEmpty else { return false }
        if normalized.hasPrefix("@") { return false }
        if hasMatchupSeparator(normalized) { return true }
        if favoriteTokens.contains(where: { strongTokenMatch(token: $0, query: normalized) }) {
            return true
        }
        if lookup.isStrongSportsQuery(normalized) {
            return true
        }
        return false
    }

    nonisolated private static func strongTokenMatch(token: String, query: String) -> Bool {
        if token == query { return true }
        if query.count >= 3, token.hasPrefix(query) { return true }
        if query.count >= 4, query.hasPrefix(token), token.count >= 3 { return true }
        return false
    }

    nonisolated private static func hasMatchupSeparator(_ query: String) -> Bool {
        let tokens = query.split(separator: " ").map(String.init)
        guard tokens.count >= 3 else { return false }
        let separators: Set<String> = ["vs", "v", "at"]
        return tokens.dropFirst().dropLast().contains(where: { separators.contains($0) })
    }

    nonisolated static func rankMatches(
        docs: [DiscoverProGameSearchDoc],
        query: String,
        favoriteTokens: Set<String>,
        limit: Int
    ) -> [String] {
        let now = Date()
        let sides = parseMatchupSides(query)
        let favorsFavorites = !favoriteTokens.isEmpty
            && favoriteTokens.contains(where: { strongTokenMatch(token: $0, query: query) })

        var best: [(key: String, score: Int, start: Date, live: Bool)] = []
        best.reserveCapacity(limit)

        func consider(_ doc: DiscoverProGameSearchDoc, _ score: Int) {
            if let idx = best.firstIndex(where: { $0.key == doc.stableKey }) {
                if score < best[idx].score
                    || (score == best[idx].score && doc.startTime < best[idx].start) {
                    best[idx] = (doc.stableKey, score, doc.startTime, doc.isLive)
                }
                return
            }
            if best.count < limit {
                best.append((doc.stableKey, score, doc.startTime, doc.isLive))
                return
            }
            if let worstIdx = best.indices.max(by: { a, b in
                if best[a].score != best[b].score { return best[a].score < best[b].score }
                return best[a].start > best[b].start
            }), score < best[worstIdx].score
                || (score == best[worstIdx].score && doc.startTime < best[worstIdx].start) {
                best[worstIdx] = (doc.stableKey, score, doc.startTime, doc.isLive)
            }
        }

        if favorsFavorites {
            for doc in docs {
                guard docIntersectsFavorites(doc, favoriteTokens: favoriteTokens) else { continue }
                if let score = score(doc, query: query, now: now, sides: sides, allowWeakMetadata: false) {
                    consider(doc, max(0, score - 5))
                }
            }
            if best.count >= limit {
                return best.sorted(by: rankSort).map(\.key)
            }
        }

        for doc in docs {
            if favorsFavorites, docIntersectsFavorites(doc, favoriteTokens: favoriteTokens) {
                continue
            }
            if let score = score(doc, query: query, now: now, sides: sides, allowWeakMetadata: false) {
                consider(doc, score)
            }
        }

        return best.sorted(by: rankSort).map(\.key)
    }

    nonisolated private static func rankSort(
        _ lhs: (key: String, score: Int, start: Date, live: Bool),
        _ rhs: (key: String, score: Int, start: Date, live: Bool)
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score < rhs.score }
        if lhs.live != rhs.live { return lhs.live && !rhs.live }
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        return lhs.key < rhs.key
    }

    nonisolated private static func docIntersectsFavorites(
        _ doc: DiscoverProGameSearchDoc,
        favoriteTokens: Set<String>
    ) -> Bool {
        if favoriteTokens.contains(doc.home) || favoriteTokens.contains(doc.away) || favoriteTokens.contains(doc.league) {
            return true
        }
        if !doc.homeAliases.isDisjoint(with: favoriteTokens) { return true }
        if !doc.awayAliases.isDisjoint(with: favoriteTokens) { return true }
        if !doc.leagueAliases.isDisjoint(with: favoriteTokens) { return true }
        return false
    }

    nonisolated private static func score(
        _ doc: DiscoverProGameSearchDoc,
        query: String,
        now: Date,
        sides: (String, String)?,
        allowWeakMetadata: Bool
    ) -> Int? {
        _ = allowWeakMetadata
        let isLive = doc.isLive
        let isFinal = doc.isFinal
        let isUpcoming = !isLive && !isFinal && doc.startTime >= now.addingTimeInterval(-15 * 60)

        if isFinal, doc.startTime < now.addingTimeInterval(-36 * 3600) {
            return nil
        }
        if !isLive && !isUpcoming && !isFinal, doc.startTime < now.addingTimeInterval(-36 * 3600) {
            return nil
        }

        var best = Int.max

        if let sides {
            let (a, b) = sides
            if teamsMatchBothWays(doc, a: a, b: b, exact: true) {
                best = min(best, isLive ? 0 : (isUpcoming ? 10 : 80))
            } else if teamsMatchBothWays(doc, a: a, b: b, exact: false) {
                best = min(best, isLive ? 5 : (isUpcoming ? 20 : 90))
            }
        }

        if doc.home == query || doc.away == query
            || doc.homeAliases.contains(query) || doc.awayAliases.contains(query) {
            best = min(best, isLive ? 1 : (isUpcoming ? 30 : 100))
        } else if doc.home.hasPrefix(query) || doc.away.hasPrefix(query)
                    || doc.homeAliases.contains(where: { $0.hasPrefix(query) })
                    || doc.awayAliases.contains(where: { $0.hasPrefix(query) }) {
            best = min(best, isLive ? 2 : (isUpcoming ? 40 : 110))
        }

        if doc.league == query || doc.leagueAliases.contains(query) {
            best = min(best, isLive ? 3 : (isUpcoming ? 50 : 120))
        } else if doc.league.hasPrefix(query) || doc.leagueAliases.contains(where: { $0.hasPrefix(query) }) {
            best = min(best, isLive ? 4 : (isUpcoming ? 55 : 125))
        }

        if query.count >= 4 {
            if doc.home.contains(query) || doc.away.contains(query)
                || doc.homeAliases.contains(where: { $0.contains(query) })
                || doc.awayAliases.contains(where: { $0.contains(query) }) {
                best = min(best, isLive ? 6 : (isUpcoming ? 60 : 130))
            }
        }

        return best == Int.max ? nil : best
    }

    nonisolated private static func teamsMatchBothWays(
        _ doc: DiscoverProGameSearchDoc,
        a: String,
        b: String,
        exact: Bool
    ) -> Bool {
        if exact {
            return (doc.home == a && doc.away == b) || (doc.home == b && doc.away == a)
        }
        let homeA = doc.home.hasPrefix(a) || doc.home.contains(a)
        let awayB = doc.away.hasPrefix(b) || doc.away.contains(b)
        let homeB = doc.home.hasPrefix(b) || doc.home.contains(b)
        let awayA = doc.away.hasPrefix(a) || doc.away.contains(a)
        return (homeA && awayB) || (homeB && awayA)
    }

    nonisolated private static func parseMatchupSides(_ query: String) -> (String, String)? {
        let tokens = query.split(separator: " ").map(String.init)
        guard tokens.count >= 3 else { return nil }
        let separators: Set<String> = ["vs", "v", "at"]
        for i in 1..<(tokens.count - 1) where separators.contains(tokens[i]) {
            let left = tokens[..<i].joined(separator: " ")
            let right = tokens[(i + 1)...].joined(separator: " ")
            if !left.isEmpty, !right.isEmpty {
                return (left, right)
            }
        }
        return nil
    }
}

struct DiscoverProGameSearchHit: Identifiable, Equatable, Sendable {
    let match: LiveMatch
    let rank: Int

    var id: String { SavedProGame.stableKey(for: match) }
}
