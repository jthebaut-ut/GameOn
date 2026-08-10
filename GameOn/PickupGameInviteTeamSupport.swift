import Foundation

/// Invite Friends security split (must match `20260938_0001_pickup_invite_fan_team_roster.sql`):
/// - Individuals → `create_pickup_game_invites` (friend | public-invitable only)
/// - Teams → `create_pickup_game_invites_from_fan_team` (active roster of a managed Team)
/// Team co-membership must NEVER widen the generic Individuals RPC.
enum PickupInviteRPCRoute: String, Equatable, Sendable {
    case individualsGeneric
    case teamBulkTrusted

    /// Which backend RPC creates invites for a picker mode.
    static func route(for mode: PickupInvitePickerMode) -> PickupInviteRPCRoute {
        switch mode {
        case .individuals: return .individualsGeneric
        case .teams: return .teamBulkTrusted
        }
    }
}

enum PickupInvitePickerMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case individuals
    case teams

    var id: String { rawValue }

    var localizedKey: String {
        switch self {
        case .individuals: return "pickup_invite_mode_individuals"
        case .teams: return "pickup_invite_mode_teams"
        }
    }
}

struct PickupFanTeamInvitePreview: Equatable, Sendable {
    let teamId: UUID
    let memberCountExcludingOrganizer: Int
    let eligibleCount: Int
    let alreadyInvitedCount: Int
    let alreadyPlayingCount: Int
    let alreadyPendingCount: Int
    let ineligibleCount: Int

    var hasExclusions: Bool {
        alreadyInvitedCount + alreadyPlayingCount + alreadyPendingCount + ineligibleCount > 0
    }
}

/// Pure preview/send capacity math for Team bulk invites.
/// Must stay aligned with `preview_pickup_game_fan_team_invite` /
/// `create_pickup_game_invites_from_fan_team` in `20260938_0001_pickup_invite_fan_team_roster.sql`.
enum PickupFanTeamInvitePreviewSemantics {
    static let maxActiveInvitesPerGame = 50

    /// Remaining create slots from non-cancelled active invites on the game.
    static func remainingSlots(activeInviteCount: Int) -> Int {
        max(0, maxActiveInvitesPerGame - max(0, activeInviteCount))
    }

    /// Actionable eligible count Send can create NOW (raw eligible capped by remaining slots).
    static func actionableEligibleCount(rawEligible: Int, activeInviteCount: Int) -> Int {
        min(max(0, rawEligible), remainingSlots(activeInviteCount: activeInviteCount))
    }

    /// Cap overflow (Send `max_reached`) folds into preview `ineligible_count`.
    static func ineligibleCountIncludingCapOverflow(
        baseIneligible: Int,
        rawEligible: Int,
        actionableEligible: Int
    ) -> Int {
        max(0, baseIneligible) + max(0, rawEligible - actionableEligible)
    }

    /// Production duplicate semantics: ANY prior invite row blocks re-invite (incl. cancelled).
    static func isAlreadyInvited(hasAnyInviteRow: Bool) -> Bool {
        hasAnyInviteRow
    }
}

enum PickupInviteRecipientGate {
    /// Soft cap matching backend `create_pickup_game_invites` LIMIT / max active invites.
    static let maxInviteesPerGame = 50
    static let bulkConfirmThreshold = 12

    static func selectableUserIds(
        candidateIds: [UUID],
        organizerId: UUID?,
        gateByUserId: [UUID: String],
        alreadySelected: Set<UUID>,
        maxTotal: Int = maxInviteesPerGame
    ) -> (added: [UUID], skippedGated: Int, skippedCapacity: Int) {
        var added: [UUID] = []
        var skippedGated = 0
        var skippedCapacity = 0
        var working = alreadySelected
        for id in candidateIds {
            if let organizerId, id == organizerId {
                skippedGated += 1
                continue
            }
            if gateByUserId[id] != nil {
                skippedGated += 1
                continue
            }
            if working.contains(id) { continue }
            if working.count >= maxTotal {
                skippedCapacity += 1
                continue
            }
            working.insert(id)
            added.append(id)
        }
        return (added, skippedGated, skippedCapacity)
    }

    static func sendButtonTitle(count: Int, languageCode: String) -> String {
        if count <= 0 {
            return L10n.t("Send", languageCode: languageCode)
        }
        if count == 1 {
            return L10n.t("pickup_invite_send_one", languageCode: languageCode)
        }
        return String(
            format: L10n.t("pickup_invite_send_count_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            Int64(count)
        )
    }
}
