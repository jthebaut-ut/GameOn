import Foundation

enum FanTeamMemberRole: String, Codable, Hashable, CaseIterable, Sendable {
    case owner
    case manager
    case captain
    case member

    var canManageTeam: Bool {
        self == .owner || self == .manager
    }

    /// Owners cannot soft-leave while they own the Team (`leave_fan_team` RPC).
    var canLeaveTeam: Bool {
        self != .owner
    }

    var localizedKey: String {
        switch self {
        case .owner: return "fan_team_role_owner"
        case .manager: return "fan_team_role_manager"
        case .captain: return "fan_team_role_captain"
        case .member: return "fan_team_role_member"
        }
    }
}

/// Categories for reporting a Fan Team (stored as plain strings; matches `report_fan_team`).
enum FanTeamReportCategory: String, CaseIterable, Identifiable, Sendable {
    case harassment = "harassment"
    case hate = "hate"
    case spam = "spam"
    case inappropriate = "inappropriate"
    case violence = "violence"
    case fakeAccount = "fake_account"
    case teamIdentity = "team_identity"
    case other = "other"

    var id: String { rawValue }

    func localizedTitle(languageCode: String) -> String {
        switch self {
        case .harassment:
            return L10n.t("group_chat_report_group_category_harassment", languageCode: languageCode)
        case .hate:
            return L10n.t("group_chat_report_group_category_hate", languageCode: languageCode)
        case .spam:
            return L10n.t("group_chat_report_group_category_spam", languageCode: languageCode)
        case .inappropriate:
            return L10n.t("group_chat_report_group_category_inappropriate", languageCode: languageCode)
        case .violence:
            return L10n.t("group_chat_report_group_category_violence", languageCode: languageCode)
        case .fakeAccount:
            return L10n.t("group_chat_report_group_category_impersonation", languageCode: languageCode)
        case .teamIdentity:
            return L10n.t("fan_teams_report_category_team_identity", languageCode: languageCode)
        case .other:
            return L10n.t("group_chat_report_group_category_other", languageCode: languageCode)
        }
    }
}

enum FanTeamReportError: LocalizedError, Equatable {
    case duplicateOpenReport
    case notActiveMember

    var errorDescription: String? {
        switch self {
        case .duplicateOpenReport:
            return L10n.t("fan_teams_report_already_reported")
        case .notActiveMember:
            return L10n.t("fan_teams_report_not_member")
        }
    }
}

/// Client mapping of authoritative `pickup_games.game_format` (not a separate Team enum).
enum FanTeamGameType: String, Codable, Hashable, CaseIterable, Sendable {
    case league_game
    case tournament_game
    case practice
    case scrimmage
    case tryout
    case clinic
    /// Legacy Team fixture token — preserved for existing rows.
    case match
    case pickup

    var localizedKey: String {
        switch self {
        case .league_game: return "pickup_game_format_league_game"
        case .tournament_game: return "pickup_game_format_tournament_game"
        case .practice: return "fan_team_game_type_practice"
        case .scrimmage: return "fan_team_game_type_scrimmage"
        case .tryout: return "pickup_game_format_tryout"
        case .clinic: return "pickup_game_format_clinic"
        case .match: return "fan_team_game_type_match"
        case .pickup: return "fan_team_game_type_pickup"
        }
    }

    var filterSystemImage: String {
        switch self {
        case .league_game, .match: return "trophy.fill"
        case .tournament_game: return "medal.fill"
        case .practice: return "figure.run"
        case .scrimmage: return "arrow.left.arrow.right"
        case .tryout: return "person.badge.plus"
        case .clinic: return "graduationcap.fill"
        case .pickup: return "person.3.fill"
        }
    }

    static func parse(_ raw: String?) -> FanTeamGameType? {
        guard let game = GameType.parse(raw) else { return nil }
        return FanTeamGameType(rawValue: game.rawValue)
    }
}

enum FanTeamGameRSVPStatus: String, Codable, Hashable, CaseIterable, Sendable {
    case going
    case maybe
    case cant_go

    var localizedKey: String {
        switch self {
        case .going: return "fan_team_rsvp_going"
        case .maybe: return "fan_team_rsvp_maybe"
        case .cant_go: return "fan_team_rsvp_cant_go"
        }
    }
}

