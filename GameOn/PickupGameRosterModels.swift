import Foundation

/// One public-safe identity row from `get_pickup_game_roster`.
struct PickupGameRosterMember: Identifiable, Equatable, Hashable, Decodable {
    let user_id: UUID
    let request_id: UUID?
    let display_name: String?
    let username: String?
    let avatar_url: String?
    let avatar_thumbnail_url: String?
    let role: String?
    let status: String?

    var id: UUID { user_id }

    var resolvedDisplayName: String {
        let name = display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        let handle = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !handle.isEmpty { return "@\(handle)" }
        return "Fan"
    }

    var isOrganizer: Bool {
        (role ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "organizer"
    }
}

/// Server roster payload for pickup social proof + organizer pending management.
struct PickupGameRosterPayload: Equatable, Decodable {
    let pickup_game_id: UUID
    let viewer_is_organizer: Bool
    let organizer: PickupGameRosterMember?
    let playing: [PickupGameRosterMember]
    let pending: [PickupGameRosterMember]
    let approved_join_count: Int?
    let playing_total_count: Int?

    /// Organizer + approved joiners (organizer not duplicated from `playing`).
    var stackMembers: [PickupGameRosterMember] {
        var rows: [PickupGameRosterMember] = []
        if let organizer {
            rows.append(organizer)
        }
        rows.append(contentsOf: playing)
        return rows
    }

    /// Public playing total: organizer + approved joiners.
    var playingTotal: Int {
        if let playing_total_count, playing_total_count >= 1 {
            return playing_total_count
        }
        return max(1, stackMembers.count)
    }

    /// Approved joiners only (matches `pickup_games.approved_join_count` / Spots math).
    var approvedJoinerCount: Int {
        if let approved_join_count, approved_join_count >= 0 {
            return approved_join_count
        }
        return playing.count
    }
}

/// Helpers for capacity-card avatar stack presentation (pure; DEBUG-testable).
enum PickupGameRosterPresentation {
    static let maxVisibleAvatars = 4

    /// Playing column number: organizer + approved joiners.
    static func playingDisplayCount(approvedJoinCount: Int, includesOrganizer: Bool = true) -> Int {
        let joiners = max(0, approvedJoinCount)
        return includesOrganizer ? 1 + joiners : joiners
    }

    static func visibleStackCount(total: Int, maxVisible: Int = maxVisibleAvatars) -> Int {
        min(max(0, total), maxVisible)
    }

    static func overflowCount(total: Int, maxVisible: Int = maxVisibleAvatars) -> Int {
        max(0, total - maxVisible)
    }

    /// Public viewers never see pending; organizers may.
    static func pendingVisibleToViewer(isOrganizer: Bool, pendingCount: Int) -> Int {
        isOrganizer ? max(0, pendingCount) : 0
    }
}
