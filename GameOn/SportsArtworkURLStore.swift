import Foundation
import Combine
import CoreGraphics

/// In-memory + UserDefaults cache of TheSportsDB artwork URLs keyed by provider ID, then league+name.
/// Populated from live-match payloads and coalesced league/player lookups — never per visible row.
nonisolated final class SportsArtworkURLStore: @unchecked Sendable {
    static let shared = SportsArtworkURLStore()

    private let lock = NSLock()
    private var badgeByProviderId: [String: String] = [:]
    private var badgeByCatalogId: [String: String] = [:]
    private var badgeByNameKey: [String: String] = [:]
    private var playerByNameKey: [String: String] = [:]
    private var leagueByNameKey: [String: String] = [:]
    private var negativeKeys: [String: Date] = [:]
    private var persistedLoaded = false
    /// Cheap skip for live-score polls that reuse the same badge URLs.
    private var lastLiveMatchesIngestFingerprint: Int?
    private var publishedRevision: UInt64 = 0

    private static let persistKey = "fangeo.sportsArtwork.urlCache.v1"
    private static let negativeTTL: TimeInterval = 24 * 60 * 60
    private static let maxPersistedEntries = 800

    private init() {
        loadPersistedIfNeeded()
    }

    // MARK: - Host policy

    /// Official TheSportsDB image hosts (API-returned URLs only).
    static func isTheSportsDBArtworkURL(_ raw: String?) -> Bool {
        guard let url = URL(string: Self.trimmed(raw) ?? "") else { return false }
        let host = (url.host ?? "").lowercased()
        return host == "www.thesportsdb.com"
            || host == "thesportsdb.com"
            || host == "r2.thesportsdb.com"
            || host.hasSuffix(".thesportsdb.com")
    }

    /// Official size variants (`/tiny`, `/small`) — not a modification of the trademarked asset.
    static func displayURL(from raw: String?, diameter: CGFloat) -> URL? {
        guard let trimmed = Self.trimmed(raw), let url = URL(string: trimmed) else { return nil }
        guard isTheSportsDBArtworkURL(trimmed) else { return url }
        let path = url.path.lowercased()
        if path.hasSuffix("/tiny") || path.hasSuffix("/small") || path.hasSuffix("/medium") {
            return url
        }
        let suffix = diameter <= 48 ? "/tiny" : "/small"
        return URL(string: trimmed + suffix) ?? url
    }

    // MARK: - Lookup

    func badgeURL(
        providerId: String? = nil,
        league: String? = nil,
        teamName: String
    ) -> String? {
        loadPersistedIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        if let id = normalizedId(providerId), let url = badgeByProviderId[id] {
            return url
        }
        let name = normalizedName(teamName)
        guard !name.isEmpty else { return nil }
        if let leagueKey = nameKey(league: league, name: teamName), let url = badgeByNameKey[leagueKey] {
            return url
        }
        return badgeByNameKey[nameOnlyKey(name)]
    }

    func badgeURL(catalogId: String) -> String? {
        loadPersistedIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        guard let id = normalizedId(catalogId) else { return nil }
        return badgeByCatalogId[id]
    }

    func playerImageURL(playerName: String) -> String? {
        loadPersistedIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return playerByNameKey[nameOnlyKey(normalizedName(playerName))]
    }

    func leagueBadgeURL(leagueName: String) -> String? {
        loadPersistedIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return leagueByNameKey[nameOnlyKey(normalizedName(leagueName))]
    }

    func hasNegativeLookup(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let at = negativeKeys[key] else { return false }
        if Date().timeIntervalSince(at) > Self.negativeTTL {
            negativeKeys.removeValue(forKey: key)
            return false
        }
        return true
    }

    func recordNegativeLookup(_ key: String) {
        lock.lock()
        negativeKeys[key] = Date()
        lock.unlock()
    }

    // MARK: - Ingest

    @discardableResult
    func ingestLiveMatch(_ match: LiveMatch) -> Bool {
        var changed = false
        if ingestTeam(
            providerId: match.homeTeamProviderId,
            league: match.sourceLeagueName ?? match.league,
            teamName: match.homeTeam,
            badgeURL: match.homeTeamBadgeURL
        ) {
            changed = true
        }
        if ingestTeam(
            providerId: match.awayTeamProviderId,
            league: match.sourceLeagueName ?? match.league,
            teamName: match.awayTeam,
            badgeURL: match.awayTeamBadgeURL
        ) {
            changed = true
        }
        if let leagueBadge = match.leagueBadgeURL,
           ingestLeague(name: match.sourceLeagueName ?? match.league, badgeURL: leagueBadge) {
            changed = true
        }
        return changed
    }

    func ingestLiveMatches(_ matches: [LiveMatch]) {
        guard !matches.isEmpty else { return }
        var hasher = Hasher()
        hasher.combine(matches.count)
        for match in matches {
            hasher.combine(match.homeTeamBadgeURL)
            hasher.combine(match.awayTeamBadgeURL)
            hasher.combine(match.leagueBadgeURL)
            hasher.combine(match.homeTeamProviderId)
            hasher.combine(match.awayTeamProviderId)
        }
        let fingerprint = hasher.finalize()
        lock.lock()
        let previousFingerprint = lastLiveMatchesIngestFingerprint
        lock.unlock()
        if fingerprint == previousFingerprint {
#if DEBUG
            SwiftUIRecompPerf.log(
                "artworkIngest skipped identicalLiveMatches count=\(matches.count)",
                key: "artwork.ingestSkip"
            )
#endif
            return
        }

        var changed = false
        for match in matches {
            if ingestLiveMatch(match) { changed = true }
        }
        lock.lock()
        lastLiveMatchesIngestFingerprint = fingerprint
        lock.unlock()
        guard changed else {
#if DEBUG
            SwiftUIRecompPerf.log(
                "artworkIngest skipped unchangedMaps count=\(matches.count)",
                key: "artwork.ingestSkip"
            )
#endif
            return
        }
        persist()
        bumpEpoch()
    }

    @discardableResult
    func ingestTeam(
        providerId: String?,
        league: String?,
        teamName: String,
        badgeURL: String?
    ) -> Bool {
        guard let url = Self.trimmed(badgeURL), Self.isTheSportsDBArtworkURL(url) else { return false }
        let name = normalizedName(teamName)
        guard !name.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        if let id = normalizedId(providerId), badgeByProviderId[id] != url {
            badgeByProviderId[id] = url
            changed = true
        }
        if let leagueKey = nameKey(league: league, name: teamName), badgeByNameKey[leagueKey] != url {
            badgeByNameKey[leagueKey] = url
            changed = true
        }
        let only = nameOnlyKey(name)
        if badgeByNameKey[only] != url {
            badgeByNameKey[only] = url
            changed = true
        }
        return changed
    }

    func ingestCatalogIdentity(
        catalogId: String,
        providerId: String?,
        league: String?,
        teamName: String,
        badgeURL: String?
    ) {
        ingestTeam(
            providerId: providerId,
            league: league,
            teamName: teamName,
            badgeURL: badgeURL
        )
        guard let url = Self.trimmed(badgeURL), Self.isTheSportsDBArtworkURL(url) else { return }
        guard let id = normalizedId(catalogId) else { return }
        lock.lock()
        if badgeByCatalogId[id] != url {
            badgeByCatalogId[id] = url
        }
        lock.unlock()
    }

    func ingestPlayer(playerName: String, imageURL: String?) {
        guard let url = Self.trimmed(imageURL), Self.isTheSportsDBArtworkURL(url) else { return }
        let name = normalizedName(playerName)
        guard !name.isEmpty else { return }
        lock.lock()
        let key = nameOnlyKey(name)
        let changed = playerByNameKey[key] != url
        playerByNameKey[key] = url
        lock.unlock()
        guard changed else { return }
        persist()
        bumpEpoch()
    }

    @discardableResult
    func ingestLeague(name: String, badgeURL: String?, catalogId: String? = nil) -> Bool {
        guard let url = Self.trimmed(badgeURL), Self.isTheSportsDBArtworkURL(url) else { return false }
        let key = nameOnlyKey(normalizedName(name))
        guard !key.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        if leagueByNameKey[key] != url {
            leagueByNameKey[key] = url
            changed = true
        }
        if let id = normalizedId(catalogId), badgeByCatalogId[id] != url {
            badgeByCatalogId[id] = url
            changed = true
        }
        return changed
    }

    func persistAndPublish() {
        persist()
        bumpEpoch()
    }

    // MARK: - Keys

    static func lookupKey(kind: String, name: String, league: String? = nil) -> String {
        let n = shared.normalizedName(name)
        if let league, !league.isEmpty {
            return "\(kind)|\(shared.normalizedName(league))|\(n)"
        }
        return "\(kind)|\(n)"
    }

    private func nameKey(league: String?, name: String) -> String? {
        let n = normalizedName(name)
        guard !n.isEmpty else { return nil }
        let l = normalizedName(league ?? "")
        guard !l.isEmpty else { return nil }
        return "l:\(l)|n:\(n)"
    }

    private func nameOnlyKey(_ name: String) -> String {
        "n:\(name)"
    }

    private func normalizedName(_ raw: String) -> String {
        raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func normalizedId(_ raw: String?) -> String? {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value.lowercased()
    }

    private static func trimmed(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func bumpEpoch() {
        lock.lock()
        publishedRevision &+= 1
        lock.unlock()
        Task { @MainActor in
            SportsArtworkEpoch.shared.bump()
        }
    }

    func currentPublishedRevision() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return publishedRevision
    }

    // MARK: - Persistence

    private func loadPersistedIfNeeded() {
        lock.lock()
        if persistedLoaded {
            lock.unlock()
            return
        }
        persistedLoaded = true
        lock.unlock()
        guard let data = UserDefaults.standard.data(forKey: Self.persistKey),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else {
            return
        }
        lock.lock()
        badgeByProviderId.merge(decoded.badgeByProviderId) { _, new in new }
        badgeByCatalogId.merge(decoded.badgeByCatalogId ?? [:]) { _, new in new }
        badgeByNameKey.merge(decoded.badgeByNameKey) { _, new in new }
        playerByNameKey.merge(decoded.playerByNameKey) { _, new in new }
        leagueByNameKey.merge(decoded.leagueByNameKey) { _, new in new }
        lock.unlock()
    }

    private func persist() {
        lock.lock()
        let snapshot = Persisted(
            badgeByProviderId: trimmedMap(badgeByProviderId),
            badgeByCatalogId: trimmedMap(badgeByCatalogId),
            badgeByNameKey: trimmedMap(badgeByNameKey),
            playerByNameKey: trimmedMap(playerByNameKey),
            leagueByNameKey: trimmedMap(leagueByNameKey)
        )
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.persistKey)
        }
    }

    private func trimmedMap(_ map: [String: String]) -> [String: String] {
        if map.count <= Self.maxPersistedEntries { return map }
        return Dictionary(uniqueKeysWithValues: map.suffix(Self.maxPersistedEntries).map { ($0.key, $0.value) })
    }

    private struct Persisted: Codable {
        var badgeByProviderId: [String: String]
        var badgeByCatalogId: [String: String]?
        var badgeByNameKey: [String: String]
        var playerByNameKey: [String: String]
        var leagueByNameKey: [String: String]
    }