struct FanTeamSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let sport: String
    let logoURL: String?
    let logoThumbnailURL: String?
    let colorHex: String?
    /// Team default `competition_level` (same tokens as pickup_games). Nil = Not specified.
    let competitionLevel: PickupCompetitionLevel?
    let ownerUserId: UUID
    let groupConversationId: UUID
    let myRole: FanTeamMemberRole
    let memberCount: Int
    /// Manager/owner-only pending invitation count from `list_my_fan_teams`. Always 0 for other roles.
    let pendingInvitationCount: Int
    /// Viewer’s per-Team push mute from `list_my_fan_teams` (`fan_team_members.push_notifications_muted`).
    let pushNotificationsMuted: Bool
    let nextGameStartsAt: Date?
    let nextGameTitle: String?
    let nextGameVenue: String?
    let createdAt: Date?

    var canManage: Bool { myRole.canManageTeam }

    /// Non-owners may leave via `leave_fan_team` (owners cannot while they own the Team).
    var canLeaveTeam: Bool { myRole.canLeaveTeam }

    /// Owner-only soft-delete via `delete_fan_team` (managers/captains/members cannot).
    var canDeleteTeam: Bool { myRole == .owner }

    /// Owner/Manager may edit Team name, sport, color, and logo (matches backend manage helper).
    var canEditIdentity: Bool { canManage }

    /// Pending indicator for My Teams cards / Roster chrome (managers only, count > 0).
    var showsPendingInvitationIndicator: Bool {
        canManage && pendingInvitationCount > 0
    }

    func applyingIdentity(
        name: String,
        sport: String,
        colorHex: String?,
        logoURL: String?,
        logoThumbnailURL: String?,
        competitionLevel: PickupCompetitionLevel?
    ) -> FanTeamSummary {
        FanTeamSummary(
            id: id,
            name: name,
            sport: sport,
            logoURL: logoURL,
            logoThumbnailURL: logoThumbnailURL,
            colorHex: colorHex,
            competitionLevel: competitionLevel,
            ownerUserId: ownerUserId,
            groupConversationId: groupConversationId,
            myRole: myRole,
            memberCount: memberCount,
            pendingInvitationCount: pendingInvitationCount,
            pushNotificationsMuted: pushNotificationsMuted,
            nextGameStartsAt: nextGameStartsAt,
            nextGameTitle: nextGameTitle,
            nextGameVenue: nextGameVenue,
            createdAt: createdAt
        )
    }

    func applyingPendingInvitationCount(_ count: Int) -> FanTeamSummary {
        FanTeamSummary(
            id: id,
            name: name,
            sport: sport,
            logoURL: logoURL,
            logoThumbnailURL: logoThumbnailURL,
            colorHex: colorHex,
            competitionLevel: competitionLevel,
            ownerUserId: ownerUserId,
            groupConversationId: groupConversationId,
            myRole: myRole,
            memberCount: memberCount,
            pendingInvitationCount: max(0, count),
            pushNotificationsMuted: pushNotificationsMuted,
            nextGameStartsAt: nextGameStartsAt,
            nextGameTitle: nextGameTitle,
            nextGameVenue: nextGameVenue,
            createdAt: createdAt
        )
    }

    func applyingPushNotificationsMuted(_ muted: Bool) -> FanTeamSummary {
        FanTeamSummary(
            id: id,
            name: name,
            sport: sport,
            logoURL: logoURL,
            logoThumbnailURL: logoThumbnailURL,
            colorHex: colorHex,
            competitionLevel: competitionLevel,
            ownerUserId: ownerUserId,
            groupConversationId: groupConversationId,
            myRole: myRole,
            memberCount: memberCount,
            pendingInvitationCount: pendingInvitationCount,
            pushNotificationsMuted: muted,
            nextGameStartsAt: nextGameStartsAt,
            nextGameTitle: nextGameTitle,
            nextGameVenue: nextGameVenue,
            createdAt: createdAt
        )
    }

    func applying(_ change: FanTeamIdentityChange) -> FanTeamSummary {
        applyingIdentity(
            name: change.name,
            sport: change.sport,
            colorHex: change.colorHex,
            logoURL: change.logoURL,
            logoThumbnailURL: change.logoThumbnailURL,
            competitionLevel: change.competitionLevel
        )
    }
}

