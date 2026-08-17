import Foundation

func pickupLocalizedSpotsOpen(_ count: Int, languageCode: String) -> String {
    let key = count == 1 ? "pickup_spot_open_singular" : "pickup_spots_open_plural"
    return String(format: L10n.t(key, languageCode: languageCode), Int64(count))
}

func pickupLocalizedSpotsLeft(_ count: Int, languageCode: String) -> String {
    let key = count == 1 ? "pickup_spot_left_singular" : "pickup_spots_left_plural"
    return String(format: L10n.t(key, languageCode: languageCode), Int64(count))
}

/// Compact / spoken duration from whole minutes between authoritative start and end.
/// Visible UI stays short (`2h`, `1h 30m`, `45m`); VoiceOver can use the spoken form.
nonisolated enum PickupGameDurationPresentation {
    /// Compact chip / inline label. No "game" suffix.
    /// Reuses activity-status `h` / `m` unit keys so locales like Polish (`g`) and Chinese (`时`/`分`) stay correct.
    static func compactLabel(totalMinutes: Int, languageCode: String) -> String? {
        guard totalMinutes > 0 else { return nil }
        let lang = L10n.normalizedLanguageCode(languageCode)
        let locale = Locale(identifier: lang.replacingOccurrences(of: "-", with: "_"))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let hoursPart: String? = hours > 0
            ? String(
                format: L10n.t("activity_status_compact_hours_format", languageCode: lang),
                locale: locale,
                hours
            )
            : nil
        let minutesPart: String? = minutes > 0
            ? String(
                format: L10n.t("activity_status_compact_minutes_format", languageCode: lang),
                locale: locale,
                minutes
            )
            : nil
        switch (hoursPart, minutesPart) {
        case let (h?, m?):
            return "\(h) \(m)"
        case let (h?, nil):
            return h
        case let (nil, m?):
            return m
        default:
            return nil
        }
    }

    /// Locale-aware spoken duration for accessibility (e.g. "2 hours", "30 minutes").
    static func spokenLabel(totalMinutes: Int, languageCode: String) -> String? {
        guard totalMinutes > 0 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .full
        var calendar = Calendar(identifier: .gregorian)
        let code = L10n.normalizedLanguageCode(languageCode)
        calendar.locale = Locale(identifier: code.replacingOccurrences(of: "-", with: "_"))
        formatter.calendar = calendar
        var components = DateComponents()
        components.hour = totalMinutes / 60
        components.minute = totalMinutes % 60
        return formatter.string(from: components)
    }
}

/// Automatic removal: `remove_after_at` is always `game_start_at` + this many hours (DB trigger + app payloads).
nonisolated enum PickupGameAutoRemoval {
    static let hoursAfterGameStart: Int = 12
}

