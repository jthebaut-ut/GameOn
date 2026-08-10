import Foundation

// MARK: - Timeline (authoritative Pickup lifecycle, no Team-only completion flag)

/// Upcoming / Past for Team → Games presentation.
///
/// Rule (documented):
/// - **Past** when RPC lifecycle status is `completed` or `cancelled`, OR the game’s
///   effective end (`endsAt` ?? `startsAt`) is before `now`.
/// - **Upcoming** otherwise (`scheduled` / active and not yet finished).
///
/// Uses `list_fan_team_games` status mapping over `pickup_games.status` / `archived_at`
/// plus `game_start_at` / `end_time` — not a separate Team completion column.
enum FanTeamGamesTimeline {
    static func isUpcoming(_ game: FanTeamGame, now: Date = Date()) -> Bool {
        let status = game.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if status == "completed" || status == "cancelled" || status == "canceled" || status == "removed" {
            return false
        }
        let effectiveEnd = game.endsAt ?? game.startsAt
        return effectiveEnd >= now
    }

    static func isPast(_ game: FanTeamGame, now: Date = Date()) -> Bool {
        !isUpcoming(game, now: now)
    }

    /// Past ordering key: most recent finished first uses this descending.
    static func pastSortDate(_ game: FanTeamGame) -> Date {
        game.endsAt ?? game.startsAt
    }
}

// MARK: - Filter / sort state

enum FanTeamGamesStatusFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case upcoming
    case past

    var id: String { rawValue }

    var localizedKey: String {
        switch self {
        case .upcoming: return "fan_teams_games_filter_upcoming"
        case .past: return "fan_teams_games_filter_past"
        }
    }

    var sectionLocalizedKey: String { localizedKey }
}

enum FanTeamGamesDatePreset: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case today
    case thisWeek
    case next7Days
    case thisMonth
    case custom

    var id: String { rawValue }

    var localizedKey: String {
        switch self {
        case .all: return "fan_teams_games_date_all"
        case .today: return "fan_teams_games_date_today"
        case .thisWeek: return "fan_teams_games_date_this_week"
        case .next7Days: return "fan_teams_games_date_next_7_days"
        case .thisMonth: return "fan_teams_games_date_this_month"
        case .custom: return "fan_teams_games_date_custom"
        }
    }
}

/// User-facing sort options. Availability depends on Upcoming vs Past.
enum FanTeamGamesSort: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// Upcoming: closest `startsAt` first.
    case soonestFirst
    /// Upcoming: furthest future `startsAt` first.
    case latestFirst
    /// Past: most recent (`endsAt` ?? `startsAt`) first.
    case mostRecentFirst
    /// Past: oldest (`endsAt` ?? `startsAt`) first.
    case oldestFirst

    var id: String { rawValue }

    var localizedKey: String {
        switch self {
        case .soonestFirst: return "fan_teams_games_sort_soonest"
        case .latestFirst: return "fan_teams_games_sort_latest"
        case .mostRecentFirst: return "fan_teams_games_sort_most_recent"
        case .oldestFirst: return "fan_teams_games_sort_oldest"
        }
    }

    static func options(for status: FanTeamGamesStatusFilter) -> [FanTeamGamesSort] {
        switch status {
        case .upcoming: return [.soonestFirst, .latestFirst]
        case .past: return [.mostRecentFirst, .oldestFirst]
        }
    }

    static func defaultSort(for status: FanTeamGamesStatusFilter) -> FanTeamGamesSort {
        switch status {
        case .upcoming: return .soonestFirst
        case .past: return .mostRecentFirst
        }
    }
}

struct FanTeamGamesFilterState: Equatable, Sendable {
    var status: FanTeamGamesStatusFilter = .upcoming
    /// `nil` = all types (`pickup_games.game_format`).
    var gameType: FanTeamGameType? = nil
    var datePreset: FanTeamGamesDatePreset = .all
    var customStart: Date? = nil
    var customEnd: Date? = nil
    /// Optional `pickup_games.competition_level` filter.
    var competitionLevel: PickupCompetitionLevel? = nil
    /// `nil` = status-aware default sort.
    var sortOverride: FanTeamGamesSort? = nil

