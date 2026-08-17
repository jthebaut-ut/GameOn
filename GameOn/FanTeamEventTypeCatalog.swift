import Foundation

/// Result / scoring capability for a Team event.
///
/// Scoring is determined by **sport + event type**, never by Team sport alone.
/// Only ``none`` and ``headToHeadScore`` are implemented for live scoring.
/// Additional cases are reserved so race time / placement / points can land later
/// without rewriting call sites.
enum FanTeamEventResultCapability: String, Codable, CaseIterable, Equatable, Sendable {
    case none
    case headToHeadScore
    /// Future: ordered finish (race / meet / climbing / dance competition).
    case placement
    /// Future: timed result (running / swimming / cycling).
    case time
    /// Future: points total (climbing / martial arts / dance judging).
    case points
    /// Future: distance / measurable performance.
    case distance
    /// Future: freeform / sport-specific result payload.
    case other

    /// Capabilities implemented in product UI today.
    static var implementedCases: [FanTeamEventResultCapability] {
        [.none, .headToHeadScore]
    }

    var isImplemented: Bool {
        Self.implementedCases.contains(self)
    }

    /// Effective capability for current product (maps reserved future cases → none).
    var effectiveForCurrentProduct: FanTeamEventResultCapability {
        isImplemented ? self : .none
    }
}

/// Centralized Team event capabilities (opponent + results).
struct FanTeamEventCapabilities: Equatable, Sendable {
    let result: FanTeamEventResultCapability
    let requiresOpponent: Bool

    var showsOpponentField: Bool { requiresOpponent }

    var supportsLiveScoring: Bool {
        result.effectiveForCurrentProduct == .headToHeadScore
    }

    var contributesWinLossTie: Bool {
        result.effectiveForCurrentProduct == .headToHeadScore
    }

    var supportsFinalResult: Bool {
        supportsLiveScoring
    }

    static let none = FanTeamEventCapabilities(result: .none, requiresOpponent: false)
}

/// Sport-aware Team Event Type projection + capability resolution.
///
/// Persisted values remain `GameType.rawValue` / `game_format`. Display labels and
/// menus are contextual by sport. Pickup keeps ``PickupEventTypeCatalog`` separately.
enum FanTeamEventTypeCatalog {
    enum SportFamily: String, Equatable, CaseIterable, Sendable {
        case teamBall
        case running
        case cycling
        case climbing
        case aerial
        case dance
        case winter
        case water
        case martial
        case general
    }

    // MARK: - Sport family

    static func sportFamily(forSport sport: String) -> SportFamily {
        let token = AppSportCatalog.canonicalFormPickerToken(for: sport)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let label = AppSportCatalog.catalogEnglishLabel(forSportToken: sport)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let hay = "\(token) \(label)"

        if matchesAny(hay, [
            "running", "track & field", "track and field", "cross country",
            "marathon", "trail run"
        ]) {
            return .running
        }
        if matchesAny(hay, ["electric scooter", "e-scooter", "escooter", "e scooter"]) {
            return .cycling
        }
        if matchesAny(hay, ["inline skat", "rollerblad", "roller blad"]) {
            return .climbing
        }
        if matchesAny(hay, ["cycling", "cycle", "bike", "biking", "mountain bik", "mtb"]) {
            return .cycling
        }
        if matchesAny(hay, ["climbing", "bouldering", "rock climb"]) {
            return .climbing
        }
        if matchesAny(hay, [
            "skydiving", "skydive", "paragliding", "hang_gliding", "hang gliding",
            "paramotoring", "paramotor"
        ]) {
            return .aerial
        }
        if matchesAny(hay, ["dance", "ballet", "break dance", "breakdance", "breaking"]) {
            return .dance
        }
        if matchesAny(hay, ["skiing", "ski", "snowboarding", "snowboard"]) {
            return .winter
        }
        if matchesAny(hay, ["swimming", "swim"]) {
            return .water
        }
        if matchesAny(hay, ["boxing", "mma", "ufc", "wrestling", "martial", "judo", "karate"]) {
            return .martial
        }
        if matchesAny(hay, [
            "soccer", "nba", "basketball", "nfl", "football", "baseball", "nhl", "hockey",
            "volleyball", "cricket", "rugby", "softball", "lacrosse", "tennis", "golf",
            "handball", "pickleball", "padel", "badminton", "ping pong", "bowling", "esports"
        ]) {
            return .teamBall
        }
        return .general
    }