/// Self-declared profile gender (`user_profiles.gender`). Not Team-specific.
enum FanProfileGender: String, Codable, Hashable, CaseIterable, Sendable {
    case male
    case female
    case nonBinary = "non_binary"
    case other
    case preferNotToSay = "prefer_not_to_say"

    var localizedKey: String {
        switch self {
        case .male: return "profile_gender_male"
        case .female: return "profile_gender_female"
        case .nonBinary: return "profile_gender_non_binary"
        case .other: return "profile_gender_other"
        case .preferNotToSay: return "profile_gender_prefer_not_to_say"
        }
    }

    /// Roster / shared surfaces: hide unset and prefer-not-to-say.
    var isDisplayableOnRoster: Bool {
        self != .preferNotToSay
    }

    static func parse(_ raw: String?) -> FanProfileGender? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty
        else { return nil }
        return FanProfileGender(rawValue: trimmed)
    }

    /// Value shown on Team Roster (nil → hide).
    static func rosterDisplayValue(from raw: String?) -> FanProfileGender? {
        guard let parsed = parse(raw), parsed.isDisplayableOnRoster else { return nil }
        return parsed
    }
}

/// Team-specific jersey/player number helpers (0–99, optional).
enum FanTeamPlayerNumber {
    static let min = 0
    static let max = 99

    static func isValid(_ value: Int?) -> Bool {
        guard let value else { return true }
        return value >= min && value <= max
    }

    static func parse(_ raw: String?) -> Int? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        guard let value = Int(trimmed) else { return nil }
        return isValid(value) ? value : nil
    }

    static func displayLabel(_ value: Int) -> String {
        "#\(value)"
    }
}

/// Roster identity presentation: `Display Name (@handle)` with single-@ normalization.
enum FanTeamRosterRowPresentation {
    /// Avatar diameter for Team Detail → Roster rows.
    static let avatarSize: CGFloat = 68

    /// Leading column width matches avatar so number + photo stay aligned.
    static var leadingColumnWidth: CGFloat { avatarSize }

    /// Normalized `@handle` for parenthetical display, or nil when no handle.
    static func parentheticalHandle(username: String?) -> String? {
        let stored = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !stored.isEmpty else { return nil }
        let display = FanGeoHandleRules.displayHandle(stored: stored)
        let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Combines display name + optional `(@handle)` for VoiceOver / plain-text uses.
    static func identityLine(displayName: String, username: String?) -> String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let handle = parentheticalHandle(username: username) else { return name }
        guard !name.isEmpty else { return "(\(handle))" }
        return "\(name) (\(handle))"
    }
}

struct FanTeamMember: Identifiable, Hashable, Sendable {
    var id: UUID { userId }
    let userId: UUID
    let role: FanTeamMemberRole
    /// Authoritative `fan_team_members.joined_at` for this Team membership (from roster payload).
    let joinedAt: Date?
    let displayName: String
    let username: String?
    let avatarURL: String?
    let avatarThumbnailURL: String?
    let lastSeenAtRaw: String?
    /// Team-specific jersey number from `fan_team_members.player_number` (nil = unassigned).
    let playerNumber: Int?
    /// Profile gender raw token from roster join (`user_profiles.gender`).
    let genderRaw: String?

    init(
        userId: UUID,
        role: FanTeamMemberRole,
        joinedAt: Date?,
        displayName: String,
        username: String?,
        avatarURL: String?,
        avatarThumbnailURL: String?,
        lastSeenAtRaw: String?,
        playerNumber: Int? = nil,
        genderRaw: String? = nil
    ) {
        self.userId = userId
        self.role = role
        self.joinedAt = joinedAt
        self.displayName = displayName
        self.username = username
        self.avatarURL = avatarURL
        self.avatarThumbnailURL = avatarThumbnailURL
        self.lastSeenAtRaw = lastSeenAtRaw
        self.playerNumber = playerNumber
        self.genderRaw = genderRaw
    }

    var preview: UserPreview {
        UserPreview(
            id: userId,
            displayName: displayName,
            username: username,
            avatarURL: avatarURL,
            avatarThumbnailURL: avatarThumbnailURL,
            lastSeenAtRaw: lastSeenAtRaw
        )
    }

