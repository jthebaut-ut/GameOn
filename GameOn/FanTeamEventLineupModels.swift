import Foundation

// MARK: - Lineup models

enum FanTeamLineupPublicationStatus: String, Codable, Hashable, Sendable {
    case draft
    case published

    var localizedKey: String {
        switch self {
        case .draft: return "fan_team_lineup_status_draft"
        case .published: return "fan_team_lineup_status_published"
        }
    }

    /// Compact status for cards / headers (`Published` / `Draft`).
    var shortLocalizedKey: String {
        switch self {
        case .draft: return "fan_team_lineup_status_draft"
        case .published: return "fan_team_lineup_published_short"
        }
    }
}

enum FanTeamLineupPlayerStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case starting
    case bench

    var localizedKey: String {
        switch self {
        case .starting: return "fan_team_lineup_starting"
        case .bench: return "fan_team_lineup_bench"
        }
    }

    var sortGroup: Int {
        switch self {
        case .starting: return 0
        case .bench: return 1
        }
    }
}

struct FanTeamLineupMemberDraft: Identifiable, Hashable, Sendable, Codable {
    var id: UUID { participantKey }
    /// Account participant. `nil` when this seat is a guardian-managed player.
    let userId: UUID?
    /// Guardian-managed participant. `nil` for account seats.
    let managedPlayerId: UUID?
    /// Stable row identity for either participant, matching the key the roster
    /// and attendance payloads use (`user_id`, which is the managed player id for
    /// managed seats).
    let participantKey: UUID
    var lineupStatus: FanTeamLineupPlayerStatus
    var positionCode: String?
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case managedPlayerId = "managed_player_id"
        case lineupStatus = "lineup_status"
        case positionCode = "position_code"
        case sortOrder = "sort_order"
    }

    init(
        userId: UUID?,
        managedPlayerId: UUID? = nil,
        lineupStatus: FanTeamLineupPlayerStatus,
        positionCode: String? = nil,
        sortOrder: Int = 0
    ) {
        // XOR, exactly as the fan_team_event_lineup_members CHECK requires.
        self.userId = userId
        self.managedPlayerId = userId == nil ? managedPlayerId : nil
        // Never use random UUID() for ForEach identity — invalid rows are filtered before UI.
        self.participantKey = userId ?? managedPlayerId ?? Self.invalidParticipantKey
        self.lineupStatus = lineupStatus
        self.positionCode = positionCode
        self.sortOrder = sortOrder
    }

    /// Sentinel only for structurally invalid decoded rows; filtered out before presentation.
    static let invalidParticipantKey = UUID(uuidString: "00000000-0000-4000-8000-ffffffffffff")!

    var isStructurallyValid: Bool { userId != nil || managedPlayerId != nil }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let user = try c.decodeIfPresent(UUID.self, forKey: .userId)
        let managed = try c.decodeIfPresent(UUID.self, forKey: .managedPlayerId)
        self.init(
            userId: user,
            managedPlayerId: managed,
            lineupStatus: try c.decode(FanTeamLineupPlayerStatus.self, forKey: .lineupStatus),
            positionCode: try c.decodeIfPresent(String.self, forKey: .positionCode),
            sortOrder: try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        )
    }

    /// Only the identity that is actually set is encoded: `save_fan_team_event_lineup`
    /// rejects an element carrying both `user_id` and `managed_player_id`.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let userId {
            try c.encode(userId, forKey: .userId)
        }
        if let managedPlayerId {
            try c.encode(managedPlayerId, forKey: .managedPlayerId)
        }
        try c.encode(lineupStatus, forKey: .lineupStatus)
        try c.encodeIfPresent(positionCode, forKey: .positionCode)
        try c.encode(sortOrder, forKey: .sortOrder)
    }

    var isManagedPlayer: Bool { managedPlayerId != nil }
}

struct FanTeamEventLineup: Identifiable, Hashable, Sendable {
    let id: UUID?
    let teamId: UUID
    let pickupGameId: UUID
    let status: FanTeamLineupPublicationStatus?
    let formation: String?
    let publishedAt: Date?
    let publishedBy: UUID?
    let updatedAt: Date?
    let viewerCanManage: Bool
    let members: [FanTeamLineupMemberDraft]

    var isPublished: Bool { status == .published }
    var isDraft: Bool { status == .draft }
    var exists: Bool { id != nil && status != nil }

    var starting: [FanTeamLineupMemberDraft] {
        FanTeamLineupOrdering.sorted(members.filter { $0.lineupStatus == .starting })
    }

    var bench: [FanTeamLineupMemberDraft] {
        FanTeamLineupOrdering.sorted(members.filter { $0.lineupStatus == .bench })
    }
}