/// Going → Hosting auto-clear: one SoT for deadline, eligibility, and countdown copy.
nonisolated enum PickupHostingAutoClear {
    static func deadline(for row: PickupGameRow) -> Date? {
        row.pickupHistoryClientCleanupDeadline()
    }

    static func isPastDeadline(row: PickupGameRow, now: Date) -> Bool {
        guard let deadline = deadline(for: row) else { return false }
        return now >= deadline
    }

    /// Live countdown / clearing status for Hosting cards (never a stable "past" label).
    static func statusLabel(
        row: PickupGameRow,
        now: Date,
        languageCode: String,
        isClearing: Bool = false,
        clearFailed: Bool = false
    ) -> String {
        if clearFailed {
            return L10n.t("pickup_auto_clear_failed_hint", languageCode: languageCode)
        }
        if isClearing {
            return L10n.t("pickup_auto_clearing_now", languageCode: languageCode)
        }
        guard let deadline = deadline(for: row) else {
            return String(
                format: L10n.t("pickup_auto_clears_after_start_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                PickupGameAutoRemoval.hoursAfterGameStart
            )
        }
        if now >= deadline {
            // Avoid a stable "Past auto-clear time" label; Going passes `isClearing` while removing.
            return L10n.t("pickup_auto_clears_soon", languageCode: languageCode)
        }
        if let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at), now < start {
            return String(
                format: L10n.t("pickup_auto_clears_after_start_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                PickupGameAutoRemoval.hoursAfterGameStart
            )
        }
        return countdownLabel(until: deadline, now: now, languageCode: languageCode)
    }

    static func countdownLabel(until deadline: Date, now: Date, languageCode: String) -> String {
        let remaining = deadline.timeIntervalSince(now)
        if remaining <= 0 {
            return L10n.t("pickup_auto_clearing_now", languageCode: languageCode)
        }
        if remaining < 15 * 60 {
            return L10n.t("pickup_auto_clears_soon", languageCode: languageCode)
        }
        if remaining < 3600 {
            let minutes = max(1, Int(ceil(remaining / 60)))
            return String(
                format: L10n.t("pickup_auto_clears_in_m_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                minutes
            )
        }
        let totalMinutes = Int(remaining / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if minutes == 0 {
            return String(
                format: L10n.t("pickup_auto_clears_in_h_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                hours
            )
        }
        return String(
            format: L10n.t("pickup_auto_clears_in_hm_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            hours,
            minutes
        )
    }
}

/// DEBUG: pickup expiration fields immediately before Supabase insert/update (edit + roster sync).
enum PickupExpirationEditDebug {
    static func log(oldGameStartAt: String?, newGameStartAt: String, cleanupDelayHours: Int, computedRemoveAfterAt: String) {
#if DEBUG
        print("[PickupExpirationEditDebug] oldGameStartAt=\(oldGameStartAt ?? "nil")")
        print("[PickupExpirationEditDebug] newGameStartAt=\(newGameStartAt)")
        print("[PickupExpirationEditDebug] cleanupDelayHours=\(cleanupDelayHours)")
        print("[PickupExpirationEditDebug] computedRemoveAfterAt=\(computedRemoveAfterAt)")
#endif
    }
}

/// Authoritative `pickup_games.game_format` tokens (event type — not competition level).
/// `team_event` is intentionally omitted from v1 (players_needed >= 1 blocks non-playing events).
enum GameType: String, Codable, CaseIterable, Hashable {
    case pickup
    case practice
    case scrimmage
    /// Legacy Team fixture token. Preserve existing rows; new Team creates prefer `.league_game`.
    case match
    case league_game
    case tournament_game
    case tryout
    case clinic
    /// Team-linked non-game activity (coach / parent / film / briefing). Not used for standalone Pickup.
    case team_meeting
    /// Flexible Team-linked fallback event type. Canonical token only — no freeform DB types.
    case other
    /// Official Team notice (Owner/Manager). Not a game/practice; title + description body.
    case announcement

    /// Classic Pickup create/edit (excludes Team-only and legacy `.match`).
    /// Sport-aware picker subsets live in ``PickupEventTypeCatalog.availableTypes(for:)``.
    static var pickupOrganizerCases: [GameType] {
        PickupEventTypeCatalog.allPickupOrganizerCases
    }

    /// My Teams → Schedule Event (same column). Includes legacy `.match` for edit compatibility.
    static var fanTeamOrganizerCases: [GameType] {
        [
            .practice, .scrimmage, .league_game, .tournament_game, .tryout, .clinic, .match,
            .team_meeting, .other, .announcement
        ]
    }

    /// Formats allowed by `link_pickup_game_to_fan_team` (plain pickup excluded).
    static var fanTeamLinkableCases: [GameType] {
        [
            .practice, .scrimmage, .league_game, .tournament_game, .tryout, .clinic, .match,
            .team_meeting, .other, .announcement
        ]
    }

    /// Default Game Format when opening Team Schedule create (not edit / not Pickup).
    static var defaultForTeamCreate: GameType { .practice }
    static var defaultForNormalCreate: GameType { .pickup }

    var displayTitle: String {
        displayTitle(languageCode: nil)
    }

    func displayTitle(languageCode: String?) -> String {
        switch self {
        case .pickup:
            return L10n.t("pickup_game_format_pickup", languageCode: languageCode)
        case .practice:
            return L10n.t("pickup_game_format_practice", languageCode: languageCode)
        case .scrimmage:
            return L10n.t("pickup_game_format_scrimmage", languageCode: languageCode)
        case .match:
            return L10n.t("fan_team_game_type_match", languageCode: languageCode)
        case .league_game:
            return L10n.t("pickup_game_format_league_game", languageCode: languageCode)
        case .tournament_game:
            return L10n.t("pickup_game_format_tournament_game", languageCode: languageCode)
        case .tryout:
            return L10n.t("pickup_game_format_tryout", languageCode: languageCode)
        case .clinic:
            return L10n.t("pickup_game_format_clinic", languageCode: languageCode)
        case .team_meeting:
            return L10n.t("pickup_game_format_team_meeting", languageCode: languageCode)
        case .other:
            return L10n.t("pickup_game_format_other", languageCode: languageCode)
        case .announcement:
            return L10n.t("pickup_game_format_announcement", languageCode: languageCode)
        }
    }

    var badgeTitle: String {
        displayTitle.uppercased()
    }

    var systemImage: String {
        switch self {
        case .pickup: return "person.3.fill"
        case .practice: return "figure.run"
        case .scrimmage: return "arrow.left.arrow.right"
        case .match, .league_game: return "trophy.fill"
        case .tournament_game: return "medal.fill"
        case .tryout: return "person.badge.plus"
        case .clinic: return "graduationcap.fill"
        case .team_meeting: return "person.3.sequence.fill"
        case .other: return "ellipsis.circle.fill"
        case .announcement: return "megaphone.fill"
        }
    }

    /// Create-form hero title. Updates live when Game Format changes (presentation only).
    func scheduleFormIntroTitle(languageCode: String?) -> String {
        switch self {
        case .pickup:
            return L10n.t("pickup_form_intro_title_pickup", languageCode: languageCode)
        case .practice:
            return L10n.t("pickup_form_intro_title_practice", languageCode: languageCode)
        case .scrimmage:
            return L10n.t("pickup_form_intro_title_scrimmage", languageCode: languageCode)
        case .league_game:
            return L10n.t("pickup_form_intro_title_league_game", languageCode: languageCode)
        case .tournament_game:
            return L10n.t("pickup_form_intro_title_tournament_game", languageCode: languageCode)
        case .tryout:
            return L10n.t("pickup_form_intro_title_tryout", languageCode: languageCode)
        case .clinic:
            return L10n.t("pickup_form_intro_title_clinic", languageCode: languageCode)
        case .match:
            return L10n.t("pickup_form_intro_title_match", languageCode: languageCode)
        case .team_meeting:
            return L10n.t("pickup_form_intro_title_team_meeting", languageCode: languageCode)
        case .other:
            return L10n.t("pickup_form_intro_title_other", languageCode: languageCode)
        case .announcement:
            return L10n.t("pickup_form_intro_title_announcement", languageCode: languageCode)
        }
    }

    /// Live summary card primary label for the selected format.
    func scheduleFormSummaryLabel(languageCode: String?) -> String {
        switch self {
        case .pickup:
            return L10n.t("pickup_form_summary_format_pickup", languageCode: languageCode)
        case .clinic:
            // Prefer short "Clinic" over picker label "Clinic / Camp".
            return L10n.t("pickup_form_summary_format_clinic", languageCode: languageCode)
        case .practice, .scrimmage, .league_game, .tournament_game, .tryout, .match,
                .team_meeting, .other, .announcement:
            return displayTitle(languageCode: languageCode)
        }
    }

    /// Compact emoji for the live summary card format column.
    var scheduleFormSummaryEmoji: String {
        switch self {
        case .pickup: return "🤝"
        case .practice: return "⚽"
        case .scrimmage: return "🔄"
        case .league_game, .match: return "🏆"
        case .tournament_game: return "🏅"
        case .tryout: return "📋"
        case .clinic: return "🎓"
        case .team_meeting: return "💬"
        case .other: return "📌"
        case .announcement: return "📣"
        }
    }

    /// Soft parse for CSV / wire strings. Unknown → nil (callers choose fallback).
    static func parse(_ raw: String?) -> GameType? {
        let normalized = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        guard !normalized.isEmpty else { return nil }
        if let exact = GameType(rawValue: normalized) { return exact }
        switch normalized {
        case "league", "leaguegame", "league_fixture":
            return .league_game
        case "tournament", "tournamentgame":
            return .tournament_game
        case "tryouts", "try_out":
            return .tryout
        case "camp", "clinic_camp", "cliniccamp":
            return .clinic
        case "game", "fixture":
            return .league_game
        case "meeting", "teammeeting", "team_meetings", "coach_meeting", "parent_meeting":
            return .team_meeting
        case "misc", "misc_event", "general", "custom":
            return .other
        default:
            return nil
        }
    }
}

/// Central presentation policy for Team-linked (and shared) event formats.
/// Keeps gameplay vs meeting/other field visibility out of scattered SwiftUI `if` chains.
enum FanTeamEventPresentation {
    static func policy(for format: GameType, sport: String = "") -> FanTeamEventFormatPolicy {
        FanTeamEventFormatPolicy(format: format, sport: sport)
    }

    static func policy(for format: FanTeamGameType, sport: String = "") -> FanTeamEventFormatPolicy {
        FanTeamEventFormatPolicy(
            format: GameType(rawValue: format.rawValue) ?? .other,
            sport: sport
        )
    }
}

struct FanTeamEventFormatPolicy: Equatable, Sendable {
    let format: GameType
    /// Sport token from the form / Team. Empty string keeps legacy format-only behavior
    /// for call sites that have not yet passed sport (defaults to team-ball-like H2H rules
    /// only when format alone historically required an opponent — prefer passing sport).
    var sport: String = ""

    /// Sport + format capability (opponent / head-to-head scoring).
    var capabilities: FanTeamEventCapabilities {
        FanTeamEventCapabilityResolver.capabilities(format: format, sport: sport)
    }

    var resultCapability: FanTeamEventResultCapability {
        capabilities.result.effectiveForCurrentProduct
    }

    /// Sport/activity formats that use gameplay-oriented fields.
    var isGameplayEvent: Bool {
        switch format {
        case .practice, .scrimmage, .league_game, .tournament_game, .match, .tryout, .clinic, .pickup:
            return true
        case .team_meeting, .other, .announcement:
            return false
        }
    }

    /// Team-linked Meeting/Other/Announcement never recruit outside players. Gameplay Team formats may.
    var allowsTeamOutsideRecruitment: Bool {
        switch format {
        case .team_meeting, .other, .announcement:
            return false
        case .practice, .scrimmage, .league_game, .tournament_game, .match, .tryout, .clinic, .pickup:
            return true
        }
    }

    var supportsOutsideRecruitment: Bool { allowsTeamOutsideRecruitment }

    var showsCompetitionLevel: Bool { isGameplayEvent }

    var showsHowYouPlay: Bool { isGameplayEvent }

    var supportsCapacity: Bool { isGameplayEvent }

    var showsSpotsLeft: Bool { isGameplayEvent }

    /// Competitive formats that require a free-text opponent — **sport-aware**.
    /// Running Race / Climbing Competition / etc. do not require a single Team opponent.
    var requiresOpponent: Bool {
        capabilities.requiresOpponent
    }

    /// Show the Matchup / Opponent row (Team Schedule create + edit).
    var showsOpponentField: Bool { requiresOpponent }

    /// Live / final head-to-head scoring UI may appear only when capability says so.
    var supportsHeadToHeadScore: Bool {
        resultCapability == .headToHeadScore
    }

    var usesGenericDetailLabels: Bool {
        if FanTeamEventTypeCatalog.usesGenericEventChrome(format: format, sport: sport) {
            return true
        }
        switch format {
        case .team_meeting, .other, .announcement:
            return true
        default:
            return false
        }
    }

    var prefersCustomTitle: Bool {
        format == .other || format == .team_meeting || format == .announcement
    }

    /// Announcement requires a non-empty description/body (message).
    var requiresDescriptionBody: Bool {
        format == .announcement
    }

    /// Hide RSVP / attendance for announcements.
    var showsAttendanceRSVP: Bool {
        isGameplayEvent || format == .team_meeting || format == .other
    }

    /// Announcements are message-first; venue/directions are optional and omitted when empty.
    var showsLocationFields: Bool {
        format != .announcement
    }

    /// Announcements are notices — no lineup / attendance roster UI.
    var showsLineup: Bool {
        format != .announcement
    }

    var systemImage: String { format.systemImage }

    func localizedTitle(languageCode: String?) -> String {
        if sport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return format.displayTitle(languageCode: languageCode)
        }
        return FanTeamEventTypeCatalog.displayTitle(
            for: format,
            sport: sport,
            languageCode: languageCode
        )
    }

    func detailSectionTitleKey() -> String {
        usesGenericDetailLabels
            ? "pickup_detail_event_details"
            : "pickup_detail_game_details"
    }

    func calendarNounKey() -> String {
        usesGenericDetailLabels
            ? "pickup_calendar_noun_event"
            : "pickup_calendar_noun_pickup"
    }
}

extension FanTeamEventPresentation {
    /// Navigation title for `DiscoverPickupGameDetailSheet`.
    /// Announcement → “Team Announcement”; Team-linked → “Event Details”; standalone → “Pickup game”.
    static func detailNavigationTitleKey(
        isTeamLinked: Bool,
        format: GameType? = nil
    ) -> String {
        if format == .announcement {
            return FanTeamAnnouncementDetailPresentation.navTitleKey
        }
        return isTeamLinked ? "team_event_detail_nav_title" : "share_pickup_card_badge"
    }
}

/// Team Schedule matchup helpers: home team is always the FanGeo team; opponent is free text.
enum FanTeamScheduleMatchup {
    static func trimmedOpponent(_ raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Only formats whose **sport-aware** capability requires an opponent serialize opponent data.
    /// Pass `sport` whenever available so Running Race / Climbing Competition do not persist opponents.
    static func persistableOpponent(format: GameType, opponentName: String?, sport: String = "") -> String? {
        guard FanTeamEventPresentation.policy(for: format, sport: sport).requiresOpponent else { return nil }
        return trimmedOpponent(opponentName)
    }

    static func matchupLine(
        homeTeamName: String,
        opponentName: String?,
        languageCode: String?
    ) -> String? {
        guard let opponent = trimmedOpponent(opponentName) else { return nil }
        let home = homeTeamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !home.isEmpty else { return nil }
        let vs = L10n.t("fan_team_schedule_vs", languageCode: languageCode)
        return "\(home) \(vs) \(opponent)"
    }
}

/// Optional `pickup_games.competition_level` (sport level — not event type).
enum PickupCompetitionLevel: String, Codable, CaseIterable, Hashable, Identifiable {
    case youth
    case high_school
    case college_university
    case adult_recreational
    case adult_competitive
    case semi_pro
    case professional

    var id: String { rawValue }

    func displayTitle(languageCode: String?) -> String {
        switch self {
        case .youth:
            return L10n.t("pickup_competition_level_youth", languageCode: languageCode)
        case .high_school:
            return L10n.t("pickup_competition_level_high_school", languageCode: languageCode)
        case .college_university:
            return L10n.t("pickup_competition_level_college_university", languageCode: languageCode)
        case .adult_recreational:
            return L10n.t("pickup_competition_level_adult_recreational", languageCode: languageCode)
        case .adult_competitive:
            return L10n.t("pickup_competition_level_adult_competitive", languageCode: languageCode)
        case .semi_pro:
            return L10n.t("pickup_competition_level_semi_pro", languageCode: languageCode)
        case .professional:
            return L10n.t("pickup_competition_level_professional", languageCode: languageCode)
        }
    }

    static func parse(_ raw: String?) -> PickupCompetitionLevel? {
        let compact = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let collapsed = compact
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "_")
        guard !collapsed.isEmpty else { return nil }
        if let exact = PickupCompetitionLevel(rawValue: collapsed) { return exact }
        switch collapsed {
        case "college", "university", "college_university", "uni":
            return .college_university
        case "hs", "highschool", "high_school":
            return .high_school
        case "adult_rec", "recreational", "adult_recreation", "rec":
            return .adult_recreational
        case "adult_comp", "competitive", "adult":
            return .adult_competitive
        case "semipro", "semi_professional", "semi_pro":
            return .semi_pro
        case "pro", "professional":
            return .professional
        case "kids", "youth":
            return .youth
        default:
            return nil
        }
    }
}

/// Lightweight context for opening the shared Pickup create form from My Teams.
/// Carries presentation identity (logo/color/level) so Schedule Game can show which Team
/// without an extra RPC — populated from the already-loaded `FanTeamSummary`.
struct PickupGameTeamCreationContext: Equatable, Hashable, Sendable {
    let teamId: UUID
    let teamName: String
    let teamSport: String
    /// Active roster size for Team Players presentation (not auto-RSVP).
    let activeMemberCount: Int
    /// Team default competition level — new games inherit unless overridden.
    let competitionLevel: PickupCompetitionLevel?
    let logoURL: String?
    let logoThumbnailURL: String?
    let colorHex: String?
    /// Durable Team Chat conversation (`fan_teams.group_conversation_id`).
    let groupConversationId: UUID?
    /// Owner/Manager (or granted) may create Announcement format.
    let canPublishAnnouncements: Bool
    /// Broad staff gate (invite / roster / identity / etc.). Prefer finer flags when available.
    let canManageTeam: Bool
    /// Edit existing Team-linked events (`edit_events`).
    let canEditTeamEvents: Bool
    /// Owner, Manager title, or granted `edit_events` may score Live/Final games.
    let canScoreTeamEvents: Bool
    /// Owner/Manager/Head Coach (or granted `create_events`) may manage Team saved locations.
    let canManageTeamLocations: Bool

    init(
        teamId: UUID,
        teamName: String,
        teamSport: String,
        activeMemberCount: Int = 0,
        competitionLevel: PickupCompetitionLevel? = nil,
        logoURL: String? = nil,
        logoThumbnailURL: String? = nil,
        colorHex: String? = nil,
        groupConversationId: UUID? = nil,
        canPublishAnnouncements: Bool = false,
        canManageTeam: Bool = false,
        canEditTeamEvents: Bool = false,
        canScoreTeamEvents: Bool = false,
        canManageTeamLocations: Bool = false
    ) {
        self.teamId = teamId
        self.teamName = teamName
        self.teamSport = teamSport
        self.activeMemberCount = max(0, activeMemberCount)
        self.competitionLevel = competitionLevel
        self.logoURL = logoURL
        self.logoThumbnailURL = logoThumbnailURL
        self.colorHex = colorHex
        self.groupConversationId = groupConversationId
        self.canPublishAnnouncements = canPublishAnnouncements
        self.canManageTeam = canManageTeam
        self.canEditTeamEvents = canEditTeamEvents
        self.canScoreTeamEvents = canScoreTeamEvents
        self.canManageTeamLocations = canManageTeamLocations
    }

    init(from summary: FanTeamSummary) {
        self.init(
            teamId: summary.id,
            teamName: summary.name,
            teamSport: summary.sport,
            activeMemberCount: summary.memberCount,
            competitionLevel: summary.competitionLevel,
            logoURL: summary.logoURL,
            logoThumbnailURL: summary.logoThumbnailURL,
            colorHex: summary.colorHex,
            groupConversationId: summary.groupConversationId,
            canPublishAnnouncements: summary.canPublishAnnouncements,
            canManageTeam: summary.canManage,
            canEditTeamEvents: summary.canEditTeamEvents,
            canScoreTeamEvents: summary.canScoreTeamEvents,
            canManageTeamLocations: summary.canOrganizeActivities
        )
    }

    /// Youth · Soccer · 24 members (hides level when nil). Presentation only.
    func scheduleHeaderMetaLine(languageCode: String) -> String {
        FanTeamMetaLine.compose(
            competitionLevel: competitionLevel,
            sport: AppSportCatalog.displayLabel(forSportToken: teamSport),
            memberCount: activeMemberCount > 0 ? activeMemberCount : nil,
            languageCode: languageCode
        )
    }

    func scheduleHeaderAccessibilityLabel(languageCode: String) -> String {
        var parts = [
            L10n.t("pickup_form_team_scheduling_a11y_prefix", languageCode: languageCode),
            teamName,
        ]
        let sport = AppSportCatalog.displayLabel(forSportToken: teamSport)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !sport.isEmpty {
            parts.append(sport)
        }
        if let competitionLevel {
            parts.append(competitionLevel.displayTitle(languageCode: languageCode))
        }
        return parts.joined(separator: ". ")
    }
}

/// Team-linked games reuse `players_needed` / `max_players` for optional outside recruiting.
/// DB floor is `players_needed >= 1`; Team create with recruiting OFF persists `1` + `max_players = nil`.
enum PickupTeamOutsideRecruiting {
    /// Sentinel persisted when Team create has “Need additional players” OFF.
    static let inactivePlayersNeededFloor = 1

    /// Whether a Team-linked row is recruiting outside the Team roster.
    static func isEnabled(playersNeeded: Int, maxPlayers: Int?) -> Bool {
        if maxPlayers != nil { return true }
        return playersNeeded > inactivePlayersNeededFloor
    }

    /// Values to persist for Team create/import when not recruiting outside.
    static func inactivePersistence() -> (playersNeeded: Int, maxPlayers: Int?) {
        (inactivePlayersNeededFloor, nil)
    }
}

/// Team Schedule / Team-linked edit: HOW YOU PLAY always keeps Indoor/Outdoor;
/// skill / who’s welcome / age govern outside recruitment only.
enum PickupTeamHowYouPlayPresentation {
    /// Standalone Pickup always shows recruitment eligibility fields.
    /// Team-linked games show them only while “Need additional players” is ON.
    static func showsOutsideRecruitmentFields(
        isTeamLinked: Bool,
        needsAdditionalPlayers: Bool
    ) -> Bool {
        if !isTeamLinked { return true }
        return needsAdditionalPlayers
    }
}

/// Team-linked Schedule Game safety: roster-only = informational note; recruiting outside = full ack.
enum PickupTeamSafetyPresentation {
    /// Compact Team-only note (no toggle) when Team-linked and not recruiting outside players.
    static func usesTeamOnlyInformationalNote(
        isTeamLinked: Bool,
        needsAdditionalPlayers: Bool
    ) -> Bool {
        isTeamLinked && !needsAdditionalPlayers
    }

    /// Acknowledgement is create-only. Edit never re-requires it (existing product semantics).
    /// Team-only create does not require acknowledgement; Team recruiting + standalone do.
    static func requiresAcknowledgment(
        isCreate: Bool,
        isTeamLinked: Bool,
        needsAdditionalPlayers: Bool
    ) -> Bool {
        guard isCreate else { return false }
        if usesTeamOnlyInformationalNote(
            isTeamLinked: isTeamLinked,
            needsAdditionalPlayers: needsAdditionalPlayers
        ) {
            return false
        }
        return true
    }
}

enum PickupGameCreationSource: String, Equatable, Sendable {
    case standard
    case team
}

struct PickupGameCreationContext: Equatable, Sendable {
    var source: PickupGameCreationSource
    var team: PickupGameTeamCreationContext?

    static let standard = PickupGameCreationContext(source: .standard, team: nil)

    static func team(_ team: PickupGameTeamCreationContext) -> PickupGameCreationContext {
        PickupGameCreationContext(source: .team, team: team)
    }

    var isTeamSourced: Bool { source == .team && team != nil }
}

/// Product rules for Public/Private on create/edit (`pickup_games.is_visible`).
///
/// Canonical field: `pickup_games.is_visible`
/// - `true`  = Public (Discover-eligible under existing RLS / Discover filters)
/// - `false` = Private (authorized viewers only; Team membership ≠ Public)
///
/// - Normal Pickup create defaults Public (`true`).
/// - Team → Schedule Game create defaults Private (`false`) — privacy-safe default only.
/// - Organizer Public/Private selection always wins on save (Team or standalone).
/// - Outside recruiting (`needsAdditionalPlayers`) is independent and must NOT override visibility.
/// - Event Type / Sport changes must NOT override visibility.
/// - Edit seeds from the existing row only (never from Team create context).
/// - Standalone pickup games are always public. There is no private pickup game.
/// - Team events keep organizer Public/Private selection.
/// - Team link is independent of visibility (Public Team-linked games stay linked).
enum PickupGameEditPrivacyPolicy {
    /// Canonical `is_visible` value persisted for standalone pickup games.
    static let standalonePickupIsVisible = true

    /// Public/Private is a Team Event control only.
    static func showsVisibilityControl(isTeamLinked: Bool) -> Bool {
        isTeamLinked
    }

    /// Initial value for a **new** game only. Edit must use `row.is_visible` for Team events.
    /// Standalone pickup create is always Public.
    static func defaultIsPublicForNewGame(isTeamSourcedCreate: Bool) -> Bool {
        isTeamSourcedCreate ? false : standalonePickupIsVisible
    }

    /// Persist the organizer's form selection for Team events.
    /// Standalone pickup always persists the canonical public value.
    static func resolvedIsVisible(formIsPublic: Bool, isStandalonePickup: Bool = false) -> Bool {
        if isStandalonePickup { return standalonePickupIsVisible }
        return formIsPublic
    }

    /// Compatibility overload — recruiting must not override visibility.
    /// Standalone pickup stays public; Team events persist the organizer selection.
    static func resolvedIsVisible(
        formIsPublic: Bool,
        isTeamLinked: Bool,
        needsAdditionalPlayers: Bool
    ) -> Bool {
        _ = needsAdditionalPlayers
        return resolvedIsVisible(
            formIsPublic: formIsPublic,
            isStandalonePickup: !isTeamLinked
        )
    }
}

// MARK: - `public.pickup_games` (Supabase snake_case matches Codable)

struct PickupGameRow: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let creator_user_id: UUID
    let creator_email: String?
    let title: String
    let sport: String
    /// Optional reusable activity subtype (`mountain_biking`, `group_ride`, …). Nil on legacy rows.
    let sport_subtype: String?
    let description: String?
    let game_format: String
    /// Optional sport level axis (`youth`…`professional`). Nil = not specified.
    let competition_level: String?
    /// Stored tokens: `casual`, `beginner_friendly`, `intermediate`, `competitive`.
    let skill_level: String
    let game_start_at: String
    /// Optional scheduled end. Older rows may be nil; UI falls back to `game_start_at + 2h`.
    let end_time: String?
    let address: String?
    let city: String?
    let state: String?
    let latitude: Double?
    let longitude: Double?
    let is_visible: Bool
    let players_needed: Int
    let play_environment: String
    let participant_preference: String
    let age_min: Int?
    let age_max: Int?
    let is_free: Bool
    let entry_fee_amount: Double?
    let max_players: Int?
    let status: String
    /// Joiners with `approved` status (Phase 2); maintained server-side.
    let approved_join_count: Int?
    let cleanup_delay_hours: Int
    let remove_after_at: String?
    let created_at: String?
    let updated_at: String?
    /// `organizer_only` (default) | `approved_players`. Nil/unknown → organizer only.
    let poll_create_permission: String?
    /// Optional free-text opponent for Team competitive events (`pickup_games.opponent_name`).
    let opponent_name: String?
    /// Optional player arrival instant (`pickup_games.arrival_time`). Nil = not specified.
    let arrival_time: String?
    /// Team scoring columns (nil until 20261003 is applied / row is Live or Final).
    let team_score: Int?
    let opponent_score: Int?
    let scoring_status: String?
    let scoring_finalized_at: String?

    var pollCreatePermission: PickupPollCreatePermission {
        PickupPollCreatePermission.resolved(poll_create_permission)
    }

    init(
        id: UUID,
        creator_user_id: UUID,
        creator_email: String?,
        title: String,
        sport: String,
        sport_subtype: String? = nil,
        description: String?,
        game_format: String,
        competition_level: String? = nil,
        skill_level: String,
        game_start_at: String,
        end_time: String?,
        address: String?,
        city: String?,
        state: String?,
        latitude: Double?,
        longitude: Double?,
        is_visible: Bool,
        players_needed: Int,
        play_environment: String,
        participant_preference: String,
        age_min: Int?,
        age_max: Int?,
        is_free: Bool,
        entry_fee_amount: Double?,
        max_players: Int?,
        status: String,
        approved_join_count: Int?,
        cleanup_delay_hours: Int,
        remove_after_at: String?,
        created_at: String?,
        updated_at: String?,
        poll_create_permission: String? = nil,
        opponent_name: String? = nil,
        arrival_time: String? = nil,
        team_score: Int? = nil,
        opponent_score: Int? = nil,
        scoring_status: String? = nil,
        scoring_finalized_at: String? = nil
    ) {
        self.id = id
        self.creator_user_id = creator_user_id
        self.creator_email = creator_email
        self.title = title
        self.sport = sport
        self.sport_subtype = sport_subtype
        self.description = description
        self.game_format = game_format
        self.competition_level = competition_level
        self.skill_level = skill_level
        self.game_start_at = game_start_at
        self.end_time = end_time
        self.address = address
        self.city = city
        self.state = state
        self.latitude = latitude
        self.longitude = longitude
        self.is_visible = is_visible
        self.players_needed = players_needed
        self.play_environment = play_environment
        self.participant_preference = participant_preference
        self.age_min = age_min
        self.age_max = age_max
        self.is_free = is_free
        self.entry_fee_amount = entry_fee_amount
        self.max_players = max_players
        self.status = status
        self.approved_join_count = approved_join_count
        self.cleanup_delay_hours = cleanup_delay_hours
        self.remove_after_at = remove_after_at
        self.created_at = created_at
        self.updated_at = updated_at
        self.poll_create_permission = poll_create_permission
        self.opponent_name = opponent_name
        self.arrival_time = arrival_time
        self.team_score = team_score
        self.opponent_score = opponent_score
        self.scoring_status = scoring_status
        self.scoring_finalized_at = scoring_finalized_at
    }
}

// MARK: - `public.pickup_game_invites`

struct PickupGameInviteRow: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let pickup_game_id: UUID
    let inviter_user_id: UUID
    let invitee_user_id: UUID
    let status: String
    let message: String?
    let created_at: String
    let responded_at: String?
}

struct PickupGameInviteCreateResult: Decodable, Equatable {
    let invitee_user_id: UUID
    let invite_id: UUID?
    let outcome: String
}

struct PickupInvitableFanSearchResult: Decodable, Identifiable, Equatable, Hashable {
    let user_id: UUID
    let display_name: String
    let handle: String?
    let avatar_url: String?
    let is_friend: Bool

    var id: UUID { user_id }

    var displayHandle: String {
        let stored = handle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? "" : FanGeoHandleRules.displayHandle(stored: stored)
    }

    var userPreview: UserPreview {
        UserPreview(
            id: user_id,
            displayName: display_name,
            username: handle,
            email: nil,
            avatarURL: avatar_url,
            avatarThumbnailURL: avatar_url
        )
    }
}

struct PickupGameInviteDisplay: Identifiable {
    let invite: PickupGameInviteRow
    let game: PickupGameRow
    let inviterProfile: UserProfileRow?

    var id: UUID { invite.id }
}

extension PickupGameRow {
    /// Local optimistic patch (e.g. after joiner withdraw) before server row is re-fetched.
    func replacingApprovedJoinCount(_ newApprovedJoinCount: Int?) -> PickupGameRow {
        PickupGameRow(
            id: id,
            creator_user_id: creator_user_id,
            creator_email: creator_email,
            title: title,
            sport: sport,
            sport_subtype: sport_subtype,
            description: description,
            game_format: game_format,
            competition_level: competition_level,
            skill_level: skill_level,
            game_start_at: game_start_at,
            end_time: end_time,
            address: address,
            city: city,
            state: state,
            latitude: latitude,
            longitude: longitude,
            is_visible: is_visible,
            players_needed: players_needed,
            play_environment: play_environment,
            participant_preference: participant_preference,
            age_min: age_min,
            age_max: age_max,
            is_free: is_free,
            entry_fee_amount: entry_fee_amount,
            max_players: max_players,
            status: status,
            approved_join_count: newApprovedJoinCount,
            cleanup_delay_hours: cleanup_delay_hours,
            remove_after_at: remove_after_at,
            created_at: created_at,
            updated_at: updated_at,
            poll_create_permission: poll_create_permission,
            opponent_name: opponent_name,
            arrival_time: arrival_time,
            team_score: team_score,
            opponent_score: opponent_score,
            scoring_status: scoring_status,
            scoring_finalized_at: scoring_finalized_at
        )
    }

    func replacingScoring(
        teamScore: Int,
        opponentScore: Int,
        scoringStatus: String,
        scoringFinalizedAt: String?
    ) -> PickupGameRow {
        PickupGameRow(
            id: id,
            creator_user_id: creator_user_id,
            creator_email: creator_email,
            title: title,
            sport: sport,
            sport_subtype: sport_subtype,
            description: description,
            game_format: game_format,
            competition_level: competition_level,
            skill_level: skill_level,
            game_start_at: game_start_at,
            end_time: end_time,
            address: address,
            city: city,
            state: state,
            latitude: latitude,
            longitude: longitude,
            is_visible: is_visible,
            players_needed: players_needed,
            play_environment: play_environment,
            participant_preference: participant_preference,
            age_min: age_min,
            age_max: age_max,
            is_free: is_free,
            entry_fee_amount: entry_fee_amount,
            max_players: max_players,
            status: status,
            approved_join_count: approved_join_count,
            cleanup_delay_hours: cleanup_delay_hours,
            remove_after_at: remove_after_at,
            created_at: created_at,
            updated_at: updated_at,
            poll_create_permission: poll_create_permission,
            opponent_name: opponent_name,
            arrival_time: arrival_time,
            team_score: teamScore,
            opponent_score: opponentScore,
            scoring_status: scoringStatus,
            scoring_finalized_at: scoringFinalizedAt
        )
    }

    /// When this row should disappear from **Settings → My pickup games → History** (and matches organizer History footer math).
    /// Prefers `remove_after_at` from the server; otherwise `game_start_at` + retention hours.
    /// Pure date arithmetic — safely callable from nonisolated helpers such as ``PickupHostingAutoClear``.
    nonisolated func pickupHistoryClientCleanupDeadline() -> Date? {
        if let rem = remove_after_at, let d = PickupGameModels.parseSupabaseTimestamptz(rem) {
            return d
        }
        guard let start = PickupGameModels.parseSupabaseTimestamptz(game_start_at) else { return nil }
        let hours = cleanup_delay_hours > 0 ? cleanup_delay_hours : PickupGameAutoRemoval.hoursAfterGameStart
        let clamped = max(1, min(168, hours))
        return start.addingTimeInterval(Double(clamped) * 3600)
    }

    var pickupCompactTimeRange: String? {
        guard let start = PickupGameModels.parseSupabaseTimestamptz(game_start_at),
              let end = PickupGameModels.endDate(for: self),
              end > start else {
            return nil
        }
        return "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    /// Whole minutes between start and end (authoritative `game_start_at` / end).
    var pickupDurationMinutes: Int? {
        guard let start = PickupGameModels.parseSupabaseTimestamptz(game_start_at),
              let end = PickupGameModels.endDate(for: self),
              end > start else {
            return nil
        }
        let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
        return minutes > 0 ? minutes : nil
    }

    /// Compact duration for chips / inline use: `45m`, `1h`, `1h 30m`, `2h` (no "game" suffix).
    func pickupCompactDurationLabel(languageCode: String) -> String? {
        guard let minutes = pickupDurationMinutes else { return nil }
        return PickupGameDurationPresentation.compactLabel(
            totalMinutes: minutes,
            languageCode: languageCode
        )
    }

    var pickupDateWithCompactTimeRange: String? {
        pickupDateWithCompactTimeRange(locale: .autoupdatingCurrent)
    }

    func pickupDateWithCompactTimeRange(languageCode: String) -> String? {
        let code = L10n.normalizedLanguageCode(languageCode)
        return pickupDateWithCompactTimeRange(
            locale: Locale(identifier: code.replacingOccurrences(of: "-", with: "_"))
        )
    }

    /// Discover / list compact line: `Aug 10, 2026 • 3:03 PM – 5:03 PM • 2h`.
    func pickupDateWithCompactTimeRangeAndDuration(languageCode: String) -> String? {
        guard let base = pickupDateWithCompactTimeRange(languageCode: languageCode) else { return nil }
        guard let duration = pickupCompactDurationLabel(languageCode: languageCode) else { return base }
        return "\(base) • \(duration)"
    }

    /// VoiceOver-friendly date/time/duration (verbose spoken duration).
    func pickupDateTimeDurationAccessibilityLabel(languageCode: String) -> String? {
        guard let start = PickupGameModels.parseSupabaseTimestamptz(game_start_at) else { return nil }
        let code = L10n.normalizedLanguageCode(languageCode)
        let locale = Locale(identifier: code.replacingOccurrences(of: "-", with: "_"))
        let dateStyle = Date.FormatStyle.dateTime
            .month(.wide)
            .day()
            .year()
            .locale(locale)
        let timeStyle = Date.FormatStyle.dateTime
            .hour()
            .minute()
            .locale(locale)
        let dateText = start.formatted(dateStyle)
        let end = end_time.flatMap { PickupGameModels.parseSupabaseTimestamptz($0) }
            ?? PickupGameModels.defaultPickupEndTime(forStart: start)
        let timePart: String
        if end > start {
            timePart = "\(start.formatted(timeStyle)) to \(end.formatted(timeStyle))"
        } else {
            timePart = start.formatted(timeStyle)
        }
        if let minutes = pickupDurationMinutes,
           let spoken = PickupGameDurationPresentation.spokenLabel(
            totalMinutes: minutes,
            languageCode: code
           ) {
            // Spoken duration already locale-aware ("2 hours"); avoid ambiguous compact "2h".
            return "\(dateText), \(timePart), \(spoken)"
        }
        return "\(dateText), \(timePart)"
    }

    private func pickupDateWithCompactTimeRange(locale: Locale) -> String? {
        guard let start = PickupGameModels.parseSupabaseTimestamptz(game_start_at) else { return nil }
        let dateStyle = Date.FormatStyle.dateTime
            .month(.abbreviated)
            .day()
            .year()
            .locale(locale)
        let timeStyle = Date.FormatStyle.dateTime
            .hour()
            .minute()
            .locale(locale)
        let dateText = start.formatted(dateStyle)
        let end = end_time.flatMap { PickupGameModels.parseSupabaseTimestamptz($0) }
            ?? PickupGameModels.defaultPickupEndTime(forStart: start)
        if end > start {
            let range = "\(start.formatted(timeStyle)) – \(end.formatted(timeStyle))"
            return "\(dateText) • \(range)"
        }
        return "\(dateText) • \(start.formatted(timeStyle))"
    }

    var gameFormat: GameType {
        GameType.parse(game_format) ?? GameType(rawValue: game_format) ?? .pickup
    }

    var competitionLevel: PickupCompetitionLevel? {
        PickupCompetitionLevel.parse(competition_level)
    }

    func isPickupGameInvitable(now: Date = Date()) -> Bool {
        guard status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "active" else { return false }
        if let raw = remove_after_at,
           let removeAfter = PickupGameModels.parseSupabaseTimestamptz(raw),
           removeAfter <= now {
            return false
        }
        return true
    }

    /// Soft-cancelled organizer lifecycle (`status = removed`).
    var isPickupGameSoftCancelled: Bool {
        let st = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return st == "removed" || st == "cancelled" || st == "canceled"
    }

    /// Organizer may cancel only while the game is still active.
    func canOrganizerCancelPickupGame(viewerUserId: UUID?) -> Bool {
        guard let viewerUserId, creator_user_id == viewerUserId else { return false }
        return status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "active"
    }

    func sportIdentityLabel(languageCode: String? = nil, compact: Bool = false) -> String {
        SportSubtypeCatalog.identityLine(
            sport: sport,
            subtype: sport_subtype,
            languageCode: languageCode,
            compactSport: compact
        )
    }
}

struct PickupGameInsert: Encodable {
    let creator_user_id: UUID
    let creator_email: String?
    let title: String
    let sport: String
    let sport_subtype: String?
    let description: String?
    let game_format: String
    let competition_level: String?
    let skill_level: String
    let game_start_at: String
    let end_time: String
    let address: String?
    let city: String?
    let state: String?
    let latitude: Double?
    let longitude: Double?
    let is_visible: Bool
    let players_needed: Int
    let play_environment: String
    let participant_preference: String
    let age_min: Int?
    let age_max: Int?
    let is_free: Bool
    let entry_fee_amount: Double?
    let max_players: Int?
    let cleanup_delay_hours: Int
    /// Always `game_start_at` + 12h; sent on every write so `remove_after_at` never lags behind an edited start time.
    let remove_after_at: String
    let poll_create_permission: String
    let opponent_name: String?
    /// Optional; omitted from JSON when nil (column stays DEFAULT NULL on insert).
    let arrival_time: String?

    /// Write payload with canonical 12h pickup retention. Preserves caller `is_visible`
    /// (classic create passes true; Team Schedule Game passes false).
    func withCanonicalPickupCleanupDelay() -> PickupGameInsert {
        let remove = PickupGameModels.encodedPickupRemoveAfterAt(forEncodedGameStart: game_start_at)
        return PickupGameInsert(
            creator_user_id: creator_user_id,
            creator_email: creator_email,
            title: title,
            sport: sport,
            sport_subtype: sport_subtype,
            description: description,
            game_format: game_format,
            competition_level: competition_level,
            skill_level: skill_level,
            game_start_at: game_start_at,
            end_time: end_time,
            address: address,
            city: city,
            state: state,
            latitude: latitude,
            longitude: longitude,
            is_visible: is_visible,
            players_needed: players_needed,
            play_environment: play_environment,
            participant_preference: participant_preference,
            age_min: age_min,
            age_max: age_max,
            is_free: is_free,
            entry_fee_amount: entry_fee_amount,
            max_players: max_players,
            cleanup_delay_hours: PickupGameAutoRemoval.hoursAfterGameStart,
            remove_after_at: remove,
            poll_create_permission: poll_create_permission,
            opponent_name: opponent_name,
            arrival_time: arrival_time
        )
    }
}

/// PostgREST UPDATE-friendly optional timestamptz: encodes JSON `null` when absent so edits clear the column.
struct PickupNullableTimestamptz: Encodable, Equatable, Sendable {
    let iso: String?

    init(_ iso: String?) {
        self.iso = iso
    }

    init(date: Date?) {
        self.iso = date.map { PickupGameModels.encodeSupabaseTimestamptz($0) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let iso {
            try container.encode(iso)
        } else {
            try container.encodeNil()
        }
    }
}

struct PickupGameFullUpdate: Encodable {
    let title: String
    let sport: String
    let sport_subtype: String?
    let description: String?
    let game_format: String
    let competition_level: String?
    let skill_level: String
    let game_start_at: String
    let end_time: String
    let address: String?
    let city: String?
    let state: String?
    let latitude: Double?
    let longitude: Double?
    let is_visible: Bool
    let players_needed: Int
    let play_environment: String
    let participant_preference: String
    let age_min: Int?
    let age_max: Int?
    let is_free: Bool
    let entry_fee_amount: Double?
    let max_players: Int?
    let cleanup_delay_hours: Int
    /// Always `game_start_at` + 12h; sent on full edit so expiration tracks the edited start instant.
    let remove_after_at: String
    let poll_create_permission: String
    let opponent_name: String?
    let arrival_time: PickupNullableTimestamptz

    /// Write payload with canonical 12h pickup retention. Preserves caller `is_visible`
    /// so Team-private games are not republished on edit.
    func withCanonicalPickupCleanupDelay() -> PickupGameFullUpdate {
        let remove = PickupGameModels.encodedPickupRemoveAfterAt(forEncodedGameStart: game_start_at)
        return PickupGameFullUpdate(
            title: title,
            sport: sport,
            sport_subtype: sport_subtype,
            description: description,
            game_format: game_format,
            competition_level: competition_level,
            skill_level: skill_level,
            game_start_at: game_start_at,
            end_time: end_time,
            address: address,
            city: city,
            state: state,
            latitude: latitude,
            longitude: longitude,
            is_visible: is_visible,
            players_needed: players_needed,
            play_environment: play_environment,
            participant_preference: participant_preference,
            age_min: age_min,
            age_max: age_max,
            is_free: is_free,
            entry_fee_amount: entry_fee_amount,
            max_players: max_players,
            cleanup_delay_hours: PickupGameAutoRemoval.hoursAfterGameStart,
            remove_after_at: remove,
            poll_create_permission: poll_create_permission,
            opponent_name: opponent_name,
            arrival_time: arrival_time
        )
    }
}

/// Post-start roster patch: includes `game_start_at` / expiration columns so DB + PostgREST always re-sync `remove_after_at`
/// to the saved start time + 12h (covers legacy `UPDATE OF …` triggers that skipped roster-only updates).
struct PickupGameRosterCapacityUpdate: Encodable {
    let players_needed: Int
    let max_players: Int?
    let game_start_at: String
    let cleanup_delay_hours: Int
    let remove_after_at: String
}

/// Organizer soft-delete: hide from Discover/Calendar and allow bulk-cancel of join requests.
struct PickupGameSoftRemoveUpdate: Encodable {
    let status: String
    let is_visible: Bool
    let remove_after_at: String
}

// MARK: - Pickup creator ratings (`public.pickup_game_creator_ratings`)

nonisolated struct PickupCreatorPublicRatingStats: Equatable {
    let avgRating: Double
    let ratingCount: Int

    var trustDisplayLine: String {
        let avg = String(format: "%.1f", avgRating)
        let n = ratingCount == 1 ? "1 rating" : "\(ratingCount) ratings"
        return "★ \(avg) · \(n)"
    }

    /// Public pickup UI: star summary when rated, otherwise **New organizer** (no private feedback).
    var organizerTrustSummaryLine: String {
        guard ratingCount > 0 else { return "New organizer" }
        return trustDisplayLine
    }

    /// Pickup game **detail** sheet: always includes a leading star; uses “reviews” wording.
    var pickupOrganizerDetailRatingLine: String {
        if ratingCount > 0 {
            let avg = String(format: "%.1f", avgRating)
            let reviews = ratingCount == 1 ? "1 review" : "\(ratingCount) reviews"
            return "★ \(avg) · \(reviews)"
        }
        return "★ New organizer · No ratings yet"
    }

    /// Optional tier for public profile (derived from existing ``ratingCount`` / ``avgRating`` only).
    var publicProfileOrganizerTierLabel: String? {
        guard ratingCount > 0 else { return nil }
        if ratingCount >= 15, avgRating >= 4.7 { return "Top host" }
        if ratingCount >= 8, avgRating >= 4.5 { return "Trusted host" }
        if ratingCount >= 3 { return "Rated host" }
        return nil
    }

    /// Short trust copy for public profile organizer card.
    var publicProfileOrganizerTrustCopy: String {
        guard ratingCount > 0 else {
            return "This host is just getting started."
        }
        if avgRating >= 4.5, ratingCount >= 5 {
            return "Trusted by local players."
        }
        if avgRating >= 4.0 {
            return "Well rated by local players."
        }
        return "Building a pickup reputation."
    }

    var hasPublicOrganizerRatings: Bool {
        ratingCount > 0
    }
}

/// DEBUG: public profile pickup organizer reputation card.
enum PickupOrganizerReputationDebug {
    static func log(creatorUserId: UUID, stats: PickupCreatorPublicRatingStats?) {
#if DEBUG
        let resolved = stats ?? PickupCreatorPublicRatingStats(avgRating: 0, ratingCount: 0)
        print("[PickupOrganizerReputationDebug] userId=\(creatorUserId.uuidString.lowercased())")
        print("[PickupOrganizerReputationDebug] existingRatingLine=\(resolved.pickupOrganizerDetailRatingLine)")
        if resolved.ratingCount > 0 {
            print("[PickupOrganizerReputationDebug] avgRating=\(String(format: "%.1f", resolved.avgRating))")
            print("[PickupOrganizerReputationDebug] ratingCount=\(resolved.ratingCount)")
        } else {
            print("[PickupOrganizerReputationDebug] avgRating=n/a")
            print("[PickupOrganizerReputationDebug] ratingCount=0")
        }
#endif
    }
}

/// DEBUG: organizer identity resolved for pickup preview/detail cards.
enum PickupOrganizerDebug {
    static func log(organizerUserId: UUID, organizerAvatarUrl: String, organizerDisplayName: String) {
#if DEBUG
        print("[PickupOrganizerDebug] organizerUserId=\(organizerUserId.uuidString.lowercased())")
        print("[PickupOrganizerDebug] organizerAvatarUrl=\(organizerAvatarUrl)")
        print("[PickupOrganizerDebug] organizerDisplayName=\(organizerDisplayName)")
#endif
    }
}

/// Decodes JSON number or string for `numeric` columns from RPC.
struct PickupRPCNumericOrString: Decodable {
    let doubleValue: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) {
            doubleValue = d
        } else if let s = try? c.decode(String.self), let d = Double(s) {
            doubleValue = d
        } else {
            doubleValue = nil
        }
    }
}

/// RPC `pickup_creator_public_rating_stats` row (PostgREST JSON).
nonisolated struct PickupCreatorPublicRatingStatsRPCRow: Decodable {
    let avg_rating: PickupRPCNumericOrString?
    let rating_count: Int64

    nonisolated func toPublicStats() -> PickupCreatorPublicRatingStats? {
        if rating_count == 0 {
            return PickupCreatorPublicRatingStats(avgRating: 0, ratingCount: 0)
        }
        guard let avg = avg_rating?.doubleValue else { return nil }
        return PickupCreatorPublicRatingStats(avgRating: avg, ratingCount: Int(rating_count))
    }
}

struct PickupGameCreatorRatingUpsert: Encodable {
    let pickup_game_id: UUID
    let creator_user_id: UUID
    let rater_user_id: UUID
    let rating: Int
    let feedback: String?
}

/// DEBUG: organizer rating line on FanGeo pickup detail (matches UI copy).
enum PickupOrganizerRatingDebug {
    static func log(creatorUserId: UUID, stats: PickupCreatorPublicRatingStats?) {
#if DEBUG
        print("[PickupOrganizerRatingDebug] creatorUserId=\(creatorUserId.uuidString.lowercased())")
        if let stats, stats.ratingCount > 0 {
            print("[PickupOrganizerRatingDebug] avgRating=\(String(format: "%.1f", stats.avgRating))")
            print("[PickupOrganizerRatingDebug] ratingCount=\(stats.ratingCount)")
            print("[PickupOrganizerRatingDebug] shownOnDetail=\(stats.pickupOrganizerDetailRatingLine)")
        } else if let stats {
            print("[PickupOrganizerRatingDebug] avgRating=n/a")
            print("[PickupOrganizerRatingDebug] ratingCount=\(stats.ratingCount)")
            print("[PickupOrganizerRatingDebug] shownOnDetail=\(stats.pickupOrganizerDetailRatingLine)")
        } else {
            print("[PickupOrganizerRatingDebug] avgRating=nil")
            print("[PickupOrganizerRatingDebug] ratingCount=nil")
            print("[PickupOrganizerRatingDebug] shownOnDetail=nil")
        }
#endif
    }
}

enum PickupCreatorRatingDebug {
    static func log(
        pickupGameId: UUID,
        creatorUserId: UUID,
        raterUserId: UUID?,
        rating: Int?,
        submitSucceeded: Bool?,
        alreadyRated: Bool?
    ) {
#if DEBUG
        print("===== PICKUP RATING =====")
        print("[PickupCreatorRatingDebug] event=legacy_submit_trace")
        print("[PickupCreatorRatingDebug] hasPickupGameId=\(true)")
        print("[PickupCreatorRatingDebug] hasCreatorUserId=\(true)")
        print("[PickupCreatorRatingDebug] hasRaterUserId=\(raterUserId != nil)")
        print("[PickupCreatorRatingDebug] rating=\(rating.map(String.init) ?? "nil")")
        print("[PickupCreatorRatingDebug] submitSucceeded=\(submitSucceeded.map { $0 ? "true" : "false" } ?? "nil")")
        print("[PickupCreatorRatingDebug] alreadyRated=\(alreadyRated.map { $0 ? "true" : "false" } ?? "nil")")
#endif
    }

    /// Privacy-safe DEBUG diagnostics for the organizer-rating lifecycle.
    static func lifecycle(_ event: String, details: String = "") {
#if DEBUG
        print("===== PICKUP RATING =====")
        if details.isEmpty {
            print("[PickupRating] \(event)")
        } else {
            print("[PickupRating] \(event) \(details)")
        }
#endif
    }
}

/// Privacy-safe DEBUG diagnostics for Discover map organizer trust lines.
enum PickupOrganizerTrustDebug {
    static func lifecycle(_ event: String, details: String = "") {
#if DEBUG
        print("===== PICKUP ORGANIZER TRUST =====")
        if details.isEmpty {
            print("[PickupOrganizerTrust] \(event)")
        } else {
            print("[PickupOrganizerTrust] \(event) \(details)")
        }
#endif
    }

    static func logResolved(summary: PickupOrganizerSummary) {
#if DEBUG
        if summary.ratingCount > 0 {
            lifecycle(
                "reputation values resolved",
                details: "hosted=\(summary.hostedCount) ratings=\(summary.ratingCount) avg=\(summary.averageRating.map { String(format: "%.1f", $0) } ?? "nil")"
            )
        } else {
            lifecycle(
                "no-rating state resolved",
                details: "hosted=\(summary.hostedCount)"
            )
        }
#endif
    }
}

// MARK: - `public.pickup_game_requests` (Phase 2 join workflow)

struct PickupGameRequestRow: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let pickup_game_id: UUID
    let requester_user_id: UUID
    let requester_email: String?
    let requester_display_name: String?
    let requester_skill_level: String
    let message: String?
    let status: String
    let created_at: String?
    let updated_at: String?
    let responded_at: String?
}

struct PickupGameRequestInsert: Encodable {
    let pickup_game_id: UUID
    let requester_user_id: UUID
    let requester_email: String?
    let requester_display_name: String?
    let requester_skill_level: String
    let message: String?
}

struct PickupJoinRequestStatusUpdate: Encodable {
    let status: String
}

extension PickupGameRequestRow {
    var requesterSkillLevelEnum: PickupGameSkillLevel {
        PickupGameSkillLevel.fromStored(requester_skill_level)
    }

    var statusDisplayTitle: String {
        statusDisplayTitle(languageCode: L10n.defaultLanguageCode)
    }

    func statusDisplayTitle(languageCode: String) -> String {
        switch status.lowercased() {
        case "pending": return L10n.t("pickup_join_status_pending", languageCode: languageCode)
        case "approved": return L10n.t("pickup_host_participant_status_approved", languageCode: languageCode)
        case "rejected": return L10n.t("pickup_join_status_rejected", languageCode: languageCode)
        case "cancelled", "withdrawn":
            return L10n.t("pickup_join_status_cancelled", languageCode: languageCode)
        default: return status.capitalized
        }
    }

    /// Prefer `updated_at` over `created_at` when multiple join rows exist for the same game (re-requests).
    var pickupJoinRequestRecencyInstant: Date {
        let u = updated_at.flatMap { PickupGameModels.parseSupabaseTimestamptz($0) }
        let c = created_at.flatMap { PickupGameModels.parseSupabaseTimestamptz($0) }
        return u ?? c ?? .distantPast
    }

    /// One row per `pickup_game_id`: the most recently touched request for that game.
    static func pickupLatestRequestByGameId(_ rows: [PickupGameRequestRow]) -> [UUID: PickupGameRequestRow] {
        var best: [UUID: PickupGameRequestRow] = [:]
        for r in rows {
            guard let existing = best[r.pickup_game_id] else {
                best[r.pickup_game_id] = r
                continue
            }
            let nr = r.pickupJoinRequestRecencyInstant
            let er = existing.pickupJoinRequestRecencyInstant
            if nr > er {
                best[r.pickup_game_id] = r
            } else if nr == er, r.id.uuidString > existing.id.uuidString {
                best[r.pickup_game_id] = r
            }
        }
        return best
    }

    var requesterNameForUI: String {
        let n = requester_display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !n.isEmpty { return n }
        return "Player"
    }

    /// Best-effort instant the organizer (or requester cancel) last changed terminal status (`responded_at`, else `updated_at`).
    var organizerDecisionDate: Date? {
        let st = status.lowercased()
        guard st != "pending" else { return nil }
        if let r = responded_at, let d = PickupGameModels.parseSupabaseTimestamptz(r) { return d }
        if let u = updated_at, let d = PickupGameModels.parseSupabaseTimestamptz(u) { return d }
        return nil
    }

    private static let organizerStampLong: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return f
    }()

    private static let organizerStampShort: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.dateFormat = "MMM d · h:mm a"
        return f
    }()

    /// Apple-style copy for the organizer requests list (e.g. `Requested May 14, 2026 at 3:42 PM`).
    func organizerRequestedCaption(compactWidth: Bool) -> String {
        guard let created_at, let date = PickupGameModels.parseSupabaseTimestamptz(created_at) else {
            return "Requested"
        }
        let stamp = compactWidth
            ? Self.organizerStampShort.string(from: date)
            : Self.organizerStampLong.string(from: date)
        return "Requested \(stamp)"
    }

    /// Second line under the request: pending vs terminal status + decision time when known.
    func organizerDecisionStatusCaption(compactWidth: Bool) -> String {
        switch status.lowercased() {
        case "pending":
            return "Waiting for your decision"
        case "approved":
            guard let date = organizerDecisionDate else { return "Approved" }
            let stamp = compactWidth
                ? Self.organizerStampShort.string(from: date)
                : Self.organizerStampLong.string(from: date)
            return "Approved \(stamp)"
        case "rejected":
            guard let date = organizerDecisionDate else { return "Rejected" }
            let stamp = compactWidth
                ? Self.organizerStampShort.string(from: date)
                : Self.organizerStampLong.string(from: date)
            return "Rejected \(stamp)"
        case "withdrawn":
            return "Player changed their mind"
        case "cancelled":
            if responded_at == nil {
                return "Player withdrew their request"
            }
            return "Player changed their mind"
        default:
            return statusDisplayTitle
        }
    }

    /// Organizer-facing line for Settings “Can’t make it” list (fan withdrew / cancelled join).
    func organizerFanWithdrawnSubtitle() -> String {
        let st = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if st == "withdrawn" { return "Player changed their mind" }
        if st == "cancelled", responded_at != nil { return "Player changed their mind" }
        return "Player withdrew their request"
    }

    func organizerFanWithdrawnTimestampLine(compactWidth: Bool) -> String? {
        guard let date = organizerDecisionDate else { return nil }
        let stamp = compactWidth
            ? Self.organizerStampShort.string(from: date)
            : Self.organizerStampLong.string(from: date)
        return "Updated \(stamp)"
    }
}

