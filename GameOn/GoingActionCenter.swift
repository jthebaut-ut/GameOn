import Foundation

/// Extensible Going-tab action kinds. UI must not switch on copy or badge math.
enum GoingActionKind: Hashable, Sendable {
    case requiresRSVP
    case scheduleChanged
    case locationChanged
    case cancelled
    case startsSoon
    case newInvitation
    case confirmationNeeded
    case newAnnouncement
    case pendingRating
    case custom(String)

    /// Sort priority (lower = higher importance).
    var priority: Int {
        switch self {
        case .cancelled: return 0
        case .newInvitation, .requiresRSVP: return 1
        case .confirmationNeeded: return 2
        case .scheduleChanged, .locationChanged: return 3
        case .pendingRating: return 4
        case .startsSoon: return 5
        case .newAnnouncement: return 6
        case .custom: return 7
        }
    }
}

/// Screen family for an Action Needed row. IDs live on ``GoingActionItem``.
enum GoingActionDestination: Hashable, Sendable {
    case pickupInvites
    case hostingApprovals
    case pendingRating
    case pickupDetail
    case watching
    case playing
    case teamsEvent
}

/// One actionable Going row. Title keys are resolved at display time.
struct GoingActionItem: Identifiable, Hashable, Sendable {
    let id: String
    let kind: GoingActionKind
    let titleKey: String
    let titleFormatArgs: [String]
    let destination: GoingActionDestination
    let timestamp: Date?
    let pickupGameId: UUID?
    let venueEventId: UUID?
    let teamId: UUID?

    init(
        id: String,
        kind: GoingActionKind,
        titleKey: String,
        titleFormatArgs: [String] = [],
        destination: GoingActionDestination,
        timestamp: Date? = nil,
        pickupGameId: UUID? = nil,
        venueEventId: UUID? = nil,
        teamId: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.titleKey = titleKey
        self.titleFormatArgs = titleFormatArgs
        self.destination = destination
        self.timestamp = timestamp
        self.pickupGameId = pickupGameId
        self.venueEventId = venueEventId
        self.teamId = teamId
    }

