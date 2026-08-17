import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Authoritative Fan Team roster roles (highest → lowest).
/// Raw values match `fan_team_members.role` tokens; unknown/legacy values map to `.member`.
enum FanTeamMemberRole: String, Codable, Hashable, CaseIterable, Sendable {
    case owner
    case manager
    case headCoach = "head_coach"
    case assistantCoach = "assistant_coach"
    case captain
    case assistantCaptain = "assistant_captain"
    case member

    /// Stable hierarchy rank (Owner = 0 … Member = 6).
    var sortRank: Int {
        switch self {
        case .owner: return 0
        case .manager: return 1
        case .headCoach: return 2
        case .assistantCoach: return 3
        case .captain: return 4
        case .assistantCaptain: return 5
        case .member: return 6
        }
    }

    /// Owner/Manager administrative gates (invite, approve, edit identity, remove non-owners).
    var canManageTeam: Bool {
        self == .owner || self == .manager
    }

    /// Owner/Manager may publish Team Announcements (stricter than schedule organize).
    var canPublishTeamAnnouncements: Bool {
        canManageTeam
    }

    /// Owner-only. Team titles and Team Administrator do not assign roles.
    var canAssignMemberRoles: Bool {
        self == .owner
    }

    /// Owner/Manager/Head Coach may schedule Team pickups / Team events.
    var canOrganizeTeamActivities: Bool {
        switch self {
        case .owner, .manager, .headCoach:
            return true
        case .assistantCoach, .captain, .assistantCaptain, .member:
            return false
        }
    }

    /// Owner/Manager/Head Coach/Assistant Coach may create/edit/publish event lineups.
    var canManageLineup: Bool {
        switch self {
        case .owner, .manager, .headCoach, .assistantCoach:
            return true
        case .captain, .assistantCaptain, .member:
            return false
        }
    }

    /// Owners cannot soft-leave while they own the Team (`leave_fan_team` RPC).
    var canLeaveTeam: Bool {
        self != .owner
    }

    /// Roles shown in Overview → Team Leadership (everyone except Member).
    var isLeadershipRole: Bool {
        self != .member
    }

    /// Roles selectable in the roster set-role menu (Owner is never selectable).
    var isAssignableViaRolePicker: Bool {
        self != .owner
    }

    var localizedKey: String {
        switch self {
        case .owner: return "fan_team_role_owner"
        case .manager: return "fan_team_role_manager"
        case .headCoach: return "fan_team_role_head_coach"
        case .assistantCoach: return "fan_team_role_assistant_coach"
        case .captain: return "fan_team_role_captain"
        case .assistantCaptain: return "fan_team_role_assistant_captain"
        case .member: return "fan_team_role_member"
        }
    }

    var badgeSystemImage: String {
        switch self {
        case .owner: return "crown.fill"
        case .manager: return "shield.fill"
        case .headCoach: return "whistle.fill"
        case .assistantCoach: return "clipboard.fill"
        case .captain: return "star.fill"
        case .assistantCaptain: return "star"
        case .member: return "person.fill"
        }
    }

    /// Semantic badge tint used by ``FanTeamRoleBadgeView``.
    var badgeTint: FanTeamRoleBadgeTint {
        switch self {
        case .owner: return .gold
        case .manager: return .purple
        case .headCoach: return .blue
        case .assistantCoach: return .indigo
        case .captain: return .orange
        case .assistantCaptain: return .teal
        case .member: return .gray
        }
    }

    /// Role picker order (Owner excluded).
    static var assignableViaRolePicker: [FanTeamMemberRole] {
        [.manager, .headCoach, .assistantCoach, .captain, .assistantCaptain, .member]
    }

    /// Hierarchy order including Owner (for CaseIterable consumers that need full sort).
    static var hierarchyOrder: [FanTeamMemberRole] {
        [.owner, .manager, .headCoach, .assistantCoach, .captain, .assistantCaptain, .member]
    }