// MARK: - Pickup option enums (raw values match DB CHECK constraints)

enum PickupPlayEnvironment: String, CaseIterable, Identifiable {
    case indoor
    case outdoor
    case either

    var id: String { rawValue }

    var displayTitle: String {
        displayTitle(languageCode: nil)
    }

    func displayTitle(languageCode: String?) -> String {
        switch self {
        case .indoor: return "Indoor"
        case .outdoor: return "Outdoor"
        case .either: return L10n.t("pickup_play_env_indoor_or_outdoor", languageCode: languageCode)
        }
    }

    var shortLabel: String {
        switch self {
        case .indoor: return "Indoor"
        case .outdoor: return "Outdoor"
        case .either: return "In or Out"
        }
    }
}

enum PickupGameSkillLevel: String, CaseIterable, Identifiable {
    case casual
    case beginner_friendly
    case intermediate
    case competitive

    var id: String { rawValue }

    var displayTitle: String {
        displayTitle(languageCode: nil)
    }

    func displayTitle(languageCode: String?) -> String {
        switch self {
        case .casual: return L10n.t("pickup_skill_casual", languageCode: languageCode)
        case .beginner_friendly: return "Beginner Friendly"
        case .intermediate: return "Intermediate"
        case .competitive: return "Competitive"
        }
    }

