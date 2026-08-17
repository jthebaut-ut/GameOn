import Foundation
import SwiftUI

/// Leading identity for Action Center cards (testable; no network).
enum FanGeoActionCenterLeadingIdentity: Sendable {
    enum Source: Equatable, Sendable {
        case teamMark
        case personAvatar
        case ratingGlyph
        case kindGlyph
    }

    /// Team-associated schedule / cancellation / invitation rows lead with the
    /// canonical Team mark whenever `teamId` is known. Affected-player photos
    /// stay in the Player body row, not the primary leading slot.
    static func prefersTeamMark(kind: FanGeoActionKind, teamId: UUID?) -> Bool {
        guard teamId != nil else { return false }
        switch kind {
        case .scheduleChange, .eventCancellation, .teamInvitation:
            return true
        default:
            return false
        }
    }

    static func source(for item: FanGeoActionItem) -> Source {
        source(
            kind: item.kind,
            teamId: item.context.teamId,
            personAvatarURL: item.context.personAvatarURL ?? item.context.personAvatarThumbnailURL,
            isPendingRating: item.kind == .pendingPickupRating,
            personName: item.context.personName,
            isManagedPlayer: item.context.isManagedPlayer || item.context.managedPlayerId != nil,
            teamName: item.context.teamName,
            inferredTeamName: FanGeoTeamEventNoticeBuilder.inferredTeamName(for: item),
            usesTeamChrome: FanGeoActionCenterTeamNotificationPresentation.usesTeamChrome(for: item)
        )
    }

    static func source(
        kind: FanGeoActionKind,
        teamId: UUID?,
        personAvatarURL: String?,
        isPendingRating: Bool,
        personName: String? = nil,
        isManagedPlayer: Bool = false,
        teamName: String? = nil,
        inferredTeamName: String? = nil,
        usesTeamChrome: Bool = false
    ) -> Source {
        if isPendingRating {
            return .ratingGlyph
        }
        if prefersTeamMark(kind: kind, teamId: teamId) {
            return .teamMark
        }
        if kind == .securitySession {
            return .kindGlyph
        }
        // Practice / event / cancellation / Team-invitation cards never use the
        // affected-player photo as the primary leading mark — even when `teamId`
        // was dropped, teamName is missing, or account-owner avatar was filled in.
        // Player photos belong only in the Player body row.
        if isTeamEventLeadingKind(kind) || usesTeamChrome {
            return .kindGlyph
        }
        let avatar = personAvatarURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !avatar.isEmpty {
            return .personAvatar
        }
        return .kindGlyph
    }

    /// Schedule / cancellation / Team invitation — never person-primary artwork.
    static func isTeamEventLeadingKind(_ kind: FanGeoActionKind) -> Bool {
        switch kind {
        case .scheduleChange, .eventCancellation, .teamInvitation:
            return true
        default:
            return false
        }
    }
}

/// Visual urgency for Action Center cards (sort priority stays on ``FanGeoActionKind``).
enum FanGeoActionUrgency: String, Sendable, Hashable {
    case highAction
    case importantChange
    case informational
}

/// Actionable items for the FanGeo Action Center (not generic notifications).
enum FanGeoActionKind: String, CaseIterable, Sendable, Hashable {
    case teamInvitation
    case pickupInvitation
    case friendRequest
    case pendingPickupRating
    case joinApproval
    case scheduleChange
    case eventCancellation
    case poke
    case businessClaim
    case securitySession

    /// Sort priority (lower = higher importance).
    var priority: Int {
        switch self {
        case .teamInvitation, .pickupInvitation, .friendRequest: return 1
        case .pendingPickupRating: return 2
        case .joinApproval: return 3
        case .scheduleChange: return 4
        case .eventCancellation: return 5
        case .poke, .businessClaim: return 6
        case .securitySession: return 3
        }
    }

    var urgency: FanGeoActionUrgency {
        switch self {
        case .teamInvitation, .pickupInvitation, .friendRequest, .pendingPickupRating, .joinApproval,
             .businessClaim:
            return .highAction
        case .scheduleChange, .eventCancellation:
            return .importantChange
        case .poke:
            return .informational
        case .securitySession:
            return .importantChange
        }
    }

    var systemImage: String {
        switch self {
        case .teamInvitation: return "envelope.badge.fill"
        case .pickupInvitation: return "figure.run"
        case .friendRequest: return "person.badge.plus"
        case .pendingPickupRating: return "star.fill"
        case .joinApproval: return "person.crop.circle.badge.checkmark"
        case .scheduleChange: return "calendar.badge.exclamationmark"
        case .eventCancellation: return "calendar.badge.minus"
        case .poke: return "hand.wave.fill"
        case .businessClaim: return "building.2.fill"
        case .securitySession: return "lock.shield.fill"
        }
    }

