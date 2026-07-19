import Foundation
import SwiftUI

// MARK: - Post-game presentation window (Live cards only)

/// Pure deterministic timing helpers for Live-card presentation only.
/// Marked `nonisolated` so sync presentation builders can call them without MainActor hops.
nonisolated enum FanGeoLivePostGameTiming {
    /// Local presentation-only window after definitive/conservatively derived completion.
    /// Live-screen only — does not change Discover `FanGeoLiveEnergy.isLiveNow` (4h window may deserve a later audit).
    static let postGameActivityWindowMinutes = 90

    /// True when `now` is at/after completion and still inside the post-game window.
    nonisolated static func isWithinPostGameActivityWindow(completionTime: Date, now: Date = Date()) -> Bool {
        let windowEnd = completionTime.addingTimeInterval(TimeInterval(postGameActivityWindowMinutes * 60))
        return now >= completionTime && now <= windowEnd
    }

    /// Prefer an authoritative/conservatively derived completion from already-loaded match timing.
    /// Returns `nil` when no honest completion time exists — callers must omit Post-Game Activity.
    ///
    /// Does **not** use Discover’s 4-hour `FanGeoLiveEnergyTiming.liveWindowHours`.
    /// Reads only immutable `LiveMatch` / timeline fields (no UI or actor state).
    nonisolated static func completionTime(from match: LiveMatch) -> Date? {
        guard match.matchStatus == .fullTime else { return nil }

        let timelineMinutes = match.timelineEvents.compactMap(\.minuteValue).filter { $0 >= 0 }
        if let lastMinute = timelineMinutes.max(), lastMinute > 0 {
            return match.startTime.addingTimeInterval(TimeInterval(lastMinute * 60))
        }
        if let minute = match.minute, minute > 0 {
            return match.startTime.addingTimeInterval(TimeInterval(minute * 60))
        }
        return nil
    }
}

// MARK: - Canonical match status (sports/event feed only)

enum LiveCanonicalMatchStatus: Equatable {
    case live(minute: Int?)
    case halfTime
    case startingSoon(minutes: Int)
    case upcoming(start: Date)
    case final
    case postponed
    case canceled
    case unknown

    var isLive: Bool {
        switch self {
        case .live, .halfTime: return true
        default: return false
        }
    }

    var isFinal: Bool {
        if case .final = self { return true }
        return false
    }

    /// Localization key for a compact status badge. `nil` means omit the badge.
    var badgeLocalizationKey: String? {
        switch self {
        case .live:
            return "LIVE"
        case .halfTime:
            return "HT"
        case .startingSoon:
            return "Starting soon"
        case .upcoming:
            return nil
        case .final:
            return "FINAL"
        case .postponed:
            return "Postponed"
        case .canceled:
            return "Canceled"
        case .unknown:
            return nil
        }
    }

    static func from(
        match: LiveMatch,
        now: Date = Date(),
        startsSoonWindowMinutes: Int = FanGeoLiveEnergyTiming.startsSoonWindowMinutes
    ) -> LiveCanonicalMatchStatus {
        if let postponedOrCanceled = postponedOrCanceled(fromRaw: match.rawMatchStatus) {
            return postponedOrCanceled
        }

        switch match.matchStatus {
        case .fullTime:
            return .final
        case .halfTime:
            return .halfTime
        case .live:
            return .live(minute: match.minute)
        case .scheduled:
            let secondsUntil = match.startTime.timeIntervalSince(now)
            if secondsUntil > 0 && secondsUntil <= TimeInterval(startsSoonWindowMinutes * 60) {
                return .startingSoon(minutes: max(1, Int(ceil(secondsUntil / 60))))
            }
            if secondsUntil > 0 {
                return .upcoming(start: match.startTime)
            }
            return .unknown
        }
    }

    static func from(
        adminStatus: String?,
        eventStart: Date?,
        now: Date = Date(),
        startsSoonWindowMinutes: Int = FanGeoLiveEnergyTiming.startsSoonWindowMinutes
    ) -> LiveCanonicalMatchStatus {
        let raw = (adminStatus ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "final", "finished", "completed", "ended":
            return .final
        case "live", "in_progress", "in progress":
            return .live(minute: nil)
        case "postponed", "delayed":
            return .postponed
        case "cancelled", "canceled", "inactive", "deleted":
            return .canceled
        default:
            break
        }

        guard let start = eventStart else { return .unknown }
        let secondsUntil = start.timeIntervalSince(now)
        if secondsUntil > 0 && secondsUntil <= TimeInterval(startsSoonWindowMinutes * 60) {
            return .startingSoon(minutes: max(1, Int(ceil(secondsUntil / 60))))
        }
        if secondsUntil > 0 {
            return .upcoming(start: start)
        }
        // Past kickoff without sports/admin status: omit LIVE (do not infer from clock window).
        return .unknown
    }