    static func fromStored(_ raw: String?) -> PickupGameSkillLevel {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return .casual
        }
        return PickupGameSkillLevel(rawValue: raw) ?? .casual
    }
}

enum PickupParticipantPreference: String, CaseIterable, Identifiable {
    case everyone
    case women_only
    case men_only
    case kids_only
    case adults_only
    case teens_welcome
    case seniors_welcome

    var id: String { rawValue }

    var displayTitle: String {
        displayTitle(languageCode: nil)
    }

    func displayTitle(languageCode: String?) -> String {
        switch self {
        case .everyone: return L10n.t("pickup_welcome_everyone", languageCode: languageCode)
        case .women_only: return "Women Only"
        case .men_only: return "Men Only"
        case .kids_only: return "Kids Only"
        case .adults_only: return "Adults Only"
        case .teens_welcome: return "Teens Welcome"
        case .seniors_welcome: return "Seniors Welcome"
        }
    }

    var shortLabel: String {
        switch self {
        case .everyone: return "All welcome"
        case .women_only: return "Women"
        case .men_only: return "Men"
        case .kids_only: return "Kids"
        case .adults_only: return "Adults"
        case .teens_welcome: return "Teens OK"
        case .seniors_welcome: return "Seniors"
        }
    }

    static func fromStored(_ raw: String?) -> PickupParticipantPreference {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return .everyone
        }
        return PickupParticipantPreference(rawValue: raw) ?? .everyone
    }
}