    var primaryCTAKey: String {
        switch self {
        case .teamInvitation:
            return "action_center_cta_review_invite"
        case .pickupInvitation, .friendRequest:
            return "action_center_cta_review_request"
        case .pendingPickupRating:
            return "action_center_cta_rate_now"
        case .joinApproval:
            return "action_center_cta_review"
        case .scheduleChange:
            return "action_center_cta_view_game"
        case .eventCancellation:
            return "action_center_cta_view_event"
        case .poke:
            return "View Profile"
        case .businessClaim:
            return "action_center_cta_review"
        case .securitySession:
            return "security_session_replaced_cta"
        }
    }

    var accentColor: Color {
        switch self {
        case .teamInvitation, .pickupInvitation, .friendRequest, .joinApproval:
            return FGColor.accentBlue
        case .pendingPickupRating:
            return Color(red: 0.52, green: 0.38, blue: 0.95)
        case .scheduleChange:
            return FGColor.accentYellow
        case .eventCancellation:
            return Color.red
        case .poke, .businessClaim:
            return FGColor.accentGreen
        case .securitySession:
            return Color(red: 0.86, green: 0.22, blue: 0.27)
        }
    }

    /// Short category chip label key (Action Center card header).
    var categoryBadgeKey: String {
        switch self {
        case .teamInvitation: return "action_center_badge_team_invite"
        case .pickupInvitation: return "action_center_badge_pickup_invite"
        case .friendRequest: return "action_center_badge_friend_request"
        case .pendingPickupRating: return "action_center_badge_rate_game"
        case .joinApproval: return "action_center_badge_join_request"
        case .scheduleChange: return "action_center_badge_event_updated"
        case .eventCancellation: return "action_center_badge_event_cancelled"
        case .poke: return "action_center_badge_poke"
        case .businessClaim: return "action_center_badge_business_claim"
        case .securitySession: return "security_session_replaced_badge"
        }
    }

    /// Presentation bucket: Action Needed vs Notifications history.
    var listSection: FanGeoActionCenterListSection {
        switch self {
        case .teamInvitation, .pickupInvitation, .friendRequest, .pendingPickupRating, .joinApproval,
             .businessClaim:
            return .actionNeeded
        case .scheduleChange, .eventCancellation, .poke, .securitySession:
            return .notifications
        }
    }

    /// Action Needed rows can be hidden without mutating the source object.
    /// Notification history uses the notification inbox clear path instead.
    var isDismissible: Bool { true }

    /// Action Needed hide policy only. Notifications use ``FanGeoNotificationInboxStore``.
    var dismissalPersistence: FanGeoActionDismissalPersistence {
        switch self {
        case .teamInvitation, .pickupInvitation, .friendRequest, .joinApproval:
            return .sessionSnooze
        case .pendingPickupRating, .businessClaim:
            return .permanent
        case .scheduleChange, .eventCancellation, .poke, .securitySession:
            // Cleared via notification inbox — not `action_center_dismissals`.
            return .notificationInbox
        }
    }
}

/// How an Action Center hide is stored.
enum FanGeoActionDismissalPersistence: String, Sendable, Hashable {
    /// Written to `action_center_dismissals` / UserDefaults for this action_key forever.
    case permanent
    /// Local TTL snooze. Not written to `action_center_dismissals`. Survives process
    /// restart within the TTL so cold launch cannot flash an already-cleared row.
    case sessionSnooze
    /// Notification history clear — ``FanGeoNotificationInboxStore`` only.
    case notificationInbox
}

/// Tabs inside FanGeo Inbox (presentation only). User-facing container title is “FanGeo Inbox”.
enum FanGeoActionCenterListSection: Int, CaseIterable, Sendable, Hashable {
    case actionNeeded
    case notifications

    var titleKey: String {
        switch self {
        case .actionNeeded: return "action_center_tab_action_needed"
        case .notifications: return "action_center_tab_notifications"
        }
    }

    var subtitleKey: String {
        switch self {
        case .actionNeeded: return "action_center_tab_action_needed_subtitle"
        case .notifications: return "action_center_tab_notifications_subtitle"
        }
    }
}

enum FanGeoActionDestination: String, Sendable, Hashable {
    case teamsHome
    case teamsInvites
    case goingPickupInvites
    case goingHostingApprovals
    case goingPendingRating
    case chatFriendRequests
    case chatUnread
    case scheduleActivity
    case accountPokes
    case accountBusinessClaim
    case accountSecurity
}

/// One old → new (or label-only) change row on a schedule card.
struct FanGeoActionChangeDetail: Hashable, Sendable {
    var labelKey: String
    var oldValue: String?
    var newValue: String?
}