    private static func postponedOrCanceled(fromRaw raw: String?) -> LiveCanonicalMatchStatus? {
        let status = (raw ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .uppercased()
        guard !status.isEmpty else { return nil }
        if status.contains("POSTPON") || status.contains("DELAY") {
            return .postponed
        }
        if status.contains("CANCEL") || status.contains("ABANDON") || status.contains("WALKOVER") {
            return .canceled
        }
        return nil
    }
}

// MARK: - Venue activity (FanGeo signals only)

enum LiveVenueActivityKind: Equatable {
    case crowdBuilding
    case activeFanZone
    case postGameActivity

    var localizationKey: String {
        switch self {
        case .crowdBuilding: return "Crowd building"
        case .activeFanZone: return "Active Fan Zone"
        case .postGameActivity: return "Post-Game Activity"
        }
    }
}

enum LiveVenueActivityResolver {
    static func resolve(
        matchStatus: LiveCanonicalMatchStatus,
        completionTime: Date?,
        goingCount: Int,
        commentCount: Int,
        friendGoingCount: Int,
        vibeCount: Int,
        energyStartsSoon: Bool,
        now: Date = Date()
    ) -> LiveVenueActivityKind? {
        let hasActivitySignal = goingCount > 0
            || commentCount > 0
            || friendGoingCount > 0
            || vibeCount > 0

        if matchStatus.isFinal {
            guard hasActivitySignal,
                  let completionTime,
                  FanGeoLivePostGameTiming.isWithinPostGameActivityWindow(
                    completionTime: completionTime,
                    now: now
                  ) else {
                return nil
            }
            return .postGameActivity
        }

        // Never attach Active Fan Zone / Crowd Building from clock-LIVE alone.
        if matchStatus.isLive { return nil }

        if energyStartsSoon, goingCount > 0 {
            return .crowdBuilding
        }

        let preview = VenueGamePreviewEnergy.evaluate(
            fireCount: 0,
            seatsCount: 0,
            tvCount: 0,
            soundCount: 0,
            crowdCount: vibeCount,
            goingCount: goingCount,
            friendGoingCount: friendGoingCount,
            commentCount: commentCount,
            isLiveNow: false,
            startsSoon: energyStartsSoon
        )
        if preview.label == "🟢 Active Fan Zone" {
            return .activeFanZone
        }
        if energyStartsSoon, preview.score >= 10, hasActivitySignal {
            return .crowdBuilding
        }
        return nil
    }
}

// MARK: - Immutable card presentation

struct LiveVenueEventCardModel: Equatable {
    let itemID: String
    let venueName: String
    let matchupTitle: String
    let homeTeam: String?
    let awayTeam: String?
    let homeScore: Int?
    let awayScore: Int?
    let scoresAvailable: Bool
    let homeBadgeURL: String?
    let awayBadgeURL: String?
    let matchStatus: LiveCanonicalMatchStatus
    let venueActivity: LiveVenueActivityKind?
    let goingCount: Int
    let showGoingCount: Bool
    let thumbnailURLString: String?
    let sport: String
    let linkedMatchID: String?
    let metadataLine: String
}

struct LivePickupCardModel: Equatable {
    let id: UUID
    let title: String
    let sport: String
    let locationLine: String?
    let statusLabelKey: String
    let statusDetail: String?
    let joinLine: String?
    let isInProgress: Bool
}

enum LiveVenueEventCardModelBuilder {
    static func build(
        item: LiveScreenLiveFeedItemBridge,
        linkedMatch: LiveMatch?,
        venueRowAdminStatus: String?,
        languageCode: String,
        formattedStartTime: (Date) -> String
    ) -> LiveVenueEventCardModel {
        let eventStart = linkedMatch?.startTime ?? item.eventDate
        let matchStatus: LiveCanonicalMatchStatus = {
            if let linkedMatch {
                return LiveCanonicalMatchStatus.from(match: linkedMatch)
            }
            return LiveCanonicalMatchStatus.from(
                adminStatus: venueRowAdminStatus,
                eventStart: eventStart
            )
        }()

        let homeTeam = linkedMatch?.homeTeam
            ?? item.homeTeam
        let awayTeam = linkedMatch?.awayTeam
            ?? item.awayTeam

        let scoresAvailable = linkedMatch?.scoresAreAvailable == true
            && (matchStatus.isLive || matchStatus.isFinal)
        let homeScore = scoresAvailable ? linkedMatch?.scoreHome : nil
        let awayScore = scoresAvailable ? linkedMatch?.scoreAway : nil

        let matchupTitle: String = {
            if let awayTeam, let homeTeam, !awayTeam.isEmpty, !homeTeam.isEmpty {
                if scoresAvailable, let awayScore, let homeScore {
                    return "\(awayTeam) \(awayScore)–\(homeScore) \(homeTeam)"
                }
                return "\(awayTeam) vs \(homeTeam)"
            }
            return item.eventTitle
        }()

        let completionTime = linkedMatch.flatMap { FanGeoLivePostGameTiming.completionTime(from: $0) }
        let venueActivity = LiveVenueActivityResolver.resolve(
            matchStatus: matchStatus,
            completionTime: completionTime,
            goingCount: item.goingCount,
            commentCount: item.commentCount,
            friendGoingCount: item.friendGoingCount,
            vibeCount: item.vibeCount,
            energyStartsSoon: item.energyStartsSoon
        )

        let metadataLine: String = {
            switch matchStatus {
            case .startingSoon(let minutes):
                return String(format: L10n.t("Starts in %lld min", languageCode: languageCode), minutes)
            case .upcoming(let start):
                return formattedStartTime(start)
            case .live(let minute):
                if let minute {
                    return "LIVE \(minute)'"
                }
                return L10n.t("LIVE", languageCode: languageCode)
            case .halfTime:
                return L10n.t("HT", languageCode: languageCode)
            case .final:
                return L10n.t("FINAL", languageCode: languageCode)
            case .postponed:
                return L10n.t("Postponed", languageCode: languageCode)
            case .canceled:
                return L10n.t("Canceled", languageCode: languageCode)
            case .unknown:
                return AppSportCatalog.displayLabel(forSportToken: item.sport)
            }
        }()

        return LiveVenueEventCardModel(
            itemID: item.id,
            venueName: item.venueName,
            matchupTitle: matchupTitle,
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            homeScore: homeScore,
            awayScore: awayScore,
            scoresAvailable: scoresAvailable,
            homeBadgeURL: linkedMatch?.homeTeamBadgeURL,
            awayBadgeURL: linkedMatch?.awayTeamBadgeURL,
            matchStatus: matchStatus,
            venueActivity: venueActivity,
            goingCount: item.goingCount,
            showGoingCount: item.goingCount > 0,
            thumbnailURLString: item.thumbnailURLString,
            sport: item.sport,
            linkedMatchID: linkedMatch?.id,
            metadataLine: metadataLine
        )
    }
}

enum LivePickupCardModelBuilder {
    static func build(row: PickupGameRow, now: Date = Date()) -> LivePickupCardModel {
        let location = [row.city, row.address]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(2)
            .joined(separator: " · ")

        let status = pickupStatus(row: row, now: now)
        let joinLine: String? = {
            let approved = row.approved_join_count
            guard approved != nil else { return nil }
            let open = row.pickupOpenSlotsRemaining
            if open > 0 {
                return open == 1 ? "1 spot open" : "\(open) spots open"
            }
            return row.lookingForPlayersLine
        }()

        return LivePickupCardModel(
            id: row.id,
            title: row.title,
            sport: row.sport,
            locationLine: location.isEmpty ? nil : location,
            statusLabelKey: status.key,
            statusDetail: status.detail,
            joinLine: joinLine,
            isInProgress: status.key == "pickup_status_in_progress"
        )
    }