enum PickupGameAgeRangeFormatter {
    static let minimumAllowedAge = 1
    static let maximumAllowedAge = 99

    static func normalized(min rawMin: Int?, max rawMax: Int?) -> (min: Int?, max: Int?) {
        let minAge = rawMin.map { min(max($0, minimumAllowedAge), maximumAllowedAge) }
        let maxAge = rawMax.map { min(max($0, minimumAllowedAge), maximumAllowedAge) }
        if let minAge, let maxAge, maxAge < minAge {
            return (minAge, minAge)
        }
        return (minAge, maxAge)
    }

    static func ageRangeText(min rawMin: Int?, max rawMax: Int?) -> String? {
        let normalized = normalized(min: rawMin, max: rawMax)
        if let minAge = normalized.min, let maxAge = normalized.max {
            return "Ages \(minAge)–\(maxAge)"
        }
        return nil
    }

    static func audienceText(
        preference: PickupParticipantPreference,
        minAge: Int?,
        maxAge: Int?
    ) -> String {
        guard let range = ageRangeText(min: minAge, max: maxAge) else {
            return preference.displayTitle
        }
        return "\(preference.displayTitle) • \(range)"
    }
}

extension PickupGameRow {
    var approvedJoinCount: Int {
        approved_join_count ?? 0
    }