    /// Gender to show on Team Roster (hidden when unset / prefer not to say).
    var rosterGender: FanProfileGender? {
        FanProfileGender.rosterDisplayValue(from: genderRaw)
    }

    func previewForDirectMessage(conversationId: UUID) -> UserPreview {
        UserPreview(
            id: userId,
            displayName: displayName,
            username: username,
            avatarURL: avatarURL,
            avatarThumbnailURL: avatarThumbnailURL,
            lastSeenAtRaw: lastSeenAtRaw,
            dmConversationId: conversationId
        )
    }

    func replacingAvatars(avatarURL: String?, avatarThumbnailURL: String?) -> FanTeamMember {
        FanTeamMember(
            userId: userId,
            role: role,
            joinedAt: joinedAt,
            displayName: displayName,
            username: username,
            avatarURL: avatarURL,
            avatarThumbnailURL: avatarThumbnailURL,
            lastSeenAtRaw: lastSeenAtRaw,
            playerNumber: playerNumber,
            genderRaw: genderRaw
        )
    }

    func replacingPlayerNumber(_ playerNumber: Int?) -> FanTeamMember {
        FanTeamMember(
            userId: userId,
            role: role,
            joinedAt: joinedAt,
            displayName: displayName,
            username: username,
            avatarURL: avatarURL,
            avatarThumbnailURL: avatarThumbnailURL,
            lastSeenAtRaw: lastSeenAtRaw,
            playerNumber: playerNumber,
            genderRaw: genderRaw
        )
    }
}

/// Overview “Team Leadership” derivation from the already-loaded active roster (no network).
enum FanTeamLeadership {
    /// Active Owner first, then every active Manager (roster order preserved within each role).
    /// Excludes members, captains, pending invitees, and left members (RPC is active-only).
    /// Dedupes by `userId` so a user never appears twice.
    static func leaders(from members: [FanTeamMember]) -> [FanTeamMember] {
        var seen = Set<UUID>()
        var result: [FanTeamMember] = []
        for member in members where member.role == .owner {
            if seen.insert(member.userId).inserted {
                result.append(member)
            }
        }
        for member in members where member.role == .manager {
            if seen.insert(member.userId).inserted {
                result.append(member)
            }
        }
        return result
    }

    static func isLeadershipRole(_ role: FanTeamMemberRole) -> Bool {
        role == .owner || role == .manager
    }

    /// Matches `openTeamMemberProfile` self vs other routing (no silent no-op for self).
    static func usesOwnPublicProfilePreview(memberUserId: UUID, currentUserId: UUID?) -> Bool {
        guard let currentUserId else { return false }
        return memberUserId == currentUserId
    }
}

/// Fan Teams are invitation-only (not Discover-public). Badge policy is explicit for tests/UI.
enum FanTeamPrivacyPresentation {
    static func showsPrivateTeamBadge(for _: FanTeamSummary) -> Bool {
        true
    }
}

/// Roster-only “Joined Team <Name> • <Month YYYY>” caption (presentation; uses existing `joinedAt`).
enum FanTeamRosterJoinedCaption {
    /// Max grapheme clusters for the dynamic Team name before ellipsis (keeps the caption single-line).
    static let maxTeamNameCharacters = 28

    static func monthYear(from date: Date, languageCode: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        formatter.setLocalizedDateFormatFromTemplate("MMM yyyy")
        return formatter.string(from: date)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func truncatedTeamName(_ teamName: String, maxCharacters: Int = maxTeamNameCharacters) -> String {
        let trimmed = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxCharacters > 1, trimmed.count > maxCharacters else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maxCharacters - 1)
        return String(trimmed[..<end]) + "…"
    }

    /// `nil` when membership timestamp is missing (caller must hide the line).
    static func line(
        teamName: String,
        joinedAt: Date?,
        languageCode: String? = nil
    ) -> String? {
        guard let joinedAt else { return nil }
        let code = L10n.normalizedLanguageCode(languageCode)
        let name = truncatedTeamName(teamName)
        guard !name.isEmpty else { return nil }
        let month = monthYear(from: joinedAt, languageCode: code)
        guard !month.isEmpty else { return nil }
        return String(
            format: L10n.t("fan_teams_joined_team_format", languageCode: code),
            locale: Locale(identifier: code),
            name,
            month
        )
    }
}

