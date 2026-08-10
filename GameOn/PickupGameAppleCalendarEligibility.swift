import Foundation

/// Pure eligibility rules for Sync to Apple Calendar → Pickup Games.
/// Team-linked games remain `pickup_games` (via `fan_team_game_links`); one id → one EventKit event.
nonisolated enum PickupGameAppleCalendarEligibility {
    static let fanGeoIdentifierPrefix = "pickup|"

    static func fanGeoIdentifier(forPickupGameId id: UUID) -> String {
        "\(fanGeoIdentifierPrefix)\(id.uuidString.lowercased())"
    }

    static func pickupGameId(fromFanGeoIdentifier raw: String?) -> UUID? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              raw.hasPrefix(fanGeoIdentifierPrefix) else { return nil }
        return UUID(uuidString: String(raw.dropFirst(fanGeoIdentifierPrefix.count)))
    }

    /// Hosted/organizer rows: only active games (soft-cancelled `removed` must not stay on calendar).
    static func shouldSyncHostedGame(status: String) -> Bool {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "active"
    }

    /**
     Participant / RSVP / invite semantics (aligned with set_fan_team_game_rsvp):
     - approved / Going → sync
     - pending + Team-linked → Team Maybe → sync
     - pending + normal Pickup → awaiting organizer approval → do not sync
     - declined / cancelled / withdrawn / Can't Go → do not sync
     */
    static func shouldSyncJoinPill(
        _ pill: PickupFollowingJoinRequestPillKind,
        isTeamLinked: Bool
    ) -> Bool {
        switch pill {
        case .approved:
            return true
        case .pending:
            return isTeamLinked
        case .declined, .cancelled, .withdrawing, .canceledByOrganizer:
            return false
        }
    }

    /// Request-row status form (when cards are not yet rebuilt).
    static func shouldSyncRequestStatus(
        _ status: String,
        isTeamLinked: Bool
    ) -> Bool {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "approved":
            return true
        case "pending":
            return isTeamLinked
        default:
            return false
        }
    }

    /// Invite statuses that commit the invitee without a separate Team RSVP row.
    static func shouldSyncInviteStatus(_ status: String) -> Bool {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "accepted", "maybe":
            return true
        default:
            return false
        }
    }
}