    /// Open join slots (joiners only; creator is separate from this count).
    var pickupOpenSlotsRemaining: Int {
        max(0, playersNeededClamped - approvedJoinCount)
    }

    var isPickupFullForDiscover: Bool {
        approvedJoinCount >= playersNeededClamped
    }

    /// Pure clamp used by UI and nonisolated diff/signature helpers. Bounds: 1...20.
    nonisolated static func clampPlayersNeeded(_ value: Int) -> Int {
        min(20, max(1, value))
    }

    var playersNeededClamped: Int {
        Self.clampPlayersNeeded(players_needed)
    }

    var lookingForPlayersLine: String {
        let n = playersNeededClamped
        return n == 1 ? "Looking for 1 player" : "Looking for \(n) players"
    }

    var playEnvironmentEnum: PickupPlayEnvironment {
        PickupPlayEnvironment(rawValue: play_environment) ?? .either
    }

    var skillLevelEnum: PickupGameSkillLevel {
        PickupGameSkillLevel.fromStored(skill_level)
    }

    var participantPreferenceEnum: PickupParticipantPreference {
        PickupParticipantPreference.fromStored(participant_preference)
    }

    var participantAudienceDisplayTitle: String {
        PickupGameAgeRangeFormatter.audienceText(
            preference: participantPreferenceEnum,
            minAge: age_min,
            maxAge: age_max
        )
    }