/// Contextual payload for rich Action Center cards (IDs + display fields).
struct FanGeoActionContext: Hashable, Sendable {
    var personName: String? = nil
    var personUsername: String? = nil
    var personAvatarURL: String? = nil
    var teamName: String? = nil
    var eventTitle: String? = nil
    var eventTypeLabel: String? = nil
    var locationLabel: String? = nil
    var eventStartAt: Date? = nil
    var relativeTimestamp: Date? = nil
    var changeDetails: [FanGeoActionChangeDetail] = []
    var moreChangesCount: Int = 0
    var pickupGameId: UUID? = nil
    var teamId: UUID? = nil
    var invitationId: UUID? = nil
    var friendshipId: UUID? = nil
    var requesterUserId: UUID? = nil
    var pokeId: UUID? = nil
    var sportLabel: String? = nil
    /// Competitive Team Schedule matchup (e.g. "JT vs Legends United").
    var matchupLabel: String? = nil
    /// Durable opponent snapshot for Team event cards (not inferred from title).
    var opponentName: String? = nil
    /// Server `notification_type` (e.g. `team_event_time_changed`). Display-only.
    var notificationType: String? = nil
    /// Team role token for membership notifications (`manager`, `member`, …).
    var roleToken: String? = nil
    /// Preferred roster line (e.g. "5 / 6 players", "6 / 6 Full").
    var capacityLabel: String? = nil
    /// Affected managed player when the payload names one. Presentation only.
    var managedPlayerId: UUID? = nil
    /// True when the payload marks the affected seat as a managed player.
    var isManagedPlayer: Bool = false
    /// Thumbnail URL for the affected player / account avatar.
    var personAvatarThumbnailURL: String? = nil
    /// Professional-game live-match id for Inbox deep links.
    var proGameMatchId: String? = nil
    /// Durable score snapshot. Historical rows render this, never current live state.
    var proGameSnapshot: FanGeoProGameInboxSnapshot? = nil
    /// Team score notification scoreline snapshot (`Sandy Strikers 3 – 2 Riverton FC`).
    var scoreLine: String? = nil
    /// Normalized scorer kind from the server (`goal`, `run`, `score`, `touchdown_or_score`).
    var scorerAttributionKind: String? = nil
}

struct FanGeoActionItem: Identifiable, Hashable, Sendable {
    let id: String
    let kind: FanGeoActionKind
    let titleKey: String
    let titleFormatArgs: [String]
    let subtitleKey: String
    let subtitleFormatArgs: [String]
    let destination: FanGeoActionDestination
    let timestamp: Date?
    let count: Int
    let context: FanGeoActionContext
    let ctaKeyOverride: String?

    init(
        id: String,
        kind: FanGeoActionKind,
        titleKey: String,
        titleFormatArgs: [String] = [],
        subtitleKey: String,
        subtitleFormatArgs: [String] = [],
        destination: FanGeoActionDestination,
        timestamp: Date? = nil,
        count: Int = 1,
        context: FanGeoActionContext = FanGeoActionContext(),
        ctaKeyOverride: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.titleKey = titleKey
        self.titleFormatArgs = titleFormatArgs
        self.subtitleKey = subtitleKey
        self.subtitleFormatArgs = subtitleFormatArgs
        self.destination = destination
        self.timestamp = timestamp
        self.count = max(1, count)
        self.context = context
        self.ctaKeyOverride = ctaKeyOverride
    }

    func withContext(_ context: FanGeoActionContext) -> FanGeoActionItem {
        FanGeoActionItem(
            id: id,
            kind: kind,
            titleKey: titleKey,
            titleFormatArgs: titleFormatArgs,
            subtitleKey: subtitleKey,
            subtitleFormatArgs: subtitleFormatArgs,
            destination: destination,
            timestamp: timestamp,
            count: count,
            context: context,
            ctaKeyOverride: ctaKeyOverride
        )
    }

    var ctaKey: String {
        FanGeoActionCenterTeamNotificationPresentation.ctaKey(for: self)
            ?? ctaKeyOverride
            ?? kind.primaryCTAKey
    }

    func title(languageCode: String) -> String {
        if FanGeoSecuritySessionReplacement.isSecurityItem(self) {
            return FanGeoSecuritySessionNotificationPresentation.title(languageCode: languageCode)
        }
        if let resolved = FanGeoActionCenterTeamNotificationPresentation.title(
            for: self,
            languageCode: languageCode
        ) {
            return resolved
        }
        return Self.formatted(key: titleKey, args: titleFormatArgs, languageCode: languageCode)
    }

    func subtitle(languageCode: String) -> String {
        if FanGeoSecuritySessionReplacement.isSecurityItem(self) {
            return FanGeoSecuritySessionNotificationPresentation.body(languageCode: languageCode)
        }
        return Self.formatted(key: subtitleKey, args: subtitleFormatArgs, languageCode: languageCode)
    }

    func accessibilitySummary(languageCode: String) -> String {
        var parts: [String] = []
        if FanGeoProGameInboxPresentation.isProGame(self),
           let snapshot = context.proGameSnapshot {
            parts.append(
                FanGeoActionCenterTeamNotificationPresentation.headerBadgeText(
                    for: self,
                    languageCode: languageCode
                )
            )
            parts.append(
                FanGeoProGameInboxPresentation.accessibilitySummary(
                    for: snapshot,
                    languageCode: languageCode
                )
            )
            parts.append(L10n.t(ctaKey, languageCode: languageCode))
            return parts.filter { !$0.isEmpty }.joined(separator: ". ")
        }
        if FanGeoActionCenterTeamNotificationPresentation.usesTeamChrome(for: self) {
            parts.append(
                FanGeoActionCenterTeamNotificationPresentation.headerBadgeText(
                    for: self,
                    languageCode: languageCode
                )
            )
        }
        if let notice = FanGeoTeamEventNoticeBuilder.make(for: self, languageCode: languageCode) {
            parts.append(notice.accessibilityLabel(languageCode: languageCode))
        } else {
            parts.append(title(languageCode: languageCode))
            parts.append(contentsOf: contextLines(languageCode: languageCode))
        }
        parts.append(L10n.t(ctaKey, languageCode: languageCode))
        return parts.filter { !$0.isEmpty }.joined(separator: ". ")
    }