enum FanTeamLineupOrdering {
    static func sorted(_ members: [FanTeamLineupMemberDraft]) -> [FanTeamLineupMemberDraft] {
        members.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.participantKey.uuidString < rhs.participantKey.uuidString
        }
    }

    static func renumber(_ members: [FanTeamLineupMemberDraft]) -> [FanTeamLineupMemberDraft] {
        members.enumerated().map { index, row in
            FanTeamLineupMemberDraft(
                userId: row.userId,
                managedPlayerId: row.managedPlayerId,
                lineupStatus: row.lineupStatus,
                positionCode: row.positionCode,
                sortOrder: index
            )
        }
    }

    /// Collapses repeated participants (either identity) for SwiftUI `ForEach`.
    /// Drops rows with neither `user_id` nor `managed_player_id` (no random identity).
    static func deduped(_ members: [FanTeamLineupMemberDraft]) -> [FanTeamLineupMemberDraft] {
        var seen = Set<UUID>()
        var out: [FanTeamLineupMemberDraft] = []
        for row in members {
            guard row.isStructurallyValid else {
#if DEBUG
                print("[FanTeamLineup] drop_invalid_draft_row reason=missing_participant_identity")
#endif
                continue
            }
            if seen.insert(row.participantKey).inserted {
                out.append(row)
            }
        }
        return out
    }
}

/// Central authorization for lineup UI (mirrors SQL `fan_team_role_can_manage_lineup`).
enum FanTeamLineupAuthorization {
    /// Role-default matrix (Owner only after the Team Administrator preset).
    /// Prefer ``FanTeamSummary/canManageLineup`` at call sites.
    static func canManageLineup(role: FanTeamMemberRole) -> Bool {
        FanTeamPermissions.roleDefaults(for: role).contains(.manageLineups)
    }

    static func canManageLineup(permissions: FanTeamPermissionSet) -> Bool {
        permissions.contains(.manageLineups)
    }

    static func canViewPublished(isActiveTeamMember: Bool) -> Bool {
        isActiveTeamMember
    }

    static func canViewDraft(role: FanTeamMemberRole) -> Bool {
        canManageLineup(role: role)
    }

    static func canViewDraft(permissions: FanTeamPermissionSet) -> Bool {
        canManageLineup(permissions: permissions)
    }
}

/// RSVP eligibility for lineup candidate sheets.
enum FanTeamLineupEligibility {
    enum Bucket: String, Hashable, Sendable {
        case going
        case maybe
        case otherTeamMembers
    }

    /// Default candidates: Going. Maybe is secondary. Can't Go / No Response excluded unless "show all".
    static func bucket(
        for attendance: PickupDetailAttendanceCategory?,
        showAllTeamMembers: Bool
    ) -> Bucket? {
        switch attendance {
        case .going:
            return .going
        case .maybe:
            return .maybe
        case .cantGo, .noResponse, .none:
            return showAllTeamMembers ? .otherTeamMembers : nil
        }
    }

    /// Staff warning when a lineup player is no longer attending.
    static func showsNoLongerAttendingWarning(
        attendance: PickupDetailAttendanceCategory?
    ) -> Bool {
        attendance == .cantGo
    }

    /// Secondary RSVP chip when staff deliberately included a non-Going player.
    static func showsSecondaryRSVPChip(
        attendance: PickupDetailAttendanceCategory?
    ) -> Bool {
        switch attendance {
        case .maybe, .noResponse, .cantGo:
            return true
        case .going, .none:
            return false
        }
    }
}

/// Projected row for UI — identity from Team roster / attendance, not lineup storage.
struct FanTeamLineupPlayerPresentation: Identifiable, Hashable, Sendable {
    var id: UUID { participantKey }
    /// Roster-seat key: the account id, or the managed player id for a managed seat.
    let participantKey: UUID
    /// `nil` for guardian-managed players (they have no account).
    let userId: UUID?
    let managedPlayerId: UUID?
    let displayName: String
    let avatarURL: String?
    let avatarThumbnailURL: String?
    let playerNumber: Int?
    let attendance: PickupDetailAttendanceCategory?
    let lineupStatus: FanTeamLineupPlayerStatus
    let positionCode: String?
    let sortOrder: Int
    let isCurrentUser: Bool