/// Presentation helpers for Team Detail → Roster overflow actions (UI only; RPC remains authoritative).
enum FanTeamRosterMemberActions {
    static func isSelf(member: FanTeamMember, currentUserId: UUID?) -> Bool {
        guard let currentUserId else { return false }
        return member.userId == currentUserId
    }

    /// Message is available for every other active roster member (block/friend gates are enforced at open time).
    static func canMessage(member: FanTeamMember, currentUserId: UUID?) -> Bool {
        !isSelf(member: member, currentUserId: currentUserId)
    }

    /// Matches `remove_fan_team_member`: owner/manager may remove non-owners; never self; never owner.
    static func canRemove(
        member: FanTeamMember,
        viewerCanManage: Bool,
        currentUserId: UUID?
    ) -> Bool {
        guard viewerCanManage else { return false }
        guard !isSelf(member: member, currentUserId: currentUserId) else { return false }
        return member.role != .owner
    }
}

struct FanTeamGame: Identifiable, Hashable, Sendable {
    /// Authoritative `pickup_games.id` (also returned as `pickup_game_id` from list RPC).
    let id: UUID
    let teamId: UUID
    let createdBy: UUID
    let gameType: FanTeamGameType
    let sport: String
    let title: String?
    let startsAt: Date
    let endsAt: Date?
    let venueName: String?
    let address: String?
    let city: String?
    let state: String?
    let latitude: Double?
    let longitude: Double?
    let opponentTeamId: UUID?
    let opponentName: String?
    let status: String
    let homeScore: Int?
    let awayScore: Int?
    /// Viewing team's link side: home | away | solo.
    let mySide: String?
    /// Optional `pickup_games.created_at` when returned by `list_fan_team_games`.
    let createdAt: Date?
    /// Optional `pickup_games.competition_level` when returned by `list_fan_team_games`.
    let competitionLevel: PickupCompetitionLevel?

    var pickupGameId: UUID { id }

    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? sport : trimmed
    }

    /// See ``FanTeamGamesTimeline`` — Pickup lifecycle + start/end, not a Team-only flag.
    var isUpcoming: Bool {
        FanTeamGamesTimeline.isUpcoming(self)
    }

    var isCompleted: Bool {
        status == "completed" || (homeScore != nil && awayScore != nil)
    }

    var locationLine: String {
        let parts = [venueName, address, city, state]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }
}

struct FanTeamDetail: Hashable, Sendable {
    var summary: FanTeamSummary
    var members: [FanTeamMember]
    /// Shared with Games tab (`list_fan_team_games`); Overview does not present game cards.
    var games: [FanTeamGame]
}

/// Pending invitation addressed to the current user (My Teams → Invitations).
struct FanTeamInvitation: Identifiable, Hashable, Sendable {
    var id: UUID { invitationId }
    let invitationId: UUID
    let teamId: UUID
    let teamName: String
    let sport: String
    let logoURL: String?
    let logoThumbnailURL: String?
    let colorHex: String?
    let memberCount: Int
    let inviterUserId: UUID
    let inviterDisplayName: String
    let inviterUsername: String?
    let createdAt: Date?
    let expiresAt: Date?
}

/// Pending invitation for a team the current user can manage (Roster → Pending Invitations).
struct FanTeamPendingInvitation: Identifiable, Hashable, Sendable {
    var id: UUID { invitationId }
    let invitationId: UUID
    let inviteeUserId: UUID
    let inviteeDisplayName: String
    let inviteeUsername: String?
    let inviteeAvatarURL: String?
    let inviteeAvatarThumbnailURL: String?
    let inviterUserId: UUID
    let createdAt: Date?
    let expiresAt: Date?

    var inviteePreview: UserPreview {
        UserPreview(
            id: inviteeUserId,
            displayName: inviteeDisplayName,
            username: inviteeUsername,
            avatarURL: inviteeAvatarURL,
            avatarThumbnailURL: inviteeAvatarThumbnailURL,
            lastSeenAtRaw: nil
        )
    }
}
