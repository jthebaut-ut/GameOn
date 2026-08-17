import Foundation
import Supabase

/// Reads durable provider artwork from `sports_provider_identities`.
/// Never calls TheSportsDB and never invokes `sync-sports-provider-artwork`.
actor SportsProviderArtworkService {
    static let shared = SportsProviderArtworkService()

    private static let clientCacheTTL: TimeInterval = 24 * 60 * 60
    private static let emptyTableRetryTTL: TimeInterval = 30 * 60
    private static let lastFetchKey = "fangeo.sportsProviderArtwork.lastFetchAt"

    private var inFlight: Task<Void, Never>?
    private var lastMemoryFetchAt: Date?

    func refreshIfStale() async {
        if let inFlight {
            await inFlight.value
            return
        }
        SportsProviderAthleteCatalog.loadPersistedIfNeeded()
        if let persisted = UserDefaults.standard.object(forKey: Self.lastFetchKey) as? Date,
           Date().timeIntervalSince(persisted) < Self.clientCacheTTL {
            lastMemoryFetchAt = persisted
            return
        }
        if let lastMemoryFetchAt, Date().timeIntervalSince(lastMemoryFetchAt) < Self.emptyTableRetryTTL {
            return
        }
        let task = Task { await self.fetchAndIngest() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    func refreshForTests(rows: [SportsProviderIdentityRow]) {
        SportsProviderArtworkIngest.ingest(rows)
        SportsProviderAthleteCatalog.ingestIdentityRows(rows)
    }

    private func fetchAndIngest() async {
        do {
            var rows: [SportsProviderIdentityRow] = []
            var from = 0
            let pageSize = 1000
            let maxRows = 12000
            while from < maxRows {
                let page: [SportsProviderIdentityRow] = try await supabase
                    .from("sports_provider_identities")
                    .select(
                        "catalog_id,kind,provider,provider_team_id,provider_player_id,canonical_name,league,sport,country,badge_url,logo_url,player_cutout_url,player_creative_commons"
                    )
                    .range(from: from, to: from + pageSize - 1)
                    .execute()
                    .value
                rows.append(contentsOf: page)
                if page.count < pageSize { break }
                from += pageSize
            }
            SportsProviderArtworkIngest.ingest(rows)
            SportsProviderAthleteCatalog.ingestIdentityRows(rows)
            let now = Date()
            lastMemoryFetchAt = now
            if rows.contains(where: { SportsArtworkURLStore.isTheSportsDBArtworkURL($0.badgeUrl) || ($0.playerCreativeCommons == true && SportsArtworkURLStore.isTheSportsDBArtworkURL($0.playerCutoutUrl)) }) || rows.contains(where: { $0.kind == "player" }) {
                UserDefaults.standard.set(now, forKey: Self.lastFetchKey)
            }
#if DEBUG
            print("[SportsProviderArtwork] ingested rows=\(rows.count) theSportsDB=false")
#endif
        } catch {
#if DEBUG
            print("[SportsProviderArtwork] fetch skipped error=\(error.localizedDescription)")
#endif
        }
    }
}