    /// Secondary / detail lines shown under the title (already localized).
    func contextLines(languageCode: String) -> [String] {
        FanGeoActionCenterCopy.contextLines(for: self, languageCode: languageCode)
    }

    private static func formatted(key: String, args: [String], languageCode: String) -> String {
        let template = L10n.t(key, languageCode: languageCode)
        guard !args.isEmpty else { return template }
        let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        switch args.count {
        case 1:
            return String(format: template, locale: locale, args[0])
        case 2:
            return String(format: template, locale: locale, args[0], args[1])
        default:
            return String(format: template, locale: locale, args[0], args[1], args[2])
        }
    }
}

// MARK: - Projection inputs (cache-backed, no N+1)

struct FanGeoActionTeamInviteInput: Equatable, Sendable {
    var invitationId: UUID
    var teamId: UUID
    var teamName: String
    var sport: String
    var inviterDisplayName: String
    var createdAt: Date?
}

struct FanGeoActionPickupInviteInput: Equatable, Sendable {
    var inviteId: UUID
    var pickupGameId: UUID
    var gameTitle: String
    var teamName: String?
    var eventTypeLabel: String?
    var startAt: Date?
    var locationLabel: String?
    var inviterName: String?
}

struct FanGeoActionFriendRequestInput: Equatable, Sendable {
    var friendshipId: UUID
    var requesterUserId: UUID
    var displayName: String
    var username: String?
    var avatarURL: String?
    var createdAt: Date?
}

struct FanGeoActionJoinApprovalInput: Equatable, Sendable, Identifiable {
    var id: UUID { requestId }
    var requestId: UUID
    var pickupGameId: UUID
    var requesterUserId: UUID
    var requesterName: String
    var requesterAvatarURL: String? = nil
    var gameTitle: String
    var teamName: String?
    var teamId: UUID?
    var eventTypeLabel: String?
    var startAt: Date?
    var locationLabel: String?
    var matchupLabel: String? = nil
    var capacityLabel: String? = nil
    var isAtCapacity: Bool = false
}

struct FanGeoActionScheduleActivityInput: Equatable, Sendable, Identifiable {
    var id: UUID { pickupGameId }
    var pickupGameId: UUID
    var title: String
    var teamName: String?
    var teamId: UUID? = nil
    var eventTypeLabel: String?
    var startAt: Date?
    var locationLabel: String?
    var isCancellation: Bool
    var changeDetails: [FanGeoActionChangeDetail]
    var moreChangesCount: Int
    /// Fingerprint of this update instance (signature hash). Empty → `"current"`.
    var activityInstanceKey: String = ""
}

struct FanGeoActionPokeInput: Equatable, Sendable {
    var pokeId: UUID
    var pokerUserId: UUID
    var displayName: String
    var username: String?
    var avatarURL: String?
    var createdAt: Date?
}

/// Completed pickup waiting for the viewer’s organizer rating (cache-backed).
struct FanGeoActionPendingRatingInput: Equatable, Sendable, Identifiable {
    var id: UUID { pickupGameId }
    var pickupGameId: UUID
    var organizerUserId: UUID
    var organizerName: String
    var organizerAvatarURL: String?
    var gameTitle: String
    var teamName: String?
    var eventTypeLabel: String?
    var matchupLabel: String?
    var startAt: Date?
}

/// Pure badge / Action Center projection from already-published app state.
enum FanGeoActionCenterProjection {
    struct Snapshot: Equatable {
        /// Combined Action Needed + Notifications (tests / legacy callers).
        var items: [FanGeoActionItem]
        var actionNeededItems: [FanGeoActionItem]
        var notificationItems: [FanGeoActionItem]
        /// Live notification candidates freshly projected (for inbox upsert).
        var liveNotificationCandidates: [FanGeoActionItem]
        var unreadNotificationIds: Set<String>
        var scheduleBadgeCount: Int
        /// Unused for the Going tab. The tab badge is ``GoingActionCenter/summary(from:languageCode:now:calendar:)``.
        var goingBadgeCount: Int
        var teamsBadgeCount: Int
        var chatUnreadCount: Int
        /// Outstanding Action Needed (includes session-snoozed pending work).
        var actionNeededBadgeCount: Int
        /// Unread notification history rows.
        var unreadNotificationCount: Int
        /// Bell badge = Action Needed + unread Notifications.
        var actionCenterBadgeCount: Int

