import Foundation
import os

/// Sport-aware scorer attribution for FanGeo Team scoring.
///
/// Centralized policy + copy. SQL/Edge persist `scorer_attribution_kind`;
/// iOS localizes presentation from that kind (never by guessing display strings).
enum FanTeamScorerAttributionMode: String, Equatable, Sendable {
    case goal
    case score
    case run
    case touchdownOrScore = "touchdown_or_score"
    case optionalPoint = "optional_point"
    case none

    var promptsForScorer: Bool {
        switch self {
        case .none, .optionalPoint: return false
        case .goal, .score, .run, .touchdownOrScore: return true
        }
    }

    static func parse(_ raw: String?) -> FanTeamScorerAttributionMode {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "goal": return .goal
        case "score": return .score
        case "run": return .run
        case "touchdown_or_score", "touchdownorscore": return .touchdownOrScore
        case "optional_point", "optionalpoint": return .optionalPoint
        default: return .none
        }
    }
}

struct FanTeamEligibleScorer: Identifiable, Hashable, Sendable {
    var id: UUID { membershipId }
    let membershipId: UUID
    let userId: UUID?
    let managedPlayerId: UUID?
    let displayName: String
    let avatarURL: String?
    let avatarThumbnailURL: String?
}

enum FanTeamScorerPick: Equatable, Sendable {
    case skip
    case player(FanTeamEligibleScorer)

    var membershipId: UUID? {
        switch self {
        case .skip: return nil
        case .player(let scorer): return scorer.membershipId
        }
    }
}

/// Last Team roster snapshot used by Roster / Team Detail / lineup.
/// Picker reads this so + never waits on a network round-trip.
enum FanTeamRosterSnapshotCache {
    private static let lock = OSAllocatedUnfairLock<[UUID: [FanTeamMember]]>(initialState: [:])

    static func store(_ members: [FanTeamMember], for teamId: UUID) {
        lock.withLock { $0[teamId] = members }
    }

    static func members(for teamId: UUID) -> [FanTeamMember] {
        lock.withLock { $0[teamId] ?? [] }
    }

    static func hasSnapshot(for teamId: UUID) -> Bool {
        lock.withLock { $0[teamId] != nil }
    }

    static func eligibleScorers(for teamId: UUID) -> [FanTeamEligibleScorer] {
        FanTeamScoreAttribution.eligibleScorers(from: members(for: teamId))
    }
}

enum FanTeamScoreAttribution {
    static func mode(forSport sport: String) -> FanTeamScorerAttributionMode {
        let token = AppSportCatalog.canonicalFormPickerToken(for: sport)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let label = AppSportCatalog.catalogEnglishLabel(forSportToken: sport)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let hay = "\(token) \(label)"

        if matchesAny(hay, [
            "volleyball", "badminton", "tennis", "padel", "pickleball", "ping pong",
            "ping-pong", "table tennis", "running", "track & field", "track and field",
            "climbing", "bouldering", "paragliding", "hang_gliding", "hang gliding",
            "paramotoring", "paramotor", "cycling", "swimming", "skiing", "golf",
            "esports", "bowling", "dance", "ballet", "boxing", "mma", "ufc", "wrestling"
        ]) {
            return .none
        }
        if matchesAny(hay, ["soccer", "futsal", "futbol"]) {
            return .goal
        }
        if matchesAny(hay, ["nhl", "hockey"]) {
            return .goal
        }
        if matchesAny(hay, ["lacrosse"]) {
            return .goal
        }
        if matchesAny(hay, ["nba", "wnba", "basketball"]) {
            return .score
        }
        if matchesAny(hay, ["baseball", "mlb", "softball"]) {
            return .run
        }
        if matchesAny(hay, ["nfl", "american football"]) {
            return .touchdownOrScore
        }
        if token == "football" || label == "football" {
            return .touchdownOrScore
        }
        return .none
    }

    static func promptsForScorer(sport: String) -> Bool {
        mode(forSport: sport).promptsForScorer
    }

    /// Active roster players only. Admin-only seats, departed members, and
    /// guardian-only rows are excluded unless they are themselves `isPlayer`.
    static func eligibleScorers(from members: [FanTeamMember]) -> [FanTeamEligibleScorer] {
        members.compactMap { member in
            guard member.isPlayer else { return nil }
            let name = member.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return FanTeamEligibleScorer(
                membershipId: member.membershipId,
                userId: member.userId,
                managedPlayerId: member.managedPlayerId,
                displayName: name,
                avatarURL: member.avatarURL,
                avatarThumbnailURL: member.avatarThumbnailURL
            )
        }
        .sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private static func matchesAny(_ hay: String, _ needles: [String]) -> Bool {
        needles.contains { hay.contains($0) }
    }
}

enum FanTeamScoreAttributionPresentation {
    static func pickerTitle(languageCode: String) -> String {
        L10n.t("team_score_who_scored", languageCode: languageCode)
    }

    static func pickerSubtitle(
        mode: FanTeamScorerAttributionMode,
        languageCode: String
    ) -> String? {
        switch mode {
        case .goal:
            return L10n.t("team_score_goal_by", languageCode: languageCode)
        case .run:
            return L10n.t("team_score_run_scored_by", languageCode: languageCode)
        case .score:
            return L10n.t("team_score_scored_by", languageCode: languageCode)
        case .touchdownOrScore:
            return L10n.t("team_score_score_by", languageCode: languageCode)
        case .optionalPoint, .none:
            return nil
        }
    }

    static func skipTitle(languageCode: String) -> String {
        L10n.t("team_score_skip_scorer", languageCode: languageCode)
    }

    static func skipAccessibilityLabel(languageCode: String) -> String {
        L10n.t("team_score_skip_scorer_a11y", languageCode: languageCode)
    }

    static func scorerRowLabel(languageCode: String) -> String {
        L10n.t("team_score_scorer", languageCode: languageCode)
    }

    static func notificationTitle(
        mode: FanTeamScorerAttributionMode,
        scorerName: String?,
        teamName: String,
        languageCode: String
    ) -> String {
        let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        let name = scorerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty {
            return teamScoredTitle(teamName: teamName, languageCode: languageCode)
        }
        switch mode {
        case .goal:
            return String(
                format: L10n.t("team_score_goal_title_format", languageCode: languageCode),
                locale: locale,
                name
            )
        case .run:
            return String(
                format: L10n.t("team_score_run_title_format", languageCode: languageCode),
                locale: locale,
                name
            )
        case .score:
            return String(
                format: L10n.t("team_score_player_scored_format", languageCode: languageCode),
                locale: locale,
                name
            )
        case .touchdownOrScore:
            return String(
                format: L10n.t("team_score_generic_title_format", languageCode: languageCode),
                locale: locale,
                name
            )
        case .optionalPoint, .none:
            return teamScoredTitle(teamName: teamName, languageCode: languageCode)
        }
    }

    static func teamScoredTitle(teamName: String, languageCode: String) -> String {
        let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        let team = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = team.isEmpty ? "Team" : team
        return String(
            format: L10n.t("team_score_team_scored_format", languageCode: languageCode),
            locale: locale,
            resolved
        )
    }

    static func finalTitle(languageCode: String) -> String {
        L10n.t("fan_team_score_final", languageCode: languageCode)
    }

    static func scoreLine(
        teamName: String,
        teamScore: Int,
        opponentName: String,
        opponentScore: Int
    ) -> String {
        FanTeamEventScoring.scoreLine(
            teamName: teamName,
            teamScore: teamScore,
            opponentName: opponentName,
            opponentScore: opponentScore
        )
    }
}
