import Foundation

/// Artwork coordinator for professional identities.
///
/// Production TheSportsDB access lives in `sync-live-matches` and
/// `sync-sports-provider-artwork` (Supabase secret `THESPORTSDB_API_KEY`).
/// iOS reads badges from `live_matches.payload` and `sports_provider_identities`.
/// This service must not call TheSportsDB and must not use the free test key `123`.
actor SportsArtworkEnrichmentService {
    static let shared = SportsArtworkEnrichmentService()

    /// Direct TheSportsDB HTTP from iOS is intentionally disabled.
    nonisolated static let usesDirectTheSportsDBAPI = false

    func enrich(favorites: [FavoriteTeam]) async {
        _ = favorites
        await SportsProviderArtworkService.shared.refreshIfStale()
        SportsArtworkURLStore.shared.persistAndPublish()
    }

    /// Re-ingest already-fetched `live_matches` so Profile can resolve crests
    /// without waiting for the Live tab to render. No extra network request.
    nonisolated func ingestFromAlreadyFetchedLiveMatches(_ matches: [LiveMatch]) {
        SportsArtworkURLStore.shared.ingestLiveMatches(matches)
    }

    func enrichLeague(_ leagueName: String) async {
        _ = leagueName
        await SportsProviderArtworkService.shared.refreshIfStale()
    }

    func enrichNamedTeam(name: String, sport: FavoriteTeamSport?, league: String?) async {
        _ = (name, sport, league)
        await SportsProviderArtworkService.shared.refreshIfStale()
    }
}