        static let empty = Snapshot(
            items: [],
            actionNeededItems: [],
            notificationItems: [],
            liveNotificationCandidates: [],
            unreadNotificationIds: [],
            scheduleBadgeCount: 0,
            goingBadgeCount: 0,
            teamsBadgeCount: 0,
            chatUnreadCount: 0,
            actionNeededBadgeCount: 0,
            unreadNotificationCount: 0,
            actionCenterBadgeCount: 0
        )
    }

    struct Inputs: Equatable {
        var teamInvitations: [FanGeoActionTeamInviteInput] = []
        /// Fallback when invitation rows are not yet cached.
        var teamInvitationCount: Int = 0
        var pickupInvites: [FanGeoActionPickupInviteInput] = []
        var friendRequests: [FanGeoActionFriendRequestInput] = []
        /// Fallback when friend rows are not yet cached.
        var friendRequestCount: Int = 0
        var joinApprovals: [FanGeoActionJoinApprovalInput] = []
        /// Fallback when per-request summaries are not yet cached.
        var pendingJoinApprovalCount: Int = 0
        var pendingRatings: [FanGeoActionPendingRatingInput] = []
        var scheduleActivities: [FanGeoActionScheduleActivityInput] = []
        /// Fallback unread activity count when per-game summaries are unavailable.
        var scheduleActivityCount: Int = 0
        var hasUnreadScheduleActivity: Bool = false
        var pokes: [FanGeoActionPokeInput] = []
        var unseenPokesCount: Int = 0
        var hasUnseenPokes: Bool = false
        var showsBusinessClaim: Bool = false
        var chatUnreadCount: Int = 0
        var isSignedInForSocial: Bool = false
        /// Permanent Action Needed hides (`action_center_dismissals` / UserDefaults).
        var dismissedActionKeys: Set<String> = []
        /// Pending-request snoozes (local UserDefaults + in-memory, TTL).
        var sessionSnoozedPendingKeys: Set<String> = []
        /// Durable Clear All hides for specific Action Needed ids (not server dismissals).
        var clearAllHiddenActionKeys: Set<String> = []
        /// Last seen detailed pending ids — used only to suppress stale count-fallback aggregates.
        var lastKnownPendingActionKeys: Set<String> = []
        /// Persisted notification inbox (already filtered of cleared ids).
        var persistedNotifications: [FanGeoActionItem] = []
        /// Unread notification ids from the inbox store.
        var unreadNotificationIds: Set<String> = []
        /// Cleared notification keys — live candidates must not reappear until a new id.
        var clearedNotificationKeys: Set<String> = []
    }

