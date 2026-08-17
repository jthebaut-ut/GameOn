import Foundation

/// Sport-aware Pickup Event Type projection.
///
/// Persisted values remain `GameType.rawValue` (`game_format`). Display labels and
/// availability are contextual by sport so Pickup stays independent of Team-only types
/// (Announcement, Team Meeting, League Game as an org concept).
enum PickupEventTypeCatalog {
    enum SportFamily: String, Equatable, CaseIterable, Sendable {
        case teamBall
        case running
        case cycling
        case climbing
        case aerial
        case dance
        case general
    }

    /// Canonical organizer formats that may appear for *some* Pickup sport.
    /// Union used for CSV/import + backward-compat edit; pickers use ``availableTypes(for:)``.
    static var allPickupOrganizerCases: [GameType] {
        [.pickup, .practice, .scrimmage, .league_game, .tournament_game, .tryout, .clinic, .other]
    }

    static func sportFamily(forSport sport: String) -> SportFamily {
        let token = AppSportCatalog.canonicalFormPickerToken(for: sport)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let label = AppSportCatalog.catalogEnglishLabel(forSportToken: sport)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let hay = "\(token) \(label)"

        if matchesAny(hay, ["running", "track & field", "track and field", "marathon", "trail run"]) {
            return .running
        }
        if matchesAny(hay, ["electric scooter", "e-scooter", "escooter", "e scooter"]) {
            return .cycling
        }
        if matchesAny(hay, ["inline skat", "rollerblad", "roller blad"]) {
            return .climbing
        }
        if matchesAny(hay, ["cycling", "cycle", "bike", "biking"]) {
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
        if matchesAny(hay, [
            "soccer", "nba", "basketball", "nfl", "football", "baseball", "nhl", "hockey",
            "volleyball", "cricket", "rugby", "softball", "lacrosse", "tennis", "golf",
            "handball", "pickleball", "padel", "badminton", "ping pong", "bowling",
            "wrestling", "boxing", "ufc", "mma", "esports"
        ]) {
            return .teamBall
        }
        return .general
    }

    /// Authoritative Pickup Event Type list for create/edit pickers.
    static func availableTypes(for sport: String) -> [GameType] {
        switch sportFamily(forSport: sport) {
        case .teamBall, .general:
            // Pickup Game, Practice, Scrimmage, Match, Training, Other
            return [.pickup, .practice, .scrimmage, .league_game, .clinic, .other]
        case .running:
            // Group Run / Activity, Training / Workout, Race / Meet, Other
            return [.pickup, .practice, .tournament_game, .other]
        case .cycling:
            // Group Ride / Activity, Training / Workout, Race / Competition, Other
            return [.pickup, .practice, .tournament_game, .other]
        case .climbing:
            // Group Session / Activity, Practice / Training, Competition, Other
            return [.pickup, .practice, .tournament_game, .other]
        case .aerial:
            // Group Session / Activity, Training, Competition, Other
            return [.pickup, .practice, .tournament_game, .other]
        case .dance:
            // Practice, Training, Group Session, Competition, Other
            return [.practice, .clinic, .pickup, .tournament_game, .other]
        }
    }

    /// Menu rows for create: sport-aware list. For edit hydration of a legacy format,
    /// appends `current` when it is a valid Pickup token but not in the sport list.
    static func menuTypes(for sport: String, current: GameType?) -> [GameType] {
        var types = availableTypes(for: sport)
        if let current,
           !types.contains(current),
           isStandalonePickupPersistedFormat(current) {
            types.append(current)
        }
        return types.filter { isStandalonePickupPersistedFormat($0) }
    }

    /// Formats that may already exist on standalone Pickup rows (never Team-only).
    static func isStandalonePickupPersistedFormat(_ format: GameType) -> Bool {
        switch format {
        case .announcement, .team_meeting:
            return false
        case .pickup, .practice, .scrimmage, .league_game, .tournament_game,
                .tryout, .clinic, .other, .match:
            return true
        }
    }

    /// When Sport changes on create, snap an unavailable format to a sensible default.
    static func ensuringValidSelection(_ format: GameType, sport: String) -> GameType {
        let available = availableTypes(for: sport)
        if available.contains(format) { return format }

        switch format {
        case .match:
            return available.contains(.league_game) ? .league_game : (available.first ?? .pickup)
        case .tryout:
            return available.contains(.practice) ? .practice : (available.first ?? .pickup)
        case .tournament_game:
            if available.contains(.league_game) { return .league_game }
            return available.first ?? .pickup
        case .league_game:
            if available.contains(.tournament_game) { return .tournament_game }
            return available.first ?? .pickup
        case .scrimmage:
            return available.contains(.practice) ? .practice : (available.first ?? .pickup)
        case .clinic:
            return available.contains(.practice) ? .practice : (available.first ?? .pickup)
        case .announcement, .team_meeting:
            return available.first ?? .pickup
        case .pickup, .practice, .other:
            return available.first ?? .pickup
        }
    }

    /// Contextual localized display for Pickup Event Type (does not change Team labels).
    static func displayTitle(
        for format: GameType,
        sport: String,
        languageCode: String?
    ) -> String {
        let family = sportFamily(forSport: sport)
        if let key = contextualTitleKey(format: format, family: family) {
            return L10n.t(key, languageCode: languageCode)
        }
        return format.displayTitle(languageCode: languageCode)
    }

    /// Running / cycling / climbing / aerial / dance use “Participants” wording.
    static func usesParticipantTerminology(for sport: String) -> Bool {
        switch sportFamily(forSport: sport) {
        case .running, .cycling, .climbing, .aerial, .dance:
            return true
        case .teamBall, .general:
            return false
        }
    }

    private static func contextualTitleKey(format: GameType, family: SportFamily) -> String? {
        switch (family, format) {
        case (.teamBall, .league_game), (.general, .league_game):
            return "pickup_event_type_match"
        case (.teamBall, .clinic), (.general, .clinic):
            return "pickup_event_type_training"
        case (.running, .pickup):
            return "pickup_event_type_group_run"
        case (.running, .practice):
            return "pickup_event_type_training_workout"
        case (.running, .tournament_game):
            return "pickup_event_type_race_meet"
        case (.cycling, .pickup):
            return "pickup_event_type_group_ride"
        case (.cycling, .practice):
            return "pickup_event_type_training_workout"
        case (.cycling, .tournament_game):
            return "pickup_event_type_race_competition"
        case (.climbing, .pickup), (.aerial, .pickup):
            return "pickup_event_type_group_session"
        case (.climbing, .practice):
            return "pickup_event_type_practice_training"
        case (.aerial, .practice):
            return "pickup_event_type_training"
        case (.climbing, .tournament_game), (.aerial, .tournament_game), (.dance, .tournament_game):
            return "pickup_event_type_competition"
        case (.dance, .pickup):
            return "pickup_event_type_group_session"
        case (.dance, .clinic):
            return "pickup_event_type_training"
        default:
            return nil
        }
    }

    private static func matchesAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}
