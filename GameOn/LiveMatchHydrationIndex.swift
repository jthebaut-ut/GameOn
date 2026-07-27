import Foundation

/// Precomputed lookup tables for saved Pro Game → `LiveMatch` hydration.
///
/// Saved-game hydration previously scanned the whole `liveMatches` array once per tier, per saved
/// game. With a warm Live cache (~680 rows) the provider-identifier tier rebuilt a normalized
/// identifier `Set` for *every* candidate row, so a single batch cost O(savedGames × rows × folds)
/// of Unicode folding on the MainActor.
///
/// This index does that normalization once per snapshot. Matching precedence, comparison rules, and
/// "first row in array order wins" semantics are identical to the previous linear scan — each table
/// keeps the **lowest** row position for a key, and tiers are consulted in the original order.
nonisolated struct LiveMatchHydrationIndex {
    /// Row count of the snapshot this index was built from (cheap cache validation).
    let sourceCount: Int
    /// Content signature of the snapshot; a mismatch means the index must be rebuilt.
    let sourceSignature: Int
    let buildMs: Double

    private let byNormalizedId: [String: Int]
    private let bySourceAndNormalizedExternalId: [String: Int]
    private let byNormalizedExternalId: [String: Int]
    private let byStableKey: [String: Int]
    private let bySourceAndRawExternalId: [String: Int]
    private let byHydrationIdentifier: [String: Int]
    private let positionsByTeamsKey: [String: [Int]]

    static let empty = LiveMatchHydrationIndex(
        sourceCount: 0,
        sourceSignature: signature(of: []),
        buildMs: 0,
        byNormalizedId: [:],
        bySourceAndNormalizedExternalId: [:],
        byNormalizedExternalId: [:],
        byStableKey: [:],
        bySourceAndRawExternalId: [:],
        byHydrationIdentifier: [:],
        positionsByTeamsKey: [:]
    )

    // MARK: - Build

    static func build(from matches: [LiveMatch]) -> LiveMatchHydrationIndex {
        let started = CFAbsoluteTimeGetCurrent()

        var byNormalizedId: [String: Int] = [:]
        var bySourceAndNormalizedExternalId: [String: Int] = [:]
        var byNormalizedExternalId: [String: Int] = [:]
        var byStableKey: [String: Int] = [:]
        var bySourceAndRawExternalId: [String: Int] = [:]
        var byHydrationIdentifier: [String: Int] = [:]
        var positionsByTeamsKey: [String: [Int]] = [:]

        byNormalizedId.reserveCapacity(matches.count)
        byStableKey.reserveCapacity(matches.count)
        positionsByTeamsKey.reserveCapacity(matches.count)

        // Lowest position wins so lookups reproduce `first(where:)` on the original array.
        func insertFirst(_ key: String, _ position: Int, into table: inout [String: Int]) {
            guard !key.isEmpty else { return }
            if let existing = table[key], existing <= position { return }
            table[key] = position
        }

        for (position, match) in matches.enumerated() {
            insertFirst(SavedProGame.normalizedHydrationToken(match.id), position, into: &byNormalizedId)

            let normalizedExternal = SavedProGame.normalizedHydrationToken(match.externalId)
            insertFirst(normalizedExternal, position, into: &byNormalizedExternalId)

            let foldedSource = foldedCaseInsensitive(match.source)
            if !foldedSource.isEmpty {
                insertFirst(
                    sourceScopedKey(source: foldedSource, external: normalizedExternal),
                    position,
                    into: &bySourceAndNormalizedExternalId
                )
                let rawExternal = foldedCaseInsensitive(match.externalId)
                insertFirst(
                    sourceScopedKey(source: foldedSource, external: rawExternal),
                    position,
                    into: &bySourceAndRawExternalId
                )
            }

            insertFirst(SavedProGame.stableKey(for: match), position, into: &byStableKey)

            for identifier in hydrationIdentifiers(id: match.id, externalId: match.externalId, source: match.source) {
                insertFirst(identifier, position, into: &byHydrationIdentifier)
            }

            let teamsKey = teamsKey(away: match.awayTeam, home: match.homeTeam)
            if !teamsKey.isEmpty {
                positionsByTeamsKey[teamsKey, default: []].append(position)
            }
        }

        return LiveMatchHydrationIndex(
            sourceCount: matches.count,
            sourceSignature: signature(of: matches),
            buildMs: (CFAbsoluteTimeGetCurrent() - started) * 1000,
            byNormalizedId: byNormalizedId,
            bySourceAndNormalizedExternalId: bySourceAndNormalizedExternalId,
            byNormalizedExternalId: byNormalizedExternalId,
            byStableKey: byStableKey,
            bySourceAndRawExternalId: bySourceAndRawExternalId,
            byHydrationIdentifier: byHydrationIdentifier,
            positionsByTeamsKey: positionsByTeamsKey
        )
    }

    /// True when this index still describes `matches` exactly.
    func isValid(for matches: [LiveMatch]) -> Bool {
        matches.count == sourceCount && Self.signature(of: matches) == sourceSignature
    }

    /// Hydration-relevant content digest. Cheap enough to run per lookup batch; catches score,
    /// status, clock, timeline, and ordering changes that would make a cached index stale.
    static func signature(of matches: [LiveMatch]) -> Int {
        var hasher = Hasher()
        hasher.combine(matches.count)
        for match in matches {
            hasher.combine(match.id)
            hasher.combine(match.externalId)
            hasher.combine(match.source)
            hasher.combine(match.scoreHome)
            hasher.combine(match.scoreAway)
            hasher.combine(match.scoresAreAvailable)
            hasher.combine(match.matchStatus)
            hasher.combine(match.rawMatchStatus)
            hasher.combine(match.minute)
            hasher.combine(match.liveClockText)
            hasher.combine(match.startTime)
            hasher.combine(match.timelineEvents.count)
        }
        return hasher.finalize()
    }

    // MARK: - Lookup

    /// Same tier order and comparison rules as the original linear scan.
    func firstMatch(
        for saved: SavedProGame,
        in matches: [LiveMatch]
    ) -> (match: LiveMatch, matchedBy: String)? {
        guard matches.count == sourceCount else { return nil }

        // Tier 1 — direct id (saved.id or saved.stableKey against match.id).
        let savedId = SavedProGame.normalizedHydrationToken(saved.id)
        let savedStableKey = SavedProGame.normalizedHydrationToken(saved.stableKey)
        if let position = lowestPosition(byNormalizedId[savedId], byNormalizedId[savedStableKey]) {
            return (matches[position], "directId")
        }

        let resolvedProviderId = saved.resolvedProviderExternalId
        let savedFoldedSource = Self.foldedCaseInsensitive(saved.source)

        // Tier 2 — same source + normalized provider external id.
        if !savedFoldedSource.isEmpty, let providerId = resolvedProviderId {
            let key = Self.sourceScopedKey(
                source: savedFoldedSource,
                external: SavedProGame.normalizedHydrationToken(providerId)
            )
            if let position = bySourceAndNormalizedExternalId[key] {
                return (matches[position], "directExternalId")
            }
        }

        // Tier 3 — normalized provider external id, any source.
        if let providerId = resolvedProviderId,
           let position = byNormalizedExternalId[SavedProGame.normalizedHydrationToken(providerId)] {
            return (matches[position], "directExternalId")
        }

        // Tier 4 — stable key.
        if let position = byStableKey[saved.stableKey] {
            return (matches[position], "stableKey")
        }

        // Tier 5 — same source + raw external id.
        if !savedFoldedSource.isEmpty {
            let rawExternal = Self.foldedCaseInsensitive(saved.externalId)
            if !rawExternal.isEmpty {
                let key = Self.sourceScopedKey(source: savedFoldedSource, external: rawExternal)
                if let position = bySourceAndRawExternalId[key] {
                    return (matches[position], "source+externalId")
                }
            }
        }

        // Tier 6 — any shared provider identifier (lowest position across all shared keys).
        let savedIdentifiers = Self.hydrationIdentifiers(
            id: saved.id,
            externalId: saved.externalId,
            source: saved.source
        )
        if !savedIdentifiers.isEmpty {
            var best: Int?
            for identifier in savedIdentifiers {
                guard let position = byHydrationIdentifier[identifier] else { continue }
                if best == nil || position < best! { best = position }
            }
            if let position = best {
                return (matches[position], "providerId")
            }
        }

        // Tier 7 — teams + date fallback; requires exactly one qualifying row, as before.
        let savedAway = LiveMatchFilters.normalizedSearchText(saved.awayTeam)
        let savedHome = LiveMatchFilters.normalizedSearchText(saved.homeTeam)
        guard !savedAway.isEmpty, !savedHome.isEmpty else { return nil }
        guard let candidatePositions = positionsByTeamsKey[Self.teamsKey(away: saved.awayTeam, home: saved.homeTeam)] else {
            return nil
        }

        let savedLeague = LiveMatchFilters.normalizedSearchText(saved.league)
        let savedSport = LiveSportVisualType.normalize(saved.sport)
        var fallbackPosition: Int?
        for position in candidatePositions {
            let match = matches[position]
            let startsNearSavedTime = abs(match.startTime.timeIntervalSince(saved.startTime)) <= 6 * 60 * 60
            let sameDay = Calendar.current.isDate(match.startTime, inSameDayAs: saved.startTime)
            guard startsNearSavedTime || sameDay else { continue }
            guard savedSport == LiveSportVisualType.normalize(match.sport) else { continue }

            let matchLeague = LiveMatchFilters.normalizedSearchText(match.league)
            if !savedLeague.isEmpty, !matchLeague.isEmpty, savedLeague != matchLeague, !startsNearSavedTime {
                continue
            }
            // More than one qualifying row is ambiguous — same as the previous `count == 1` guard.
            if fallbackPosition != nil { return nil }
            fallbackPosition = position
        }
        guard let position = fallbackPosition else { return nil }
        return (matches[position], "teams+date")
    }

    // MARK: - Key helpers

    private func lowestPosition(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (l?, r?): return min(l, r)
        case let (l?, nil): return l
        case let (nil, r?): return r
        default: return nil
        }
    }

    /// Equivalent to `caseInsensitiveCompare(_:) == .orderedSame` on trimmed values.
    private static func foldedCaseInsensitive(_ raw: String?) -> String {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return ""
        }
        return trimmed.folding(options: .caseInsensitive, locale: nil)
    }

    private static func sourceScopedKey(source: String, external: String) -> String {
        guard !source.isEmpty, !external.isEmpty else { return "" }
        return "\(source)\u{1}\(external)"
    }

    private static func teamsKey(away: String, home: String) -> String {
        let awayKey = LiveMatchFilters.normalizedSearchText(away)
        let homeKey = LiveMatchFilters.normalizedSearchText(home)
        guard !awayKey.isEmpty, !homeKey.isEmpty else { return "" }
        return "\(awayKey)\u{1}\(homeKey)"
    }

    /// Mirrors `MapViewModel.savedProGameHydrationIdentifiers(id:externalId:source:)`.
    static func hydrationIdentifiers(id: String, externalId: String?, source: String?) -> Set<String> {
        var identifiers = Set<String>()
        for raw in [id, externalId].compactMap({ $0 }) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            insert(trimmed, into: &identifiers)
            if let last = trimmed.split(separator: ":").last {
                insert(String(last), into: &identifiers)
            }
            if let source {
                let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalizedSource.isEmpty {
                    insert("\(normalizedSource):\(trimmed)", into: &identifiers)
                }
            }
        }
        return identifiers
    }

    private static func insert(_ raw: String, into identifiers: inout Set<String>) {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        guard !normalized.isEmpty else { return }
        identifiers.insert(normalized)
    }
}