    static func snapshot(from inputs: Inputs) -> Snapshot {
        var items: [FanGeoActionItem] = []
        let languageCode = L10n.normalizedLanguageCode(
            UserDefaults.standard.string(forKey: L10n.appLanguageKey)
        )

        if inputs.isSignedInForSocial, !inputs.teamInvitations.isEmpty {
            for invite in inputs.teamInvitations {
                let team = invite.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
                let inviter = invite.inviterDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
                items.append(
                    FanGeoActionItem(
                        id: FanGeoActionCenterActionKey.teamInvite(invite.invitationId),
                        kind: .teamInvitation,
                        titleKey: "action_center_invited_to_team_format",
                        titleFormatArgs: [team.isEmpty ? L10n.t("teams") : team],
                        subtitleKey: inviter.isEmpty
                            ? "action_center_team_invite_subtitle"
                            : "action_center_invited_by_format",
                        subtitleFormatArgs: inviter.isEmpty ? [] : [inviter],
                        destination: .teamsInvites,
                        timestamp: invite.createdAt,
                        count: 1,
                        context: FanGeoActionContext(
                            personName: inviter.isEmpty ? nil : inviter,
                            teamName: team.isEmpty ? nil : team,
                            teamId: invite.teamId,
                            invitationId: invite.invitationId,
                            sportLabel: invite.sport.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                        )
                    )
                )
            }
        } else if inputs.isSignedInForSocial, inputs.teamInvitationCount > 0 {
            items.append(
                FanGeoActionItem(
                    id: FanGeoActionCenterActionKey.teamInvitesAggregate,
                    kind: .teamInvitation,
                    titleKey: inputs.teamInvitationCount == 1
                        ? "action_center_team_invite_title_one"
                        : "action_center_team_invite_title_many",
                    titleFormatArgs: inputs.teamInvitationCount == 1
                        ? []
                        : ["\(inputs.teamInvitationCount)"],
                    subtitleKey: "action_center_team_invite_subtitle",
                    destination: .teamsInvites,
                    count: inputs.teamInvitationCount
                )
            )
        }

        for invite in inputs.pickupInvites {
            let title = invite.gameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let display = title.isEmpty ? L10n.t("Pickup") : title
            items.append(
                FanGeoActionItem(
                    id: FanGeoActionCenterActionKey.pickupInvite(invite.inviteId),
                    kind: .pickupInvitation,
                    titleKey: "action_center_pickup_invite_title",
                    titleFormatArgs: [display],
                    subtitleKey: "action_center_pickup_invite_subtitle",
                    destination: .goingPickupInvites,
                    timestamp: invite.startAt,
                    count: 1,
                    context: FanGeoActionContext(
                        personName: invite.inviterName,
                        teamName: invite.teamName,
                        eventTitle: display,
                        eventTypeLabel: invite.eventTypeLabel,
                        locationLabel: invite.locationLabel,
                        eventStartAt: invite.startAt,
                        pickupGameId: invite.pickupGameId,
                        invitationId: invite.inviteId
                    )
                )
            )
        }

        if !inputs.friendRequests.isEmpty {
            for request in inputs.friendRequests {
                let name = request.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                let display = name.isEmpty ? L10n.t("Fan") : name
                items.append(
                    FanGeoActionItem(
                        id: FanGeoActionCenterActionKey.friendRequest(request.friendshipId),
                        kind: .friendRequest,
                        titleKey: "action_center_friend_request_from_format",
                        titleFormatArgs: [display],
                        subtitleKey: "action_center_friend_request_subtitle",
                        destination: .chatFriendRequests,
                        timestamp: request.createdAt,
                        count: 1,
                        context: FanGeoActionContext(
                            personName: display,
                            personUsername: request.username,
                            personAvatarURL: request.avatarURL,
                            friendshipId: request.friendshipId,
                            requesterUserId: request.requesterUserId
                        )
                    )
                )
            }
        } else if inputs.friendRequestCount > 0 {
            items.append(
                FanGeoActionItem(
                    id: FanGeoActionCenterActionKey.friendRequestsAggregate,
                    kind: .friendRequest,
                    titleKey: inputs.friendRequestCount == 1
                        ? "action_center_friend_request_title_one"
                        : "action_center_friend_request_title_many",
                    titleFormatArgs: inputs.friendRequestCount == 1
                        ? []
                        : ["\(inputs.friendRequestCount)"],
                    subtitleKey: "action_center_friend_request_subtitle",
                    destination: .chatFriendRequests,
                    count: inputs.friendRequestCount
                )
            )
        }

        if !inputs.joinApprovals.isEmpty {
            for approval in inputs.joinApprovals {
                let person = approval.requesterName.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayPerson = person.isEmpty ? L10n.t("Fan") : person
                let game = approval.gameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                items.append(
                    FanGeoActionItem(
                        id: FanGeoActionCenterActionKey.joinApproval(approval.requestId),
                        kind: .joinApproval,
                        titleKey: "action_center_wants_to_join_format",
                        titleFormatArgs: [displayPerson],
                        subtitleKey: "action_center_join_approval_subtitle",
                        destination: .goingHostingApprovals,
                        timestamp: approval.startAt,
                        count: 1,
                        context: FanGeoActionContext(
                            personName: displayPerson,
                            personAvatarURL: approval.requesterAvatarURL,
                            teamName: approval.teamName,
                            eventTitle: FanGeoJoinRequestEventIdentity.primaryTitle(
                                gameTitle: game,
                                eventTypeLabel: approval.eventTypeLabel,
                                matchupLabel: approval.matchupLabel,
                                languageCode: languageCode
                            ),
                            eventTypeLabel: approval.eventTypeLabel,
                            locationLabel: approval.locationLabel,
                            eventStartAt: approval.startAt,
                            pickupGameId: approval.pickupGameId,
                            teamId: approval.teamId,
                            requesterUserId: approval.requesterUserId,
                            matchupLabel: approval.matchupLabel,
                            capacityLabel: approval.capacityLabel
                        ),
                        ctaKeyOverride: "action_center_cta_review"
                    )
                )
            }
        } else if inputs.pendingJoinApprovalCount > 0 {
            items.append(
                FanGeoActionItem(
                    id: FanGeoActionCenterActionKey.joinApprovalsAggregate,
                    kind: .joinApproval,
                    titleKey: inputs.pendingJoinApprovalCount == 1
                        ? "action_center_join_approval_title_one"
                        : "action_center_join_approval_title_many",
                    titleFormatArgs: inputs.pendingJoinApprovalCount == 1
                        ? []
                        : ["\(inputs.pendingJoinApprovalCount)"],
                    subtitleKey: "action_center_join_approval_subtitle",
                    destination: .goingHostingApprovals,
                    count: inputs.pendingJoinApprovalCount
                )
            )
        }

        for rating in inputs.pendingRatings {
            let organizer = rating.organizerName.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayOrganizer = organizer.isEmpty ? L10n.t("Fan") : organizer
            let game = rating.gameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = game.isEmpty ? L10n.t("Pickup") : game
            let hasMatchup = !(rating.matchupLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            items.append(
                FanGeoActionItem(
                    id: FanGeoActionCenterActionKey.rateGame(rating.pickupGameId),
                    kind: .pendingPickupRating,
                    titleKey: hasMatchup
                        ? "action_center_rate_organizer_title"
                        : "action_center_rate_pickup_title",
                    subtitleKey: "pickup_rating_prompt_subtitle_format",
                    subtitleFormatArgs: [displayOrganizer],
                    destination: .goingPendingRating,
                    timestamp: rating.startAt,
                    count: 1,
                    context: FanGeoActionContext(
                        personName: displayOrganizer,
                        personAvatarURL: rating.organizerAvatarURL,
                        teamName: rating.teamName,
                        eventTitle: displayTitle,
                        eventTypeLabel: rating.eventTypeLabel,
                        eventStartAt: rating.startAt,
                        pickupGameId: rating.pickupGameId,
                        requesterUserId: rating.organizerUserId,
                        matchupLabel: rating.matchupLabel
                    ),
                    ctaKeyOverride: "action_center_cta_rate_now"
                )
            )
        }

        let scheduleActivityFallbackCount = inputs.hasUnreadScheduleActivity
            ? max(0, inputs.scheduleActivityCount)
            : 0
        if !inputs.scheduleActivities.isEmpty {
            for activity in inputs.scheduleActivities {
                let title = activity.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let baseTitle = title.isEmpty ? L10n.t("Pickup") : title
                let displayTitle: String = {
                    guard let team = activity.teamName?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !team.isEmpty else { return baseTitle }
                    if baseTitle.localizedCaseInsensitiveContains(team) { return baseTitle }
                    return "\(team) \(baseTitle)"
                }()
                if activity.isCancellation {
                    items.append(
                        FanGeoActionItem(
                            id: FanGeoActionCenterActionKey.pickupCancel(
                                gameId: activity.pickupGameId,
                                instanceKey: activity.activityInstanceKey
                            ),
                            kind: .eventCancellation,
                            titleKey: "action_center_event_cancelled_format",
                            titleFormatArgs: [displayTitle],
                            subtitleKey: "action_center_schedule_change_subtitle",
                            destination: .scheduleActivity,
                            timestamp: activity.startAt,
                            count: 1,
                            context: FanGeoActionContext(
                                teamName: activity.teamName,
                                eventTitle: displayTitle,
                                eventTypeLabel: activity.eventTypeLabel,
                                locationLabel: activity.locationLabel,
                                eventStartAt: activity.startAt,
                                pickupGameId: activity.pickupGameId,
                                teamId: activity.teamId
                            )
                        )
                    )
                } else {
                    items.append(
                        FanGeoActionItem(
                            id: FanGeoActionCenterActionKey.pickupUpdate(
                                gameId: activity.pickupGameId,
                                instanceKey: activity.activityInstanceKey
                            ),
                            kind: .scheduleChange,
                            titleKey: "action_center_event_changed_format",
                            titleFormatArgs: [displayTitle],
                            subtitleKey: "action_center_schedule_change_subtitle",
                            destination: .scheduleActivity,
                            timestamp: activity.startAt,
                            count: 1,
                            context: FanGeoActionContext(
                                teamName: activity.teamName,
                                eventTitle: displayTitle,
                                eventTypeLabel: activity.eventTypeLabel,
                                locationLabel: activity.locationLabel,
                                eventStartAt: activity.startAt,
                                changeDetails: activity.changeDetails,
                                moreChangesCount: activity.moreChangesCount,
                                pickupGameId: activity.pickupGameId,
                                teamId: activity.teamId
                            )
                        )
                    )
                }
            }
        } else if scheduleActivityFallbackCount > 0 {
            items.append(
                FanGeoActionItem(
                    id: FanGeoActionCenterActionKey.scheduleActivityAggregate,
                    kind: .scheduleChange,
                    titleKey: scheduleActivityFallbackCount == 1
                        ? "action_center_schedule_change_title_one"
                        : "action_center_schedule_change_title_many",
                    titleFormatArgs: scheduleActivityFallbackCount == 1
                        ? []
                        : ["\(scheduleActivityFallbackCount)"],
                    subtitleKey: "action_center_schedule_change_subtitle",
                    destination: .scheduleActivity,
                    count: scheduleActivityFallbackCount
                )
            )
        }

        if inputs.hasUnseenPokes {
            if !inputs.pokes.isEmpty {
                for poke in inputs.pokes {
                    let name = poke.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let display = name.isEmpty ? L10n.t("Fan") : name
                    items.append(
                        FanGeoActionItem(
                            id: FanGeoActionCenterActionKey.poke(poke.pokeId),
                            kind: .poke,
                            titleKey: "action_center_poke_from_format",
                            titleFormatArgs: [display],
                            subtitleKey: "action_center_poke_subtitle",
                            destination: .accountPokes,
                            timestamp: poke.createdAt,
                            count: 1,
                            context: FanGeoActionContext(
                                personName: display,
                                personUsername: poke.username,
                                personAvatarURL: poke.avatarURL,
                                relativeTimestamp: poke.createdAt,
                                requesterUserId: poke.pokerUserId,
                                pokeId: poke.pokeId
                            )
                        )
                    )
                }
            } else if inputs.unseenPokesCount > 0 {
                items.append(
                    FanGeoActionItem(
                        id: FanGeoActionCenterActionKey.pokesAggregate,
                        kind: .poke,
                        titleKey: inputs.unseenPokesCount == 1
                            ? "action_center_poke_title_one"
                            : "action_center_poke_title_many",
                        titleFormatArgs: inputs.unseenPokesCount == 1
                            ? []
                            : ["\(inputs.unseenPokesCount)"],
                        subtitleKey: "action_center_poke_subtitle",
                        destination: .accountPokes,
                        count: inputs.unseenPokesCount
                    )
                )
            }
        }

        if inputs.showsBusinessClaim {
            items.append(
                FanGeoActionItem(
                    id: FanGeoActionCenterActionKey.businessClaim,
                    kind: .businessClaim,
                    titleKey: "action_center_business_claim_title",
                    subtitleKey: "action_center_business_claim_subtitle",
                    destination: .accountBusinessClaim,
                    count: 1
                )
            )
        }

        items.sort {
            if $0.kind.priority != $1.kind.priority {
                return $0.kind.priority < $1.kind.priority
            }
            let lhsTime = $0.timestamp?.timeIntervalSince1970 ?? 0
            let rhsTime = $1.timestamp?.timeIntervalSince1970 ?? 0
            if lhsTime != rhsTime {
                return lhsTime > rhsTime
            }
            return $0.id < $1.id
        }

        let liveNotifications = items.filter {
            $0.kind.listSection == .notifications
                && !inputs.clearedNotificationKeys.contains($0.id)
        }
        var actionItems = items.filter { $0.kind.listSection == .actionNeeded }

        let dismissed = inputs.dismissedActionKeys
        if !dismissed.isEmpty {
            actionItems.removeAll {
                $0.kind.dismissalPersistence == .permanent && dismissed.contains($0.id)
            }
        }

        let teamsBadge = inputs.isSignedInForSocial
            ? (inputs.teamInvitations.isEmpty
                ? max(0, inputs.teamInvitationCount)
                : inputs.teamInvitations.count)
            : 0
        let chatUnread = inputs.isSignedInForSocial ? max(0, inputs.chatUnreadCount) : 0

        let snoozed = inputs.sessionSnoozedPendingKeys
        if !snoozed.isEmpty {
            actionItems.removeAll {
                $0.kind.dismissalPersistence == .sessionSnooze
                    && FanGeoActionCenterActionKey.isHiddenByPendingSnooze($0.id, snoozed: snoozed)
            }
        }
        let clearAllHidden = inputs.clearAllHiddenActionKeys
        if !clearAllHidden.isEmpty || !inputs.lastKnownPendingActionKeys.isEmpty {
            actionItems.removeAll {
                FanGeoActionCenterLocalVisibility.isHiddenByClearAll(
                    $0.id,
                    hidden: clearAllHidden,
                    lastKnownPendingKeys: inputs.lastKnownPendingActionKeys
                )
            }
        }
        // Visible Action Needed only. Snoozed/Clear All hidden items do not badge.
        let actionNeededBadge = actionItems.reduce(0) { $0 + $1.count }

        // Notification history: persisted inbox wins; live candidates upsert into the store upstream.
        var notificationById: [String: FanGeoActionItem] = [:]
        for item in inputs.persistedNotifications where item.kind.listSection == .notifications {
            notificationById[item.id] = item
        }
        for item in liveNotifications {
            if notificationById[item.id] == nil {
                notificationById[item.id] = item
            }
        }
        let notificationItems = notificationById.values.sorted {
            let lhsTime = $0.timestamp?.timeIntervalSince1970 ?? 0
            let rhsTime = $1.timestamp?.timeIntervalSince1970 ?? 0
            if lhsTime != rhsTime { return lhsTime > rhsTime }
            return $0.id < $1.id
        }
        let unreadIds = inputs.unreadNotificationIds.union(
            Set(liveNotifications.map(\.id)).subtracting(Set(inputs.persistedNotifications.map(\.id)))
        ).intersection(Set(notificationItems.map(\.id)))
        let unreadNotificationCount = notificationItems.reduce(0) { partial, item in
            partial + (unreadIds.contains(item.id) ? item.count : 0)
        }

        let combined = actionItems + notificationItems
        return Snapshot(
            items: combined,
            actionNeededItems: actionItems,
            notificationItems: notificationItems,
            liveNotificationCandidates: liveNotifications,
            unreadNotificationIds: unreadIds,
            // Schedule tab badge is reserved for Schedule-specific actions (none today).
            // Going tab badge is ``GoingActionCenter`` only — never this snapshot.
            scheduleBadgeCount: 0,
            goingBadgeCount: 0,
            teamsBadgeCount: teamsBadge,
            chatUnreadCount: chatUnread,
            actionNeededBadgeCount: actionNeededBadge,
            unreadNotificationCount: unreadNotificationCount,
            actionCenterBadgeCount: actionNeededBadge + unreadNotificationCount
        )
    }

    static func badgeLabel(_ count: Int) -> String {
        count > 99 ? "99+" : "\(max(0, count))"
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
