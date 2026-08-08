import Foundation

/// Internal FanGeo chat professional-game share payload (encoded in message body — no migration).
nonisolated struct ProGameSharePayload: Codable, Equatable, Sendable {
    let v: Int
    let gameId: String
    let stableKey: String
    let sport: String
    let league: String
    let homeTeam: String
    let awayTeam: String
    let startTimeISO: String
    /// `upcoming` | `live` | `final`
    let status: String
    let scoreHome: Int?
    let scoreAway: Int?
    let venueName: String?
    let source: String?
    let externalId: String?
    let sharedByName: String?

    enum CodingKeys: String, CodingKey {
        case v
        case gameId = "game_id"
        case stableKey = "stable_key"
        case sport
        case league
        case homeTeam = "home_team"
        case awayTeam = "away_team"
        case startTimeISO = "start_time"
        case status
        case scoreHome = "score_home"
        case scoreAway = "score_away"
        case venueName = "venue_name"
        case source
        case externalId = "external_id"
        case sharedByName = "shared_by_name"
    }

    init(
        gameId: String,
        stableKey: String,
        sport: String,
        league: String,
        homeTeam: String,
        awayTeam: String,
        startTimeISO: String,
        status: String,
        scoreHome: Int?,
        scoreAway: Int?,
        venueName: String?,
        source: String?,
        externalId: String?,
        sharedByName: String?
    ) {
        self.v = 1
        self.gameId = gameId
        self.stableKey = stableKey
        self.sport = sport
        self.league = league
        self.homeTeam = homeTeam
        self.awayTeam = awayTeam
        self.startTimeISO = startTimeISO
        self.status = status
        self.scoreHome = scoreHome
        self.scoreAway = scoreAway
        self.venueName = venueName
        self.source = source
        self.externalId = externalId
        self.sharedByName = sharedByName
    }
}

enum ProGameShareMessage {
    nonisolated static let sentinel = "__FG_PRO_SHARE_V1__"

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func payload(
        from game: SavedProGame,
        sharedByDisplayName: String
    ) -> ProGameSharePayload? {
        let home = game.homeTeam.trimmingCharacters(in: .whitespacesAndNewlines)
        let away = game.awayTeam.trimmingCharacters(in: .whitespacesAndNewlines)
        let gameId = game.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !home.isEmpty, !away.isEmpty, !gameId.isEmpty else { return nil }

        let status: String
        if game.isFinal {
            status = "final"
        } else if game.matchStatus.isHappeningNow {
            status = "live"
        } else {
            status = "upcoming"
        }

        let startISO = isoFormatter.string(from: game.startTime)

        let includeScores = game.isFinal || game.matchStatus.isHappeningNow

        return ProGameSharePayload(
            gameId: gameId,
            stableKey: game.stableKey,
            sport: game.sport,
            league: game.league,
            homeTeam: home,
            awayTeam: away,
            startTimeISO: startISO,
            status: status,
            scoreHome: includeScores ? game.scoreHome : nil,
            scoreAway: includeScores ? game.scoreAway : nil,
            venueName: nil,
            source: game.source?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            externalId: game.externalId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            sharedByName: sharedByDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    static func encodeBody(payload: ProGameSharePayload) -> String {
        let preview = previewLine(for: payload)
        guard let jsonData = try? JSONEncoder().encode(payload),
              let json = String(data: jsonData, encoding: .utf8) else {
            return preview
        }
        return "\(preview)\n\(sentinel)\(json)"
    }

    /// Pure sentinel + JSON decode — no MainActor state.
    nonisolated static func decode(from body: String) -> ProGameSharePayload? {
        guard let range = body.range(of: sentinel) else { return nil }
        let jsonPart = body[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonPart.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ProGameSharePayload.self, from: data),
              payload.v == 1 else {
            return nil
        }
        return payload
    }

    static func inboxPreview(from body: String) -> String? {
        if let payload = decode(from: body) {
            return previewLine(for: payload)
        }
        guard let sentinelRange = body.range(of: sentinel) else { return nil }
        let prefix = body[..<sentinelRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? "Shared a FanGeo professional game" : prefix
    }

    static func previewLine(for payload: ProGameSharePayload) -> String {
        let sharer = payload.sharedByName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sharerPrefix = (sharer?.isEmpty == false)
            ? "\(sharer!) shared a FanGeo pro game: "
            : "Shared a FanGeo pro game: "
        let sport = AppSportCatalog.displayLabel(forSportToken: payload.sport)
        return "\(sharerPrefix)\(payload.awayTeam) at \(payload.homeTeam) · \(sport)"
    }

    static func parseStartTime(_ iso: String) -> Date? {
        if let d = isoFormatter.date(from: iso) { return d }
        return isoFormatterNoFraction.date(from: iso)
    }

    static func matchStatus(fromShareStatus status: String) -> MatchStatus {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "final", "ft", "fulltime", "full_time":
            return .fullTime
        case "live", "ht", "halftime", "half_time":
            return .live
        default:
            return .scheduled
        }
    }

    /// Builds a `LiveMatch` snapshot from the share payload when live/saved resolution fails.
    static func reconstructedLiveMatch(from payload: ProGameSharePayload) -> LiveMatch? {
        let gameId = payload.gameId.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = payload.homeTeam.trimmingCharacters(in: .whitespacesAndNewlines)
        let away = payload.awayTeam.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gameId.isEmpty, !home.isEmpty, !away.isEmpty else { return nil }
        guard let start = parseStartTime(payload.startTimeISO) else { return nil }

        let status = matchStatus(fromShareStatus: payload.status)
        let scoreHome = payload.scoreHome ?? 0
        let scoreAway = payload.scoreAway ?? 0
        let scoresAvailable = payload.scoreHome != nil || payload.scoreAway != nil || status == .fullTime || status.isHappeningNow

        return LiveMatch(
            id: gameId,
            source: payload.source,
            externalId: payload.externalId,
            sport: payload.sport,
            homeTeam: home,
            awayTeam: away,
            scoreHome: scoreHome,
            scoreAway: scoreAway,
            scoresAreAvailable: scoresAvailable,
            matchStatus: status,
            rawMatchStatus: payload.status.uppercased(),
            minute: nil,
            liveClockText: nil,
            league: payload.league,
            sourceLeagueName: nil,
            eventName: nil,
            leagueAlternate: nil,
            sourceSportName: nil,
            startTime: start,
            venueName: payload.venueName,
            venueCity: nil,
            venueLatitude: nil,
            venueLongitude: nil,
            leagueCountry: nil,
            tvBroadcasts: [],
            timelineEvents: [],
            featuredEventSlug: nil,
            homeTeamBadgeURL: nil,
            awayTeamBadgeURL: nil
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