    /// One line for list rows: "Free" or "$12 entry" (USD).
    var entryFeeDisplayLine: String {
        if is_free { return "Free" }
        guard let amt = entry_fee_amount else { return "Paid" }
        return PickupGameModels.currencyEntryString(amount: amt)
    }

    /// Compact Discover chip, e.g. "$12".
    var entryFeeChipTitle: String {
        if is_free { return "Free" }
        guard let amt = entry_fee_amount else { return "Paid" }
        return PickupGameModels.currencyChipString(amount: amt)
    }

    var maxPlayersChipTitle: String? {
        guard let max = max_players else { return nil }
        return "Max \(max)"
    }

    /// True when local time has reached or passed the scheduled start (`now >= game_start_at`).
    func hasPickupGameStarted(now: Date = Date()) -> Bool {
        guard let start = PickupGameModels.parseSupabaseTimestamptz(game_start_at) else { return false }
        return now >= start
    }

    /// Post-game organizer rating: scheduled end reached (matches backend `submit_pickup_creator_rating`).
    /// Uses `end_time`, or start + 2h when end is missing — not merely game start / remove_after.
    func isPickupCreatorRatingPromptEligible(now: Date = Date()) -> Bool {
        let st = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if st == "cancelled" || st == "canceled" { return false }
        guard let end = PickupGameModels.endDate(for: self) else { return false }
        return now >= end
    }
}