    func title(languageCode: String) -> String {
        Self.formatted(key: titleKey, args: titleFormatArgs, languageCode: languageCode)
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

/// Badge count and Action Needed rows — always the same list.
struct GoingActionSummary: Equatable, Sendable {
    var items: [GoingActionItem]

    var count: Int { items.count }
    var badgeCount: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    static let empty = GoingActionSummary(items: [])
}

struct GoingActionRSVPInput: Equatable, Sendable, Identifiable {
    var id: UUID
    var title: String
    var startAt: Date?
    var pickupGameId: UUID?
    var teamId: UUID?
    var destination: GoingActionDestination
}

struct GoingActionAnnouncementInput: Equatable, Sendable, Identifiable {
    var id: UUID
    var title: String
    var timestamp: Date?
    var teamId: UUID?
    var pickupGameId: UUID?
}

struct GoingActionStartsSoonInput: Equatable, Sendable, Identifiable {
    enum Surface: Hashable, Sendable {
        case pickup
        case watch
    }

    var id: UUID
    var title: String
    var startAt: Date
    var surface: Surface
}

/// Pure Going Action Needed projection (tests / legacy). Going UI no longer shows this list;
/// FanGeo Inbox is the single Action Needed surface. Going-tab badge is Going content only.
enum GoingActionCenter {
    static let startsSoonWindow: TimeInterval = 3600

    struct Inputs: Equatable {
        var pickupInvites: [FanGeoActionPickupInviteInput] = []
        var joinApprovals: [FanGeoActionJoinApprovalInput] = []
        var pendingJoinApprovalCount: Int = 0
        var pendingRatings: [FanGeoActionPendingRatingInput] = []
        var scheduleActivities: [FanGeoActionScheduleActivityInput] = []
        var rsvpItems: [GoingActionRSVPInput] = []
        var announcements: [GoingActionAnnouncementInput] = []
        var startsSoon: [GoingActionStartsSoonInput] = []
        var customItems: [GoingActionItem] = []
        var isSignedIn: Bool = false
    }

    static func summary(
        from inputs: Inputs,
        languageCode: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> GoingActionSummary {
        guard inputs.isSignedIn else { return .empty }

        var items: [GoingActionItem] = []
        var claimedPickupIds: Set<UUID> = []
        var claimedVenueIds: Set<UUID> = []

        func claimPickup(_ id: UUID?) {
            if let id { claimedPickupIds.insert(id) }
        }

        for invite in inputs.pickupInvites {
            let title = displayTitle(invite.gameTitle, languageCode: languageCode)
            let isTomorrow = invite.startAt.map { calendar.isDateInTomorrow($0) } ?? false
            let kind: GoingActionKind = isTomorrow ? .requiresRSVP : .newInvitation
            let titleKey = isTomorrow
                ? "going_action_needed_rsvp_tomorrow_format"
                : "going_action_needed_invite_format"
            items.append(
                GoingActionItem(
                    id: "going_invite:\(invite.inviteId.uuidString.lowercased())",
                    kind: kind,
                    titleKey: titleKey,
                    titleFormatArgs: [title],
                    destination: .pickupInvites,
                    timestamp: invite.startAt,
                    pickupGameId: invite.pickupGameId
                )
            )
            claimPickup(invite.pickupGameId)
        }

        if !inputs.joinApprovals.isEmpty {
            for approval in inputs.joinApprovals {
                let person = approval.requesterName.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayPerson = person.isEmpty ? L10n.t("Fan", languageCode: languageCode) : person
                let game = displayTitle(approval.gameTitle, languageCode: languageCode)
                items.append(
                    GoingActionItem(
                        id: "going_join:\(approval.requestId.uuidString.lowercased())",
                        kind: .confirmationNeeded,
                        titleKey: "going_action_needed_join_format",
                        titleFormatArgs: [displayPerson, game],
                        destination: .hostingApprovals,
                        timestamp: approval.startAt,
                        pickupGameId: approval.pickupGameId,
                        teamId: approval.teamId
                    )
                )
                claimPickup(approval.pickupGameId)
            }
        } else if inputs.pendingJoinApprovalCount > 0 {
            items.append(
                GoingActionItem(
                    id: "going_join:aggregate",
                    kind: .confirmationNeeded,
                    titleKey: "going_action_needed_confirmation_needed",
                    destination: .hostingApprovals
                )
            )
        }

        for rsvp in inputs.rsvpItems {
            if let pickupId = rsvp.pickupGameId, claimedPickupIds.contains(pickupId) {
                continue
            }
            let title = displayTitle(rsvp.title, languageCode: languageCode)
            let isTomorrow = rsvp.startAt.map { calendar.isDateInTomorrow($0) } ?? false
            items.append(
                GoingActionItem(
                    id: "going_rsvp:\(rsvp.id.uuidString.lowercased())",
                    kind: .requiresRSVP,
                    titleKey: isTomorrow
                        ? "going_action_needed_rsvp_tomorrow_format"
                        : "going_action_needed_rsvp_format",
                    titleFormatArgs: [title],
                    destination: rsvp.destination,
                    timestamp: rsvp.startAt,
                    pickupGameId: rsvp.pickupGameId,
                    teamId: rsvp.teamId
                )
            )
            claimPickup(rsvp.pickupGameId)
        }

        for activity in inputs.scheduleActivities {
            let title = displayTitle(activity.title, languageCode: languageCode)
            let classified = classifyScheduleActivity(activity)
            items.append(
                GoingActionItem(
                    id: "going_schedule:\(activity.pickupGameId.uuidString.lowercased())",
                    kind: classified.kind,
                    titleKey: classified.titleKey,
                    titleFormatArgs: [title],
                    destination: .pickupDetail,
                    timestamp: activity.startAt,
                    pickupGameId: activity.pickupGameId
                )
            )
            claimPickup(activity.pickupGameId)
        }

        for rating in inputs.pendingRatings {
            let title = displayTitle(rating.gameTitle, languageCode: languageCode)
            items.append(
                GoingActionItem(
                    id: "going_rating:\(rating.pickupGameId.uuidString.lowercased())",
                    kind: .pendingRating,
                    titleKey: "going_action_needed_rating_format",
                    titleFormatArgs: [title],
                    destination: .pendingRating,
                    timestamp: rating.startAt,
                    pickupGameId: rating.pickupGameId
                )
            )
            claimPickup(rating.pickupGameId)
        }

        for announcement in inputs.announcements {
            let title = displayTitle(announcement.title, languageCode: languageCode)
            items.append(
                GoingActionItem(
                    id: "going_announcement:\(announcement.id.uuidString.lowercased())",
                    kind: .newAnnouncement,
                    titleKey: "going_action_needed_announcement_format",
                    titleFormatArgs: [title],
                    destination: announcement.teamId != nil ? .teamsEvent : .pickupDetail,
                    timestamp: announcement.timestamp,
                    pickupGameId: announcement.pickupGameId,
                    teamId: announcement.teamId
                )
            )
            claimPickup(announcement.pickupGameId)
        }

        for soon in inputs.startsSoon {
            switch soon.surface {
            case .pickup:
                if claimedPickupIds.contains(soon.id) { continue }
                guard isStartsSoon(soon.startAt, now: now) else { continue }
                items.append(startsSoonItem(soon, languageCode: languageCode, now: now))
                claimedPickupIds.insert(soon.id)
            case .watch:
                if claimedVenueIds.contains(soon.id) { continue }
                guard isStartsSoon(soon.startAt, now: now) else { continue }
                items.append(startsSoonItem(soon, languageCode: languageCode, now: now))
                claimedVenueIds.insert(soon.id)
            }
        }

        items.append(contentsOf: inputs.customItems)

        items.sort {
            if $0.kind.priority != $1.kind.priority {
                return $0.kind.priority < $1.kind.priority
            }
            let lhsTime = $0.timestamp?.timeIntervalSince1970 ?? 0
            let rhsTime = $1.timestamp?.timeIntervalSince1970 ?? 0
            if lhsTime != rhsTime {
                return lhsTime < rhsTime
            }
            return $0.id < $1.id
        }

        return GoingActionSummary(items: items)
    }

    static func isStartsSoon(_ startAt: Date, now: Date) -> Bool {
        let delta = startAt.timeIntervalSince(now)
        return delta > 0 && delta <= startsSoonWindow
    }

    private static func displayTitle(_ raw: String, languageCode: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.t("Pickup", languageCode: languageCode) : trimmed
    }

    private static func classifyScheduleActivity(
        _ activity: FanGeoActionScheduleActivityInput
    ) -> (kind: GoingActionKind, titleKey: String) {
        if activity.isCancellation {
            return (.cancelled, "going_action_needed_cancelled_format")
        }
        let keys = Set(activity.changeDetails.map(\.labelKey))
        let hasTime = keys.contains("action_center_change_time")
            || keys.contains("action_center_change_end_time")
        let hasLocation = keys.contains("action_center_change_location")
        if hasLocation && !hasTime {
            return (.locationChanged, "going_action_needed_location_changed_format")
        }
        if hasTime && !hasLocation {
            return (.scheduleChanged, "going_action_needed_time_changed_format")
        }
        return (.scheduleChanged, "going_action_needed_schedule_changed_format")
    }

    private static func startsSoonItem(
        _ soon: GoingActionStartsSoonInput,
        languageCode: String,
        now: Date
    ) -> GoingActionItem {
        let title = displayTitle(soon.title, languageCode: languageCode)
        let minutes = max(1, Int((soon.startAt.timeIntervalSince(now) / 60).rounded(.up)))
        let usesHourCopy = minutes >= 45
        return GoingActionItem(
            id: soon.surface == .watch
                ? "going_soon_watch:\(soon.id.uuidString.lowercased())"
                : "going_soon_pickup:\(soon.id.uuidString.lowercased())",
            kind: .startsSoon,
            titleKey: usesHourCopy
                ? "going_action_needed_starts_soon_hour_format"
                : "going_action_needed_starts_soon_minutes_format",
            titleFormatArgs: usesHourCopy ? [title] : [title, "\(minutes)"],
            destination: soon.surface == .watch ? .watching : .pickupDetail,
            timestamp: soon.startAt,
            pickupGameId: soon.surface == .pickup ? soon.id : nil,
            venueEventId: soon.surface == .watch ? soon.id : nil
        )
    }
}
