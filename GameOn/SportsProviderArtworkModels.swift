import Foundation

/// Read-only row from `public.sports_provider_identities`.
nonisolated struct SportsProviderIdentityRow: Decodable, Equatable, Sendable {
    let catalogId: String
    let kind: String
    let provider: String
    let providerTeamId: String?
    let providerPlayerId: String?
    let canonicalName: String
    let league: String?
    let sport: String?
    let country: String?
    let badgeUrl: String?
    let logoUrl: String?
    let playerCutoutUrl: String?
    let playerCreativeCommons: Bool?

    enum CodingKeys: String, CodingKey {
        case catalogId = "catalog_id"
        case kind
        case provider
        case providerTeamId = "provider_team_id"
        case providerPlayerId = "provider_player_id"
        case canonicalName = "canonical_name"
        case league
        case sport
        case country
        case badgeUrl = "badge_url"
        case logoUrl = "logo_url"
        case playerCutoutUrl = "player_cutout_url"
        case playerCreativeCommons = "player_creative_commons"
    }
}

/// Parses provider identity rows into ``SportsArtworkURLStore``.
/// The store is already a lock-protected nonisolated cache; ingest is not UI work.
nonisolated enum SportsProviderArtworkIngest {
    static func ingest(_ rows: [SportsProviderIdentityRow]) {
        guard !rows.isEmpty else { return }
        var ingestedAny = false
        for row in rows {
            switch row.kind {
            case "player":
                guard row.playerCreativeCommons == true else { continue }
                let image = row.playerCutoutUrl
                guard SportsArtworkURLStore.isTheSportsDBArtworkURL(image) else { continue }
                SportsArtworkURLStore.shared.ingestPlayer(
                    playerName: row.canonicalName,
                    imageURL: image
                )
                ingestedAny = true
            case "league":
                let badge = row.badgeUrl ?? row.logoUrl
                guard SportsArtworkURLStore.isTheSportsDBArtworkURL(badge) else { continue }
                SportsArtworkURLStore.shared.ingestLeague(
                    name: row.canonicalName,
                    badgeURL: badge,
                    catalogId: row.catalogId
                )
                ingestedAny = true
            default:
                let badge = row.badgeUrl ?? row.logoUrl
                guard SportsArtworkURLStore.isTheSportsDBArtworkURL(badge) else { continue }
                SportsArtworkURLStore.shared.ingestCatalogIdentity(
                    catalogId: row.catalogId,
                    providerId: row.providerTeamId,
                    league: row.league,
                    teamName: row.canonicalName,
                    badgeURL: badge
                )
                ingestedAny = true
            }
        }
        if ingestedAny {
            SportsArtworkURLStore.shared.persistAndPublish()
        }
    }
}
