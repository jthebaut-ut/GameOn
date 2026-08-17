import Foundation

/// Copies already-fetched `live_matches` badge URLs onto favorite catalog identities.
/// Game cards read `strHomeTeamBadge` from the row; favorites previously only reverse-looked-up
/// the store by catalog name, so the same payload never reached the Favorite Teams row.
enum SportsFavoriteArtworkHydration {
    private static let lock = NSLock()
    private static var lastIngestFingerprint: Int?

    static func ingest(favorites: [FavoriteTeam], from matches: [LiveMatch]) {
        guard !favorites.isEmpty, !matches.isEmpty else { return }
        var hasher = Hasher()
        hasher.combine(favorites.count)
        hasher.combine(matches.count)
        for favorite in favorites {
            hasher.combine(favorite.id)
        }
        for match in matches {
            hasher.combine(match.homeTeamBadgeURL)
            hasher.combine(match.awayTeamBadgeURL)
            hasher.combine(match.homeTeamProviderId)
            hasher.combine(match.awayTeamProviderId)
        }
        let fingerprint = hasher.finalize()
        lock.lock()
        let previous = lastIngestFingerprint
        lock.unlock()
        if previous == fingerprint {
            return
        }

        var ingestedAny = false
        for favorite in favorites {
            switch favorite.kind {
            case .team, .nationalTeam, .interest:
                if ingestTeamFavorite(favorite, from: matches) {
                    ingestedAny = true
                }
            case .player, .driver, .fighter, .league, .competition, .tournament:
                continue
            }
        }
        lock.lock()
        lastIngestFingerprint = fingerprint
        lock.unlock()
        if ingestedAny {
            SportsArtworkURLStore.shared.persistAndPublish()
        }
    }

    private static func ingestTeamFavorite(_ favorite: FavoriteTeam, from matches: [LiveMatch]) -> Bool {
        for match in matches {
            guard let side = FavoriteTeamLiveMatcher.matchingSide(for: favorite, match: match) else {
                continue
            }
            let badge: String?
            let providerId: String?
            switch side {
            case .home:
                badge = match.homeTeamBadgeURL
                providerId = match.homeTeamProviderId
            case .away:
                badge = match.awayTeamBadgeURL
                providerId = match.awayTeamProviderId
            }
            guard SportsArtworkURLStore.isTheSportsDBArtworkURL(badge) else { continue }
            let liveLeague = match.sourceLeagueName ?? match.league
            SportsArtworkURLStore.shared.ingestTeam(
                providerId: providerId,
                league: liveLeague,
                teamName: favorite.name,
                badgeURL: badge
            )
            SportsArtworkURLStore.shared.ingestTeam(
                providerId: providerId,
                league: favorite.league,
                teamName: favorite.name,
                badgeURL: badge
            )
            return true
        }
        return false
    }
}