    init(
        userId: UUID?,
        managedPlayerId: UUID? = nil,
        displayName: String,
        avatarURL: String?,
        avatarThumbnailURL: String?,
        playerNumber: Int?,
        attendance: PickupDetailAttendanceCategory?,
        lineupStatus: FanTeamLineupPlayerStatus,
        positionCode: String?,
        sortOrder: Int,
        isCurrentUser: Bool
    ) {
        self.userId = userId
        self.managedPlayerId = userId == nil ? managedPlayerId : nil
        self.participantKey = userId ?? managedPlayerId ?? FanTeamLineupMemberDraft.invalidParticipantKey
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.avatarThumbnailURL = avatarThumbnailURL
        self.playerNumber = playerNumber
        self.attendance = attendance
        self.lineupStatus = lineupStatus
        self.positionCode = positionCode
        self.sortOrder = sortOrder
        self.isCurrentUser = isCurrentUser
    }

    var isStructurallyValid: Bool { userId != nil || managedPlayerId != nil }

    var isManagedPlayer: Bool { managedPlayerId != nil }

    var numberLabel: String? {
        guard let playerNumber else { return nil }
        return FanTeamPlayerNumber.displayLabel(playerNumber)
    }
}

enum FanTeamLineupPresentation {
    static func project(
        members: [FanTeamLineupMemberDraft],
        teamMembersById: [UUID: FanTeamMember],
        attendanceById: [UUID: PickupDetailAttendanceCategory],
        rosterMembersById: [UUID: PickupGameRosterMember],
        currentUserId: UUID?
    ) -> [FanTeamLineupPlayerPresentation] {
        let unique = FanTeamLineupOrdering.deduped(members)
        return FanTeamLineupOrdering.sorted(unique).map { row in
            // Display always resolves through the roster seat / attendance payload,
            // both of which key managed players on their managed player id.
            let key = row.participantKey
            let team = teamMembersById[key]
            let roster = rosterMembersById[key]
            let name = (team?.displayName ?? roster?.resolvedDisplayName ?? "Fan")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return FanTeamLineupPlayerPresentation(
                userId: row.userId,
                managedPlayerId: row.managedPlayerId,
                displayName: name.isEmpty ? "Fan" : name,
                avatarURL: team?.avatarURL ?? roster?.avatar_url,
                avatarThumbnailURL: team?.avatarThumbnailURL ?? roster?.avatar_thumbnail_url,
                playerNumber: team?.playerNumber,
                attendance: attendanceById[key],
                lineupStatus: row.lineupStatus,
                positionCode: row.positionCode,
                sortOrder: row.sortOrder,
                isCurrentUser: row.userId != nil && currentUserId == row.userId
            )
        }
    }

    static func noLongerAttendingCount(
        members: [FanTeamLineupMemberDraft],
        attendanceById: [UUID: PickupDetailAttendanceCategory]
    ) -> Int {
        let unique = FanTeamLineupOrdering.deduped(members)
        return unique.filter {
            FanTeamLineupEligibility.showsNoLongerAttendingWarning(
                attendance: attendanceById[$0.participantKey]
            )
        }.count
    }