    // MARK: - Available types (create menu)

    /// Concise sport-aware Team Event Type list (no giant sport×event enum).
    static func availableTypes(for sport: String, canPublishAnnouncements: Bool) -> [GameType] {
        var types: [GameType]
        switch sportFamily(forSport: sport) {
        case .teamBall, .general:
            // Practice, Game/Match, Scrimmage, Tournament/Competition, Tryout, Clinic/Camp, …
            types = [
                .practice, .league_game, .scrimmage, .tournament_game, .tryout, .clinic,
                .team_meeting, .other
            ]
        case .running:
            // Training/Workout, Group Activity, Race/Meet, Competition, …
            types = [
                .practice, .clinic, .tournament_game, .league_game,
                .team_meeting, .other
            ]
        case .cycling:
            types = [
                .practice, .clinic, .tournament_game, .league_game,
                .team_meeting, .other
            ]
        case .climbing, .aerial:
            types = [
                .practice, .clinic, .tournament_game,
                .team_meeting, .other
            ]
        case .dance:
            // Practice, Training, Group Session (clinic), Competition, Other
            types = [
                .practice, .clinic, .tournament_game,
                .team_meeting, .other
            ]
        case .winter, .water, .martial:
            types = [
                .practice, .clinic, .tournament_game, .league_game,
                .team_meeting, .other
            ]
        }
        if canPublishAnnouncements {
            types.append(.announcement)
        }
        return types
    }

    static func menuTypes(
        for sport: String,
        current: GameType?,
        canPublishAnnouncements: Bool
    ) -> [GameType] {
        var types = availableTypes(for: sport, canPublishAnnouncements: canPublishAnnouncements)
        if let current,
           !types.contains(current),
           GameType.fanTeamOrganizerCases.contains(current)
            || current == .match
            || current == .pickup {
            // Preserve edit of legacy / previously selected tokens.
            if current == .announcement, !canPublishAnnouncements {
                // Still show current announcement when editing an existing one.
                types.append(current)
            } else if current != .announcement || canPublishAnnouncements {
                types.append(current)
            } else {
                types.append(current)
            }
        }
        // Never offer plain pickup on Team create menus unless already selected (legacy).
        return types.filter { $0 != .pickup || $0 == current }
    }

    static func ensuringValidSelection(
        _ format: GameType,
        sport: String,
        canPublishAnnouncements: Bool
    ) -> GameType {
        let available = availableTypes(for: sport, canPublishAnnouncements: canPublishAnnouncements)
        if available.contains(format) { return format }
        if format == .match {
            return available.contains(.league_game) ? .league_game : (available.first ?? .practice)
        }
        if format == .announcement, !canPublishAnnouncements {
            return available.first ?? .practice
        }
        if format == .scrimmage {
            return available.contains(.practice) ? .practice : (available.first ?? .practice)
        }
        if format == .tryout {
            return available.contains(.practice) ? .practice : (available.first ?? .practice)
        }
        return available.first ?? .practice
    }

    // MARK: - Display titles (UI only)

    static func displayTitle(
        for format: GameType,
        sport: String,
        languageCode: String?
    ) -> String {
        let family = sportFamily(forSport: sport)
        if let key = contextualTitleKey(format: format, family: family) {
            return L10n.t(key, languageCode: languageCode)
        }
        return format.scheduleFormSummaryLabel(languageCode: languageCode)
    }

