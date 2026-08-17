import Foundation

/// One public-safe identity row from `get_pickup_game_roster`.
///
/// Explicitly `Sendable` + `nonisolated` members: module default actor isolation is MainActor
/// (`SWIFT_DEFAULT_ACTOR_ISOLATION`), but this type is immutable value data used from
/// nonisolated presentation helpers / `Decodable` without UI.
struct PickupGameRosterMember: Identifiable, Equatable, Hashable, Decodable, Sendable {
    /// Participant key. For a guardian-managed seat this is the `managed_player_id`
    /// (20260961) — managed players have no account, and the client only needs a
    /// stable identity here.
    let user_id: UUID
    let request_id: UUID?
    let display_name: String?
    let username: String?
    let avatar_url: String?
    let avatar_thumbnail_url: String?
    let role: String?
    let status: String?
    /// Present after 20260961 for Team roster seats (absent for outside requesters).
    let membership_id: UUID?
    /// Present after 20260961. Absent on older payloads → treated as `false`.
    let is_managed_player: Bool?
    let managed_player_id: UUID?

    enum CodingKeys: String, CodingKey {
        case user_id
        case request_id
        case display_name
        case username
        case avatar_url
        case avatar_thumbnail_url
        case role
        case status
        case membership_id
        case is_managed_player
        case managed_player_id
    }

    nonisolated init(
        user_id: UUID,
        request_id: UUID? = nil,
        display_name: String? = nil,
        username: String? = nil,
        avatar_url: String? = nil,
        avatar_thumbnail_url: String? = nil,
        role: String? = nil,
        status: String? = nil,
        membership_id: UUID? = nil,
        is_managed_player: Bool? = nil,
        managed_player_id: UUID? = nil
    ) {
        self.user_id = user_id
        self.request_id = request_id
        self.display_name = display_name
        self.username = username
        self.avatar_url = avatar_url
        self.avatar_thumbnail_url = avatar_thumbnail_url
        self.role = role
        self.status = status
        self.membership_id = membership_id
        self.is_managed_player = is_managed_player
        self.managed_player_id = managed_player_id
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user_id = try c.decode(UUID.self, forKey: .user_id)
        request_id = try c.decodeIfPresent(UUID.self, forKey: .request_id)
        display_name = try c.decodeIfPresent(String.self, forKey: .display_name)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        avatar_url = try c.decodeIfPresent(String.self, forKey: .avatar_url)
        avatar_thumbnail_url = try c.decodeIfPresent(String.self, forKey: .avatar_thumbnail_url)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        membership_id = try c.decodeIfPresent(UUID.self, forKey: .membership_id)
        is_managed_player = try c.decodeIfPresent(Bool.self, forKey: .is_managed_player)
        managed_player_id = try c.decodeIfPresent(UUID.self, forKey: .managed_player_id)
    }

    nonisolated var id: UUID { user_id }

    /// Managed players are not social identities: no profile, DM or friend actions.
    nonisolated var isManagedPlayer: Bool {
        is_managed_player == true || managed_player_id != nil
    }

    /// Account id, or `nil` for a guardian-managed seat.
    nonisolated var accountUserId: UUID? {
        isManagedPlayer ? nil : user_id
    }

    /// Pure display-name fallback: trimmed display name → @username → `"Fan"`.
    nonisolated var resolvedDisplayName: String {
        let name = display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        let handle = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !handle.isEmpty { return "@\(handle)" }
        return "Fan"
    }

    nonisolated var isOrganizer: Bool {
        (role ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "organizer"
    }
}

/// Server roster payload for pickup social proof + organizer pending management.
///
/// Same isolation rule as ``PickupGameRosterMember``: pure value payload, safe from
/// nonisolated attendance/presentation helpers.
struct PickupGameRosterPayload: Equatable, Decodable, Sendable {
    let pickup_game_id: UUID
    let viewer_is_organizer: Bool
    let organizer: PickupGameRosterMember?
    let playing: [PickupGameRosterMember]
    let pending: [PickupGameRosterMember]
    /// Present after 20260948 for Team-linked viewers (Can't Go / declined).
    let declined: [PickupGameRosterMember]?
    /// Present after 20260948 for Team-linked viewers (active members with no RSVP).
    let no_response: [PickupGameRosterMember]?
    /// Present after 20260958 — active Team members staff-excluded from this event.
    let excluded: [PickupGameRosterMember]?
    /// Present after 20260958 — viewer may manage event exclusions / add-back.
    let viewer_can_manage_event_roster: Bool?
    let approved_join_count: Int?
    let playing_total_count: Int?

