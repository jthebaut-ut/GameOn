import Foundation
import SwiftUI

/// Viewing-team vs opponent scores. `homeScore`/`awayScore` on ``FanTeamGame``
/// are the viewing Team and opponent (not venue home/away).
enum FanTeamEventScoringStatus: String, Codable, Hashable, Sendable {
    case scheduled
    case live
    case final

    static func parse(_ raw: String?) -> FanTeamEventScoringStatus {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "live": return .live
        case "final": return .final
        default: return .scheduled
        }
    }
}

enum FanTeamEventResultKind: String, Hashable, Sendable {
    case win
    case loss
    case tie

    var badgeKey: String {
        switch self {
        case .win: return "fan_team_score_result_win"
        case .loss: return "fan_team_score_result_loss"
        case .tie: return "fan_team_score_result_tie"
        }
    }
}

struct FanTeamRecord: Hashable, Sendable {
    var wins: Int
    var losses: Int
    var ties: Int

    static let empty = FanTeamRecord(wins: 0, losses: 0, ties: 0)

    var displayLine: String { "\(max(0, wins))–\(max(0, losses))–\(max(0, ties))" }

    var totalFinals: Int { max(0, wins) + max(0, losses) + max(0, ties) }
}

enum FanTeamEventScoring {
    static func isScoreCapable(gameType: FanTeamGameType, sport: String) -> Bool {
        let format = GameType(rawValue: gameType.rawValue) ?? .other
        return FanTeamEventTypeCatalog.capabilities(for: format, sport: sport).supportsLiveScoring
    }

    static func isScoreCapable(format: GameType, sport: String) -> Bool {
        FanTeamEventTypeCatalog.capabilities(for: format, sport: sport).supportsLiveScoring
    }

    static func hasOpponent(opponentName: String?, opponentTeamId: UUID?) -> Bool {
        if opponentTeamId != nil { return true }
        let name = opponentName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !name.isEmpty
    }

    static func result(teamScore: Int, opponentScore: Int) -> FanTeamEventResultKind {
        if teamScore > opponentScore { return .win }
        if teamScore < opponentScore { return .loss }
        return .tie
    }

    static func record(from games: [FanTeamGame]) -> FanTeamRecord {
        var wins = 0
        var losses = 0
        var ties = 0
        for game in games where game.isScoringFinal && isScoreCapable(gameType: game.gameType, sport: game.sport) {
            switch result(teamScore: game.teamScoreValue, opponentScore: game.opponentScoreValue) {
            case .win: wins += 1
            case .loss: losses += 1
            case .tie: ties += 1
            }
        }
        return FanTeamRecord(wins: wins, losses: losses, ties: ties)
    }

    static func recentFinals(from games: [FanTeamGame], limit: Int = 5) -> [FanTeamGame] {
        games
            .filter { $0.isScoringFinal && isScoreCapable(gameType: $0.gameType, sport: $0.sport) }
            .sorted { lhs, rhs in
                let a = lhs.scoringFinalizedAt ?? FanTeamGamesTimeline.pastSortDate(lhs)
                let b = rhs.scoringFinalizedAt ?? FanTeamGamesTimeline.pastSortDate(rhs)
                if a != b { return a > b }
                return lhs.id.uuidString > rhs.id.uuidString
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    static func applyingDelta(current: Int, delta: Int) -> Int? {
        let next = current + delta
        return next >= 0 ? next : nil
    }

    static func scoreLine(teamName: String, teamScore: Int, opponentName: String, opponentScore: Int) -> String {
        "\(teamName) \(teamScore) – \(opponentScore) \(opponentName)"
    }
}

extension FanTeamSummary {
    /// Owner, Manager title, or granted `edit_events`.
    var canScoreTeamEvents: Bool {
        hasAccountSeat && (
            myRole == .owner
                || myRole == .manager
                || hasPermission(.editEvents)
        )
    }
}