    private static func contextualTitleKey(format: GameType, family: SportFamily) -> String? {
        switch (family, format) {
        case (.teamBall, .league_game), (.general, .league_game), (.teamBall, .match), (.general, .match):
            return "team_event_type_game_match"
        case (.teamBall, .tournament_game), (.general, .tournament_game):
            return "team_event_type_tournament_competition"
        case (.teamBall, .clinic), (.general, .clinic):
            return "team_event_type_clinic_camp"

        case (.running, .practice), (.cycling, .practice), (.winter, .practice), (.water, .practice), (.martial, .practice):
            return "team_event_type_training_workout"
        case (.running, .clinic), (.cycling, .clinic), (.winter, .clinic), (.water, .clinic), (.martial, .clinic):
            return "team_event_type_group_activity_session"
        case (.running, .tournament_game):
            return "team_event_type_race_meet"
        case (.running, .league_game), (.cycling, .league_game), (.winter, .league_game), (.water, .league_game), (.martial, .league_game):
            return "team_event_type_competition"
        case (.cycling, .tournament_game):
            return "team_event_type_race_competition"

        case (.climbing, .practice), (.aerial, .practice):
            return "team_event_type_practice_training"
        case (.climbing, .clinic), (.aerial, .clinic):
            return "team_event_type_group_session"
        case (.climbing, .tournament_game), (.aerial, .tournament_game):
            return "team_event_type_competition"

        case (.dance, .practice):
            return nil // "Practice"
        case (.dance, .clinic):
            return "team_event_type_training"
        case (.dance, .tournament_game):
            return "team_event_type_competition"

        default:
            return nil
        }
    }

    // MARK: - Capabilities

    static func capabilities(for format: GameType, sport: String) -> FanTeamEventCapabilities {
        FanTeamEventCapabilityResolver.capabilities(format: format, sport: sport)
    }

    /// Prefer generic “Event” chrome when the activity is not a traditional scored game.
    static func usesGenericEventChrome(format: GameType, sport: String) -> Bool {
        switch format {
        case .team_meeting, .other, .announcement:
            return true
        default:
            break
        }
        let caps = capabilities(for: format, sport: sport)
        if caps.result.effectiveForCurrentProduct == .headToHeadScore {
            return false
        }
        switch sportFamily(forSport: sport) {
        case .teamBall:
            // Practice / tryout / clinic still say “game” less often — use event chrome.
            switch format {
            case .practice, .tryout, .clinic:
                return true
            default:
                return false
            }
        case .running, .cycling, .climbing, .aerial, .dance, .winter, .water, .martial, .general:
            return true
        }
    }

    private static func matchesAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}

/// Authoritative sport+format → opponent / result capability mapping.
enum FanTeamEventCapabilityResolver {
    static func capabilities(format: GameType, sport: String) -> FanTeamEventCapabilities {
        switch format {
        case .announcement, .team_meeting, .other, .pickup, .practice, .tryout, .clinic:
            return .none
        case .scrimmage, .match, .league_game, .tournament_game:
            break
        }

        let trimmedSport = sport.trimmingCharacters(in: .whitespacesAndNewlines)
        // Legacy format-only call sites (no sport yet): preserve historical H2H + opponent
        // for competitive tokens so existing schedule/import paths keep working.
        if trimmedSport.isEmpty {
            return FanTeamEventCapabilities(result: .headToHeadScore, requiresOpponent: true)
        }

        let family = FanTeamEventTypeCatalog.sportFamily(forSport: trimmedSport)
        switch family {
        case .teamBall:
            switch format {
            case .scrimmage, .match, .league_game, .tournament_game:
                return FanTeamEventCapabilities(result: .headToHeadScore, requiresOpponent: true)
            default:
                return .none
            }
        case .running, .cycling, .climbing, .aerial, .dance, .winter, .water, .martial, .general:
            // Race / Competition / Meet may exist as event types, but do NOT force
            // a single opponent or 0–0 head-to-head score in this product phase.
            // Future: map tournament_game → .time / .placement via result capability.
            return .none
        }
    }
}
