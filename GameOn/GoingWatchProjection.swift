import Foundation

/// Compact Going → Watch filter. Chips are the only Watch filter UI.
enum GoingWatchFilter: String, CaseIterable, Hashable, Sendable {
    case all
    case games
    case favoriteSpots

    /// Watch has no Filter dropdown; chips stay on-screen.
    static var usesAlwaysVisibleChips: Bool { true }

    var titleKey: String {
        switch self {
        case .all: return "going_play_filter_all"
        case .games: return "games_im_going_to"
        case .favoriteSpots: return "saved_spots"
        }
    }

    /// Short chip label. Semantics stay on ``titleKey``.
    var chipTitleKey: String {
        switch self {
        case .all: return "going_play_filter_all"
        case .games: return "going_watch_chip_im_going"
        case .favoriteSpots: return "saved_spots"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "tv.fill"
        case .games: return "calendar"
        case .favoriteSpots: return "heart.fill"
        }
    }
}

/// One Watch feed row. Games and favorite spots stay distinct models;
/// this is a presentation/projection layer only.
struct GoingWatchItem: Identifiable, Equatable {
    enum Source: Equatable {
        case game
        case favoriteSpot
    }

    let source: Source
    let game: FollowingGoingDisplayItem?
    let spot: BarVenue?

    var id: String {
        switch source {
        case .game:
            return "watch-game-\(game?.id.uuidString ?? "")"
        case .favoriteSpot:
            return "watch-spot-\(spot?.id.uuidString ?? "")"
        }
    }
}

enum GoingWatchProjection {
    struct FilterCounts: Equatable {
        var all: Int
        var games: Int
        var favoriteSpots: Int
    }

    /// Games first (existing chronological order), then favorite spots in
    /// the existing saved-venue order. Spots have no fabricated start time.
    static func unified(
        games: [FollowingGoingDisplayItem],
        spots: [BarVenue]
    ) -> [GoingWatchItem] {
        var seenGames = Set<UUID>()
        var seenSpots = Set<UUID>()
        var items: [GoingWatchItem] = []
        items.reserveCapacity(games.count + spots.count)

        for game in games {
            guard seenGames.insert(game.id).inserted else { continue }
            items.append(GoingWatchItem(source: .game, game: game, spot: nil))
        }
        for spot in spots {
            guard seenSpots.insert(spot.id).inserted else { continue }
            items.append(GoingWatchItem(source: .favoriteSpot, game: nil, spot: spot))
        }
        return items
    }

    static func filtered(
        _ items: [GoingWatchItem],
        filter: GoingWatchFilter
    ) -> [GoingWatchItem] {
        switch filter {
        case .all:
            return items
        case .games:
            return items.filter { $0.source == .game }
        case .favoriteSpots:
            return items.filter { $0.source == .favoriteSpot }
        }
    }

    static func filterCounts(_ items: [GoingWatchItem]) -> FilterCounts {
        FilterCounts(
            all: items.count,
            games: items.filter { $0.source == .game }.count,
            favoriteSpots: items.filter { $0.source == .favoriteSpot }.count
        )
    }

    static func gameTitle(for item: FollowingGoingDisplayItem) -> String {
        let title = VenueGameCompetitorDisplay.publicTitle(
            eventTitle: item.venueEvent.event_title,
            sport: item.venueEvent.sport,
            homeTeam: item.venueEvent.home_team,
            awayTeam: item.venueEvent.away_team
        )
        if !title.isEmpty { return title }
        let fallback = item.venueEvent.event_title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fallback.isEmpty ? item.bar.name : fallback
    }

    static func statusTimeLine(
        for item: FollowingGoingDisplayItem,
        languageCode: String,
        timeZoneOption: FanGeoTimeZonePreference,
        now: Date = Date()
    ) -> String {
        if let start = VenueGameExpiration.scheduledStartDate(for: item.venueEvent) {
            let day = compactDayLabel(for: start, languageCode: languageCode, now: now)
            let time = CompactGameTimeFormatter.timeWithZone(
                for: start,
                timeZoneOption: timeZoneOption
            )
            return "\(day) · \(time)"
        }
        let datePart = item.venueEvent.event_date?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let timePart = item.venueEvent.event_time?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return [datePart, timePart].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func locationLine(
        bar: BarVenue,
        languageCode: String
    ) -> String {
        let address = FanTeamScheduleLocationPresentation.collapsedLine(
            bar.displayAddress(languageCode: languageCode)
        )
        return FanTeamScheduleLocationPresentation.displayLocation(
            venueName: bar.name,
            address: address.isEmpty ? nil : address,
            city: nil,
            state: nil
        )
    }

    static func spotLocationLine(
        bar: BarVenue,
        languageCode: String
    ) -> String {
        FanTeamScheduleLocationPresentation.collapsedLine(
            bar.displayAddress(languageCode: languageCode)
        )
    }

    static func tonightTitles(
        for spot: BarVenue,
        games: [FollowingGoingDisplayItem],
        now: Date = Date()
    ) -> [String] {
        let calendar = Calendar.current
        var seen = Set<String>()
        var titles: [String] = []
        for game in games where game.bar.id == spot.id {
            let start = VenueGameExpiration.scheduledStartDate(for: game.venueEvent)
            let isToday: Bool
            if let start {
                isToday = calendar.isDate(start, inSameDayAs: now)
            } else {
                isToday = false
            }
            guard isToday else { continue }
            let title = gameTitle(for: game)
            guard !title.isEmpty, seen.insert(title.lowercased()).inserted else { continue }
            titles.append(title)
        }
        return titles
    }

    static func compactDayLabel(
        for date: Date,
        languageCode: String,
        now: Date = Date()
    ) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return L10n.t("Today", languageCode: languageCode)
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return L10n.t("Tomorrow", languageCode: languageCode)
        }
        let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        return date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted)
                .weekday(.abbreviated)
                .locale(locale)
        )
    }

    static func emptyTitleKey(for filter: GoingWatchFilter) -> String {
        switch filter {
        case .all: return "going_watch_empty_title"
        case .games: return "going_watch_empty_games"
        case .favoriteSpots: return "going_watch_empty_spots"
        }
    }

    static func emptySupportingKey(for filter: GoingWatchFilter) -> String {
        switch filter {
        case .all: return "going_watch_empty_supporting"
        case .games: return "going_watch_empty_games_supporting"
        case .favoriteSpots: return "going_watch_empty_spots_supporting"
        }
    }
}