    static func accessibilityRowLabel(
        player: FanTeamLineupPlayerPresentation,
        sportToken: String?,
        languageCode: String
    ) -> String {
        var parts: [String] = []
        if let number = player.playerNumber {
            parts.append(
                String(
                    format: L10n.t("fan_teams_player_number_a11y_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    Int64(number)
                )
            )
        }
        parts.append(player.displayName)
        if let position = FanTeamSportPositions.position(code: player.positionCode, sportToken: sportToken) {
            parts.append(position.accessibilityLabel(languageCode: languageCode))
        } else if let code = FanTeamLineupPresentation.displayPositionCode(
            positionCode: player.positionCode,
            sportToken: sportToken
        ) {
            parts.append(code)
        }
        parts.append(L10n.t(player.lineupStatus.localizedKey, languageCode: languageCode))
        if player.isCurrentUser {
            parts.append(L10n.t("pickup_attendance_you", languageCode: languageCode))
        }
        if FanTeamLineupEligibility.showsNoLongerAttendingWarning(attendance: player.attendance) {
            parts.append(L10n.t("fan_team_lineup_no_longer_attending", languageCode: languageCode))
        }
        return parts.joined(separator: ", ")
    }

    /// Compact event-detail preview: first N players in Starting→Bench order.
    static let compactPreviewLimit = 4

    static func compactPreviewPlayers(
        from lineup: FanTeamEventLineup,
        teamMembersById: [UUID: FanTeamMember],
        attendanceById: [UUID: PickupDetailAttendanceCategory],
        rosterMembersById: [UUID: PickupGameRosterMember],
        currentUserId: UUID?,
        limit: Int = compactPreviewLimit
    ) -> (visible: [FanTeamLineupPlayerPresentation], hiddenCount: Int) {
        // Starting then Bench, each in stored sort_order (never alphabetical).
        let ordered =
            project(
                members: lineup.starting,
                teamMembersById: teamMembersById,
                attendanceById: attendanceById,
                rosterMembersById: rosterMembersById,
                currentUserId: currentUserId
            )
            + project(
                members: lineup.bench,
                teamMembersById: teamMembersById,
                attendanceById: attendanceById,
                rosterMembersById: rosterMembersById,
                currentUserId: currentUserId
            )
        let visible = Array(ordered.prefix(max(0, limit)))
        return (visible, max(0, ordered.count - visible.count))
    }

    /// Display token for a stored event position (catalog label, else raw uppercase code).
    static func displayPositionCode(
        positionCode: String?,
        sportToken: String?
    ) -> String? {
        if let catalog = FanTeamSportPositions.position(code: positionCode, sportToken: sportToken) {
            return catalog.shortLabel()
        }
        let raw = positionCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        return raw.isEmpty ? nil : raw
    }

    /// Player/parent published list: one flat order (position groups → unassigned → substitutes).
    /// Formation and Starting/Bench section chrome are intentionally omitted from this projection.
    static func playerParentOrderedPlayers(
        from lineup: FanTeamEventLineup,
        sportToken: String?,
        teamMembersById: [UUID: FanTeamMember],
        attendanceById: [UUID: PickupDetailAttendanceCategory],
        rosterMembersById: [UUID: PickupGameRosterMember],
        currentUserId: UUID?
    ) -> [FanTeamLineupPlayerPresentation] {
        let projected = project(
            members: lineup.members,
            teamMembersById: teamMembersById,
            attendanceById: attendanceById,
            rosterMembersById: rosterMembersById,
            currentUserId: currentUserId
        )
        return projected.sorted { lhs, rhs in
            let l = playerParentSortKey(for: lhs, sportToken: sportToken)
            let r = playerParentSortKey(for: rhs, sportToken: sportToken)
            if l != r { return l < r }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Future-ready viewer highlight (today: signed-in user; later: managed children).
    static func isHighlightedForViewer(_ player: FanTeamLineupPlayerPresentation) -> Bool {
        player.isCurrentUser
    }

    static func viewerHighlightLabelKey() -> String {
        "pickup_attendance_you"
    }

    /// Compact badge for player/parent rows (`GK`, `SUB`, `—`).
    static func playerParentPositionBadge(
        player: FanTeamLineupPlayerPresentation,
        sportToken: String?,
        languageCode: String
    ) -> String {
        if player.lineupStatus == .bench {
            return L10n.t("fan_team_lineup_sub_badge", languageCode: languageCode)
        }
        if let code = displayPositionCode(positionCode: player.positionCode, sportToken: sportToken) {
            return code
        }
        return L10n.t("fan_team_lineup_unassigned_badge", languageCode: languageCode)
    }

    /// Long position title for player/parent rows.
    static func playerParentPositionTitle(
        player: FanTeamLineupPlayerPresentation,
        sportToken: String?,
        languageCode: String
    ) -> String {
        if player.lineupStatus == .bench {
            return L10n.t("fan_team_lineup_substitute", languageCode: languageCode)
        }
        if let position = FanTeamSportPositions.position(code: player.positionCode, sportToken: sportToken) {
            return position.accessibilityLabel(languageCode: languageCode)
        }
        if let code = displayPositionCode(positionCode: player.positionCode, sportToken: sportToken) {
            return code
        }
        return L10n.t("fan_team_lineup_no_position", languageCode: languageCode)
    }

    private static func playerParentSortKey(
        for player: FanTeamLineupPlayerPresentation,
        sportToken: String?
    ) -> (Int, Int, Int, Int) {
        // Bucket: starters with position → unassigned starters → substitutes.
        if player.lineupStatus == .bench {
            return (2, player.sortOrder, 0, 0)
        }
        let groups = FanTeamSportPositions.groups(forSportToken: sportToken)
        let normalized = (player.positionCode ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !normalized.isEmpty else {
            return (1, player.sortOrder, 0, 0)
        }
        for (groupIndex, group) in groups.enumerated() {
            if let positionIndex = group.positions.firstIndex(where: { $0.code == normalized }) {
                return (0, groupIndex, positionIndex, player.sortOrder)
            }
        }
        // Unknown code: keep with starters, after catalog groups.
        return (0, groups.count, Int(normalized.unicodeScalars.first?.value ?? 0), player.sortOrder)
    }
}

/// Lightweight navigation context for lineup leaf screens (Team-linked events only).
struct FanTeamEventLineupContext: Hashable, Sendable {
    let teamId: UUID
    let pickupGameId: UUID
    let teamName: String
    let teamLogoURL: String?
    let teamLogoThumbnailURL: String?
    let teamColorHex: String?
    let sportToken: String
    let eventTitle: String
    let eventStartsAt: Date?
    let isEventCancelled: Bool
}