    static let `default` = FanTeamGamesFilterState()

    /// Secondary filters only (not Upcoming/Past, not sort).
    var hasActiveSecondaryFilters: Bool {
        gameType != nil
            || datePreset != .all
            || competitionLevel != nil
            || customStart != nil
            || customEnd != nil
    }

    /// Count of distinct secondary filter dimensions (for Filter badge).
    var activeSecondaryFilterCount: Int {
        var count = 0
        if gameType != nil { count += 1 }
        if datePreset != .all { count += 1 }
        if competitionLevel != nil { count += 1 }
        return count
    }

    var isDefault: Bool {
        status == .upcoming
            && !hasActiveSecondaryFilters
            && sortOverride == nil
    }

    var hasActiveFilters: Bool { hasActiveSecondaryFilters }

    mutating func clearSecondaryFilters() {
        gameType = nil
        datePreset = .all
        customStart = nil
        customEnd = nil
        competitionLevel = nil
    }

    /// Clears secondary filters only (preserves Upcoming/Past + sort).
    mutating func clear() {
        clearSecondaryFilters()
    }

    func resolvedSort() -> FanTeamGamesSort {
        let options = FanTeamGamesSort.options(for: status)
        if let sortOverride, options.contains(sortOverride) {
            return sortOverride
        }
        return FanTeamGamesSort.defaultSort(for: status)
    }

    mutating func selectStatus(_ next: FanTeamGamesStatusFilter) {
        status = next
        // Drop sort override that doesn't apply to the new status.
        if let sortOverride, !FanTeamGamesSort.options(for: next).contains(sortOverride) {
            self.sortOverride = nil
        }
    }
}

// MARK: - Sections

enum FanTeamGamesSectionKind: String, Hashable, Sendable {
    case upcoming
    case past

    var localizedKey: String {
        switch self {
        case .upcoming: return "fan_teams_games_filter_upcoming"
        case .past: return "fan_teams_games_filter_past"
        }
    }
}

struct FanTeamGamesSection: Identifiable, Equatable, Sendable {
    let kind: FanTeamGamesSectionKind
    let games: [FanTeamGame]

    var id: String { kind.rawValue }
}

struct FanTeamGamesPresentationResult: Equatable, Sendable {
    let sections: [FanTeamGamesSection]
    let filteredCount: Int
    let totalCount: Int
}

enum FanTeamGamesFilterEngine {
    /// Supported `pickup_games.game_format` filters (secondary menu only).
    static let supportedTypeFilters: [FanTeamGameType] = [
        .league_game, .tournament_game, .match, .practice, .scrimmage, .tryout, .clinic, .pickup
    ]

