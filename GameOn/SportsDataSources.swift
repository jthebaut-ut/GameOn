import Foundation

enum SportsDataProvider: String, CaseIterable {
    case theSportsDB
    case apiSports
    case sportsDataIO
    case sportradar
}

struct SportsDataSourceConfig {
    let provider: SportsDataProvider
    let isEnabled: Bool
    let apiKey: String
    let baseURL: String
}

struct SportsDataSources {

    static let sources: [SportsDataSourceConfig] = [

        // MARK: - TheSportsDB
        //
        // Live scores / schedules / statuses do NOT use this key.
        // Those come from Supabase `live_matches`, filled by `sync-live-matches`
        // with the paid `THESPORTSDB_API_KEY` secret.
        //
        // This client entry is only the free test key for `SportsAPIService`
        // venue-calendar `eventsday.php`. Artwork must not use this path.

        SportsDataSourceConfig(
            provider: .theSportsDB,
            isEnabled: true,
            apiKey: "123",
            baseURL: "https://www.thesportsdb.com/api/v1/json"
        ),

        // MARK: - API-SPORTS

        SportsDataSourceConfig(
            provider: .apiSports,
            isEnabled: false,
            apiKey: "YOUR_API_SPORTS_KEY",
            baseURL: "https://v3.football.api-sports.io"
        ),

        // MARK: - SportsDataIO

        SportsDataSourceConfig(
            provider: .sportsDataIO,
            isEnabled: false,
            apiKey: "YOUR_SPORTSDATAIO_KEY",
            baseURL: "https://api.sportsdata.io/v3"
        ),

        // MARK: - Sportradar

        SportsDataSourceConfig(
            provider: .sportradar,
            isEnabled: false,
            apiKey: "YOUR_SPORTRADAR_KEY",
            baseURL: "https://api.sportradar.com"
        )
    ]
}
