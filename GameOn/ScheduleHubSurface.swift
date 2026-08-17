import SwiftUI

/// Top-level Schedule destination surface (Live / Watch / Play / Pro).
///
/// Session + SceneStorage only — no backend. Watch/Play/Pro map onto existing
/// ``CalendarTabGameFilter`` without changing calendar business logic.
///
/// Going is a **root** tab (`AppTab.following`), not a Schedule surface.
enum ScheduleHubSurface: String, CaseIterable, Identifiable, Equatable, Sendable {
    case live
    case watch
    case play
    case pro

    var id: String { rawValue }

    /// Legacy SceneStorage value from the intermediate Schedule-embedded Going build.
    static let legacyGoingRawValue = "going"

    static let primarySegments: [ScheduleHubSurface] = [.live, .watch, .play, .pro]

    var segmentTitleKey: String {
        switch self {
        case .live: return "live"
        case .watch: return "intent_watch"
        case .play: return "intent_play"
        case .pro: return "pro_games"
        }
    }

    var segmentTitle: String {
        L10n.t(segmentTitleKey)
    }

    var accessibilityLabelKey: String {
        switch self {
        case .live: return "live"
        case .watch: return "schedule_a11y_watch"
        case .play: return "schedule_a11y_play"
        case .pro: return "schedule_a11y_pro_games"
        }
    }

    var systemImage: String {
        switch self {
        case .live: return "dot.radiowaves.left.and.right"
        case .watch: return "sportscourt.fill"
        case .play: return "figure.run"
        case .pro: return "trophy.fill"
        }
    }

    var intentTint: Color {
        switch self {
        case .live: return FGColor.accentGreen
        case .watch: return FGColor.intentWatch
        case .play: return FGColor.intentPlay
        case .pro: return FGColor.intentProGames
        }
    }

    var calendarFilter: CalendarTabGameFilter? {
        switch self {
        case .watch: return .venueGames
        case .play: return .pickupGames
        case .pro: return .proGames
        case .live: return nil
        }
    }

    var isCalendarContent: Bool {
        calendarFilter != nil
    }

    static func from(calendarFilter: CalendarTabGameFilter) -> ScheduleHubSurface {
        switch calendarFilter {
        case .venueGames: return .watch
        case .pickupGames: return .play
        case .proGames: return .pro
        }
    }

    static func primarySegments(hidingPlay: Bool) -> [ScheduleHubSurface] {
        hidingPlay ? [.live, .watch, .pro] : primarySegments
    }

    /// Migrates the intermediate `"going"` SceneStorage value to a Schedule surface.
    static func migrating(rawValue: String?) -> ScheduleHubSurface {
        let raw = (rawValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw == legacyGoingRawValue { return .watch }
        return ScheduleHubSurface(rawValue: raw) ?? .watch
    }
}
