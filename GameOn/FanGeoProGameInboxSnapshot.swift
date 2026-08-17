import Foundation

/// Durable professional-game score snapshot for Inbox rows.
///
/// Render **only** from these stored fields. Never parse title/body text
/// to invent teams, scores, scoring team, or a winner.
struct FanGeoProGameInboxSnapshot: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case score
        case final
        case kickoff
        case halftime

        var notificationTypeToken: String {
            switch self {
            case .score: return "pro_game_score"
            case .final: return "pro_game_final"
            case .kickoff: return "pro_game_kickoff"
            case .halftime: return "pro_game_halftime"
            }
        }

        var badgeKey: String {
            switch self {
            case .score: return "action_center_pro_game_badge_score_update"
            case .final: return "action_center_pro_game_badge_final"
            case .kickoff: return "action_center_pro_game_badge_kickoff"
            case .halftime: return "action_center_pro_game_badge_halftime"
            }
        }

        static func from(
            notificationType: String?,
            sourceType: String? = nil,
            matchStatus: String? = nil
        ) -> Kind? {
            let raw = (notificationType ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let source = (sourceType ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            switch raw {
            case "pro_game_score", "pro_game_goal", "score", "goal":
                if source.isEmpty
                    || source == ProGameNotificationDeepLinkPayload.sourceValue
                    || raw.hasPrefix("pro_game_") {
                    return .score
                }
            case "pro_game_final", "final":
                if source.isEmpty
                    || source == ProGameNotificationDeepLinkPayload.sourceValue
                    || raw.hasPrefix("pro_game_") {
                    return .final
                }
            case "pro_game_kickoff", "kickoff":
                if source.isEmpty
                    || source == ProGameNotificationDeepLinkPayload.sourceValue
                    || raw.hasPrefix("pro_game_") {
                    return .kickoff
                }
            case "pro_game_halftime", "halftime":
                if source.isEmpty
                    || source == ProGameNotificationDeepLinkPayload.sourceValue
                    || raw.hasPrefix("pro_game_") {
                    return .halftime
                }
            default:
                break
            }
            if source == ProGameNotificationDeepLinkPayload.sourceValue {
                return kind(fromMatchStatus: matchStatus) ?? .score
            }
            return kind(fromMatchStatus: matchStatus)
        }

        fileprivate static func kind(fromMatchStatus raw: String?) -> Kind? {
            let token = (raw ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            switch token {
            case "FT", "FINAL", "FT-PEN", "AET", "AP", "FULL TIME", "FULLTIME":
                return .final
            case "HT", "HALFTIME", "HALF TIME":
                return .halftime
            case "NS", "TBD", "NOT STARTED":
                return .kickoff
            case "LIVE", "1H", "2H", "ET", "PEN":
                return .score
            default:
                return nil
            }
        }
    }

    enum Outcome: Equatable, Sendable {
        case homeWin
        case awayWin
        case draw
    }

    var kind: Kind
    var matchID: String
    var homeTeam: String
    var awayTeam: String
    var homeScore: Int
    var awayScore: Int
    var scoringTeam: String?
    var league: String?
    var sport: String?
    var matchStatus: String?
    var clock: String?
    var homeBadgeURL: String?
    var awayBadgeURL: String?
    var homeProviderId: String?
    var awayProviderId: String?

    var isRenderable: Bool {
        let home = homeTeam.trimmingCharacters(in: .whitespacesAndNewlines)
        let away = awayTeam.trimmingCharacters(in: .whitespacesAndNewlines)
        return !home.isEmpty && !away.isEmpty && !matchID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Scoring team only when the payload names a side that matches home or away.
    /// Pure snapshot field matching — safe for push payload construction off the main actor.
    nonisolated var identifiedScoringTeam: String? {
        let named = scoringTeam?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !named.isEmpty else { return nil }
        let token = Self.normalizedTeamToken(named)
        if token == Self.normalizedTeamToken(homeTeam) { return homeTeam.trimmingCharacters(in: .whitespacesAndNewlines) }
        if token == Self.normalizedTeamToken(awayTeam) { return awayTeam.trimmingCharacters(in: .whitespacesAndNewlines) }
        return nil
    }

    var finalOutcome: Outcome? {
        guard kind == .final else { return nil }
        if homeScore > awayScore { return .homeWin }
        if awayScore > homeScore { return .awayWin }
        return .draw
    }

    var winnerTeamName: String? {
        switch finalOutcome {
        case .homeWin:
            return homeTeam.trimmingCharacters(in: .whitespacesAndNewlines)
        case .awayWin:
            return awayTeam.trimmingCharacters(in: .whitespacesAndNewlines)
        case .draw, .none:
            return nil
        }
    }

    func isWinner(_ side: Side) -> Bool {
        switch (side, finalOutcome) {
        case (.home, .homeWin), (.away, .awayWin):
            return true
        default:
            return false
        }
    }

    enum Side: Equatable, Hashable, Sendable {
        case home
        case away
    }

    static func from(
        payload: [String: AnyCodableJSON]?,
        notificationType: String?,
        sourceType: String?,
        sourceID: String?
    ) -> FanGeoProGameInboxSnapshot? {
        let map = flattenedPayload(payload)
        let type = notificationType
            ?? map.flatMap { string($0, "notification_type") }
            ?? map.flatMap { string($0, "type") }
        let home = map.flatMap { string($0, "home_team") } ?? ""
        let away = map.flatMap { string($0, "away_team") } ?? ""
        let matchID = map.flatMap { string($0, "match_id") }
            ?? sourceID
            ?? ""
        let matchStatus = map.flatMap { string($0, "match_status") }
        let hasStructuredTeams = !home.isEmpty && !away.isEmpty && !matchID.isEmpty
        let kind = Kind.from(
            notificationType: type,
            sourceType: sourceType ?? map.flatMap { string($0, "source") },
            matchStatus: matchStatus
        ) ?? (hasStructuredTeams ? (Kind.kind(fromMatchStatus: matchStatus) ?? .score) : nil)
        guard let kind else { return nil }
        let sport = map.flatMap { string($0, "sport") }
        let clock = map.flatMap { string($0, "clock") }
            ?? map.flatMap { raw in
                string(raw, "minute").flatMap { minuteClock($0, sport: sport) }
            }
        let snapshot = FanGeoProGameInboxSnapshot(
            kind: kind,
            matchID: matchID,
            homeTeam: home,
            awayTeam: away,
            homeScore: map.flatMap { int($0, "home_score") } ?? 0,
            awayScore: map.flatMap { int($0, "away_score") } ?? 0,
            scoringTeam: map.flatMap { string($0, "scoring_team") },
            league: map.flatMap { string($0, "league") },
            sport: sport,
            matchStatus: matchStatus,
            clock: clock,
            homeBadgeURL: map.flatMap { string($0, "home_badge_url") },
            awayBadgeURL: map.flatMap { string($0, "away_badge_url") },
            homeProviderId: map.flatMap { string($0, "home_provider_id") },
            awayProviderId: map.flatMap { string($0, "away_provider_id") }
        )
        return snapshot.isRenderable ? snapshot : nil
    }

    static func from(userInfo: [AnyHashable: Any], notificationType: String?) -> FanGeoProGameInboxSnapshot? {
        let flat = flattenedUserInfo(userInfo)
        var payload: [String: AnyCodableJSON] = [:]
        for key in Self.payloadKeys {
            if let value = stringValue(flat[key]) {
                payload[key] = .string(value)
            }
        }
        let type = notificationType
            ?? stringValue(flat["notification_type"])
            ?? stringValue(flat["type"])
        let source = stringValue(flat["source"])
        let sourceID = stringValue(flat["match_id"])
            ?? stringValue(flat["live_match_id"])
        return from(
            payload: payload.isEmpty ? nil : payload,
            notificationType: type,
            sourceType: source,
            sourceID: sourceID
        )
    }

    func userInfoFields() -> [String: String] {
        var fields: [String: String] = [
            ProGameNotificationDeepLinkPayload.sourceKey: ProGameNotificationDeepLinkPayload.sourceValue,
            ProGameNotificationDeepLinkPayload.matchIDKey: matchID,
            "notification_type": kind.notificationTypeToken,
            "home_team": homeTeam,
            "away_team": awayTeam,
            "home_score": "\(homeScore)",
            "away_score": "\(awayScore)",
            "inbox_dedupe_key": dedupeKey
        ]
        if let scoringTeam, !scoringTeam.isEmpty { fields["scoring_team"] = scoringTeam }
        if let league, !league.isEmpty { fields["league"] = league }
        if let sport, !sport.isEmpty { fields["sport"] = sport }
        if let matchStatus, !matchStatus.isEmpty { fields["match_status"] = matchStatus }
        if let clock, !clock.isEmpty { fields["clock"] = clock }
        if let homeBadgeURL, !homeBadgeURL.isEmpty { fields["home_badge_url"] = homeBadgeURL }
        if let awayBadgeURL, !awayBadgeURL.isEmpty { fields["away_badge_url"] = awayBadgeURL }
        if let homeProviderId, !homeProviderId.isEmpty { fields["home_provider_id"] = homeProviderId }
        if let awayProviderId, !awayProviderId.isEmpty { fields["away_provider_id"] = awayProviderId }
        return fields
    }

    var dedupeKey: String {
        let scoreline = "\(awayScore)-\(homeScore)"
        return FanGeoActionCenterActionKey.sanitize(
            "pro_game:\(kind.rawValue):\(matchID):\(scoreline)"
        )
    }

    private static let payloadKeys = [
        "match_id", "live_match_id", "notification_type", "type", "source",
        "home_team", "away_team", "home_score", "away_score",
        "scoring_team", "league", "sport", "match_status", "clock", "minute",
        "home_badge_url", "away_badge_url", "home_provider_id", "away_provider_id",
        "homeTeam", "awayTeam", "homeScore", "awayScore", "scoringTeam",
        "matchId", "matchID", "liveMatchId",
        "homeBadgeUrl", "awayBadgeUrl", "homeBadgeURL", "awayBadgeURL",
        "homeProviderId", "awayProviderId"
    ]

    private static func flattenedPayload(
        _ payload: [String: AnyCodableJSON]?
    ) -> [String: AnyCodableJSON]? {
        guard var map = payload else { return nil }
        for nestedKey in ["payload", "data", "game", "snapshot"] {
            if case .object(let nested)? = map[nestedKey] {
                for (key, value) in nested where map[key] == nil {
                    map[key] = value
                }
            }
        }
        let aliases: [(String, String)] = [
            ("homeTeam", "home_team"),
            ("awayTeam", "away_team"),
            ("homeScore", "home_score"),
            ("awayScore", "away_score"),
            ("scoringTeam", "scoring_team"),
            ("matchId", "match_id"),
            ("matchID", "match_id"),
            ("live_match_id", "match_id"),
            ("liveMatchId", "match_id"),
            ("homeBadgeUrl", "home_badge_url"),
            ("awayBadgeUrl", "away_badge_url"),
            ("homeBadgeURL", "home_badge_url"),
            ("awayBadgeURL", "away_badge_url"),
            ("homeProviderId", "home_provider_id"),
            ("awayProviderId", "away_provider_id"),
            ("notificationType", "notification_type"),
            ("matchStatus", "match_status")
        ]
        for (from, to) in aliases {
            if map[to] == nil, let value = map[from] {
                map[to] = value
            }
        }
        return map
    }

    private static func flattenedUserInfo(_ userInfo: [AnyHashable: Any]) -> [AnyHashable: Any] {
        var flat = userInfo
        for nestedKey in ["payload", "data", "game", "snapshot"] {
            let nested: [AnyHashable: Any]?
            if let asHashable = userInfo[nestedKey] as? [AnyHashable: Any] {
                nested = asHashable
            } else if let asString = userInfo[nestedKey] as? [String: Any] {
                nested = asString
            } else {
                nested = nil
            }
            guard let nested else { continue }
            for (key, value) in nested where flat[key] == nil {
                flat[key] = value
            }
        }
        return flat
    }

    private static func string(_ payload: [String: AnyCodableJSON], _ key: String) -> String? {
        guard let raw = payload[key]?.stringValue else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func int(_ payload: [String: AnyCodableJSON], _ key: String) -> Int? {
        payload[key]?.intValue
    }

    private static func stringValue(_ raw: Any?) -> String? {
        if let s = raw as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if raw is Bool { return nil }
        if let n = raw as? Int { return String(n) }
        if let n = raw as? Double, n.rounded() == n { return String(Int(n)) }
        if let n = raw as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            let text = n.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func minuteClock(_ raw: String, sport: String?) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let sportToken = (sport ?? "").lowercased()
        if sportToken.contains("soccer")
            || (sportToken.contains("football") && !sportToken.contains("american")) {
            if trimmed.hasSuffix("'") { return trimmed }
            return "\(trimmed)'"
        }
        return trimmed
    }

    nonisolated private static func normalizedTeamToken(_ raw: String) -> String {
        ProGameTeamScoreIdentity.cleanTeamName(raw)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

struct FanGeoProGameInboxArtworkIdentity: Equatable, Sendable {
    let teamName: String
    let badgeURL: String?
    let providerId: String?
    let league: String?
}

struct FanGeoProGameInboxScoreboardRow: Equatable, Sendable {
    let side: FanGeoProGameInboxSnapshot.Side
    let teamName: String
    let score: Int
    let isWinner: Bool
    let artwork: FanGeoProGameInboxArtworkIdentity
}

enum FanGeoProGameInboxPresentation {
    static let artworkDiameter: CGFloat = 32
    static let scoreColumnMinWidth: CGFloat = 32

    static func isProGame(_ item: FanGeoActionItem) -> Bool {
        item.context.proGameSnapshot?.isRenderable == true
    }

    /// Snapshot-backed rows must never use the generic title/body renderer.
    static func usesGenericTitleRenderer(_ item: FanGeoActionItem) -> Bool {
        !isProGame(item)
    }

    static func headerBadgeText(for item: FanGeoActionItem, languageCode: String) -> String? {
        guard let snapshot = item.context.proGameSnapshot, snapshot.isRenderable else { return nil }
        return L10n.t(snapshot.kind.badgeKey, languageCode: languageCode)
    }

    static func scoreboardRows(for snapshot: FanGeoProGameInboxSnapshot) -> [FanGeoProGameInboxScoreboardRow] {
        [scoreboardRow(side: .away, snapshot: snapshot), scoreboardRow(side: .home, snapshot: snapshot)]
    }

    static func artworkIdentities(
        for snapshot: FanGeoProGameInboxSnapshot
    ) -> (away: FanGeoProGameInboxArtworkIdentity, home: FanGeoProGameInboxArtworkIdentity) {
        (
            artworkIdentity(side: .away, snapshot: snapshot),
            artworkIdentity(side: .home, snapshot: snapshot)
        )
    }

    static func accessibilitySummary(
        for snapshot: FanGeoProGameInboxSnapshot,
        languageCode: String
    ) -> String {
        let rows = scoreboardRows(for: snapshot)
        let matchup = rows
            .map { "\($0.teamName) \($0.score)" }
            .joined(separator: " ")
        let context = contextLine(for: snapshot, languageCode: languageCode)
        let footer = footerLine(for: snapshot, languageCode: languageCode)
        return [matchup, context, footer].compactMap { $0 }.joined(separator: ". ")
    }

    static func footerLine(for snapshot: FanGeoProGameInboxSnapshot, languageCode: String) -> String {
        let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        switch snapshot.kind {
        case .final:
            if let winner = snapshot.winnerTeamName {
                return String(
                    format: L10n.t("action_center_pro_game_won_format", languageCode: languageCode),
                    locale: locale,
                    winner
                )
            }
            return L10n.t("action_center_pro_game_draw", languageCode: languageCode)
        case .score:
            if let team = snapshot.identifiedScoringTeam {
                return String(
                    format: L10n.t("action_center_pro_game_scored_format", languageCode: languageCode),
                    locale: locale,
                    team
                )
            }
            return L10n.t("action_center_pro_game_score_updated", languageCode: languageCode)
        case .kickoff:
            return L10n.t("action_center_pro_game_starting_now", languageCode: languageCode)
        case .halftime:
            return L10n.t("action_center_pro_game_badge_halftime", languageCode: languageCode)
        }
    }

    static func contextLine(for snapshot: FanGeoProGameInboxSnapshot, languageCode: String) -> String? {
        var parts: [String] = []
        let league = snapshot.league?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !league.isEmpty { parts.append(league) }
        if snapshot.kind != .final {
            let status = statusLabel(snapshot.matchStatus, languageCode: languageCode)
            if let status { parts.append(status) }
            let clock = snapshot.clock?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !clock.isEmpty { parts.append(clock) }
        }
        let joined = parts.joined(separator: " · ")
        return joined.isEmpty ? nil : joined
    }

    private static func scoreboardRow(
        side: FanGeoProGameInboxSnapshot.Side,
        snapshot: FanGeoProGameInboxSnapshot
    ) -> FanGeoProGameInboxScoreboardRow {
        FanGeoProGameInboxScoreboardRow(
            side: side,
            teamName: side == .home ? snapshot.homeTeam : snapshot.awayTeam,
            score: side == .home ? snapshot.homeScore : snapshot.awayScore,
            isWinner: snapshot.isWinner(side),
            artwork: artworkIdentity(side: side, snapshot: snapshot)
        )
    }

    private static func artworkIdentity(
        side: FanGeoProGameInboxSnapshot.Side,
        snapshot: FanGeoProGameInboxSnapshot
    ) -> FanGeoProGameInboxArtworkIdentity {
        FanGeoProGameInboxArtworkIdentity(
            teamName: side == .home ? snapshot.homeTeam : snapshot.awayTeam,
            badgeURL: side == .home ? snapshot.homeBadgeURL : snapshot.awayBadgeURL,
            providerId: side == .home ? snapshot.homeProviderId : snapshot.awayProviderId,
            league: snapshot.league
        )
    }

    private static func statusLabel(_ raw: String?, languageCode: String) -> String? {
        let token = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch token {
        case "LIVE":
            return L10n.t("action_center_pro_game_live", languageCode: languageCode)
        case "HT":
            return L10n.t("action_center_pro_game_badge_halftime", languageCode: languageCode)
        case "FT":
            return L10n.t("action_center_pro_game_badge_final", languageCode: languageCode)
        default:
            return nil
        }
    }
}