#if DEBUG
    func resetForTests() {
        lock.lock()
        badgeByProviderId = [:]
        badgeByCatalogId = [:]
        badgeByNameKey = [:]
        playerByNameKey = [:]
        leagueByNameKey = [:]
        negativeKeys = [:]
        persistedLoaded = true
        lastLiveMatchesIngestFingerprint = nil
        lock.unlock()
    }

    func pushTestIsolation() -> Data? {
        loadPersistedIfNeeded()
        let snapshot = UserDefaults.standard.data(forKey: Self.persistKey)
        resetForTests()
        return snapshot
    }

    func popTestIsolation(_ snapshot: Data?) {
        resetForTests()
        if let snapshot {
            UserDefaults.standard.set(snapshot, forKey: Self.persistKey)
        }
        lock.lock()
        persistedLoaded = false
        badgeByProviderId = [:]
        badgeByCatalogId = [:]
        badgeByNameKey = [:]
        playerByNameKey = [:]
        leagueByNameKey = [:]
        negativeKeys = [:]
        lastLiveMatchesIngestFingerprint = nil
        lock.unlock()
        loadPersistedIfNeeded()
        bumpEpoch()
    }
#endif
}

@MainActor
final class SportsArtworkEpoch: ObservableObject {
    static let shared = SportsArtworkEpoch()
    @Published private(set) var generation: UInt64 = 0

    func bump() {
        generation &+= 1
#if DEBUG
        SwiftUIRecompPerf.log("artworkEpochBump generation=\(generation)", key: "artwork.epoch")
#endif
    }
}
