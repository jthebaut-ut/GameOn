import Foundation

/// Authoritative Discover-map venue energy (day-scoped fan activity).
/// Shared by snapshot, fallback pin scoring, and cluster energy.
/// Commercial/Pro/sponsored status must never contribute organic points.
///
/// Explicitly ``nonisolated``: scoring is pure value math used from detached
/// Discover map snapshot builders (project default isolation is MainActor).
nonisolated enum VenueMapEnergyScore {
    // MARK: - Points

    static let pointsGoing = 5
    static let pointsAtmosphere = 4
    static let pointsCrowded = 4
    static let pointsTV = 3
    static let pointsSound = 3
    static let pointsSeating = 2
    static let pointsUniqueCommenter = 2
    static let pointsLiveBonus = 15

    // MARK: - Caps (per event)

    static let capGoing = 100
    static let capAtmosphere = 40
    static let capCrowded = 40
    static let capTV = 30
    static let capSound = 30
    static let capSeating = 20
    static let capUniqueCommenters = 20

    // MARK: - Canonical vibe storage keys (`venue_event_vibes.vibe_type`)

    /// Product: Great Atmosphere / On fire
    static let vibeAtmosphere = "packed"
    /// Product: Crowded
    static let vibeCrowded = "crowd"
    /// Product: TVs Available
    static let vibeTV = "tv_visible"
    /// Product: Game Sound
    static let vibeSound = "audio_on"
    /// Product: Seating Available
    static let vibeSeating = "seats_open"

    // MARK: - Tiers

    enum EnergyTier: String, Sendable {
        case normal = "Normal"
        case starting = "Starting"
        case active = "Active"
        case hot = "Hot"
        case trending = "Trending"

        var emoji: String {
            switch self {
            case .normal: return ""
            case .starting: return "✨"
            case .active: return "🔥"
            case .hot: return "🚀"
            case .trending: return "👑"
            }
        }

        var clusterCaption: String? {
            switch self {
            case .normal: return nil
            case .starting: return "✨ Starting"
            case .active: return "🔥 Active"
            case .hot: return "🚀 Hot"
            case .trending: return "👑 Trending"
            }
        }

        /// Pulse for Hot/Trending (and LIVE handled separately by callers).
        var shouldPulse: Bool {
            switch self {
            case .hot, .trending: return true
            default: return false
            }
        }

        var isTrendingPulse: Bool { self == .trending }
    }

    /// Hot threshold — also the pulse floor when not LIVE.
    static let hotPulseThreshold = 30

    static func tier(for score: Int) -> EnergyTier {
        switch score {
        case 60...: return .trending
        case 30..<60: return .hot
        case 10..<30: return .active
        case 1..<10: return .starting
        default: return .normal
        }
    }

    // MARK: - Inputs / outputs

    struct EventActivity: Equatable, Sendable {
        var goingCount: Int
        var atmosphereCount: Int
        var crowdedCount: Int
        var tvCount: Int
        var soundCount: Int
        var seatingCount: Int
        /// Unique fans who participated in visible comments for this event.
        var uniqueCommenterCount: Int
        var isLiveNow: Bool
    }

    struct Breakdown: Equatable, Sendable {
        var goingPoints: Int
        var atmospherePoints: Int
        var crowdedPoints: Int
        var tvPoints: Int
        var soundPoints: Int
        var seatingPoints: Int
        var commenterPoints: Int
        var liveBonus: Int

        var total: Int {
            goingPoints
                + atmospherePoints
                + crowdedPoints
                + tvPoints
                + soundPoints
                + seatingPoints
                + commenterPoints
                + liveBonus
        }

        var tier: EnergyTier { VenueMapEnergyScore.tier(for: total) }
    }

    // MARK: - Scoring

    /// Per-event contribution (capped). LIVE is recorded here for aggregation;
    /// venue-level scoring applies LIVE at most once via ``score(events:)``.
    static func eventContribution(_ activity: EventActivity, includeLiveBonus: Bool) -> Breakdown {
        Breakdown(
            goingPoints: min(capGoing, max(0, activity.goingCount) * pointsGoing),
            atmospherePoints: min(capAtmosphere, max(0, activity.atmosphereCount) * pointsAtmosphere),
            crowdedPoints: min(capCrowded, max(0, activity.crowdedCount) * pointsCrowded),
            tvPoints: min(capTV, max(0, activity.tvCount) * pointsTV),
            soundPoints: min(capSound, max(0, activity.soundCount) * pointsSound),
            seatingPoints: min(capSeating, max(0, activity.seatingCount) * pointsSeating),
            commenterPoints: min(capUniqueCommenters, max(0, activity.uniqueCommenterCount) * pointsUniqueCommenter),
            liveBonus: includeLiveBonus && activity.isLiveNow ? pointsLiveBonus : 0
        )
    }

    /// Venue pin energy for the selected day: sum event activity + at most one LIVE bonus.
    static func score(events: [EventActivity]) -> Breakdown {
        guard !events.isEmpty else {
            return Breakdown(
                goingPoints: 0,
                atmospherePoints: 0,
                crowdedPoints: 0,
                tvPoints: 0,
                soundPoints: 0,
                seatingPoints: 0,
                commenterPoints: 0,
                liveBonus: 0
            )
        }

        var going = 0
        var atmosphere = 0
        var crowded = 0
        var tv = 0
        var sound = 0
        var seating = 0
        var commenters = 0
        var anyLive = false

        for event in events {
            let part = eventContribution(event, includeLiveBonus: false)
            going += part.goingPoints
            atmosphere += part.atmospherePoints
            crowded += part.crowdedPoints
            tv += part.tvPoints
            sound += part.soundPoints
            seating += part.seatingPoints
            commenters += part.commenterPoints
            if event.isLiveNow { anyLive = true }
        }

        return Breakdown(
            goingPoints: going,
            atmospherePoints: atmosphere,
            crowdedPoints: crowded,
            tvPoints: tv,
            soundPoints: sound,
            seatingPoints: seating,
            commenterPoints: commenters,
            liveBonus: anyLive ? pointsLiveBonus : 0
        )
    }

    static func scoreTotal(events: [EventActivity]) -> Int {
        score(events: events).total
    }

    static func eventActivity(
        goingCount: Int,
        vibeCounts: [String: Int],
        uniqueCommenterCount: Int,
        isLiveNow: Bool
    ) -> EventActivity {
        EventActivity(
            goingCount: goingCount,
            atmosphereCount: vibeCounts[vibeAtmosphere] ?? 0,
            crowdedCount: vibeCounts[vibeCrowded] ?? 0,
            tvCount: vibeCounts[vibeTV] ?? 0,
            soundCount: vibeCounts[vibeSound] ?? 0,
            seatingCount: vibeCounts[vibeSeating] ?? 0,
            uniqueCommenterCount: uniqueCommenterCount,
            isLiveNow: isLiveNow
        )
    }

#if DEBUG
    static func debugLog(venueName: String, venueId: UUID, breakdown: Breakdown, activityTotals: EventActivity?) {
        let a = activityTotals
        print(
            """
            [VenueEnergy] venue=\(venueName) id=\(venueId.uuidString.lowercased()) \
            goingPts=\(breakdown.goingPoints) atmospherePts=\(breakdown.atmospherePoints) \
            crowdedPts=\(breakdown.crowdedPoints) tvPts=\(breakdown.tvPoints) \
            soundPts=\(breakdown.soundPoints) seatingPts=\(breakdown.seatingPoints) \
            commentersPts=\(breakdown.commenterPoints) live=\(breakdown.liveBonus) \
            total=\(breakdown.total) tier=\(breakdown.tier.rawValue) \
            rawGoing=\(a?.goingCount ?? -1) rawAtm=\(a?.atmosphereCount ?? -1) \
            rawCrowd=\(a?.crowdedCount ?? -1) rawTV=\(a?.tvCount ?? -1) \
            rawSound=\(a?.soundCount ?? -1) rawSeat=\(a?.seatingCount ?? -1) \
            rawCommenters=\(a?.uniqueCommenterCount ?? -1) rawLive=\(a?.isLiveNow ?? false)
            """
        )
    }
#endif
}