    /// Parses DB / wire tokens with backward-compatible aliases; unknown → `.member`.
    static func parse(_ raw: String?) -> FanTeamMemberRole {
        let normalized = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        switch normalized {
        case "owner":
            return .owner
        case "manager":
            return .manager
        case "head_coach", "headcoach", "coach":
            return .headCoach
        case "assistant_coach", "assistantcoach", "asst_coach", "assistant":
            return .assistantCoach
        case "captain":
            return .captain
        case "assistant_captain", "assistantcaptain", "asst_captain", "a_captain":
            return .assistantCaptain
        case "member", "":
            return .member
        default:
            return FanTeamMemberRole(rawValue: normalized) ?? .member
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = FanTeamMemberRole.parse(raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum FanTeamRoleBadgeTint: String, Hashable, Sendable {
    case gold
    case purple
    case blue
    case indigo
    case orange
    case teal
    case gray

    func color(for colorScheme: ColorScheme) -> Color {
        switch self {
        case .gold:
            return Color(red: 0.85, green: 0.65, blue: 0.13)
        case .purple:
            return Color(red: 0.56, green: 0.27, blue: 0.78)
        case .blue:
            return Color(red: 0.20, green: 0.47, blue: 0.96)
        case .indigo:
            return colorScheme == .dark
                ? Color(red: 0.55, green: 0.48, blue: 0.95)
                : Color(red: 0.35, green: 0.28, blue: 0.75)
        case .orange:
            return Color(red: 0.95, green: 0.55, blue: 0.15)
        case .teal:
            return Color(red: 0.15, green: 0.68, blue: 0.68)
        case .gray:
            return Color(UIColor.secondaryLabel)
        }
    }
}

/// Compact role chip (icon + localized title) for headers, leadership, and roster.
struct FanTeamRoleBadgeView: View {
    let role: FanTeamMemberRole
    let languageCode: String
    var showsTitle: Bool = true
    var compact: Bool = true

    @Environment(\.colorScheme) private var colorScheme

    /// Prefer the role glyph; fall back if the symbol is unavailable on this OS.
    private var resolvedSystemImage: String {
        let preferred = role.badgeSystemImage
#if canImport(UIKit)
        if UIImage(systemName: preferred) != nil {
            return preferred
        }
#endif
        return "person.fill"
    }

    var body: some View {
        let tint = role.badgeTint.color(for: colorScheme)
        let title = L10n.t(role.localizedKey, languageCode: languageCode)
        HStack(spacing: compact ? 4 : 6) {
            Image(systemName: resolvedSystemImage)
                .font(.system(size: compact ? 9 : 11, weight: .bold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            if showsTitle {
                Text(title)
                    .font(compact ? .caption2.weight(.bold) : .caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    // Intrinsic width — never compress “Owner” / “Manager” into “Ow…”.
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 3 : 5)
        .background(
            tint.opacity(colorScheme == .dark ? 0.22 : 0.14),
            in: Capsule()
        )
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
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
    case team_meeting
    case other
    case announcement

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
        case .team_meeting: return "pickup_game_format_team_meeting"
        case .other: return "pickup_game_format_other"
        case .announcement: return "pickup_game_format_announcement"
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
        case .team_meeting: return "person.3.sequence.fill"
        case .other: return "ellipsis.circle.fill"
        case .announcement: return "megaphone.fill"
        }
    }

    /// Solid accent for Schedule labels / rings / icon-circle fill (by event type).
    var scheduleDateBlockColor: Color {
        scheduleDateBlockGradientColors.bottom
    }

    /// Vertical gradient stops for the floating Schedule date badge (top → bottom).
    var scheduleDateBlockGradientColors: (top: Color, bottom: Color) {
        switch self {
        case .practice:
            // Blue
            return (
                Color(red: 0.38, green: 0.64, blue: 0.98),
                Color(red: 0.14, green: 0.40, blue: 0.88)
            )
        case .league_game:
            // Green
            return (
                Color(red: 0.32, green: 0.84, blue: 0.54),
                Color(red: 0.10, green: 0.58, blue: 0.36)
            )
        case .tournament_game:
            // Orange / gold
            return (
                Color(red: 1.00, green: 0.74, blue: 0.32),
                Color(red: 0.92, green: 0.48, blue: 0.12)
            )
        case .tryout:
            // Purple
            return (
                Color(red: 0.74, green: 0.54, blue: 0.98),
                Color(red: 0.50, green: 0.30, blue: 0.88)
            )
        case .clinic:
            // Teal (Clinic / Camp)
            return (
                Color(red: 0.30, green: 0.84, blue: 0.80),
                Color(red: 0.08, green: 0.54, blue: 0.58)
            )
        case .match:
            // Red
            return (
                Color(red: 0.98, green: 0.46, blue: 0.46),
                Color(red: 0.82, green: 0.18, blue: 0.24)
            )
        case .team_meeting:
            // Slate
            return (
                Color(red: 0.58, green: 0.62, blue: 0.74),
                Color(red: 0.36, green: 0.40, blue: 0.52)
            )
        case .scrimmage:
            // Cyan (between practice blue and clinic teal)
            return (
                Color(red: 0.34, green: 0.78, blue: 0.90),
                Color(red: 0.10, green: 0.52, blue: 0.68)
            )
        case .pickup:
            return (
                Color(red: 1.00, green: 0.72, blue: 0.38),
                Color(red: 0.94, green: 0.50, blue: 0.14)
            )
        case .other:
            // Gray
            return (
                Color(red: 0.64, green: 0.68, blue: 0.74),
                Color(red: 0.42, green: 0.46, blue: 0.52)
            )
        case .announcement:
            // Amber / notice
            return (
                Color(red: 1.00, green: 0.78, blue: 0.36),
                Color(red: 0.90, green: 0.52, blue: 0.10)
            )
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

/// Cached `get_fan_team_game_rsvp` result for one `pickup_games.id` (event-scoped).
enum FanTeamCachedSelfRSVP: Equatable, Hashable, Sendable {
    case unanswered
    case status(FanTeamGameRSVPStatus)

    var asStatus: FanTeamGameRSVPStatus? {
        switch self {
        case .unanswered: return nil
        case .status(let status): return status
        }
    }

    /// True only for a definitive Going / Maybe / Can't Go answer.
    var isDefinitive: Bool {
        if case .status = self { return true }
        return false
    }

    var debugLabel: String {
        switch self {
        case .unanswered: return "unanswered"
        case .status(let status): return status.rawValue
        }
    }

    static func from(rpcStatus: FanTeamGameRSVPStatus?) -> FanTeamCachedSelfRSVP {
        guard let rpcStatus else { return .unanswered }
        return .status(rpcStatus)
    }
}

/// One row from additive `list_fan_team_schedule_attendance`.
struct FanTeamScheduleAttendanceRow: Sendable {
    let pickupGameId: UUID
    let roster: PickupGameRosterPayload
    let selfRSVP: FanTeamGameRSVPStatus?
}

/// How `list_my_fan_teams` authorized a home-list row for the authenticated viewer.
enum FanTeamListAccessVia: String, Equatable, Hashable, Sendable {
    case account
    case managedPlayer = "managed_player"

    static func resolved(_ raw: String?) -> FanTeamListAccessVia {
        let token = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return FanTeamListAccessVia(rawValue: token) ?? .account
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
    /// Up to 4 hierarchy-ordered active member avatar previews (20260966).
    /// Empty when the deployed RPC predates the field or the Team has no seats.
    let memberAvatarPreviews: [FanTeamMemberAvatarPreview]
    /// How `list_my_fan_teams` authorized this row (20260972). Defaults to `.account`.
    let accessVia: FanTeamListAccessVia
    /// Compact labels for managed players this guardian has on the Team (home “Via …” chip).
    let viaManagedPlayerNames: [String]
    /// Effective management permissions for the viewer on this Team (20260985).
    /// When older RPCs omit `my_permissions`, falls back to role defaults.
    let myPermissions: FanTeamPermissionSet

    init(
        id: UUID,
        name: String,
        sport: String,
        logoURL: String?,
        logoThumbnailURL: String?,
        colorHex: String?,
        competitionLevel: PickupCompetitionLevel?,
        ownerUserId: UUID,
        groupConversationId: UUID,
        myRole: FanTeamMemberRole,
        memberCount: Int,
        pendingInvitationCount: Int,
        pushNotificationsMuted: Bool,
        nextGameStartsAt: Date?,
        nextGameTitle: String?,
        nextGameVenue: String?,
        createdAt: Date?,
        memberAvatarPreviews: [FanTeamMemberAvatarPreview] = [],
        accessVia: FanTeamListAccessVia = .account,
        viaManagedPlayerNames: [String] = [],
        myPermissions: FanTeamPermissionSet? = nil
    ) {
        self.id = id
        self.name = name
        self.sport = sport
        self.logoURL = logoURL
        self.logoThumbnailURL = logoThumbnailURL
        self.colorHex = colorHex
        self.competitionLevel = competitionLevel
        self.ownerUserId = ownerUserId
        self.groupConversationId = groupConversationId
        self.myRole = myRole
        self.memberCount = memberCount
        self.pendingInvitationCount = pendingInvitationCount
        self.pushNotificationsMuted = pushNotificationsMuted
        self.nextGameStartsAt = nextGameStartsAt
        self.nextGameTitle = nextGameTitle
        self.nextGameVenue = nextGameVenue
        self.createdAt = createdAt
        self.memberAvatarPreviews = memberAvatarPreviews
        self.accessVia = accessVia
        self.viaManagedPlayerNames = viaManagedPlayerNames
        self.myPermissions = myPermissions ?? FanTeamPermissions.roleDefaults(for: myRole)
    }

    /// True when the authenticated account holds a `fan_team_members` seat.
    /// Independent of Team Chat: a guardian may have Team access with no seat.
    var hasAccountSeat: Bool { accessVia == .account }

    /// Canonical Team ACCOUNT ACCESS for this `list_my_fan_teams` row.
    /// True for a direct account seat OR guardian-via-managed-player access.
    /// Independent of `is_player`, roster player count, and moderation rights.
    var hasTeamAccountAccess: Bool {
        switch accessVia {
        case .account, .managedPlayer:
            return true
        }
    }

    /// Team Chat follows account access, not Myself player participation.
    var canAccessTeamChat: Bool { hasTeamAccountAccess }

    func hasPermission(_ key: FanTeamPermissionKey) -> Bool {
        hasAccountSeat && myPermissions.contains(key)
    }

    var canManage: Bool {
        hasAccountSeat && (
            myRole == .owner
                || hasPermission(.inviteMembers)
                || hasPermission(.manageRoster)
                || hasPermission(.publishAnnouncements)
                || hasPermission(.editTeamInformation)
                || hasPermission(.manageManagedPlayers)
                || hasPermission(.editEvents)
                || hasPermission(.moderateTeamChat)
        )
    }

    /// Owner or granted `publishAnnouncements` (Team Administrator preset includes this).
    var canPublishAnnouncements: Bool { hasPermission(.publishAnnouncements) }

    /// Owner-only Team title assignment. Manager / Team Administrator
    /// operational access (`can_manage`, roster, invite) must not assign roles.
    var canAssignRoles: Bool {
        hasAccountSeat && myRole == .owner
    }

    /// Owner/Manager/Head Coach or granted `createEvents`.
    var canOrganizeActivities: Bool { hasPermission(.createEvents) }

    /// Owner/Manager/Head Coach/Assistant Coach or granted `manageLineups`.
    var canManageLineup: Bool { hasPermission(.manageLineups) }

    /// Non-owners may leave via `leave_fan_team` (owners cannot while they own the Team).
    /// Guardian-only access cannot leave as a "member" — they are not on the roster.
    var canLeaveTeam: Bool { hasAccountSeat && myRole.canLeaveTeam }

    /// Owner-only soft-delete via `delete_fan_team` (managers/captains/members cannot).
    var canDeleteTeam: Bool { hasAccountSeat && myRole == .owner }

    /// Owner/Manager or granted `editTeamInformation`.
    var canEditIdentity: Bool { hasPermission(.editTeamInformation) }

    /// Edit Team-linked events (Owner/Manager defaults or granted `editEvents`).
    var canEditTeamEvents: Bool { hasPermission(.editEvents) }

    /// Invite members (Owner/Manager defaults or granted).
    var canInviteMembers: Bool { hasPermission(.inviteMembers) }

    /// Roster staff actions (jersey remove, etc.).
    var canManageRoster: Bool { hasPermission(.manageRoster) }

    /// Staff managed-player placement beyond guardian self-service.
    var canManageManagedPlayersStaff: Bool { hasPermission(.manageManagedPlayers) }

    var canModerateTeamChat: Bool { hasPermission(.moderateTeamChat) }

    /// Pending indicator for My Teams cards / Roster chrome (managers only, count > 0).
    var showsPendingInvitationIndicator: Bool {
        canManage && pendingInvitationCount > 0
    }

    private func copying(
        name: String? = nil,
        sport: String? = nil,
        colorHex: String?? = nil,
        logoURL: String?? = nil,
        logoThumbnailURL: String?? = nil,
        competitionLevel: PickupCompetitionLevel?? = nil,
        memberCount: Int? = nil,
        pendingInvitationCount: Int? = nil,
        pushNotificationsMuted: Bool? = nil,
        nextGameStartsAt: Date?? = nil,
        nextGameTitle: String?? = nil,
        nextGameVenue: String?? = nil,
        memberAvatarPreviews: [FanTeamMemberAvatarPreview]? = nil,
        accessVia: FanTeamListAccessVia? = nil,
        viaManagedPlayerNames: [String]? = nil,
        myPermissions: FanTeamPermissionSet? = nil
    ) -> FanTeamSummary {
        FanTeamSummary(
            id: id,
            name: name ?? self.name,
            sport: sport ?? self.sport,
            logoURL: logoURL ?? self.logoURL,
            logoThumbnailURL: logoThumbnailURL ?? self.logoThumbnailURL,
            colorHex: colorHex ?? self.colorHex,
            competitionLevel: competitionLevel ?? self.competitionLevel,
            ownerUserId: ownerUserId,
            groupConversationId: groupConversationId,
            myRole: myRole,
            memberCount: memberCount ?? self.memberCount,
            pendingInvitationCount: pendingInvitationCount ?? self.pendingInvitationCount,
            pushNotificationsMuted: pushNotificationsMuted ?? self.pushNotificationsMuted,
            nextGameStartsAt: nextGameStartsAt ?? self.nextGameStartsAt,
            nextGameTitle: nextGameTitle ?? self.nextGameTitle,
            nextGameVenue: nextGameVenue ?? self.nextGameVenue,
            createdAt: createdAt,
            memberAvatarPreviews: memberAvatarPreviews ?? self.memberAvatarPreviews,
            accessVia: accessVia ?? self.accessVia,
            viaManagedPlayerNames: viaManagedPlayerNames ?? self.viaManagedPlayerNames,
            myPermissions: myPermissions ?? self.myPermissions
        )
    }

    func applyingIdentity(
        name: String,
        sport: String,
        colorHex: String?,
        logoURL: String?,
        logoThumbnailURL: String?,
        competitionLevel: PickupCompetitionLevel?
    ) -> FanTeamSummary {
        copying(
            name: name,
            sport: sport,
            colorHex: .some(colorHex),
            logoURL: .some(logoURL),
            logoThumbnailURL: .some(logoThumbnailURL),
            competitionLevel: .some(competitionLevel)
        )
    }

    func applyingPendingInvitationCount(_ count: Int) -> FanTeamSummary {
        copying(pendingInvitationCount: max(0, count))
    }

    /// Refresh role / canManage from authoritative roster after membership changes.
    /// Pass `myPermissions` from `list_fan_team_members.effective_permissions` when available
    /// so Owner-granted custom permissions are not wiped back to role defaults.
    func applyingMyRole(
        _ role: FanTeamMemberRole,
        memberCount: Int,
        myPermissions: FanTeamPermissionSet? = nil
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
            myRole: role,
            memberCount: max(0, memberCount),
            pendingInvitationCount: role.canManageTeam ? pendingInvitationCount : 0,
            pushNotificationsMuted: pushNotificationsMuted,
            nextGameStartsAt: nextGameStartsAt,
            nextGameTitle: nextGameTitle,
            nextGameVenue: nextGameVenue,
            createdAt: createdAt,
            memberAvatarPreviews: memberAvatarPreviews,
            accessVia: accessVia,
            viaManagedPlayerNames: viaManagedPlayerNames,
            myPermissions: myPermissions ?? FanTeamPermissions.roleDefaults(for: role)
        )
    }

    func applyingMemberCount(_ count: Int) -> FanTeamSummary {
        copying(memberCount: max(0, count))
    }

    func applyingPushNotificationsMuted(_ muted: Bool) -> FanTeamSummary {
        copying(pushNotificationsMuted: muted)
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

    func applyingMyPermissions(_ permissions: FanTeamPermissionSet) -> FanTeamSummary {
        copying(myPermissions: permissions)
    }
}

/// Safe Teams-home avatar chip from `list_my_fan_teams.member_avatar_previews`.
struct FanTeamMemberAvatarPreview: Identifiable, Hashable, Sendable {
    let membershipId: UUID
    /// Present for managed seats after 20260970; nil for account seats / older RPCs.
    let managedPlayerId: UUID?
    let displayName: String
    let avatarURL: String?
    let avatarThumbnailURL: String?
    let role: FanTeamMemberRole
    let isManagedPlayer: Bool

    var id: UUID { membershipId }

    init(
        membershipId: UUID,
        managedPlayerId: UUID? = nil,
        displayName: String,
        avatarURL: String?,
        avatarThumbnailURL: String?,
        role: FanTeamMemberRole,
        isManagedPlayer: Bool
    ) {
        self.membershipId = membershipId
        self.managedPlayerId = isManagedPlayer ? managedPlayerId : nil
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.avatarThumbnailURL = avatarThumbnailURL
        self.role = role
        self.isManagedPlayer = isManagedPlayer
    }
}

/// Presentation helpers for the Teams home overlapping avatar stack.
enum FanTeamHomeMemberAvatarStack {
    static let maxVisibleAvatars = 4
    static let avatarSize: CGFloat = 32
    static let overlap: CGFloat = -9

    static func visiblePreviews(
        from previews: [FanTeamMemberAvatarPreview],
        memberCount: Int
    ) -> [FanTeamMemberAvatarPreview] {
        Array(previews.prefix(maxVisibleAvatars))
    }

    static func overflowCount(
        memberCount: Int,
        visiblePreviewCount: Int
    ) -> Int {
        max(0, memberCount - visiblePreviewCount)
    }

    static func accessibilityLabel(
        memberCount: Int,
        visibleNames: [String],
        languageCode: String
    ) -> String {
        let countLine = String(
            format: L10n.t("fan_teams_members_count_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            Int64(memberCount)
        )
        let names = visibleNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return countLine }

        let remaining = max(0, memberCount - names.count)
        if remaining > 0 {
            let more = String(
                format: L10n.t("fan_teams_avatar_stack_and_more_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                Int64(remaining)
            )
            return "\(countLine). \(names.joined(separator: ", ")), \(more)"
        }
        return "\(countLine). \(names.joined(separator: ", "))"
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
///
/// `nonisolated`: module default actor isolation is MainActor, but these are pure
/// value transforms (safe from `Optional.map` / nonisolated presentation helpers).
nonisolated enum FanTeamPlayerNumber {
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

/// Compact roster metadata: `#24 · CB`, `#24`, or `CB`.
enum FanTeamMemberPositionPresentation {
    static func compactMetadata(playerNumber: Int?, preferredPositionCode: String?) -> String? {
        let numberLabel = playerNumber.map(FanTeamPlayerNumber.displayLabel)
        let position = preferredPositionCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let positionLabel = (position?.isEmpty == false) ? position : nil
        switch (numberLabel, positionLabel) {
        case let (number?, position?):
            return "\(number) · \(position)"
        case let (number?, nil):
            return number
        case let (nil, position?):
            return position
        case (nil, nil):
            return nil
        }
    }

    /// Prefill event lineup position from Team preferred position (new members only).
    static func lineupPrefillPositionCode(
        preferredPositionCode: String?,
        sportToken: String?
    ) -> String? {
        guard FanTeamSportPositions.isValid(code: preferredPositionCode, sportToken: sportToken) else {
            return nil
        }
        return FanTeamSportPositions.position(code: preferredPositionCode, sportToken: sportToken)?.code
    }

    /// Overview “My Player Info” position line: `Goalkeeper (GK)`, else canonical code, else nil when unset.
    static func overviewPositionDisplay(
        preferredPositionCode: String?,
        sportToken: String?,
        languageCode: String
    ) -> String? {
        let normalized = preferredPositionCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        guard !normalized.isEmpty else { return nil }
        if let catalog = FanTeamSportPositions.position(code: normalized, sportToken: sportToken) {
            let long = catalog.accessibilityLabel(languageCode: languageCode)
            return "\(long) (\(catalog.code))"
        }
        return normalized
    }

    /// VoiceOver value for Overview position (long title + spaced code letters when catalog resolves).
    static func overviewPositionAccessibilityValue(
        preferredPositionCode: String?,
        sportToken: String?,
        languageCode: String
    ) -> String? {
        let normalized = preferredPositionCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        guard !normalized.isEmpty else { return nil }
        if let catalog = FanTeamSportPositions.position(code: normalized, sportToken: sportToken) {
            let long = catalog.accessibilityLabel(languageCode: languageCode)
            let spaced = catalog.code.map { String($0) }.joined(separator: " ")
            return "\(long), \(spaced)"
        }
        return normalized.map { String($0) }.joined(separator: " ")
    }
}

/// Team Overview → “My Player Info” for the current authenticated Team member (presentation only).
enum FanTeamMyPlayerInfoPresentation {
    /// Resolve the viewer’s active `FanTeamMember` row from the already-loaded roster.
    static func viewerMember(
        from members: [FanTeamMember],
        currentUserId: UUID?
    ) -> FanTeamMember? {
        guard let currentUserId else { return nil }
        return members.first { $0.userId == currentUserId }
    }

    /// Managed players the viewer guards on this Team (drives the "My Players" card).
    static func viewerManagedMembers(
        from members: [FanTeamMember],
        managedPlayerIds: Set<UUID>
    ) -> [FanTeamMember] {
        guard !managedPlayerIds.isEmpty else { return [] }
        return members.filter { member in
            guard let id = member.managedPlayerId else { return false }
            return managedPlayerIds.contains(id)
        }
    }

    /// Show only when the viewer has an active membership row in this Team’s roster.
    static func shouldShow(viewerMember: FanTeamMember?) -> Bool {
        viewerMember != nil
    }

    /// This card never grants jersey/position edit rights (roster permissions stay authoritative).
    static var grantsSelfEditPermission: Bool { false }

    static func jerseyDisplayValue(playerNumber: Int?, languageCode: String) -> String {
        if let playerNumber, FanTeamPlayerNumber.isValid(playerNumber) {
            return FanTeamPlayerNumber.displayLabel(playerNumber)
        }
        return L10n.t("fan_teams_not_set", languageCode: languageCode)
    }

    static func positionDisplayValue(
        preferredPositionCode: String?,
        sportToken: String?,
        languageCode: String
    ) -> String {
        FanTeamMemberPositionPresentation.overviewPositionDisplay(
            preferredPositionCode: preferredPositionCode,
            sportToken: sportToken,
            languageCode: languageCode
        ) ?? L10n.t("fan_teams_not_set", languageCode: languageCode)
    }

    static func memberSinceDisplayValue(joinedAt: Date?, languageCode: String) -> String {
        guard let joinedAt else {
            return L10n.t("fan_teams_not_set", languageCode: languageCode)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: joinedAt)
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
    /// Roster seat identity (`fan_team_members.membership_id`). Stable for both
    /// authenticated members and managed players; `userId` is nil for the latter.
    var id: UUID { membershipId }
    let membershipId: UUID
    /// Authenticated participant. `nil` when this seat is a guardian-managed player.
    let userId: UUID?
    /// Guardian-managed participant. `nil` for authenticated members.
    let managedPlayerId: UUID?
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
    /// Team-specific preferred position from `fan_team_members.preferred_position_code` (nil = unset).
    let preferredPositionCode: String?
    /// Profile gender raw token from roster join (`user_profiles.gender`).
    let genderRaw: String?
    /// Rostered player vs account-access-only (`fan_team_members.is_player`).
    /// Defaults to `true` when older RPCs omit the column (pre-20260984).
    let isPlayer: Bool
    /// Owner customized this seat's permissions (20260985).
    let useCustomPermissions: Bool
    /// Owner-saved keys when `useCustomPermissions` (may be empty).
    let grantedPermissions: FanTeamPermissionSet
    /// Effective management permissions for this seat.
    let effectivePermissions: FanTeamPermissionSet

    /// `membershipId` is optional at the call site so the legacy construction path
    /// (`FanTeamMember(userId:…)`) keeps working: it falls back to `userId`, which
    /// was the row identity before 20260960 introduced roster seats.
    init(
        membershipId: UUID? = nil,
        userId: UUID?,
        managedPlayerId: UUID? = nil,
        role: FanTeamMemberRole,
        joinedAt: Date?,
        displayName: String,
        username: String?,
        avatarURL: String?,
        avatarThumbnailURL: String?,
        lastSeenAtRaw: String?,
        playerNumber: Int? = nil,
        preferredPositionCode: String? = nil,
        genderRaw: String? = nil,
        isPlayer: Bool = true,
        useCustomPermissions: Bool = false,
        grantedPermissions: FanTeamPermissionSet = .empty,
        effectivePermissions: FanTeamPermissionSet? = nil
    ) {
        self.membershipId = membershipId ?? userId ?? managedPlayerId ?? UUID()
        self.userId = userId
        self.managedPlayerId = managedPlayerId
        self.role = role
        self.joinedAt = joinedAt
        self.displayName = displayName
        self.username = username
        self.avatarURL = avatarURL
        self.avatarThumbnailURL = avatarThumbnailURL
        self.lastSeenAtRaw = lastSeenAtRaw
        self.playerNumber = playerNumber
        let normalized = preferredPositionCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        self.preferredPositionCode = (normalized?.isEmpty == false) ? normalized : nil
        self.genderRaw = genderRaw
        // Managed seats are always players (DB CHECK); never allow false.
        self.isPlayer = managedPlayerId != nil ? true : isPlayer
        self.useCustomPermissions = useCustomPermissions
        self.grantedPermissions = grantedPermissions
        self.effectivePermissions = effectivePermissions
            ?? FanTeamPermissions.effective(
                role: role,
                useCustom: useCustomPermissions,
                granted: grantedPermissions
            )
    }

    func hasPermission(_ key: FanTeamPermissionKey) -> Bool {
        effectivePermissions.contains(key)
    }

    /// Roster seat identity as an explicit XOR (matches the database CHECK).
    var participantIdentity: TeamParticipantIdentity? {
        TeamParticipantIdentity.resolve(userId: userId, managedPlayerId: managedPlayerId)
    }

    /// Key shared with the roster / attendance / lineup payloads, whose `user_id`
    /// field carries the managed player id for managed seats.
    var participantKey: UUID? { userId ?? managedPlayerId }

    var isManagedPlayer: Bool { managedPlayerId != nil }

    /// Profile / DM / friend affordances require a real account.
    var supportsSocialActions: Bool { userId != nil }

    /// `nil` for managed players: they have no `user_profiles` row, so a
    /// `UserPreview` would be a fabricated social identity. Managed-player avatars
    /// come from `avatarURL` / `avatarThumbnailURL` on the member itself.
    var preview: UserPreview? {
        guard let userId else { return nil }
        return UserPreview(
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

    func previewForDirectMessage(conversationId: UUID) -> UserPreview? {
        guard let userId else { return nil }
        return UserPreview(
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
            membershipId: membershipId,
            userId: userId,
            managedPlayerId: managedPlayerId,
            role: role,
            joinedAt: joinedAt,
            displayName: displayName,
            username: username,
            avatarURL: avatarURL,
            avatarThumbnailURL: avatarThumbnailURL,
            lastSeenAtRaw: lastSeenAtRaw,
            playerNumber: playerNumber,
            preferredPositionCode: preferredPositionCode,
            genderRaw: genderRaw,
            isPlayer: isPlayer,
            useCustomPermissions: useCustomPermissions,
            grantedPermissions: grantedPermissions,
            effectivePermissions: effectivePermissions
        )
    }

    func replacingPlayerNumber(_ playerNumber: Int?) -> FanTeamMember {
        FanTeamMember(
            membershipId: membershipId,
            userId: userId,
            managedPlayerId: managedPlayerId,
            role: role,
            joinedAt: joinedAt,
            displayName: displayName,
            username: username,
            avatarURL: avatarURL,
            avatarThumbnailURL: avatarThumbnailURL,
            lastSeenAtRaw: lastSeenAtRaw,
            playerNumber: playerNumber,
            preferredPositionCode: preferredPositionCode,
            genderRaw: genderRaw,
            isPlayer: isPlayer,
            useCustomPermissions: useCustomPermissions,
            grantedPermissions: grantedPermissions,
            effectivePermissions: effectivePermissions
        )
    }

    func replacingPreferredPositionCode(_ preferredPositionCode: String?) -> FanTeamMember {
        FanTeamMember(
            membershipId: membershipId,
            userId: userId,
            managedPlayerId: managedPlayerId,
            role: role,
            joinedAt: joinedAt,
            displayName: displayName,
            username: username,
            avatarURL: avatarURL,
            avatarThumbnailURL: avatarThumbnailURL,
            lastSeenAtRaw: lastSeenAtRaw,
            playerNumber: playerNumber,
            preferredPositionCode: preferredPositionCode,
            genderRaw: genderRaw,
            isPlayer: isPlayer,
            useCustomPermissions: useCustomPermissions,
            grantedPermissions: grantedPermissions,
            effectivePermissions: effectivePermissions
        )
    }

    func replacingRole(_ role: FanTeamMemberRole) -> FanTeamMember {
        FanTeamMember(
            membershipId: membershipId,
            userId: userId,
            managedPlayerId: managedPlayerId,
            role: role,
            joinedAt: joinedAt,
            displayName: displayName,
            username: username,
            avatarURL: avatarURL,
            avatarThumbnailURL: avatarThumbnailURL,
            lastSeenAtRaw: lastSeenAtRaw,
            playerNumber: playerNumber,
            preferredPositionCode: preferredPositionCode,
            genderRaw: genderRaw,
            isPlayer: isPlayer,
            useCustomPermissions: useCustomPermissions,
            grantedPermissions: grantedPermissions,
            effectivePermissions: useCustomPermissions
                ? effectivePermissions
                : FanTeamPermissions.roleDefaults(for: role)
        )
    }

    func replacingIsPlayer(_ isPlayer: Bool) -> FanTeamMember {
        FanTeamMember(
            membershipId: membershipId,
            userId: userId,
            managedPlayerId: managedPlayerId,
            role: role,
            joinedAt: joinedAt,
            displayName: displayName,
            username: username,
            avatarURL: avatarURL,
            avatarThumbnailURL: avatarThumbnailURL,
            lastSeenAtRaw: lastSeenAtRaw,
            playerNumber: isPlayer ? playerNumber : nil,
            preferredPositionCode: isPlayer ? preferredPositionCode : nil,
            genderRaw: genderRaw,
            isPlayer: isPlayer,
            useCustomPermissions: useCustomPermissions,
            grantedPermissions: grantedPermissions,
            effectivePermissions: effectivePermissions
        )
    }

    func replacingPermissions(
        useCustom: Bool,
        granted: FanTeamPermissionSet
    ) -> FanTeamMember {
        FanTeamMember(
            membershipId: membershipId,
            userId: userId,
            managedPlayerId: managedPlayerId,
            role: role,
            joinedAt: joinedAt,
            displayName: displayName,
            username: username,
            avatarURL: avatarURL,
            avatarThumbnailURL: avatarThumbnailURL,
            lastSeenAtRaw: lastSeenAtRaw,
            playerNumber: playerNumber,
            preferredPositionCode: preferredPositionCode,
            genderRaw: genderRaw,
            isPlayer: isPlayer,
            useCustomPermissions: useCustom,
            grantedPermissions: granted,
            effectivePermissions: FanTeamPermissions.effective(
                role: role,
                useCustom: useCustom,
                granted: granted
            )
        )
    }
}

/// Roster helpers: player seats vs access-only account seats.
enum FanTeamRosterPlayerPresentation {
    /// Active seats that count as rostered players (lineup / jersey / member count).
    static func playerSeats(from members: [FanTeamMember]) -> [FanTeamMember] {
        members.filter(\.isPlayer)
    }

    static func playerCount(from members: [FanTeamMember]) -> Int {
        playerSeats(from: members).count
    }
}

/// Overview “Team Leadership” derivation from the already-loaded active roster (no network).
enum FanTeamLeadership {
    /// Leadership roles only (Owner → Assistant Captain), sorted by hierarchy then display name.
    /// Excludes Members, pending invitees, and left members (RPC is active-only).
    /// Dedupes by roster seat (`membership_id`) so a person never appears twice.
    /// Managed-player captains/coaches are included; they are real roster seats.
    static func leaders(from members: [FanTeamMember]) -> [FanTeamMember] {
        var seen = Set<UUID>()
        let leadership = members.filter(\.role.isLeadershipRole)
        let sorted = FanTeamRosterOrdering.sorted(leadership)
        var result: [FanTeamMember] = []
        for member in sorted {
            if seen.insert(member.membershipId).inserted {
                result.append(member)
            }
        }
        return result
    }

    static func isLeadershipRole(_ role: FanTeamMemberRole) -> Bool {
        role.isLeadershipRole
    }

    /// Matches `openTeamMemberProfile` self vs other routing (no silent no-op for self).
    static func usesOwnPublicProfilePreview(memberUserId: UUID, currentUserId: UUID?) -> Bool {
        guard let currentUserId else { return false }
        return memberUserId == currentUserId
    }
}

/// Shared roster / invite / leadership sort: role hierarchy, then display name.
enum FanTeamRosterOrdering {
    static func sorted(_ members: [FanTeamMember]) -> [FanTeamMember] {
        members.sorted { lhs, rhs in
            if lhs.role.sortRank != rhs.role.sortRank {
                return lhs.role.sortRank < rhs.role.sortRank
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
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
        guard let currentUserId, let memberUserId = member.userId else { return false }
        return memberUserId == currentUserId
    }

    /// Message is available for every other active roster member (block/friend gates are enforced at open time).
    /// Managed players have no account to message.
    static func canMessage(member: FanTeamMember, currentUserId: UUID?) -> Bool {
        member.supportsSocialActions && !isSelf(member: member, currentUserId: currentUserId)
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
    var status: String
    var homeScore: Int?
    var awayScore: Int?
    /// Viewing team's link side: home | away | solo.
    let mySide: String?
    /// Optional `pickup_games.created_at` when returned by `list_fan_team_games`.
    let createdAt: Date?
    /// Optional `pickup_games.competition_level` when returned by `list_fan_team_games`.
    let competitionLevel: PickupCompetitionLevel?
    /// Optional announcement/message body from `pickup_games.description`.
    /// Named `messageBody` (not `description`) to avoid CustomStringConvertible collisions.
    let messageBody: String?
    /// `scheduled` | `live` | `final`. Missing on older RPCs → scheduled.
    var scoringStatus: String = "scheduled"
    var scoringFinalizedAt: Date? = nil

    var pickupGameId: UUID { id }

    var scoringLifecycle: FanTeamEventScoringStatus {
        FanTeamEventScoringStatus.parse(scoringStatus)
    }

    /// Viewing Team score (home_score from list RPC after scoring migration).
    var teamScoreValue: Int { homeScore ?? 0 }

    /// Opponent score (away_score from list RPC after scoring migration).
    var opponentScoreValue: Int { awayScore ?? 0 }

    var isScoringLive: Bool { scoringLifecycle == .live || status.lowercased() == "live" }

    var isScoringFinal: Bool { scoringLifecycle == .final }

    var isScoreCapable: Bool {
        FanTeamEventScoring.isScoreCapable(gameType: gameType, sport: sport)
    }

    var hasScoringOpponent: Bool {
        FanTeamEventScoring.hasOpponent(opponentName: opponentName, opponentTeamId: opponentTeamId)
    }

    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? sport : trimmed
    }

    /// See ``FanTeamGamesTimeline`` — Pickup lifecycle + start/end, not a Team-only flag.
    var isUpcoming: Bool {
        FanTeamGamesTimeline.isUpcoming(self)
    }

    var isCompleted: Bool {
        isScoringFinal || status == "completed"
    }

    var locationLine: String {
        FanTeamEventLocationPresentation.displayLocation(
            venueName: venueName,
            address: address,
            city: city,
            state: state
        )
    }

    /// Same coordinate gate as Team event-detail Directions (`pickupHasUsableMapCoordinate`).
    var hasUsableDirectionsCoordinate: Bool {
        FanGeoDirectionsActions.hasUsableCoordinate(latitude: latitude, longitude: longitude)
    }

    /// Prefer venue / street for Maps pin title; fall back to cleaned location line / event title.
    var directionsDestinationName: String {
        let venue = venueName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !venue.isEmpty { return venue }
        let line = locationLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty {
            return line.components(separatedBy: " · ").first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? line
        }
        return displayTitle
    }

    func applyingScoring(
        teamScore: Int,
        opponentScore: Int,
        scoringStatus: String,
        scoringFinalizedAt: Date?
    ) -> FanTeamGame {
        var next = self
        next.homeScore = teamScore
        next.awayScore = opponentScore
        next.scoringStatus = FanTeamEventScoringStatus.parse(scoringStatus).rawValue
        next.scoringFinalizedAt = scoringFinalizedAt
        switch FanTeamEventScoringStatus.parse(scoringStatus) {
        case .live:
            next.status = "live"
        case .final:
            next.status = "completed"
        case .scheduled:
            if next.status == "live" { next.status = "scheduled" }
        }
        return next
    }
}

struct FanTeamDetail: Hashable, Sendable {
    var summary: FanTeamSummary
    var members: [FanTeamMember]
    /// Shared with Games tab (`list_fan_team_games`); Overview does not present game cards.
    var games: [FanTeamGame]
    /// Server-derived W-L-T when scoring RPCs are deployed; otherwise client-derived.
    var record: FanTeamRecord = .empty
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