    enum CodingKeys: String, CodingKey {
        case pickup_game_id
        case viewer_is_organizer
        case organizer
        case playing
        case pending
        case declined
        case no_response
        case excluded
        case viewer_can_manage_event_roster
        case approved_join_count
        case playing_total_count
    }

    nonisolated init(
        pickup_game_id: UUID,
        viewer_is_organizer: Bool,
        organizer: PickupGameRosterMember?,
        playing: [PickupGameRosterMember],
        pending: [PickupGameRosterMember],
        declined: [PickupGameRosterMember]? = nil,
        no_response: [PickupGameRosterMember]? = nil,
        excluded: [PickupGameRosterMember]? = nil,
        viewer_can_manage_event_roster: Bool? = nil,
        approved_join_count: Int?,
        playing_total_count: Int?
    ) {
        self.pickup_game_id = pickup_game_id
        self.viewer_is_organizer = viewer_is_organizer
        self.organizer = organizer
        // Normalize at the boundary: roster RPCs can emit multiple request rows per user
        // (e.g. historical withdrawn/rejected), and SwiftUI ForEach IDs are `user_id`.
        self.playing = PickupGameRosterPresentation.uniqueMembersByUserId(playing)
        self.pending = PickupGameRosterPresentation.uniqueMembersByUserId(pending)
        self.declined = declined.map(PickupGameRosterPresentation.uniqueMembersByUserId)
        self.no_response = no_response.map(PickupGameRosterPresentation.uniqueMembersByUserId)
        self.excluded = excluded.map(PickupGameRosterPresentation.uniqueMembersByUserId)
        self.viewer_can_manage_event_roster = viewer_can_manage_event_roster
        self.approved_join_count = approved_join_count
        self.playing_total_count = playing_total_count
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pickup_game_id = try c.decode(UUID.self, forKey: .pickup_game_id)
        viewer_is_organizer = try c.decode(Bool.self, forKey: .viewer_is_organizer)
        organizer = try c.decodeIfPresent(PickupGameRosterMember.self, forKey: .organizer)
        playing = PickupGameRosterPresentation.uniqueMembersByUserId(
            try c.decodeIfPresent([PickupGameRosterMember].self, forKey: .playing) ?? []
        )
        pending = PickupGameRosterPresentation.uniqueMembersByUserId(
            try c.decodeIfPresent([PickupGameRosterMember].self, forKey: .pending) ?? []
        )
        declined = try c.decodeIfPresent([PickupGameRosterMember].self, forKey: .declined)
            .map(PickupGameRosterPresentation.uniqueMembersByUserId)
        no_response = try c.decodeIfPresent([PickupGameRosterMember].self, forKey: .no_response)
            .map(PickupGameRosterPresentation.uniqueMembersByUserId)
        excluded = try c.decodeIfPresent([PickupGameRosterMember].self, forKey: .excluded)
            .map(PickupGameRosterPresentation.uniqueMembersByUserId)
        viewer_can_manage_event_roster = try c.decodeIfPresent(
            Bool.self,
            forKey: .viewer_can_manage_event_roster
        )
        approved_join_count = try c.decodeIfPresent(Int.self, forKey: .approved_join_count)
        playing_total_count = try c.decodeIfPresent(Int.self, forKey: .playing_total_count)
    }

    /// Organizer + approved joiners (organizer never duplicated from `playing`).
    nonisolated var stackMembers: [PickupGameRosterMember] {
        var rows: [PickupGameRosterMember] = []
        var seen = Set<UUID>()
        if let organizer {
            rows.append(organizer)
            seen.insert(organizer.user_id)
        }
        for member in playing where seen.insert(member.user_id).inserted {
            rows.append(member)
        }
        return rows
    }