    static func dateInterval(
        for preset: FanTeamGamesDatePreset,
        customStart: Date?,
        customEnd: Date?,
        now: Date,
        calendar: Calendar
    ) -> DateInterval? {
        switch preset {
        case .all:
            return nil
        case .today:
            let start = calendar.startOfDay(for: now)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: now)
        case .next7Days:
            let start = calendar.startOfDay(for: now)
            guard let end = calendar.date(byAdding: .day, value: 7, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now)
        case .custom:
            let startDay = calendar.startOfDay(for: customStart ?? now)
            let endBase = customEnd ?? customStart ?? now
            let endDayStart = calendar.startOfDay(for: endBase)
            let endExclusive = calendar.date(byAdding: .day, value: 1, to: endDayStart)
                ?? endDayStart.addingTimeInterval(24 * 3600)
            let lo = min(startDay, endDayStart)
            let hi = max(startDay.addingTimeInterval(24 * 3600), endExclusive)
            return DateInterval(start: lo, end: hi)
        }
    }

    static func matchesDate(_ game: FanTeamGame, interval: DateInterval?) -> Bool {
        guard let interval else { return true }
        return interval.contains(game.startsAt)
    }

    static func filter(
        _ games: [FanTeamGame],
        state: FanTeamGamesFilterState,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [FanTeamGame] {
        let interval = dateInterval(
            for: state.datePreset,
            customStart: state.customStart,
            customEnd: state.customEnd,
            now: now,
            calendar: calendar
        )
        return games.filter { game in
            switch state.status {
            case .upcoming:
                guard FanTeamGamesTimeline.isUpcoming(game, now: now) else { return false }
            case .past:
                guard FanTeamGamesTimeline.isPast(game, now: now) else { return false }
            }
            if let type = state.gameType, game.gameType != type {
                return false
            }
            if let level = state.competitionLevel, game.competitionLevel != level {
                return false
            }
            return matchesDate(game, interval: interval)
        }
    }

    static func sort(
        _ games: [FanTeamGame],
        sort: FanTeamGamesSort,
        status: FanTeamGamesStatusFilter,
        now: Date = Date()
    ) -> [FanTeamGame] {
        _ = now
        _ = status
        switch sort {
        case .soonestFirst:
            return games.sorted {
                if $0.startsAt != $1.startsAt { return $0.startsAt < $1.startsAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        case .latestFirst:
            return games.sorted {
                if $0.startsAt != $1.startsAt { return $0.startsAt > $1.startsAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        case .mostRecentFirst:
            return games.sorted {
                let a = FanTeamGamesTimeline.pastSortDate($0)
                let b = FanTeamGamesTimeline.pastSortDate($1)
                if a != b { return a > b }
                return $0.id.uuidString < $1.id.uuidString
            }
        case .oldestFirst:
            return games.sorted {
                let a = FanTeamGamesTimeline.pastSortDate($0)
                let b = FanTeamGamesTimeline.pastSortDate($1)
                if a != b { return a < b }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
    }

    static func present(
        _ games: [FanTeamGame],
        state: FanTeamGamesFilterState,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> FanTeamGamesPresentationResult {
        let filtered = filter(games, state: state, now: now, calendar: calendar)
        let sorted = sort(filtered, sort: state.resolvedSort(), status: state.status, now: now)
        let sections = buildSections(sorted, state: state)
        return FanTeamGamesPresentationResult(
            sections: sections,
            filteredCount: sorted.count,
            totalCount: games.count
        )
    }

    /// Single section matching the primary Upcoming/Past segment.
    static func buildSections(
        _ games: [FanTeamGame],
        state: FanTeamGamesFilterState
    ) -> [FanTeamGamesSection] {
        guard !games.isEmpty else { return [] }
        let kind: FanTeamGamesSectionKind = state.status == .past ? .past : .upcoming
        return [FanTeamGamesSection(kind: kind, games: games)]
    }

    static func summaryLine(
        result: FanTeamGamesPresentationResult,
        state: FanTeamGamesFilterState,
        languageCode: String
    ) -> String? {
        guard state.hasActiveSecondaryFilters, result.filteredCount > 0 else { return nil }
        let count = result.filteredCount
        let locale = Locale(identifier: languageCode)

        if let type = state.gameType {
            let typeName = L10n.t(type.localizedKey, languageCode: languageCode).lowercased(with: locale)
            if state.status == .upcoming {
                return String(
                    format: L10n.t("fan_teams_games_summary_upcoming_type_format", languageCode: languageCode),
                    locale: locale,
                    Int64(count),
                    typeName
                )
            }
            return String(
                format: L10n.t("fan_teams_games_summary_type_format", languageCode: languageCode),
                locale: locale,
                Int64(count),
                typeName
            )
        }

        if state.status == .upcoming {
            return String(
                format: L10n.t("fan_teams_games_summary_upcoming_format", languageCode: languageCode),
                locale: locale,
                Int64(count)
            )
        }
        return String(
            format: L10n.t("fan_teams_games_summary_past_format", languageCode: languageCode),
            locale: locale,
            Int64(count)
        )
    }
}