    private static func pickupStatus(row: PickupGameRow, now: Date) -> (key: String, detail: String?) {
        let statusRaw = row.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if statusRaw == "cancelled" || statusRaw == "canceled" {
            return ("Canceled", nil)
        }

        guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else {
            return ("Starting soon", nil)
        }

        let end: Date = {
            if let raw = row.end_time, let parsed = PickupGameModels.parseSupabaseTimestamptz(raw) {
                return parsed
            }
            return start.addingTimeInterval(2 * 3600)
        }()

        if now >= end {
            return ("Completed", nil)
        }

        if row.hasPickupGameStarted(now: now) {
            return ("pickup_status_in_progress", nil)
        }

        let secondsUntil = start.timeIntervalSince(now)
        if secondsUntil > 0 && secondsUntil <= TimeInterval(FanGeoLiveEnergyTiming.startsSoonWindowMinutes * 60) {
            let minutes = max(1, Int(ceil(secondsUntil / 60)))
            return ("Starting soon", "\(minutes)")
        }
        return ("Starting soon", nil)
    }
}

/// Narrow bridge so presentation builders stay free of LiveScreen’s private types.
struct LiveScreenLiveFeedItemBridge: Equatable {
    let id: String
    let eventTitle: String
    let eventDate: Date
    let sport: String
    let venueName: String
    let homeTeam: String?
    let awayTeam: String?
    let goingCount: Int
    let commentCount: Int
    let friendGoingCount: Int
    let vibeCount: Int
    let energyStartsSoon: Bool
    let thumbnailURLString: String?
}