    /// Public playing total: organizer + approved joiners.
    nonisolated var playingTotal: Int {
        if let playing_total_count, playing_total_count >= 1 {
            return playing_total_count
        }
        return max(1, stackMembers.count)
    }

    /// Approved joiners only (matches `pickup_games.approved_join_count` / Spots math).
    nonisolated var approvedJoinerCount: Int {
        if let approved_join_count, approved_join_count >= 0 {
            return approved_join_count
        }
        return playing.count
    }

    nonisolated var declinedMembers: [PickupGameRosterMember] { declined ?? [] }
    nonisolated var noResponseMembers: [PickupGameRosterMember] { no_response ?? [] }
    nonisolated var excludedMembers: [PickupGameRosterMember] { excluded ?? [] }
    nonisolated var canManageEventRoster: Bool { viewer_can_manage_event_roster == true }
}

/// Detail-screen attendance buckets mapped from existing roster / Team RSVP request statuses.
enum PickupDetailAttendanceCategory: String, CaseIterable, Hashable, Sendable {
    case going
    case maybe
    case noResponse
    case cantGo

    /// Personal RSVP chip copy ("I'm Going", etc.).
    nonisolated func personalTitleKey() -> String {
        switch self {
        case .going: return "fan_team_rsvp_going"
        case .maybe: return "fan_team_rsvp_maybe"
        case .noResponse: return "pickup_detail_no_response"
        case .cantGo: return "fan_team_rsvp_cant_go"
        }
    }

    /// Aggregate / group attendance copy ("Going", "Maybe", …) — never personal pronouns.
    nonisolated func aggregateTitleKey() -> String {
        switch self {
        case .going: return "Going"
        case .maybe: return "Maybe"
        case .noResponse: return "pickup_detail_no_response"
        case .cantGo: return "fan_team_rsvp_cant_go"
        }
    }

    @available(*, deprecated, renamed: "personalTitleKey")
    nonisolated func titleKey() -> String { personalTitleKey() }
}

/// One row in the Team-linked game attendance roster (membership + RSVP for this game).
struct PickupTeamAttendanceRow: Identifiable, Equatable, Hashable, Sendable {
    let member: PickupGameRosterMember
    let category: PickupDetailAttendanceCategory

