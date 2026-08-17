import Foundation

/// Presentation-only status attached to the standalone Pickup emblem.
/// Does not change join rules, visibility, or map clustering.
enum FanGeoPickupEmblemStatus: String, Equatable, CaseIterable, Sendable {
    case live
    case started
    case full
    case fewSpots
    case newGame

    var localizationKey: String {
        switch self {
        case .live: return "discover_pickup_emblem_live"
        case .started: return "discover_pickup_emblem_started"
        case .full: return "discover_pickup_emblem_full"
        case .fewSpots: return "discover_pickup_emblem_few_spots"
        case .newGame: return "discover_pickup_emblem_new"
        }
    }

    /// One badge max. In-progress games prefer LIVE; already-started-but-ended stay Started.
    static func resolve(
        hasStarted: Bool,
        hasEnded: Bool,
        isFull: Bool,
        openSlots: Int,
        createdAt: Date?,
        now: Date = Date()
    ) -> FanGeoPickupEmblemStatus? {
        if hasStarted, !hasEnded {
            return .live
        }
        if hasStarted {
            return .started
        }
        if isFull {
            return .full
        }
        if openSlots > 0, openSlots <= 3 {
            return .fewSpots
        }
        if let createdAt, now.timeIntervalSince(createdAt) >= 0, now.timeIntervalSince(createdAt) < 24 * 60 * 60 {
            return .newGame
        }
        return nil
    }

    static func resolve(row: PickupGameRow, now: Date = Date()) -> FanGeoPickupEmblemStatus? {
        let started = row.hasPickupGameStarted(now: now)
        let ended: Bool = {
            guard let end = PickupGameModels.endDate(for: row) else { return false }
            return now >= end
        }()
        let created = row.created_at.flatMap { PickupGameModels.parseSupabaseTimestamptz($0) }
        return resolve(
            hasStarted: started,
            hasEnded: ended,
            isFull: row.isPickupFullForDiscover,
            openSlots: row.pickupOpenSlotsRemaining,
            createdAt: created,
            now: now
        )
    }
}