/// DEBUG lines for pickup post-start organizer UX (see product spec).
enum PickupGameStartedStateDebug {
    private static let logNowFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func log(row: PickupGameRow, now: Date, allowedActions: String) {
#if DEBUG
        let isStarted = row.hasPickupGameStarted(now: now)
        print("[PickupGameStartedStateDebug] gameId=\(row.id.uuidString.lowercased())")
        print("[PickupGameStartedStateDebug] game_start_at=\(row.game_start_at)")
        print("[PickupGameStartedStateDebug] now=\(logNowFormatter.string(from: now))")
        print("[PickupGameStartedStateDebug] isStarted=\(isStarted)")
        print("[PickupGameStartedStateDebug] allowedActions=\(allowedActions)")
#endif
    }
}

enum PickupGameModels {
    private static let moneyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 2
        return f
    }()

    nonisolated static func parseSupabaseTimestamptz(_ raw: String) -> Date? {
        SupabaseTimestampParsing.parseTimestamptz(raw)
    }

    nonisolated static func encodeSupabaseTimestamptz(_ date: Date) -> String {
        SupabaseTimestampParsing.encodeTimestamptz(date)
    }

    nonisolated static func defaultPickupEndTime(forStart start: Date) -> Date {
        start.addingTimeInterval(2 * 3600)
    }

    nonisolated static func endDate(for row: PickupGameRow) -> Date? {
        if let raw = row.end_time, let end = parseSupabaseTimestamptz(raw) {
            return end
        }
        guard let start = parseSupabaseTimestamptz(row.game_start_at) else { return nil }
        return defaultPickupEndTime(forStart: start)
    }

    nonisolated static func encodedDefaultEndTime(forStart start: Date) -> String {
        encodeSupabaseTimestamptz(defaultPickupEndTime(forStart: start))
    }

    /// Encoded `remove_after_at` for `pickup_games`: `game_start_at` + fixed pickup retention (12h).
    nonisolated static func encodedPickupRemoveAfterAt(forEncodedGameStart gameStartISO: String) -> String {
        let start = parseSupabaseTimestamptz(gameStartISO) ?? Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(Double(PickupGameAutoRemoval.hoursAfterGameStart) * 3600)
        return encodeSupabaseTimestamptz(end)
    }

    static func currencyEntryString(amount: Double) -> String {
        let n = NSNumber(value: amount)
        let base = moneyFormatter.string(from: n) ?? "$\(String(format: "%.2f", amount))"
        return base + " entry"
    }

    static func currencyChipString(amount: Double) -> String {
        let n = NSNumber(value: amount)
        return moneyFormatter.string(from: n) ?? "$\(String(format: "%.2f", amount))"
    }
}

enum PickupGameClientError: LocalizedError {
    case notSignedIn
    case missingRowAfterWrite
    case businessAccountsCannotUsePickupGames
    case pickupGameNotFound
    case pickupGameNotOrganizer

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to manage pickup games."
        case .missingRowAfterWrite:
            return "Couldn’t read the saved pickup game. Try again in a moment."
        case .businessAccountsCannotUsePickupGames:
            return BusinessFanGateCopy.pickupFanOnly
        case .pickupGameNotFound:
            return "Couldn’t find this pickup game to update. Try refreshing My pickup games."
        case .pickupGameNotOrganizer:
            return "Only the organizer can cancel this pickup game."
        }
    }
}