    nonisolated var id: UUID { member.user_id }
}

/// Builds Team-game attendance rows from `get_pickup_game_roster` (20260948 buckets).
///
/// Important: do **not** treat `stackMembers` (organizer ∪ playing) as Going.
/// The organizer object is always present for the creator even when their
/// event-specific RSVP is Maybe / Can't Go / unanswered. Using stackMembers
/// caused Schedule quick-RSVP to flip Can't Go → Going after refresh and made
/// every event the viewer created appear Going regardless of that event's row.
nonisolated enum PickupTeamAttendancePresentation {
    /// Priority when a user appears in more than one bucket (should be rare after RPC dedupe).
    /// Response buckets beat organizer-inferred Going so Can't Go / Maybe win.
    private static let categoryPriority: [PickupDetailAttendanceCategory] = [
        .cantGo, .maybe, .noResponse, .going
    ]

    static func rows(from roster: PickupGameRosterPayload) -> [PickupTeamAttendanceRow] {
        var best: [UUID: PickupTeamAttendanceRow] = [:]
        func consider(_ members: [PickupGameRosterMember], _ category: PickupDetailAttendanceCategory) {
            for member in PickupGameRosterPresentation.uniqueMembersByUserId(members) {
                let row = PickupTeamAttendanceRow(member: member, category: category)
                if let existing = best[member.user_id] {
                    let oldIdx = categoryPriority.firstIndex(of: existing.category) ?? Int.max
                    let newIdx = categoryPriority.firstIndex(of: category) ?? Int.max
                    if newIdx < oldIdx {
                        best[member.user_id] = row
                    }
                } else {
                    best[member.user_id] = row
                }
            }
        }

        // Explicit request buckets first (event-scoped).
        consider(roster.declinedMembers, .cantGo)
        consider(roster.pending, .maybe)
        consider(roster.noResponseMembers, .noResponse)
        consider(roster.playing, .going)

        // Creator is always returned as `organizer` and (pre-fix) may be omitted from
        // playing/declined/no_response. For Team payloads (`no_response` / `declined`
        // keys present), never invent Going from organizer role — that made every
        // event the creator scheduled look Going and masked Can't Go after refresh.
        // Standalone pickups omit those keys; host still counts as Going.
        if let organizer = roster.organizer {
            let uid = organizer.user_id
            let hasExplicitResponse =
                roster.declinedMembers.contains(where: { $0.user_id == uid })
                || roster.pending.contains(where: { $0.user_id == uid })
                || roster.noResponseMembers.contains(where: { $0.user_id == uid })
                || roster.playing.contains(where: { $0.user_id == uid })
            let isTeamAttendancePayload = roster.no_response != nil || roster.declined != nil
            if !hasExplicitResponse, !isTeamAttendancePayload {
                consider([organizer], .going)
            }
        }

        let displayOrder: [PickupDetailAttendanceCategory] = [
            .going, .maybe, .noResponse, .cantGo
        ]
        return displayOrder.flatMap { category in
            best.values
                .filter { $0.category == category }
                .sorted {
                    $0.member.resolvedDisplayName.localizedCaseInsensitiveCompare(
                        $1.member.resolvedDisplayName
                    ) == .orderedAscending
                }
        }
    }

    static func counts(from roster: PickupGameRosterPayload) -> (
        going: Int,
        maybe: Int,
        noResponse: Int,
        cantGo: Int
    ) {
        let rows = rows(from: roster)
        return (
            going: rows.filter { $0.category == .going }.count,
            maybe: rows.filter { $0.category == .maybe }.count,
            noResponse: rows.filter { $0.category == .noResponse }.count,
            cantGo: rows.filter { $0.category == .cantGo }.count
        )
    }
}

enum PickupDetailLocationPresentation {
    /// Avoid repeating identical address / city-state lines in the When & Where card.
    static func lines(address: String?, city: String?, state: String?) -> (primary: String?, secondary: String?) {
        let addressTrimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cityState = [city, state]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let addr = addressTrimmed.isEmpty ? nil : addressTrimmed
        let cityLine = cityState.isEmpty ? nil : cityState
        guard let addr else { return (cityLine, nil) }
        guard let cityLine else { return (addr, nil) }
        if Self.normalized(addr) == Self.normalized(cityLine) {
            return (addr, nil)
        }
        if Self.normalized(addr).contains(Self.normalized(cityLine))
            || Self.normalized(cityLine).contains(Self.normalized(addr)) {
            return (addr, nil)
        }
        return (addr, cityLine)
    }

    private static func normalized(_ raw: String) -> String {
        raw
            .lowercased()
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

enum PickupDetailGameDetailsPresentation {
    /// Who’s welcome / skill describe outside recruitment — hide for Team-only (not recruiting).
    static func showsOutsideRecruitmentMetadata(
        isTeamLinked: Bool,
        isOutsideRecruitingEnabled: Bool
    ) -> Bool {
        if !isTeamLinked { return true }
        return isOutsideRecruitingEnabled
    }
}

/// Helpers for capacity-card avatar stack presentation (pure; DEBUG-testable).
///
/// `nonisolated`: module default actor isolation is MainActor (`SWIFT_DEFAULT_ACTOR_ISOLATION`),
/// but these helpers are pure value transforms and must stay callable from
/// `Decodable.init(from:)` / other nonisolated contexts without actor hops.
nonisolated enum PickupGameRosterPresentation {
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

    /// Collapse duplicate roster identities for SwiftUI `ForEach` / avatar stacks.
    ///
    /// `PickupGameRosterMember.id` is `user_id`. Team roster payloads (esp. `declined`
    /// from multiple historical request rows) can repeat the same user, which aborts
    /// with a SwiftUI duplicate-ID fatal. Preserves first occurrence / input order
    /// (callers that want “latest” should pre-sort, as `20260948` does for declined).
    static func uniqueMembersByUserId(_ members: [PickupGameRosterMember]) -> [PickupGameRosterMember] {
        var seen = Set<UUID>()
        var out: [PickupGameRosterMember] = []
        out.reserveCapacity(members.count)
        for member in members {
            if seen.insert(member.user_id).inserted {
                out.append(member)
            }
        }
        return out
    }
}
