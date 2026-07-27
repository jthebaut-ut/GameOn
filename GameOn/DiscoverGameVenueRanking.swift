import Foundation

/// Game-specific Discover venue ranking for a focused professional game.
/// Reuses ``VenueMapEnergyScore`` at event scope — never a second formula.
///
/// Explicitly ``nonisolated``: pure ranking math (project default isolation is MainActor).
nonisolated enum DiscoverGameVenueRanking {
    static let topLimit = 5

    struct Candidate: Equatable, Sendable, Identifiable {
        let id: UUID
        let venueName: String
        let gameSpecificEnergy: Int
        let goingCount: Int
        let distanceMiles: Double?
        let isLiveNow: Bool
        let venueEventID: UUID?

        var tier: VenueMapEnergyScore.EnergyTier {
            VenueMapEnergyScore.tier(for: gameSpecificEnergy)
        }
    }

    /// Single-event energy via the shared Venue Energy model (Going, vibes, commenters, LIVE).
    static func gameSpecificEnergy(activity: VenueMapEnergyScore.EventActivity) -> Int {
        VenueMapEnergyScore.scoreTotal(events: [activity])
    }

    static func gameSpecificEnergy(
        goingCount: Int,
        vibeCounts: [String: Int],
        uniqueCommenterCount: Int,
        isLiveNow: Bool
    ) -> Int {
        gameSpecificEnergy(
            activity: VenueMapEnergyScore.eventActivity(
                goingCount: goingCount,
                vibeCounts: vibeCounts,
                uniqueCommenterCount: uniqueCommenterCount,
                isLiveNow: isLiveNow
            )
        )
    }

    /// Deterministic Top N: energy DESC → going DESC → distance ASC → name ASC → id ASC.
    /// Business Pro / sponsorship never participate.
    static func rank(_ candidates: [Candidate], limit: Int = topLimit) -> [Candidate] {
        let capped = max(0, limit)
        guard capped > 0 else { return [] }

        return candidates.sorted { lhs, rhs in
            if lhs.gameSpecificEnergy != rhs.gameSpecificEnergy {
                return lhs.gameSpecificEnergy > rhs.gameSpecificEnergy
            }
            if lhs.goingCount != rhs.goingCount {
                return lhs.goingCount > rhs.goingCount
            }
            let ld = lhs.distanceMiles ?? .greatestFiniteMagnitude
            let rd = rhs.distanceMiles ?? .greatestFiniteMagnitude
            if ld != rd {
                return ld < rd
            }
            let nameCmp = lhs.venueName.localizedCaseInsensitiveCompare(rhs.venueName)
            if nameCmp != .orderedSame {
                return nameCmp == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        .prefix(capped)
        .map { $0 }
    }

    /// Display caption for list/map (empty when Normal / zero energy).
    static func tierCaption(forEnergy energy: Int) -> String {
        let tier = VenueMapEnergyScore.tier(for: energy)
        switch tier {
        case .normal:
            return ""
        case .starting, .active, .hot, .trending:
            let emoji = tier.emoji
            return emoji.isEmpty ? tier.rawValue : "\(emoji) \(tier.rawValue)"
        }
    }
}
