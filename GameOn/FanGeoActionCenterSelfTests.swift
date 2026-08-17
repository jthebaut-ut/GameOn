import Foundation
import SwiftUI

#if DEBUG
enum FanGeoActionCenterSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[ActionCenterTest] PASS \(name)")
            } else {
                failures += 1
                print("[ActionCenterTest] FAIL \(name)")
            }
        }

        let empty = FanGeoActionCenterProjection.snapshot(
            from: .init(
                chatUnreadCount: 3,
                isSignedInForSocial: true
            )
        )
        expect(
            L10n.t("action_center_title", languageCode: "en") == "FanGeo Inbox",
            "user-facing container title is FanGeo Inbox"
        )
        expect(
            L10n.t("action_center_subtitle", languageCode: "en")
                == "Your actions, updates, and notification history.",
            "FanGeo Inbox subtitle covers actions and history"
        )
        expect(
            L10n.t("action_center_a11y_hint", languageCode: "en") == "Open FanGeo Inbox",
            "bell a11y hint opens FanGeo Inbox"
        )
        expect(
            L10n.t("action_center_tab_action_needed", languageCode: "en") == "Action Needed",
            "Action Needed tab name is unchanged"
        )
        expect(
            L10n.t("action_center_tab_notifications", languageCode: "en") == "Notifications",
            "Notifications tab name is unchanged"
        )
        expect(
            FanGeoInboxChrome.envelopeSymbol == "envelope.fill",
            "Inbox header uses envelope.fill"
        )
        expect(
            FanGeoInboxChrome.tabOrder == [.notifications, .actionNeeded],
            "visual tab order is Notifications then Action Needed"
        )
        expect(FanGeoInboxChrome.showsFilterToolbar == false, "no Filter toolbar")
        expect(FanGeoInboxChrome.showsUnreadFilter == false, "no Unread toolbar")
        expect(FanGeoInboxChrome.showsSearch == false, "no Search toolbar")
        expect(FanGeoInboxChrome.showsNewestSort == false, "no Newest toolbar")
        expect(FanGeoInboxChrome.showsComposeButton == false, "no compose pencil")
        expect(empty.items.isEmpty, "no actions → empty FanGeo Inbox")
        expect(empty.scheduleBadgeCount == 0, "schedule badge 0")
        expect(empty.goingBadgeCount == 0, "going badge 0")
        expect(empty.teamsBadgeCount == 0, "teams badge 0")
        expect(empty.chatUnreadCount == 3, "chat unread preserved")
        expect(empty.actionCenterBadgeCount == 0, "action center hidden when empty")

        let gameId = UUID()
        let requestId = UUID()
        let mixed = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitationCount: 2,
                pickupInvites: [
                    FanGeoActionPickupInviteInput(
                        inviteId: UUID(),
                        pickupGameId: gameId,
                        gameTitle: "JT League Game",
                        teamName: "JT",
                        eventTypeLabel: "League Game",
                        startAt: Date(),
                        locationLabel: "Galena Hills Trail",
                        inviterName: "Jonathan"
                    )
                ],
                friendRequestCount: 1,
                joinApprovals: [
                    FanGeoActionJoinApprovalInput(
                        requestId: requestId,
                        pickupGameId: gameId,
                        requesterUserId: UUID(),
                        requesterName: "Emma",
                        gameTitle: "JT League Game",
                        teamName: "JT",
                        teamId: UUID(),
                        eventTypeLabel: "League Game",
                        startAt: Date(),
                        locationLabel: "Galena Hills Trail"
                    )
                ],
                scheduleActivities: [
                    FanGeoActionScheduleActivityInput(
                        pickupGameId: gameId,
                        title: "JT League Game",
                        teamName: "JT",
                        eventTypeLabel: "League Game",
                        startAt: Date(),
                        locationLabel: "Galena Hills Trail",
                        isCancellation: false,
                        changeDetails: [
                            FanGeoActionChangeDetail(
                                labelKey: "action_center_change_time",
                                oldValue: "6:58 PM",
                                newValue: "7:30 PM"
                            )
                        ],
                        moreChangesCount: 0
                    )
                ],
                hasUnreadScheduleActivity: true,
                unseenPokesCount: 2,
                hasUnseenPokes: true,
                chatUnreadCount: 5,
                isSignedInForSocial: true
            )
        )
        expect(mixed.joinApprovalsBadge == 1, "join approval item from summary")
        expect(
            mixed.items.contains(where: { $0.kind == .joinApproval && $0.context.personName == "Emma" }),
            "join approval shows requester"
        )
        expect(
            mixed.notificationItems.contains(where: { $0.kind == .scheduleChange && !$0.context.changeDetails.isEmpty }),
            "schedule change is Notifications history"
        )
        expect(
            mixed.actionNeededItems.contains(where: { $0.kind == .scheduleChange }) == false,
            "schedule change is not Action Needed"
        )
        expect(mixed.goingBadgeCount == 0, "Inbox snapshot never drives the Going tab badge")
        expect(mixed.scheduleBadgeCount == 0, "schedule badge does not duplicate Going activity")
        expect(mixed.teamsBadgeCount == 2, "teams = Team invitations only")
        expect(mixed.chatUnreadCount == 5, "chat unread only")
        expect(!mixed.items.contains(where: { $0.destination == .chatUnread }), "unread not Action Center rows")
        expect(
            mixed.actionNeededItems.map(\.kind.priority) == mixed.actionNeededItems.map(\.kind.priority).sorted(),
            "action items sorted by priority"
        )
        expect(
            mixed.actionNeededItems.contains(where: {
                $0.kind == .pickupInvitation && $0.destination == .goingPickupInvites
            }),
            "pickup invite deep-links to invitation details"
        )
        let pickupInvite = mixed.actionNeededItems.first(where: { $0.kind == .pickupInvitation })
        let pickupTitle = pickupInvite?.title(languageCode: "en") ?? ""
        let expectedPickupTitle = String(
            format: L10n.t("action_center_pickup_invite_title", languageCode: "en"),
            locale: Locale(identifier: "en"),
            "JT League Game"
        )
        expect(pickupTitle == expectedPickupTitle, "pickup invite interpolates game title")
        expect(
            pickupTitle != "action_center_pickup_invite_title",
            "pickup invite title is not the raw catalog key"
        )
        expect(
            pickupTitle.contains("JT League Game"),
            "pickup invite title includes the game name"
        )
        expect(
            FanGeoLocalizationRegressionSelfTests.looksLikeUnresolvedKey(pickupTitle) == false,
            "pickup invite title is not unresolved-shaped"
        )
        let pickupSubtitle = pickupInvite?.subtitle(languageCode: "en") ?? ""
        expect(
            pickupSubtitle != "action_center_pickup_invite_subtitle",
            "pickup invite subtitle is not the raw catalog key"
        )
        expect(
            mixed.actionNeededItems.contains(where: {
                $0.kind == .joinApproval && $0.destination == .goingHostingApprovals
            }),
            "join request deep-links to review"
        )

        let joinReview = FanGeoActionCenterProjection.snapshot(
            from: .init(
                joinApprovals: [
                    FanGeoActionJoinApprovalInput(
                        requestId: requestId,
                        pickupGameId: gameId,
                        requesterUserId: UUID(),
                        requesterName: "Enea Rrokaj",
                        gameTitle: "League Game",
                        teamName: "JT",
                        teamId: UUID(),
                        eventTypeLabel: "League Game",
                        startAt: Date(),
                        locationLabel: "Galena Hills Trail",
                        matchupLabel: "JT vs Brighton FC",
                        capacityLabel: "5 / 6 players",
                        isAtCapacity: false
                    )
                ],
                isSignedInForSocial: true
            )
        )
        let joinItem = joinReview.actionNeededItems.first(where: { $0.kind == .joinApproval })
        expect(joinItem?.context.eventTitle == "JT vs Brighton FC", "join card event title is matchup")
        expect(joinItem?.context.teamName == "JT", "join card keeps Team as secondary")
        expect(joinItem?.context.capacityLabel == "5 / 6 players", "join card shows capacity")
        let joinLines = joinItem?.contextLines(languageCode: "en") ?? []
        expect(joinLines.contains("JT vs Brighton FC"), "join context leads with event")
        expect(joinLines.contains("JT"), "join context still includes Team")
        expect(joinLines.contains("5 / 6 players"), "join context includes capacity")
        if let joinItem {
            let joinMeta = FanGeoActionCenterCopy.metadataRows(for: joinItem, languageCode: "en")
            expect(joinMeta.contains(where: { $0.text == "JT" }), "Team is a metadata row, not the title")
            expect(joinMeta.contains(where: { $0.text == "5 / 6 players" }), "capacity is a metadata row")
        } else {
            expect(false, "join approval item exists for hierarchy checks")
        }

        let approvedNotif = FanGeoActionItem(
            id: "join_decision_approved",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["Your request to join"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                eventTitle: "Friday Night Practice",
                pickupGameId: gameId,
                notificationType: "join_request_approved"
            )
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.title(
                for: approvedNotif,
                languageCode: "en"
            ) == "Your request to join",
            "approval notification title"
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.summaryLine(
                for: approvedNotif,
                languageCode: "en"
            )?.contains("Friday Night Practice") == true,
            "approval notification names the event"
        )
        expect(
            !FanGeoActionCenterTeamNotificationPresentation.usesTeamChrome(for: approvedNotif),
            "join decision is not Team membership chrome"
        )
        expect(
            mixed.actionNeededItems.contains(where: {
                $0.kind == .teamInvitation && $0.destination == .teamsInvites
            }),
            "team invite deep-links to invitation details"
        )
        expect(
            mixed.notificationItems.contains(where: {
                $0.kind == .scheduleChange && $0.destination == .scheduleActivity
            }),
            "schedule change deep-links to the updated event"
        )

        let ratingGameId = UUID()
        let ratingOrganizerId = UUID()
        let withRating = FanGeoActionCenterProjection.snapshot(
            from: .init(
                pendingRatings: [
                    FanGeoActionPendingRatingInput(
                        pickupGameId: ratingGameId,
                        organizerUserId: ratingOrganizerId,
                        organizerName: "FanGeo Demo User",
                        organizerAvatarURL: nil,
                        gameTitle: "Rock Climbing Demo",
                        teamName: nil,
                        eventTypeLabel: nil,
                        matchupLabel: nil,
                        startAt: Date()
                    ),
                    FanGeoActionPendingRatingInput(
                        pickupGameId: UUID(),
                        organizerUserId: ratingOrganizerId,
                        organizerName: "Jonathan",
                        organizerAvatarURL: nil,
                        gameTitle: "JT League Game",
                        teamName: "JT",
                        eventTypeLabel: "League Game",
                        matchupLabel: "JT vs Legends United",
                        startAt: Date()
                    )
                ],
                isSignedInForSocial: true
            )
        )
        expect(withRating.items.filter { $0.kind == .pendingPickupRating }.count == 2, "pending ratings appear")
        expect(
            withRating.items.contains(where: {
                $0.kind == .pendingPickupRating
                    && $0.titleKey == "action_center_rate_pickup_title"
                    && $0.context.eventTitle == "Rock Climbing Demo"
                    && $0.ctaKey == "action_center_cta_rate_now"
            }),
            "pickup rating card uses Rate Now + event title"
        )
        expect(
            withRating.items.contains(where: {
                $0.kind == .pendingPickupRating
                    && $0.titleKey == "action_center_rate_organizer_title"
                    && $0.context.matchupLabel == "JT vs Legends United"
            }),
            "competitive rating card prefers Rate your organizer + matchup"
        )
        expect(withRating.goingBadgeCount == 0, "Inbox snapshot never drives the Going tab badge")
        expect(
            withRating.actionNeededItems.contains(where: {
                $0.kind == .pendingPickupRating && $0.destination == .goingPendingRating
            }),
            "rating reminder deep-links to rating"
        )
        expect(withRating.actionCenterBadgeCount == 2, "action center badge includes pending ratings")
        expect(
            withRating.items.allSatisfy { $0.destination == .goingPendingRating || $0.kind != .pendingPickupRating },
            "rating items route to goingPendingRating"
        )
        expect(
            FanGeoActionKind.joinApproval.listSection == .actionNeeded,
            "join approvals are Action Needed"
        )
        expect(
            FanGeoActionKind.poke.listSection == .notifications,
            "pokes are Notifications history"
        )
        expect(
            FanGeoActionKind.pendingPickupRating.categoryBadgeKey == "action_center_badge_rate_game",
            "rating badge key"
        )

        let cancel = FanGeoActionCenterProjection.snapshot(
            from: .init(
                scheduleActivities: [
                    FanGeoActionScheduleActivityInput(
                        pickupGameId: UUID(),
                        title: "JT League Game",
                        teamName: "JT",
                        eventTypeLabel: "League Game",
                        startAt: Date(),
                        locationLabel: "Draper, UT",
                        isCancellation: true,
                        changeDetails: [],
                        moreChangesCount: 0
                    )
                ],
                hasUnreadScheduleActivity: true,
                isSignedInForSocial: true
            )
        )
        expect(
            cancel.items.contains(where: { $0.kind == .eventCancellation }),
            "cancellation maps to eventCancellation kind"
        )

        expect(FanGeoActionKind.allCases.allSatisfy(\.isDismissible), "all current kinds are dismissible")
        expect(
            FanGeoActionKind.teamInvitation.dismissalPersistence == .sessionSnooze
                && FanGeoActionKind.pickupInvitation.dismissalPersistence == .sessionSnooze
                && FanGeoActionKind.friendRequest.dismissalPersistence == .sessionSnooze
                && FanGeoActionKind.joinApproval.dismissalPersistence == .sessionSnooze,
            "pending requests snooze only"
        )
        expect(
            FanGeoActionKind.pendingPickupRating.dismissalPersistence == .permanent
                && FanGeoActionKind.businessClaim.dismissalPersistence == .permanent,
            "action-needed hideable kinds are permanent dismissals"
        )
        expect(
            FanGeoActionKind.scheduleChange.dismissalPersistence == .notificationInbox
                && FanGeoActionKind.eventCancellation.dismissalPersistence == .notificationInbox
                && FanGeoActionKind.poke.dismissalPersistence == .notificationInbox
                && FanGeoActionKind.securitySession.dismissalPersistence == .notificationInbox,
            "history kinds clear via notification inbox"
        )
        expect(
            FanGeoActionKind.scheduleChange.listSection == .notifications
                && FanGeoActionKind.pendingPickupRating.listSection == .actionNeeded,
            "action vs notification buckets"
        )

        let ratingDismissKey = FanGeoActionCenterActionKey.rateGame(ratingGameId)
        let dismissedRating = FanGeoActionCenterProjection.snapshot(
            from: .init(
                pendingRatings: [
                    FanGeoActionPendingRatingInput(
                        pickupGameId: ratingGameId,
                        organizerUserId: ratingOrganizerId,
                        organizerName: "FanGeo Demo User",
                        organizerAvatarURL: nil,
                        gameTitle: "Rock Climbing Demo",
                        teamName: nil,
                        eventTypeLabel: nil,
                        matchupLabel: nil,
                        startAt: Date()
                    )
                ],
                isSignedInForSocial: true,
                dismissedActionKeys: [ratingDismissKey]
            )
        )
        expect(dismissedRating.items.isEmpty, "dismissed rate game is filtered before render")
        expect(dismissedRating.actionCenterBadgeCount == 0, "action center badge excludes dismissed rating")
        expect(dismissedRating.goingBadgeCount == 0, "Inbox snapshot never drives the Going tab badge")

        let updateGameId = UUID()
        let firstInstance = FanGeoActionCenterActionKey.instanceKey(fromSignature: "sig-a")
        let secondInstance = FanGeoActionCenterActionKey.instanceKey(fromSignature: "sig-b")
        expect(firstInstance != secondInstance, "signature instance keys differ across updates")
        let firstUpdateKey = FanGeoActionCenterActionKey.pickupUpdate(
            gameId: updateGameId,
            instanceKey: firstInstance
        )
        let firstUpdate = FanGeoActionCenterProjection.snapshot(
            from: .init(
                scheduleActivities: [
                    FanGeoActionScheduleActivityInput(
                        pickupGameId: updateGameId,
                        title: "JT League Game",
                        teamName: "JT",
                        eventTypeLabel: "League Game",
                        startAt: Date(),
                        locationLabel: "Draper, UT",
                        isCancellation: false,
                        changeDetails: [],
                        moreChangesCount: 0,
                        activityInstanceKey: firstInstance
                    )
                ],
                hasUnreadScheduleActivity: true,
                isSignedInForSocial: true
            )
        )
        expect(firstUpdate.notificationItems.contains(where: { $0.id == firstUpdateKey }), "update uses instance action key")
        let afterDismissFirst = FanGeoActionCenterProjection.snapshot(
            from: .init(
                scheduleActivities: [
                    FanGeoActionScheduleActivityInput(
                        pickupGameId: updateGameId,
                        title: "JT League Game",
                        teamName: "JT",
                        eventTypeLabel: "League Game",
                        startAt: Date(),
                        locationLabel: "Draper, UT",
                        isCancellation: false,
                        changeDetails: [],
                        moreChangesCount: 0,
                        activityInstanceKey: firstInstance
                    )
                ],
                hasUnreadScheduleActivity: true,
                isSignedInForSocial: true,
                clearedNotificationKeys: [firstUpdateKey]
            )
        )
        expect(afterDismissFirst.notificationItems.isEmpty, "cleared notification stays filtered")
        let laterUpdate = FanGeoActionCenterProjection.snapshot(
            from: .init(
                scheduleActivities: [
                    FanGeoActionScheduleActivityInput(
                        pickupGameId: updateGameId,
                        title: "JT League Game",
                        teamName: "JT",
                        eventTypeLabel: "League Game",
                        startAt: Date(),
                        locationLabel: "Draper, UT",
                        isCancellation: false,
                        changeDetails: [],
                        moreChangesCount: 0,
                        activityInstanceKey: secondInstance
                    )
                ],
                hasUnreadScheduleActivity: true,
                isSignedInForSocial: true,
                clearedNotificationKeys: [firstUpdateKey]
            )
        )
        expect(
            laterUpdate.notificationItems.contains(where: { $0.kind == .scheduleChange && $0.id != firstUpdateKey }),
            "later update for same game appears as a new notification item"
        )
        expect(
            FanGeoActionCenterActionKey.sanitize("Rate Game!") == "rategame",
            "action keys strip unsupported characters"
        )

        let inviteId = UUID()
        let inviteKey = FanGeoActionCenterActionKey.teamInvite(inviteId)
        let pendingInviteInputs = FanGeoActionCenterProjection.Inputs(
            teamInvitations: [
                FanGeoActionTeamInviteInput(
                    invitationId: inviteId,
                    teamId: UUID(),
                    teamName: "JT",
                    sport: "Soccer",
                    inviterDisplayName: "Jonathan",
                    createdAt: Date()
                )
            ],
            isSignedInForSocial: true
        )
        let persistedPending = FanGeoActionCenterProjection.snapshot(
            from: FanGeoActionCenterProjection.Inputs(
                teamInvitations: pendingInviteInputs.teamInvitations,
                isSignedInForSocial: true,
                dismissedActionKeys: [inviteKey]
            )
        )
        expect(
            persistedPending.items.contains(where: { $0.id == inviteKey }),
            "pending invite is not permanently hidden by action_center_dismissals"
        )
        expect(persistedPending.actionCenterBadgeCount == 1, "unresolved pending invite still badges")
        expect(persistedPending.teamsBadgeCount == 1, "Teams badge still reflects pending invite")

        let snoozedPending = FanGeoActionCenterProjection.snapshot(
            from: FanGeoActionCenterProjection.Inputs(
                teamInvitations: pendingInviteInputs.teamInvitations,
                isSignedInForSocial: true,
                sessionSnoozedPendingKeys: [inviteKey]
            )
        )
        expect(snoozedPending.items.isEmpty, "snoozed pending invite is hidden from the inbox list")
        expect(
            snoozedPending.actionNeededBadgeCount == 0
                && snoozedPending.actionCenterBadgeCount == 0,
            "snoozed pending invite does not contribute to the visible Inbox/bell badge during TTL"
        )
        expect(snoozedPending.teamsBadgeCount == 1, "Teams badge still reflects unresolved pending invite")
        expect(
            FanGeoActionCenterActionKey.isPendingRequestKey(inviteKey)
                && !FanGeoActionCenterActionKey.isPendingRequestKey(ratingDismissKey),
            "pending vs informational key classification"
        )

        expect(FanGeoActionCenterProjection.badgeLabel(9) == "9", "badge 9")
        expect(FanGeoActionCenterProjection.badgeLabel(100) == "99+", "badge 99+")
        expect(
            FanGeoActionCenterCopy.changeLabelKey(for: .start) == "action_center_change_time",
            "start → Time changed key"
        )
        expect(
            ActionCenterRouteDebug.organizerRequestsRequiresRootMapViewModelEnvironmentObject(),
            "organizer requests require root MapViewModel EnvironmentObject"
        )
        expect(
            ActionCenterRouteDebug.log(
                kind: "joinApproval",
                pickupGameId: gameId,
                teamId: nil,
                presentation: "organizerRequests",
                mapViewModelInjected: true
            ),
            "route debug reports mapViewModelInjected"
        )

        let signedOutStaleTeams = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitationCount: 4,
                chatUnreadCount: 9,
                isSignedInForSocial: false
            )
        )
        expect(signedOutStaleTeams.teamsBadgeCount == 0, "signed-out Teams badge ignores stale invites")
        expect(
            !signedOutStaleTeams.items.contains(where: { $0.kind == .teamInvitation }),
            "signed-out Action Center hides Team invitations"
        )
        expect(signedOutStaleTeams.chatUnreadCount == 0, "signed-out chat unread hidden")

        let teamId = UUID()
        expect(
            FanGeoActionCenterLeadingIdentity.prefersTeamMark(
                kind: .scheduleChange,
                teamId: teamId
            ),
            "scheduleChange with teamId uses Team mark"
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(
                kind: .scheduleChange,
                teamId: teamId,
                personAvatarURL: nil,
                isPendingRating: false
            ) == .teamMark,
            "EVENT UPDATED / time change leads with Team avatar"
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(
                kind: .scheduleChange,
                teamId: nil,
                personAvatarURL: nil,
                isPendingRating: false
            ) == .kindGlyph,
            "scheduleChange without teamId keeps kind glyph"
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(
                kind: .eventCancellation,
                teamId: teamId,
                personAvatarURL: nil,
                isPendingRating: false
            ) == .teamMark,
            "event cancellation with teamId uses Team mark"
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(
                kind: .teamInvitation,
                teamId: teamId,
                personAvatarURL: "https://example.test/avatar.jpg",
                isPendingRating: false
            ) == .teamMark,
            "team invitation prefers Team mark over person avatar"
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(
                kind: .friendRequest,
                teamId: nil,
                personAvatarURL: "https://example.test/avatar.jpg",
                isPendingRating: false
            ) == .personAvatar,
            "friend request still uses person avatar"
        )
        expect(
            !FanGeoActionCenterLeadingIdentity.prefersTeamMark(
                kind: .joinApproval,
                teamId: teamId
            ),
            "join approval keeps requester identity (not Team mark)"
        )

        let teamTimeItem = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):time",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["JT updated the time"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            timestamp: Date(),
            context: FanGeoActionContext(
                teamName: "JT",
                eventTitle: "Practice",
                eventTypeLabel: "practice",
                locationLabel: "Draper, UT 84020",
                eventStartAt: Date(),
                changeDetails: [
                    FanGeoActionChangeDetail(
                        labelKey: "action_center_change_time",
                        oldValue: "7:00 PM",
                        newValue: "8:30 PM"
                    )
                ],
                teamId: teamId,
                notificationType: "team_event_time_changed"
            )
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.usesTeamChrome(for: teamTimeItem),
            "Team time change uses Team chrome"
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.variant(for: teamTimeItem) == .timeChanged,
            "time_changed maps to timeChanged variant"
        )
        expect(
            teamTimeItem.title(languageCode: "en") == "Practice Updated",
            "Team time title is Practice Updated"
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.summaryLine(
                for: teamTimeItem,
                languageCode: "en"
            ) == nil,
            "time change does not use combined summaryLine"
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.headerBadgeText(
                for: teamTimeItem,
                languageCode: "en"
            ) == "PRACTICE UPDATED",
            "Team event header is PRACTICE UPDATED"
        )
        expect(
            !FanGeoActionCenterTeamNotificationPresentation.showsTimestampStatusDot(
                for: teamTimeItem
            ),
            "Team cards do not show a second timestamp status dot"
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.badgeKey(for: teamTimeItem)
                == "action_center_badge_event_updated",
            "Team event badge key stays event-updated, not TEAM"
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.cardAccent(for: teamTimeItem)
                == FGColor.accentYellow,
            "Team event cards keep the event-updated yellow accent"
        )

        let pickupNoTeam = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):solo",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["Jonathan updated the time"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            timestamp: Date(),
            context: FanGeoActionContext(
                eventTitle: "Pickup Game",
                notificationType: "time_changed"
            )
        )
        expect(
            !FanGeoActionCenterTeamNotificationPresentation.usesTeamChrome(for: pickupNoTeam),
            "standalone Pickup keeps generic fallback"
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.showsTimestampStatusDot(
                for: pickupNoTeam
            ),
            "Pickup cards keep existing timestamp status dot"
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.headerBadgeText(
                for: pickupNoTeam,
                languageCode: "en"
            ) != "TEAM · JT",
            "Pickup header is not TEAM · name"
        )
        expect(
            pickupNoTeam.title(languageCode: "en") == "Jonathan updated the time",
            "non-Team title stays passthrough"
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.cardAccent(for: pickupNoTeam)
                == FGColor.accentYellow,
            "standalone schedule change still uses yellow"
        )

        let moved = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):loc",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["JT updated the location"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "JT",
                eventTypeLabel: "practice",
                locationLabel: "AF Canyon Park",
                eventStartAt: PickupGameModels.parseSupabaseTimestamptz("2026-08-14T14:14:00+00:00"),
                changeDetails: [
                    FanGeoActionChangeDetail(
                        labelKey: "action_center_change_location",
                        oldValue: "Lone Peak Hospital",
                        newValue: "AF Canyon Park"
                    )
                ],
                teamId: teamId,
                notificationType: "team_event_location_changed"
            )
        )
        expect(moved.title(languageCode: "en") == "Practice Updated", "location title is Practice Updated")
        expect(
            FanGeoActionCenterTeamNotificationPresentation.summaryLine(for: moved, languageCode: "en")
                == nil,
            "location summary is owned by notice rows"
        )

        let announcement = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):ann",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["JT announcement"],
            subtitleKey: "action_center_notification_title_passthrough_format",
            subtitleFormatArgs: ["Bring a white jersey tonight."],
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "JT",
                eventTitle: "Bring a white jersey tonight.",
                eventTypeLabel: "announcement",
                teamId: teamId,
                notificationType: "team_announcement"
            )
        )
        expect(
            announcement.title(languageCode: "en") == "New Announcement",
            "announcement title is New Announcement"
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.headerBadgeText(
                for: announcement,
                languageCode: "en"
            ) == "NEW ANNOUNCEMENT",
            "announcement header is NEW ANNOUNCEMENT"
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.summaryLine(
                for: announcement,
                languageCode: "en"
            )?.contains("Bring a white jersey tonight.") == true,
            "announcement shows quoted body"
        )

        let created = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):create",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["JT scheduled a League Game"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "JT",
                eventTypeLabel: "league_game",
                teamId: teamId,
                notificationType: "team_game_created"
            )
        )
        expect(
            created.title(languageCode: "en") == "New League Game",
            "create title is New League Game"
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.headerBadgeText(
                for: created,
                languageCode: "en"
            ) == "NEW LEAGUE GAME",
            "created event header is NEW LEAGUE GAME"
        )

        let dateMoved = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):date",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["JT updated the time"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "Best Team Ever",
                eventTypeLabel: "league_game",
                changeDetails: [
                    FanGeoActionChangeDetail(
                        labelKey: "action_center_change_time",
                        oldValue: "2026-08-14T14:01:00+00:00",
                        newValue: "2026-08-15T16:01:00+00:00"
                    )
                ],
                teamId: teamId,
                notificationType: "team_event_time_changed"
            )
        )
        expect(
            dateMoved.title(languageCode: "en") == "League Game Updated",
            "League Game time/date title is League Game Updated"
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.headerBadgeText(
                for: dateMoved,
                languageCode: "en"
            ) == "LEAGUE GAME UPDATED",
            "event-type badge, not the long Team name"
        )
        if let notice = FanGeoTeamEventNoticeBuilder.make(for: dateMoved, languageCode: "en") {
            expect(
                notice.changeRows.contains(where: { $0.kind == .date && $0.displayValue(languageCode: "en").contains("→") }),
                "date move shows Date old → new"
            )
            expect(
                FanGeoActionCenterTeamNotificationPresentation.summaryLine(for: dateMoved, languageCode: "en") == nil,
                "date move does not use combined summaryLine"
            )
        } else {
            expect(false, "date move notice")
        }

        let matchCreated = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):match",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["JT scheduled a Match"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "JT",
                eventTypeLabel: "match",
                teamId: teamId,
                notificationType: "team_game_created"
            )
        )
        expect(
            matchCreated.title(languageCode: "en") == "New Match",
            "Match created uses New Match"
        )

        let tournamentUpdated = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):tourney",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["JT updated Tournament Game"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "JT",
                eventTypeLabel: "tournament_game",
                teamId: teamId,
                notificationType: "team_event_updated"
            )
        )
        expect(
            tournamentUpdated.title(languageCode: "en") == "Tournament Game Updated",
            "Tournament Game updated uses Tournament Game Updated"
        )

        let cancelled = FanGeoActionItem(
            id: "pickup_cancel:\(UUID().uuidString.lowercased()):x",
            kind: .eventCancellation,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["JT cancelled Practice"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "JT",
                eventTypeLabel: "practice",
                teamId: teamId,
                notificationType: "cancelled"
            )
        )
        expect(
            cancelled.title(languageCode: "en") == "Practice Cancelled",
            "cancellation title is Practice Cancelled"
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.headerBadgeText(
                for: cancelled,
                languageCode: "en"
            ) == "PRACTICE CANCELLED",
            "cancellation header is PRACTICE CANCELLED"
        )

        let scrimmageCancelled = FanGeoActionItem(
            id: "pickup_cancel:\(UUID().uuidString.lowercased()):scrim",
            kind: .eventCancellation,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["JT cancelled Scrimmage"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "JT",
                eventTypeLabel: "scrimmage",
                teamId: teamId,
                notificationType: "cancelled"
            )
        )
        expect(
            scrimmageCancelled.title(languageCode: "en") == "Scrimmage Cancelled",
            "Scrimmage cancelled uses Team · event noun"
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.cardAccent(for: cancelled) == Color.red,
            "cancellation keeps red warning accent"
        )

        let friend = FanGeoActionItem(
            id: "friend:\(UUID().uuidString.lowercased())",
            kind: .friendRequest,
            titleKey: "action_center_friend_request_title_format",
            titleFormatArgs: ["Sam"],
            subtitleKey: "action_center_friend_request_subtitle",
            destination: .chatFriendRequests,
            context: FanGeoActionContext(personName: "Sam")
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.title(for: friend, languageCode: "en") == nil,
            "non-Team notifications keep existing titles"
        )

        let removed = FanGeoActionItem(
            id: "team_removed:\(teamId.uuidString.lowercased()):user:event",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["Team updated"],
            subtitleKey: "action_center_notification_title_passthrough_format",
            subtitleFormatArgs: ["Removed from team"],
            destination: .teamsHome,
            context: FanGeoActionContext(
                teamName: "JT",
                sportLabel: "Soccer",
                notificationType: "removed_from_team"
            )
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.usesTeamChrome(for: removed),
            "removed-from-Team uses Team chrome"
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.variant(for: removed) == nil,
            "removed-from-Team is not a schedule variant"
        )
        expect(
            removed.title(languageCode: "en") == "Removed from Team",
            "removed-from-Team title is not Event updated"
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.summaryLine(
                for: removed,
                languageCode: "en"
            ) == "You are no longer a member of JT.",
            "removed-from-Team body names the Team"
        )
        expect(removed.destination == .teamsHome, "removed-from-Team taps Teams list")
        expect(removed.ctaKey == "action_center_cta_view_teams", "removed-from-Team CTA is View Teams")
        expect(
            FanGeoActionCenterLeadingIdentity.prefersTeamMark(
                kind: .scheduleChange,
                teamId: teamId
            ),
            "removed-from-Team still prefers Team mark"
        )

        let promoted = FanGeoActionItem(
            id: "team_role_changed:\(teamId.uuidString.lowercased()):user:event",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["Team Role Updated"],
            subtitleKey: "action_center_notification_title_passthrough_format",
            subtitleFormatArgs: ["You're now a Manager for JT."],
            destination: .teamsHome,
            context: FanGeoActionContext(
                teamName: "JT",
                notificationType: "team_role_changed",
                roleToken: "manager"
            )
        )
        expect(
            promoted.title(languageCode: "en") == "Team Role Updated",
            "role change title"
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.summaryLine(
                for: promoted,
                languageCode: "en"
            ) == "You're now a Manager for JT.",
            "role promotion uses localized role name"
        )

        let demoted = FanGeoActionItem(
            id: "team_role_changed:\(teamId.uuidString.lowercased()):user:event2",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["Team Role Updated"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .teamsHome,
            context: FanGeoActionContext(
                teamName: "JT",
                notificationType: "team_role_changed",
                roleToken: "member"
            )
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.summaryLine(
                for: demoted,
                languageCode: "en"
            ) == "Your role on JT is now Member.",
            "role demotion to Member"
        )

        let adminOn = FanGeoActionItem(
            id: "team_admin_granted:\(teamId.uuidString.lowercased()):user:event",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["Team Access Updated"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .teamsHome,
            context: FanGeoActionContext(
                teamName: "JT",
                notificationType: "team_admin_granted"
            )
        )
        expect(
            adminOn.title(languageCode: "en") == "Team Access Updated",
            "admin grant title"
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.summaryLine(
                for: adminOn,
                languageCode: "en"
            ) == "You can now help manage JT.",
            "admin grant body"
        )

        let morningStart = PickupGameModels.parseSupabaseTimestamptz("2026-08-14T14:14:00+00:00")
        let createdPractice = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):created-rich",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["ER basketball scheduled a Practice"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "ER basketball",
                eventTitle: "Practice",
                eventTypeLabel: "practice",
                locationLabel: "Intermountain Medical Center",
                eventStartAt: morningStart,
                pickupGameId: UUID(),
                teamId: teamId,
                notificationType: "team_event_created"
            )
        )
        if let notice = FanGeoTeamEventNoticeBuilder.make(for: createdPractice, languageCode: "en") {
            expect(createdPractice.title(languageCode: "en") == "New Practice", "1 created title")
            expect(!notice.identityRows.contains(where: { $0.kind == .team }), "1 no Team identity row")
            expect(notice.supportingRows.contains(where: { $0.kind == .team && $0.value == "ER basketball" }), "1 Team supporting row")
            expect(!notice.identityRows.contains(where: { $0.kind == .game }), "1 no generated Game row")
            expect(notice.supportingRows.contains(where: { $0.kind == .date }), "1 Date row")
            expect(notice.supportingRows.contains(where: { $0.kind == .time }), "1 Time row")
            expect(notice.supportingRows.contains(where: { $0.kind == .location }), "1 Location row")
            expect(notice.changeRows.isEmpty, "1 created has no old → new rows")
            expect(
                FanGeoActionCenterTeamNotificationPresentation.summaryLine(
                    for: createdPractice,
                    languageCode: "en"
                ) == nil,
                "1 created has no combined subtitle"
            )
            expect(notice.omitsGameRow, "1 generic Practice omits Game fallback")
            expect(
                !notice.supportingRows.contains(where: { $0.kind == .player }),
                "1 created without payload player does not invent a Player row"
            )
        } else {
            expect(false, "1 created notice")
        }

        let emmaId = UUID()
        let emmaStart = PickupGameModels.parseSupabaseTimestamptz("2026-08-18T05:27:00+00:00")
        let emmaPractice = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):emma-practice",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["IMC Team scheduled a Practice"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            timestamp: emmaStart,
            context: FanGeoActionContext(
                personName: "Emma",
                personAvatarURL: "https://example.test/emma.jpg",
                teamName: "IMC Team",
                eventTitle: "Practice",
                eventTypeLabel: "practice",
                locationLabel: "Draper, UT",
                eventStartAt: emmaStart,
                pickupGameId: UUID(),
                teamId: teamId,
                notificationType: "team_event_created",
                managedPlayerId: emmaId,
                isManagedPlayer: true,
                personAvatarThumbnailURL: "https://example.test/emma-thumb.jpg"
            )
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.headerBadgeText(
                for: emmaPractice,
                languageCode: "en"
            ) == "NEW PRACTICE",
            "Emma created badge is NEW PRACTICE"
        )
        expect(emmaPractice.title(languageCode: "en") == "New Practice", "Emma created title is New Practice")
        expect(
            FanGeoActionCenterLeadingIdentity.source(for: emmaPractice) == .teamMark,
            "practice update card prefers team logo as primary artwork"
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(for: emmaPractice) != .personAvatar,
            "player avatar is not the main leading artwork for Emma practice card"
        )
        if let notice = FanGeoTeamEventNoticeBuilder.make(for: emmaPractice, languageCode: "en") {
            expect(
                notice.supportingRows.contains(where: { $0.kind == .player && $0.value == "Emma" }),
                "Emma Player row"
            )
            expect(
                notice.supportingRows.contains(where: { $0.kind == .team && $0.value == "IMC Team" }),
                "Emma Team supporting row"
            )
            expect(notice.supportingRows.contains(where: { $0.kind == .date }), "Emma Date row")
            expect(notice.supportingRows.contains(where: { $0.kind == .time }), "Emma Time row")
            expect(
                notice.supportingRows.contains(where: {
                    $0.kind == .location && $0.value.contains("Draper")
                }),
                "Emma Location row"
            )
            expect(notice.changeRows.isEmpty, "Emma created has no change rows")
        } else {
            expect(false, "Emma created notice")
        }

        let jonathanPractice = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):jonathan-practice",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["IMC Team scheduled a Practice"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                personName: "Jonathan",
                personAvatarURL: "https://example.test/jonathan.jpg",
                teamName: "IMC Team",
                eventTitle: "Practice",
                eventTypeLabel: "practice",
                locationLabel: "Draper, UT",
                eventStartAt: emmaStart,
                pickupGameId: UUID(),
                teamId: teamId,
                notificationType: "team_event_created",
                isManagedPlayer: false
            )
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(for: jonathanPractice) == .teamMark,
            "Jonathan practice card prefers team logo as primary artwork"
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(for: jonathanPractice) != .personAvatar,
            "player avatar is not the main leading artwork for Jonathan practice card"
        )
        if let notice = FanGeoTeamEventNoticeBuilder.make(for: jonathanPractice, languageCode: "en") {
            expect(
                notice.supportingRows.contains(where: { $0.kind == .player && $0.value == "Jonathan" }),
                "Jonathan Player row"
            )
            expect(
                !notice.supportingRows.contains(where: { $0.kind == .player && $0.value == "Emma" }),
                "Jonathan card does not show Emma"
            )
        } else {
            expect(false, "Jonathan created notice")
        }

        expect(emmaPractice.destination == .scheduleActivity, "practice update tap destination unchanged")
        expect(
            FanGeoActionKind.scheduleChange.dismissalPersistence == .notificationInbox,
            "practice update dismiss still clears the Inbox row"
        )
        expect(FanGeoActionKind.scheduleChange.isDismissible, "practice update remains dismissible")

        let missingLogoPractice = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):missing-logo",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["IMC Team updated a Practice"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                personName: "FanGeo",
                personAvatarURL: "https://example.test/fangeo.jpg",
                teamName: "IMC Team",
                eventTitle: "Practice",
                eventTypeLabel: "practice",
                locationLabel: "Draper, UT 84020",
                eventStartAt: emmaStart,
                pickupGameId: UUID(),
                teamId: teamId,
                sportLabel: "soccer",
                notificationType: "team_event_updated",
                isManagedPlayer: false
            )
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(for: missingLogoPractice) == .teamMark,
            "cards with team logo missing still use Team mark, not player avatar"
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(for: missingLogoPractice) != .personAvatar,
            "missing team logo does not fall back to player avatar as leading artwork"
        )
        if let notice = FanGeoTeamEventNoticeBuilder.make(for: missingLogoPractice, languageCode: "en") {
            expect(
                notice.supportingRows.contains(where: { $0.kind == .player && $0.value == "FanGeo" }),
                "player row still renders when leading artwork is Team mark"
            )
            expect(
                notice.supportingRows.contains(where: { $0.kind == .team && $0.value == "IMC Team" }),
                "IMC Team row still renders in the body"
            )
        } else {
            expect(false, "missing-logo practice notice")
        }

        let namedTeamWithoutId = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):named-team-no-id",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["IMC Team updated a Practice"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                personName: "FanGeo",
                personAvatarURL: "https://example.test/fangeo.jpg",
                teamName: "IMC Team",
                eventTitle: "Practice",
                eventTypeLabel: "practice",
                pickupGameId: UUID(),
                notificationType: "team_event_updated"
            )
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(for: namedTeamWithoutId) == .kindGlyph,
            "team-named practice without teamId uses the existing kind-glyph fallback"
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(for: namedTeamWithoutId) != .personAvatar,
            "team-named practice without teamId does not use player avatar as leading artwork"
        )

        let inferredTeamWithOwnerAvatar = FanGeoTeamEventAffectedPlayerResolver.applyingAccountOwner(
            to: FanGeoActionItem(
                id: "pickup_update:\(UUID().uuidString.lowercased()):imc-owner-avatar",
                kind: .scheduleChange,
                titleKey: "action_center_event_changed_format",
                titleFormatArgs: ["IMC Team · Practice"],
                subtitleKey: "action_center_schedule_change_subtitle",
                destination: .scheduleActivity,
                context: FanGeoActionContext(
                    eventTitle: "IMC Team · Practice",
                    eventTypeLabel: "Practice",
                    locationLabel: "Draper, UT 84020",
                    eventStartAt: emmaStart,
                    pickupGameId: UUID(),
                    notificationType: "team_event_updated"
                )
            ),
            displayName: "FanGeo",
            avatarURL: "https://example.test/fangeo.jpg",
            avatarThumbnailURL: "https://example.test/fangeo-thumb.jpg"
        )
        expect(
            inferredTeamWithOwnerAvatar.context.teamId == nil,
            "legacy screenshot row does not invent teamId"
        )
        expect(
            inferredTeamWithOwnerAvatar.context.personName == "FanGeo",
            "account owner still fills the Player row"
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(for: inferredTeamWithOwnerAvatar) == .kindGlyph,
            "Practice Updated with teamName inferred and no teamId uses event/team fallback"
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(for: inferredTeamWithOwnerAvatar) != .personAvatar,
            "cached/legacy Team-event row does not regress to player-primary artwork"
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(
                kind: .scheduleChange,
                teamId: teamId,
                personAvatarURL: "https://example.test/fangeo.jpg",
                isPendingRating: false,
                personName: "FanGeo",
                isManagedPlayer: false,
                teamName: "IMC Team"
            ) == .teamMark,
            "Practice Updated with teamId + player avatar uses Team mark"
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(
                kind: .scheduleChange,
                teamId: teamId,
                personAvatarURL: "https://example.test/fangeo.jpg",
                isPendingRating: false,
                personName: "FanGeo",
                teamName: "IMC Team"
            ) == FanGeoActionCenterLeadingIdentity.source(for: missingLogoPractice),
            "leading identity helper and item renderer stay consistent"
        )
        if let notice = FanGeoTeamEventNoticeBuilder.make(
            for: inferredTeamWithOwnerAvatar,
            languageCode: "en"
        ) {
            expect(
                notice.supportingRows.contains(where: { $0.kind == .player && $0.value == "FanGeo" }),
                "Player body row still shows when leading artwork is not the player"
            )
            expect(
                notice.supportingRows.contains(where: { $0.kind == .team && $0.value == "IMC Team" }),
                "inferred IMC Team row remains in the body"
            )
        } else {
            expect(false, "inferred Team-event notice")
        }

        let ownerFallback = FanGeoTeamEventAffectedPlayerResolver.applyingAccountOwner(
            to: createdPractice,
            displayName: "Jonathan",
            avatarURL: "https://example.test/jonathan.jpg",
            avatarThumbnailURL: nil
        )
        expect(ownerFallback.context.personName == "Jonathan", "account owner fills when payload has no player")
        expect(ownerFallback.context.isManagedPlayer == false, "account owner is not a managed player")
        expect(ownerFallback.context.managedPlayerId == nil, "account owner does not invent managed_player_id")

        let emmaPreserved = FanGeoTeamEventAffectedPlayerResolver.applyingAccountOwner(
            to: emmaPractice,
            displayName: "Jonathan",
            avatarURL: "https://example.test/jonathan.jpg",
            avatarThumbnailURL: nil
        )
        expect(emmaPreserved.context.personName == "Emma", "account owner does not overwrite Emma")
        expect(emmaPreserved.context.managedPlayerId == emmaId, "Emma managed_player_id is preserved")

        let managedFromPayload = FanGeoTeamEventAffectedPlayerResolver.fromPayload([
            "managed_player_id": .string(emmaId.uuidString),
            "managed_player_name": .string("Emma"),
            "is_managed_player": .bool(true),
            "player_name": .string("Lucas")
        ])
        expect(managedFromPayload?.displayName == "Emma", "managed_player_id wins over other names")
        expect(managedFromPayload?.managedPlayerId == emmaId, "managed_player_id is used")
        expect(managedFromPayload?.isManagedPlayer == true, "managed_player_id marks managed")

        let seatFromPayload = FanGeoTeamEventAffectedPlayerResolver.fromPayload([
            "membership_id": .string(UUID().uuidString),
            "player_display_name": .string("Lucas"),
            "player_avatar_url": .string("https://example.test/lucas.jpg")
        ])
        expect(seatFromPayload?.displayName == "Lucas", "participant/player seat uses player_display_name")
        expect(seatFromPayload?.isManagedPlayer == false, "seat without managed flag is not guessed as managed")

        expect(
            FanGeoTeamEventAffectedPlayerResolver.fromPayload([
                "team_name": .string("IMC Team"),
                "title": .string("Practice")
            ]) == nil,
            "payload without player keys does not invent a player"
        )

        let createdTypeSamples: [(String, String, String)] = [
            ("practice", "NEW PRACTICE", "New Practice"),
            ("scrimmage", "NEW SCRIMMAGE", "New Scrimmage"),
            ("league_game", "NEW LEAGUE GAME", "New League Game"),
            ("tournament_game", "NEW TOURNAMENT GAME", "New Tournament Game"),
            ("match", "NEW MATCH", "New Match"),
            ("tryout", "NEW TRYOUT", "New Tryout"),
            ("clinic", "NEW CLINIC", "New Clinic"),
            ("camp", "NEW CLINIC", "New Clinic"),
            ("team_meeting", "NEW TEAM MEETING", "New Team Meeting")
        ]
        for (token, badge, title) in createdTypeSamples {
            let sample = FanGeoActionItem(
                id: "pickup_update:\(UUID().uuidString.lowercased()):type-\(token)",
                kind: .scheduleChange,
                titleKey: "action_center_notification_title_passthrough_format",
                titleFormatArgs: ["x"],
                subtitleKey: "action_center_notification_subtitle_default",
                destination: .scheduleActivity,
                context: FanGeoActionContext(
                    teamName: "IMC Team",
                    eventTypeLabel: token,
                    teamId: teamId,
                    notificationType: "team_event_created"
                )
            )
            expect(
                FanGeoActionCenterTeamNotificationPresentation.headerBadgeText(
                    for: sample,
                    languageCode: "en"
                ) == badge,
                "created \(token) badge is \(badge)"
            )
            expect(sample.title(languageCode: "en") == title, "created \(token) title is \(title)")
        }

        if let notice = FanGeoTeamEventNoticeBuilder.make(for: teamTimeItem, languageCode: "en") {
            expect(!notice.identityRows.contains(where: { $0.kind == .team }), "2 no Team row")
            expect(!notice.identityRows.contains(where: { $0.kind == .game }), "2 no generated Game row")
            expect(
                notice.changeRows.contains(where: {
                    $0.kind == .time && $0.displayValue(languageCode: "en").contains("→")
                }),
                "2 Time old → new"
            )
            expect(!notice.supportingRows.contains(where: { $0.kind == .date }), "2 no unchanged Date")
            expect(!notice.supportingRows.contains(where: { $0.kind == .location }), "2 no unchanged Location")
            expect(!notice.supportingRows.contains(where: { $0.kind == .time }), "2 Time is not also supporting")
            expect(
                !notice.allRows.contains(where: {
                    $0.displayValue(languageCode: "en").localizedCaseInsensitiveContains(" at ")
                }),
                "2 no combined date-at-time duplicate"
            )
            let spoken = teamTimeItem.accessibilitySummary(languageCode: "en")
            expect(spoken.contains("Practice Updated"), "2 VoiceOver names the event")
            expect(
                spoken.localizedCaseInsensitiveContains("7:00 PM")
                    && spoken.localizedCaseInsensitiveContains("8:30 PM"),
                "2 VoiceOver names the time change"
            )
            expect(
                spoken.components(separatedBy: " at ").count <= 2,
                "2 VoiceOver does not repeat combined date at time"
            )
        } else {
            expect(false, "2 time notice")
        }

        let dateOnly = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):date-only",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["x"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "ER basketball",
                eventTitle: "Practice",
                eventTypeLabel: "practice",
                locationLabel: "Intermountain Medical Center",
                eventStartAt: morningStart,
                changeDetails: [
                    FanGeoActionChangeDetail(
                        labelKey: "action_center_change_date",
                        oldValue: "2026-08-14T14:14:00+00:00",
                        newValue: "2026-08-15T14:14:00+00:00"
                    )
                ],
                pickupGameId: UUID(),
                teamId: teamId,
                notificationType: "team_event_time_changed"
            )
        )
        expect(dateOnly.title(languageCode: "en") == "Practice Updated", "3 date title")
        if let notice = FanGeoTeamEventNoticeBuilder.make(for: dateOnly, languageCode: "en") {
            expect(notice.changeRows.contains(where: { $0.kind == .date }), "3 Date row")
            expect(!notice.changeRows.contains(where: { $0.kind == .time }), "3 no extra Time row")
            expect(!notice.supportingRows.contains(where: { $0.kind == .time }), "3 no unchanged Time")
            expect(!notice.supportingRows.contains(where: { $0.kind == .location }), "3 no unchanged Location")
            expect(!notice.supportingRows.contains(where: { $0.kind == .date }), "3 Date is not also supporting")
            expect(notice.omitsGameRow, "3 generic date change omits Game fallback")
            expect(!notice.identityRows.contains(where: { $0.kind == .game }), "3 no standalone Practice")
        } else {
            expect(false, "3 date notice")
        }

        if let notice = FanGeoTeamEventNoticeBuilder.make(for: moved, languageCode: "en") {
            expect(
                notice.changeRows.contains(where: {
                    $0.kind == .location && $0.displayValue(languageCode: "en").contains("→")
                }),
                "4 location old → new"
            )
            expect(!notice.supportingRows.contains(where: { $0.kind == .date }), "4 no unchanged Date")
            expect(!notice.supportingRows.contains(where: { $0.kind == .time }), "4 no unchanged Time")
            expect(!notice.supportingRows.contains(where: { $0.kind == .location }), "4 Location is not also supporting")
            expect(notice.omitsGameRow, "4 generic location change omits Game fallback")
        } else {
            expect(false, "4 location notice")
        }

        let dateTime = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):dt",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["x"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "ER basketball",
                eventTypeLabel: "practice",
                locationLabel: "Intermountain Medical Center",
                eventStartAt: morningStart,
                changeDetails: [
                    FanGeoActionChangeDetail(
                        labelKey: "action_center_change_date",
                        oldValue: "2026-08-14T14:14:00+00:00",
                        newValue: "2026-08-15T15:14:00+00:00"
                    ),
                    FanGeoActionChangeDetail(
                        labelKey: "action_center_change_time",
                        oldValue: "2026-08-14T14:14:00+00:00",
                        newValue: "2026-08-15T15:14:00+00:00"
                    )
                ],
                teamId: teamId,
                notificationType: "team_event_updated"
            )
        )
        expect(dateTime.title(languageCode: "en") == "Practice Updated", "5 multi title")
        if let notice = FanGeoTeamEventNoticeBuilder.make(for: dateTime, languageCode: "en") {
            expect(notice.changeRows.filter { $0.kind == .date }.count == 1, "5 one Date")
            expect(notice.changeRows.filter { $0.kind == .time }.count == 1, "5 one Time")
            expect(notice.changeRows.filter { $0.kind == .location }.isEmpty, "5 no location")
            expect(!notice.supportingRows.contains(where: { $0.kind == .location }), "5 no unchanged Location")
            expect(!notice.supportingRows.contains(where: { $0.kind == .date }), "5 Date is not also supporting")
            expect(!notice.supportingRows.contains(where: { $0.kind == .time }), "5 Time is not also supporting")
        } else {
            expect(false, "5 dt notice")
        }

        let triple = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):triple",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["x"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "ER basketball",
                eventTitle: "Morning Practice",
                eventTypeLabel: "practice",
                changeDetails: [
                    FanGeoActionChangeDetail(
                        labelKey: "action_center_change_date",
                        oldValue: "2026-08-14T14:14:00+00:00",
                        newValue: "2026-08-15T15:14:00+00:00"
                    ),
                    FanGeoActionChangeDetail(
                        labelKey: "action_center_change_time",
                        oldValue: "2026-08-14T14:14:00+00:00",
                        newValue: "2026-08-15T15:14:00+00:00"
                    ),
                    FanGeoActionChangeDetail(
                        labelKey: "action_center_change_location",
                        oldValue: "Field A",
                        newValue: "Field B"
                    )
                ],
                teamId: teamId,
                notificationType: "team_event_updated"
            )
        )
        if let notice = FanGeoTeamEventNoticeBuilder.make(for: triple, languageCode: "en") {
            expect(notice.changeRows.count == 3, "6 three change rows")
            expect(
                Set(notice.changeRows.map(\.kind)) == Set([.date, .time, .location]),
                "6 no duplicate kinds"
            )
            expect(
                FanGeoTeamEventNoticeBuilder.secondaryGameIdentity(
                    teamName: "ER basketball",
                    customTitle: "Morning Practice",
                    gameFormat: "practice",
                    opponent: nil,
                    matchupLabel: nil,
                    languageCode: "en"
                ) == "Morning Practice",
                "9 custom title wins"
            )
            expect(triple.title(languageCode: "en") == "Practice Updated", "9 event-type title")
            expect(notice.identityRows.isEmpty, "9 no duplicate Game row")
        } else {
            expect(false, "6 triple notice")
        }

        let league = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):league",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["x"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "JT",
                eventTypeLabel: "league_game",
                pickupGameId: UUID(),
                teamId: teamId,
                matchupLabel: "JT vs Brighton FC",
                opponentName: "Brighton FC",
                notificationType: "team_game_created"
            )
        )
        if let notice = FanGeoTeamEventNoticeBuilder.make(for: league, languageCode: "en") {
            expect(
                league.title(languageCode: "en") == "New League Game",
                "7 title is New League Game"
            )
            expect(notice.identityRows.isEmpty, "7 no duplicate Game row")
        } else {
            expect(false, "7 league notice")
        }

        let oppChanged = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):opp",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["x"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "JT",
                eventTypeLabel: "league_game",
                changeDetails: [
                    FanGeoActionChangeDetail(
                        labelKey: "action_center_change_opponent",
                        oldValue: "Brighton FC",
                        newValue: "Wasatch SC"
                    )
                ],
                pickupGameId: UUID(),
                teamId: teamId,
                matchupLabel: "JT vs Wasatch SC",
                opponentName: "Wasatch SC",
                notificationType: "team_event_updated"
            )
        )
        expect(oppChanged.title(languageCode: "en") == "League Game Updated", "8 opponent title is League Game Updated")
        if let notice = FanGeoTeamEventNoticeBuilder.make(for: oppChanged, languageCode: "en") {
            expect(
                notice.changeRows.contains(where: {
                    $0.kind == .opponent
                        && $0.displayValue(languageCode: "en") == "Brighton FC → Wasatch SC"
                }),
                "8 opponent arrow"
            )
        } else {
            expect(false, "8 opponent notice")
        }

        expect(
            FanGeoTeamEventNoticeBuilder.secondaryGameIdentity(
                teamName: "ER basketball",
                customTitle: "Practice",
                gameFormat: "practice",
                opponent: nil,
                matchupLabel: nil,
                languageCode: "en"
            ) == nil,
            "10 generic Practice has no secondary Game row"
        )
        expect(
            FanGeoTeamEventNoticeBuilder.secondaryGameIdentity(
                teamName: "ER basketball",
                customTitle: "ER basketball · Practice",
                gameFormat: "practice",
                opponent: nil,
                matchupLabel: nil,
                languageCode: "en"
            ) == nil,
            "10 generated Team · Practice is not a Game row"
        )
        expect(
            FanGeoTeamEventNoticeBuilder.gameLabel(
                teamName: "ER basketball",
                customTitle: "Practice",
                gameFormat: "practice",
                opponent: nil,
                matchupLabel: nil,
                languageCode: "en"
            ) == "ER basketball · Practice",
            "10 fallback Team · type is non-empty for Going Play"
        )
        expect(
            !FanGeoTeamEventNoticeBuilder.gameLabel(
                teamName: "ER basketball",
                customTitle: UUID().uuidString,
                gameFormat: "practice",
                opponent: nil,
                matchupLabel: nil,
                languageCode: "en"
            ).contains("-"),
            "10 UUID title is not used"
        )

        let cancelledEvent = FanGeoActionItem(
            id: "pickup_cancel:\(UUID().uuidString.lowercased())",
            kind: .eventCancellation,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["x"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "JT",
                eventTypeLabel: "league_game",
                eventStartAt: morningStart,
                pickupGameId: UUID(),
                teamId: teamId,
                matchupLabel: "JT vs Brighton FC",
                opponentName: "Brighton FC",
                notificationType: "cancelled"
            )
        )
        expect(cancelledEvent.title(languageCode: "en") == "League Game Cancelled", "11 cancelled title")
        if let notice = FanGeoTeamEventNoticeBuilder.make(for: cancelledEvent, languageCode: "en") {
            expect(
                notice.supportingRows.contains(where: { $0.kind == FanGeoTeamEventNoticeRow.Kind.team && $0.value == "JT" }),
                "11 Team supporting row"
            )
            expect(
                notice.identityRows.isEmpty,
                "11 no identity Game row"
            )
            expect(
                !notice.supportingRows.contains(where: { $0.kind == FanGeoTeamEventNoticeRow.Kind.status }),
                "11 no duplicate Cancelled status"
            )
            expect(
                !notice.supportingRows.contains(where: { $0.kind == FanGeoTeamEventNoticeRow.Kind.date }),
                "11 cancelled does not repeat unchanged Date"
            )
        } else {
            expect(false, "11 cancelled notice")
        }

        let otherTeamPractice = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):other",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["x"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "IMC Team",
                eventTypeLabel: "practice",
                teamId: UUID(),
                notificationType: "team_event_created"
            )
        )
        if let a = FanGeoTeamEventNoticeBuilder.make(for: createdPractice, languageCode: "en"),
           let b = FanGeoTeamEventNoticeBuilder.make(for: otherTeamPractice, languageCode: "en") {
            expect(
                a.supportingRows.contains(where: { $0.kind == .team && $0.value == "ER basketball" }),
                "12 first Team in supporting row"
            )
            expect(
                b.supportingRows.contains(where: { $0.kind == .team && $0.value == "IMC Team" }),
                "12 second Team in supporting row"
            )
            expect(a.omitsGameRow && b.omitsGameRow, "12 generic created omits Game fallback")
        } else {
            expect(false, "12 two-team notice")
        }

        expect(
            FanGeoTeamEventNoticeBuilder.make(for: announcement, languageCode: "en")?.omitsGameRow == true,
            "14 announcement has no Game:"
        )
        expect(
            FanGeoTeamEventNoticeBuilder.make(for: announcement, languageCode: "en")?
                .identityRows.contains(where: { $0.kind == .game }) != true,
            "14 announcement identity has no Game row"
        )

        let longTeam = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):long",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["x"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "East Ridge Youth Basketball Association Select",
                eventTitle: "Saturday Morning Skills and Conditioning Practice",
                eventTypeLabel: "practice",
                locationLabel: "Intermountain Medical Center Main Campus South Parking Structure Field 4",
                changeDetails: [
                    FanGeoActionChangeDetail(
                        labelKey: "action_center_change_location",
                        oldValue: "Brighton High School Stadium Turf Complex North Lot",
                        newValue: "Intermountain Medical Center Main Campus South Parking Structure Field 4"
                    )
                ],
                pickupGameId: UUID(),
                teamId: teamId,
                notificationType: "team_event_location_changed"
            )
        )
        if let notice = FanGeoTeamEventNoticeBuilder.make(for: longTeam, languageCode: "en") {
            expect(longTeam.title(languageCode: "en") == "Practice Updated", "15 event-type title")
            expect(!longTeam.title(languageCode: "en").contains("East Ridge"), "15 long Team is not the title")
            expect(notice.identityRows.isEmpty, "16 no duplicate Game row")
            expect(
                notice.changeRows.first(where: { $0.kind == .location })?
                    .displayValue(languageCode: "en")
                    .contains("→") == true,
                "17 long location arrow"
            )
        } else {
            expect(false, "15-17 long wrap notice")
        }

        expect(createdPractice.destination == .scheduleActivity, "18 Inbox destination schedule")
        expect(createdPractice.context.teamId == teamId, "18 team_id present")
        expect(createdPractice.context.pickupGameId != nil, "18 event id present")
        expect(oppChanged.destination == .scheduleActivity, "19 APNs/Inbox same destination")
        expect(
            FanGeoActionCenterTeamNotificationPresentation.isJoinRequestDecision("join_request_approved"),
            "22 join decisions unchanged"
        )
        expect(
            L10n.t("action_center_label_team", languageCode: "en") == "Team:",
            "24 Team label key"
        )
        expect(
            L10n.t("action_center_label_game", languageCode: "en") == "Game:",
            "24 Game label key"
        )
        if let notice = FanGeoTeamEventNoticeBuilder.make(for: teamTimeItem, languageCode: "en") {
            let spoken = notice.accessibilityLabel(languageCode: "en")
            expect(spoken.contains("Practice Updated"), "25 a11y title")
            expect(
                spoken.components(separatedBy: "Practice").count - 1 == 1,
                "25 a11y does not repeat Practice"
            )
            expect(!spoken.lowercased().contains("team:"), "25 a11y no Team: label on updates")
            expect(!spoken.lowercased().contains("game:"), "25 a11y no Game: label for generic")
        }
        expect(
            pickupNoTeam.title(languageCode: "en") == "Jonathan updated the time",
            "26 non-Team card unchanged"
        )
        expect(
            !FanGeoTeamEventNoticeBuilder.isScheduleEventNotice(for: pickupNoTeam),
            "26 pickup is not Team event notice"
        )
        expect(
            !FanGeoTeamEventNoticeBuilder.isScheduleEventNotice(for: adminOn),
            "26 membership is not Team event notice"
        )

        let genericLeague = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):generic-league",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["x"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "JT",
                eventTitle: "League Game",
                eventTypeLabel: "league_game",
                changeDetails: [
                    FanGeoActionChangeDetail(
                        labelKey: "action_center_change_time",
                        oldValue: "6:00 PM",
                        newValue: "7:00 PM"
                    )
                ],
                teamId: teamId,
                notificationType: "team_event_time_changed"
            )
        )
        expect(genericLeague.title(languageCode: "en") == "League Game Updated", "7b generic league title")
        expect(
            FanGeoTeamEventNoticeBuilder.make(for: genericLeague, languageCode: "en")?.omitsGameRow == true,
            "7b generic League Game has no Game row"
        )

        let morningCustom = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):morning",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["x"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "ER basketball",
                eventTitle: "Morning Practice",
                eventTypeLabel: "practice",
                changeDetails: [
                    FanGeoActionChangeDetail(
                        labelKey: "action_center_change_location",
                        oldValue: "Gym A",
                        newValue: "Gym B"
                    )
                ],
                teamId: teamId,
                notificationType: "team_event_location_changed"
            )
        )
        let eveningCustom = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):evening",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["x"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "ER basketball",
                eventTitle: "Evening Practice",
                eventTypeLabel: "practice",
                changeDetails: [
                    FanGeoActionChangeDetail(
                        labelKey: "action_center_change_location",
                        oldValue: "Gym A",
                        newValue: "Gym C"
                    )
                ],
                teamId: teamId,
                notificationType: "team_event_location_changed"
            )
        )
        if let morningNotice = FanGeoTeamEventNoticeBuilder.make(for: morningCustom, languageCode: "en"),
           let eveningNotice = FanGeoTeamEventNoticeBuilder.make(for: eveningCustom, languageCode: "en") {
            expect(
                morningNotice.supportingRows.contains(where: { $0.kind == .title && $0.value == "Morning Practice" }),
                "two custom morning"
            )
            expect(
                eveningNotice.supportingRows.contains(where: { $0.kind == .title && $0.value == "Evening Practice" }),
                "two custom evening"
            )
            expect(
                morningNotice.supportingRows.contains(where: { $0.value == "Morning Practice" })
                    && eveningNotice.supportingRows.contains(where: { $0.value == "Evening Practice" }),
                "two custom Practices stay distinguishable"
            )
        } else {
            expect(false, "two custom Practice notices")
        }

        let dupLocation = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):dup-loc",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["x"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "IMC Team",
                eventTitle: "Practice",
                eventTypeLabel: "practice",
                locationLabel: "Draper, UT 84020, Draper, UT 84020",
                changeDetails: [
                    FanGeoActionChangeDetail(
                        labelKey: "action_center_change_location",
                        oldValue: "Draper, UT 84020, Draper, UT 84020",
                        newValue: "Draper, UT 84020, Draper, UT 84020"
                    )
                ],
                teamId: teamId,
                notificationType: "team_event_location_changed"
            )
        )
        if let notice = FanGeoTeamEventNoticeBuilder.make(for: dupLocation, languageCode: "en") {
            let line = notice.changeRows.first(where: { $0.kind == .location })?
                .displayValue(languageCode: "en") ?? ""
            expect(line == "Draper, UT 84020", "duplicate location fragments collapse")
            expect(!line.contains("Draper, UT 84020, Draper"), "collapsed location is not doubled")
        } else {
            expect(false, "duplicate location notice")
        }

        expect(
            !FanGeoActionCenterTeamNotificationPresentation.showsTimestampStatusDot(
                for: teamTimeItem,
                isUnread: true
            ),
            "unread Team event has no status dot"
        )
        expect(
            !FanGeoActionCenterTeamNotificationPresentation.showsTimestampStatusDot(
                for: teamTimeItem,
                isUnread: false
            ),
            "read Team event has no Team-color/yellow timestamp dot"
        )
        expect(
            !FanGeoActionCenterTeamNotificationPresentation.showsTimestampStatusDot(
                for: pickupNoTeam,
                isUnread: true
            ),
            "unread Pickup never stacks a second timestamp dot"
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.showsTimestampStatusDot(
                for: pickupNoTeam,
                isUnread: false
            ),
            "read Pickup keeps existing timestamp status dot"
        )
        expect(
            FanGeoActionCenterCopy.relativeTimestampLabel(for: teamTimeItem, languageCode: "en") != nil,
            "timestamp still renders"
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.headerBadgeText(
                for: removed,
                languageCode: "en"
            ).hasPrefix("TEAM"),
            "membership header stays TEAM · name"
        )
        expect(
            !FanGeoTeamEventNoticeBuilder.isScheduleEventNotice(for: removed),
            "membership is unchanged and has no Game row"
        )
        expect(
            L10n.t("action_center_badge_event_created", languageCode: "en") == "EVENT CREATED",
            "EVENT CREATED localizes"
        )
        expect(
            String(
                format: L10n.t("action_center_team_notif_changed_format", languageCode: "en"),
                locale: Locale(identifier: "en"),
                "Practice"
            ) == "Practice changed",
            "changed format localizes"
        )
        expect(
            L10n.t("action_center_team_event_identity_format", languageCode: "en")
                .contains("%@"),
            "identity format localizes"
        )
        expect(
            FanGeoTeamEventNoticeBuilder.secondaryGameIdentity(
                teamName: "IMC Team",
                customTitle: "IMC Team · Practice changed",
                gameFormat: "practice",
                opponent: nil,
                matchupLabel: nil,
                languageCode: "en"
            ) == nil,
            "APNs headline is not a custom Game title"
        )
        if let spokenCustom = FanGeoTeamEventNoticeBuilder.make(for: morningCustom, languageCode: "en")?
            .accessibilityLabel(languageCode: "en") {
            expect(spokenCustom.contains("Practice Updated"), "custom a11y title is event type")
            expect(!spokenCustom.contains("ER basketball · Morning Practice"), "custom a11y does not use Team · title")
        }

        let endOnly = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):end-only",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["x"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "JT",
                eventTypeLabel: "league_game",
                eventStartAt: PickupGameModels.parseSupabaseTimestamptz("2026-08-20T00:00:00+00:00"),
                changeDetails: [
                    FanGeoActionChangeDetail(
                        labelKey: "action_center_change_end_time",
                        oldValue: "2026-08-20T01:30:00+00:00",
                        newValue: "2026-08-20T02:00:00+00:00"
                    )
                ],
                teamId: teamId,
                notificationType: "time_changed"
            )
        )
        if let notice = FanGeoTeamEventNoticeBuilder.make(for: endOnly, languageCode: "en") {
            expect(
                notice.changeRows.contains(where: {
                    $0.kind == .time && $0.displayValue(languageCode: "en").contains("→")
                }),
                "4 end-time range old → new"
            )
        } else {
            expect(false, "end-only notice")
        }

        let titleChanged = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):title",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["x"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "ER basketball",
                eventTitle: "Evening Practice",
                eventTypeLabel: "practice",
                changeDetails: [
                    FanGeoActionChangeDetail(
                        labelKey: "action_center_change_title",
                        oldValue: "Morning Practice",
                        newValue: "Evening Practice"
                    )
                ],
                teamId: teamId,
                notificationType: "schedule_change"
            )
        )
        expect(titleChanged.title(languageCode: "en") == "Practice Updated", "title change headline")
        if let notice = FanGeoTeamEventNoticeBuilder.make(for: titleChanged, languageCode: "en") {
            expect(
                notice.changeRows.contains(where: {
                    $0.kind == .title && $0.displayValue(languageCode: "en").contains("→")
                }),
                "title old → new"
            )
        } else {
            expect(false, "title change notice")
        }

        let typeChanged = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):type",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["x"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "JT",
                eventTypeLabel: "scrimmage",
                changeDetails: [
                    FanGeoActionChangeDetail(
                        labelKey: "action_center_change_event_type",
                        oldValue: "practice",
                        newValue: "scrimmage"
                    )
                ],
                teamId: teamId,
                notificationType: "schedule_change"
            )
        )
        expect(typeChanged.title(languageCode: "en") == "Scrimmage Updated", "event type headline uses new type")
        if let notice = FanGeoTeamEventNoticeBuilder.make(for: typeChanged, languageCode: "en") {
            expect(
                notice.changeRows.contains(where: {
                    $0.kind == .eventType && $0.displayValue(languageCode: "en").contains("→")
                }),
                "event type old → new"
            )
        } else {
            expect(false, "event type notice")
        }

        let statusChanged = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):status",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["x"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "JT",
                eventTypeLabel: "league_game",
                changeDetails: [
                    FanGeoActionChangeDetail(
                        labelKey: "action_center_change_status",
                        oldValue: "scheduled",
                        newValue: "cancelled"
                    )
                ],
                teamId: teamId,
                notificationType: "schedule_change"
            )
        )
        if let notice = FanGeoTeamEventNoticeBuilder.make(for: statusChanged, languageCode: "en") {
            expect(
                notice.changeRows.contains(where: {
                    $0.kind == .status && $0.displayValue(languageCode: "en").contains("→")
                }),
                "status old → new when surfaced"
            )
        } else {
            expect(false, "status notice")
        }

        let visibilityChanged = FanGeoActionItem(
            id: "pickup_update:\(UUID().uuidString.lowercased()):vis",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["x"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "JT",
                eventTypeLabel: "practice",
                changeDetails: [
                    FanGeoActionChangeDetail(
                        labelKey: "action_center_change_visibility",
                        oldValue: "true",
                        newValue: "false"
                    )
                ],
                teamId: teamId,
                notificationType: "schedule_change"
            )
        )
        if let notice = FanGeoTeamEventNoticeBuilder.make(for: visibilityChanged, languageCode: "en") {
            expect(
                notice.changeRows.contains(where: {
                    $0.kind == .visibility && $0.displayValue(languageCode: "en").contains("→")
                }),
                "visibility old → new when payload has both"
            )
        } else {
            expect(false, "visibility notice")
        }

        let startSplit = FanGeoTeamEventChangeProjection.details(
            beforeStartRaw: "2026-08-17T18:00:00+00:00",
            afterStartRaw: "2026-08-17T20:00:00+00:00",
            beforeEndRaw: nil,
            afterEndRaw: nil,
            beforeLocation: nil,
            afterLocation: nil,
            beforeOpponent: nil,
            afterOpponent: nil,
            beforeStatus: nil,
            afterStatus: nil,
            beforeTitle: nil,
            afterTitle: nil,
            beforeEventType: nil,
            afterEventType: nil,
            beforeVisibility: nil,
            afterVisibility: nil,
            changeKinds: ["start"]
        )
        expect(
            startSplit.contains(where: { $0.labelKey == "action_center_change_time" })
                && !startSplit.contains(where: { $0.labelKey == "action_center_change_date" }),
            "same-day start diff is Time only"
        )
        let dateSplit = FanGeoTeamEventChangeProjection.details(
            beforeStartRaw: "2026-08-14T18:00:00+00:00",
            afterStartRaw: "2026-08-15T18:00:00+00:00",
            beforeEndRaw: nil,
            afterEndRaw: nil,
            beforeLocation: nil,
            afterLocation: nil,
            beforeOpponent: nil,
            afterOpponent: nil,
            beforeStatus: nil,
            afterStatus: nil,
            beforeTitle: nil,
            afterTitle: nil,
            beforeEventType: nil,
            afterEventType: nil,
            beforeVisibility: nil,
            afterVisibility: nil,
            changeKinds: ["start"]
        )
        expect(
            dateSplit.contains(where: { $0.labelKey == "action_center_change_date" })
                && !dateSplit.contains(where: { $0.labelKey == "action_center_change_time" }),
            "same-clock start diff is Date only"
        )
        let bothSplit = FanGeoTeamEventChangeProjection.details(
            beforeStartRaw: "2026-08-14T18:00:00+00:00",
            afterStartRaw: "2026-08-15T20:00:00+00:00",
            beforeEndRaw: nil,
            afterEndRaw: nil,
            beforeLocation: nil,
            afterLocation: nil,
            beforeOpponent: nil,
            afterOpponent: nil,
            beforeStatus: nil,
            afterStatus: nil,
            beforeTitle: nil,
            afterTitle: nil,
            beforeEventType: nil,
            afterEventType: nil,
            beforeVisibility: nil,
            afterVisibility: nil,
            changeKinds: ["start"]
        )
        expect(
            bothSplit.contains(where: { $0.labelKey == "action_center_change_date" })
                && bothSplit.contains(where: { $0.labelKey == "action_center_change_time" }),
            "day and clock diffs are Date + Time"
        )
        expect(
            L10n.t("action_center_label_title", languageCode: "en").isEmpty == false,
            "Title label localizes"
        )
        expect(
            L10n.t("action_center_label_event_type", languageCode: "en").isEmpty == false,
            "Event Type label localizes"
        )

        let inboxPresentationKeys = [
            "action_center_pickup_invite_title",
            "action_center_pickup_invite_subtitle",
            "action_center_invited_to_team_format",
            "action_center_team_invite_title_one",
            "action_center_team_invite_title_many",
            "action_center_team_invite_subtitle",
            "action_center_event_changed_format",
            "action_center_event_cancelled_format",
            "action_center_rate_pickup_title",
            "action_center_rate_organizer_title",
            "going_action_needed_rsvp_format",
            "going_action_needed_rsvp_tomorrow_format",
            "action_center_team_notif_announcement",
            "action_center_team_notif_removed_title",
            "action_center_team_notif_role_title",
            "action_center_wants_to_join_format",
            "action_center_join_approval_title_one",
            "action_center_join_approval_title_many",
            "action_center_join_decision_title",
            "action_center_change_date",
            "action_center_change_opponent",
            "action_center_change_status",
        ]
        for key in inboxPresentationKeys {
            let value = L10n.t(key, languageCode: "en")
            expect(value != key, "inbox \(key) is not the raw key")
            expect(!value.isEmpty, "inbox \(key) is non-empty")
            expect(
                FanGeoLocalizationRegressionSelfTests.looksLikeUnresolvedKey(value) == false,
                "inbox \(key) is not unresolved-shaped"
            )
        }

        let teamInvite = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitations: [
                    FanGeoActionTeamInviteInput(
                        invitationId: UUID(),
                        teamId: teamId,
                        teamName: "JT",
                        sport: "Soccer",
                        inviterDisplayName: "Jonathan",
                        createdAt: Date()
                    )
                ],
                isSignedInForSocial: true
            )
        ).actionNeededItems.first(where: { $0.kind == .teamInvitation })
        let teamInviteTitle = teamInvite?.title(languageCode: "en") ?? ""
        expect(teamInviteTitle.contains("JT"), "Team Invite interpolates team name")
        expect(
            FanGeoLocalizationRegressionSelfTests.looksLikeUnresolvedKey(teamInviteTitle) == false,
            "Team Invite title is localized"
        )

        let ratingItem = FanGeoActionItem(
            id: "rate:\(gameId.uuidString.lowercased())",
            kind: .pendingPickupRating,
            titleKey: "action_center_rate_pickup_title",
            subtitleKey: "pickup_rating_prompt_subtitle_format",
            subtitleFormatArgs: ["Jonathan"],
            destination: .goingPendingRating
        )
        expect(
            FanGeoLocalizationRegressionSelfTests.looksLikeUnresolvedKey(
                ratingItem.title(languageCode: "en")
            ) == false,
            "Rating title is localized"
        )

        let rsvpCopy = String(
            format: L10n.t("going_action_needed_rsvp_format", languageCode: "en"),
            locale: Locale(identifier: "en"),
            "JT League Game"
        )
        expect(rsvpCopy.contains("JT League Game"), "RSVP interpolates event name")
        expect(
            FanGeoLocalizationRegressionSelfTests.looksLikeUnresolvedKey(rsvpCopy) == false,
            "RSVP copy is localized"
        )

        let announcementItem = FanGeoActionItem(
            id: "announcement_inbox:\(teamId.uuidString.lowercased())",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["Team updated"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .teamsHome,
            context: FanGeoActionContext(
                teamName: "JT",
                notificationType: "team_announcement"
            )
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.title(
                for: announcementItem,
                languageCode: "en"
            ) != "action_center_team_notif_announcement",
            "Announcement title is not the raw key"
        )

        let joinRequestTitle = String(
            format: L10n.t("action_center_wants_to_join_format", languageCode: "en"),
            locale: Locale(identifier: "en"),
            "Emma"
        )
        expect(joinRequestTitle.contains("Emma"), "Join request interpolates requester")
        expect(
            FanGeoLocalizationRegressionSelfTests.looksLikeUnresolvedKey(joinRequestTitle) == false,
            "Join request title is localized"
        )

        for item in mixed.items {
            let title = item.title(languageCode: "en")
            let subtitle = item.subtitle(languageCode: "en")
            expect(
                FanGeoLocalizationRegressionSelfTests.looksLikeUnresolvedKey(title) == false,
                "mixed \(item.kind) title is localized"
            )
            expect(
                FanGeoLocalizationRegressionSelfTests.looksLikeUnresolvedKey(subtitle) == false,
                "mixed \(item.kind) subtitle is localized"
            )
        }

        let screenshotStart = PickupGameModels.parseSupabaseTimestamptz("2026-08-18T05:27:00+00:00")
        let screenshotIMC = FanGeoActionItem(
            id: "pickup_update:imc-screenshot",
            kind: .scheduleChange,
            titleKey: "action_center_event_changed_format",
            titleFormatArgs: ["IMC Team · Practice"],
            subtitleKey: "action_center_schedule_change_subtitle",
            destination: .scheduleActivity,
            timestamp: screenshotStart,
            context: FanGeoActionContext(
                eventTitle: "IMC Team · Practice",
                eventTypeLabel: "Practice",
                locationLabel: "Draper, UT 84020",
                eventStartAt: screenshotStart,
                changeDetails: [],
                pickupGameId: UUID(),
                notificationType: nil
            )
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.usesTeamChrome(for: screenshotIMC),
            "screenshot live row recovers Team chrome from identity title"
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(for: screenshotIMC) != .personAvatar,
            "screenshot live row does not use player avatar as leading artwork"
        )
        let screenshotWithOwner = FanGeoTeamEventAffectedPlayerResolver.applyingAccountOwner(
            to: screenshotIMC,
            displayName: "FanGeo",
            avatarURL: "https://example.test/fangeo.jpg",
            avatarThumbnailURL: nil
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(for: screenshotWithOwner) != .personAvatar,
            "screenshot Practice Updated with owner avatar still does not lead with the player"
        )
        expect(
            screenshotIMC.title(languageCode: "en") == "Practice Updated",
            "screenshot title is Practice Updated"
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.summaryLine(
                for: screenshotIMC,
                languageCode: "en"
            ) == nil,
            "screenshot does not use legacy summaryLine"
        )
        if let notice = FanGeoTeamEventNoticeBuilder.make(for: screenshotIMC, languageCode: "en") {
            expect(
                !notice.allRows.contains(where: {
                    $0.displayValue(languageCode: "en").localizedCaseInsensitiveContains(" at ")
                }),
                "screenshot notice has no combined date-at-time"
            )
            expect(
                notice.supportingRows.contains(where: { $0.kind == .date })
                    && notice.supportingRows.contains(where: { $0.kind == .time })
                    && notice.supportingRows.contains(where: { $0.kind == .location }),
                "screenshot shows Date + Time + Location without fabricating old values"
            )
        } else {
            expect(false, "screenshot live row uses Team-event notice path")
        }

        let missingBefore = FanGeoActionItem(
            id: "pickup_update:er-missing-before",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["ER basketball · Practice changed"],
            subtitleKey: "action_center_notification_title_passthrough_format",
            subtitleFormatArgs: ["Aug 14, 2026 at 8:14 AM"],
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                eventTitle: "ER basketball · Practice changed",
                eventTypeLabel: "practice",
                locationLabel: "Intermountain Medical Center Oncology Clinic, Salt Lake City, UT 84107",
                eventStartAt: PickupGameModels.parseSupabaseTimestamptz("2026-08-14T14:14:00+00:00"),
                changeDetails: FanGeoTeamEventChangeProjection.details(
                    beforeStartRaw: nil,
                    afterStartRaw: "2026-08-14T14:14:00+00:00",
                    beforeEndRaw: nil,
                    afterEndRaw: nil,
                    beforeLocation: nil,
                    afterLocation: "Intermountain Medical Center Oncology Clinic, Salt Lake City, UT 84107",
                    beforeOpponent: nil,
                    afterOpponent: nil,
                    beforeStatus: nil,
                    afterStatus: nil,
                    beforeTitle: nil,
                    afterTitle: nil,
                    beforeEventType: nil,
                    afterEventType: nil,
                    beforeVisibility: nil,
                    afterVisibility: nil,
                    changeKinds: ["start"]
                ),
                pickupGameId: UUID(),
                notificationType: "time_changed"
            )
        )
        expect(
            missingBefore.title(languageCode: "en") == "Practice Updated",
            "missing before_* still uses event-type title"
        )
        if let notice = FanGeoTeamEventNoticeBuilder.make(for: missingBefore, languageCode: "en") {
            expect(
                notice.changeRows.contains(where: { $0.kind == .time }),
                "missing before_* still names Time as the change"
            )
            expect(
                !notice.changeRows.contains(where: {
                    $0.displayValue(languageCode: "en").contains("→")
                }),
                "missing before_* does not invent an old value"
            )
            expect(
                FanGeoActionCenterTeamNotificationPresentation.summaryLine(
                    for: missingBefore,
                    languageCode: "en"
                ) == nil,
                "missing before_* has no legacy summaryLine"
            )
        } else {
            expect(false, "missing before_* uses notice path")
        }

        let cubsBadge = "https://www.thesportsdb.com/images/media/team/badge/cubs.png"
        let cardsBadge = "https://www.thesportsdb.com/images/media/team/badge/cardinals.png"
        let scoreSnapshot = FanGeoProGameInboxSnapshot(
            kind: .score,
            matchID: "mlb-cubs-cardinals-2026-08-14",
            homeTeam: "Chicago Cubs",
            awayTeam: "St. Louis Cardinals",
            homeScore: 3,
            awayScore: 0,
            scoringTeam: "Chicago Cubs",
            league: "MLB",
            sport: "Baseball",
            matchStatus: "LIVE",
            clock: nil,
            homeBadgeURL: cubsBadge,
            awayBadgeURL: cardsBadge,
            homeProviderId: "135269",
            awayProviderId: "135272"
        )
        let scoreItem = FanGeoActionItem(
            id: scoreSnapshot.dedupeKey,
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["Chicago Cubs scored"],
            subtitleKey: "action_center_notification_title_passthrough_format",
            subtitleFormatArgs: ["St. Louis Cardinals 0 - 3 Chicago Cubs"],
            destination: .scheduleActivity,
            timestamp: Date(),
            context: FanGeoActionContext(
                notificationType: "pro_game_score",
                proGameMatchId: scoreSnapshot.matchID,
                proGameSnapshot: scoreSnapshot
            )
        )
        expect(scoreSnapshot.homeTeam == "Chicago Cubs", "score-update snapshot has home team")
        expect(scoreSnapshot.awayTeam == "St. Louis Cardinals", "score-update snapshot has away team")
        expect(scoreSnapshot.homeScore == 3 && scoreSnapshot.awayScore == 0, "score-update snapshot has both scores")
        expect(
            FanGeoActionCenterTeamNotificationPresentation.headerBadgeText(
                for: scoreItem,
                languageCode: "en"
            ) == "SCORE UPDATE",
            "score-update badge is SCORE UPDATE"
        )
        expect(
            FanGeoProGameInboxPresentation.footerLine(for: scoreSnapshot, languageCode: "en")
                == "Chicago Cubs scored",
            "score-update names the scoring team when payload identifies it"
        )
        expect(
            FanGeoProGameInboxPresentation.contextLine(for: scoreSnapshot, languageCode: "en") == "MLB · LIVE",
            "score-update shows league and LIVE"
        )
        expect(
            !FanGeoActionCenterTeamNotificationPresentation.usesTeamChrome(for: scoreItem),
            "pro-game score card does not use Team event chrome"
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(for: scoreItem) == .kindGlyph,
            "pro-game score card leading identity is unchanged"
        )
        expect(
            FanGeoProGameInboxPresentation.isProGame(scoreItem),
            "pro-game score card still uses the rich scoreboard path"
        )
        expect(
            FanGeoProGameInboxPresentation.usesGenericTitleRenderer(scoreItem) == false,
            "valid score snapshot never uses generic Final Score renderer"
        )
        let scoreRows = FanGeoProGameInboxPresentation.scoreboardRows(for: scoreSnapshot)
        expect(scoreRows.count == 2, "scoreboard has two team rows")
        expect(scoreRows[0].teamName == "St. Louis Cardinals" && scoreRows[0].score == 0, "score snapshot renders away name and score")
        expect(scoreRows[1].teamName == "Chicago Cubs" && scoreRows[1].score == 3, "score snapshot renders home name and score")
        expect(!scoreRows[0].isWinner && !scoreRows[1].isWinner, "live score update does not mark a winner")
        let scoreArt = FanGeoProGameInboxPresentation.artworkIdentities(for: scoreSnapshot)
        expect(scoreArt.away.badgeURL == cardsBadge && scoreArt.away.providerId == "135272", "away artwork identity is passed through")
        expect(scoreArt.home.badgeURL == cubsBadge && scoreArt.home.providerId == "135269", "home artwork identity is passed through")
        expect(
            FanGeoProGameInboxPresentation.scoreColumnMinWidth >= 28,
            "long team names keep a reserved trailing score column"
        )
        expect(scoreItem.context.proGameMatchId == scoreSnapshot.matchID, "score-update keeps pro-game deep link id")

        let unidentifiedScore = FanGeoProGameInboxSnapshot(
            kind: .score,
            matchID: scoreSnapshot.matchID,
            homeTeam: scoreSnapshot.homeTeam,
            awayTeam: scoreSnapshot.awayTeam,
            homeScore: 3,
            awayScore: 0,
            scoringTeam: "Unknown Club",
            league: "MLB",
            sport: "Baseball",
            matchStatus: "LIVE",
            clock: nil,
            homeBadgeURL: cubsBadge,
            awayBadgeURL: cardsBadge,
            homeProviderId: "135269",
            awayProviderId: "135272"
        )
        expect(unidentifiedScore.identifiedScoringTeam == nil, "non-matching scoring team is not guessed")
        expect(
            FanGeoProGameInboxPresentation.footerLine(for: unidentifiedScore, languageCode: "en")
                == "Score updated",
            "missing scoring-team identity shows Score updated"
        )
        expect(
            FanGeoProGameInboxPresentation.footerLine(
                for: FanGeoProGameInboxSnapshot(
                    kind: .score,
                    matchID: scoreSnapshot.matchID,
                    homeTeam: scoreSnapshot.homeTeam,
                    awayTeam: scoreSnapshot.awayTeam,
                    homeScore: 3,
                    awayScore: 0,
                    scoringTeam: nil,
                    league: "MLB",
                    sport: "Baseball",
                    matchStatus: "LIVE",
                    clock: nil,
                    homeBadgeURL: nil,
                    awayBadgeURL: nil,
                    homeProviderId: nil,
                    awayProviderId: nil
                ),
                languageCode: "en"
            ) == "Score updated",
            "nil scoring team is not inferred from title"
        )

        let finalSnapshot = FanGeoProGameInboxSnapshot(
            kind: .final,
            matchID: scoreSnapshot.matchID,
            homeTeam: "Chicago Cubs",
            awayTeam: "St. Louis Cardinals",
            homeScore: 3,
            awayScore: 0,
            scoringTeam: nil,
            league: "MLB",
            sport: "Baseball",
            matchStatus: "FT",
            clock: nil,
            homeBadgeURL: cubsBadge,
            awayBadgeURL: cardsBadge,
            homeProviderId: "135269",
            awayProviderId: "135272"
        )
        let finalItem = FanGeoActionItem(
            id: finalSnapshot.dedupeKey,
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["Final Score"],
            subtitleKey: "action_center_notification_title_passthrough_format",
            subtitleFormatArgs: ["St. Louis Cardinals 0 - 3 Chicago Cubs"],
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                notificationType: "pro_game_final",
                proGameMatchId: finalSnapshot.matchID,
                proGameSnapshot: finalSnapshot
            )
        )
        expect(finalSnapshot.homeTeam == "Chicago Cubs" && finalSnapshot.awayTeam == "St. Louis Cardinals", "final snapshot has both teams")
        expect(finalSnapshot.homeScore == 3 && finalSnapshot.awayScore == 0, "final snapshot has both scores")
        expect(finalSnapshot.winnerTeamName == "Chicago Cubs", "final winner is the higher score")
        expect(finalSnapshot.isWinner(.home) && !finalSnapshot.isWinner(.away), "final emphasizes the home winner only")
        expect(
            FanGeoActionCenterTeamNotificationPresentation.headerBadgeText(
                for: finalItem,
                languageCode: "en"
            ) == "FINAL",
            "final badge is FINAL"
        )
        expect(
            FanGeoProGameInboxPresentation.footerLine(for: finalSnapshot, languageCode: "en")
                == "Chicago Cubs won",
            "final footer names the winner"
        )
        expect(
            FanGeoProGameInboxPresentation.contextLine(for: finalSnapshot, languageCode: "en") == "MLB",
            "final context does not repeat FINAL"
        )
        expect(
            FanGeoProGameInboxPresentation.usesGenericTitleRenderer(finalItem) == false,
            "valid final snapshot never uses generic Final Score renderer"
        )
        let finalRows = FanGeoProGameInboxPresentation.scoreboardRows(for: finalSnapshot)
        expect(finalRows[0].score == 0 && finalRows[1].score == 3, "final snapshot renders both stored scores")
        expect(finalRows[1].isWinner && !finalRows[0].isWinner, "final emphasizes the winner scoreboard row")
        expect(
            !FanGeoProGameInboxPresentation.accessibilitySummary(for: finalSnapshot, languageCode: "en")
                .localizedCaseInsensitiveContains("FINAL FINAL"),
            "final spoken summary does not duplicate FINAL"
        )

        let drawSnapshot = FanGeoProGameInboxSnapshot(
            kind: .final,
            matchID: "epl-draw",
            homeTeam: "Arsenal",
            awayTeam: "Chelsea",
            homeScore: 1,
            awayScore: 1,
            scoringTeam: nil,
            league: "Premier League",
            sport: "Soccer",
            matchStatus: "FT",
            clock: nil,
            homeBadgeURL: nil,
            awayBadgeURL: nil,
            homeProviderId: nil,
            awayProviderId: nil
        )
        expect(drawSnapshot.finalOutcome == .draw, "equal final scores are a draw")
        expect(drawSnapshot.winnerTeamName == nil, "draw does not invent a winner")
        expect(
            FanGeoProGameInboxPresentation.footerLine(for: drawSnapshot, languageCode: "en") == "Draw",
            "tied final shows Draw"
        )

        let cubsArtwork = SportsIdentityArtworkResolver.resolveProGameTeam(
            teamName: "Chicago Cubs",
            badgeURL: cubsBadge,
            entityID: "135269",
            league: "MLB",
            source: "proGameInbox",
            diameter: FanGeoProGameInboxPresentation.artworkDiameter
        )
        expect(
            {
                if case .verifiedRemote(let url) = cubsArtwork.kind {
                    return url.absoluteString.contains("thesportsdb.com")
                }
                return false
            }(),
            "provider artwork is shown when badge URL is available"
        )
        expect(
            !SportsArtworkEnrichmentService.usesDirectTheSportsDBAPI,
            "pro-game inbox artwork does not call TheSportsDB from iOS"
        )

        let frozenPayload: [String: AnyCodableJSON] = [
            "match_id": .string("mlb-cubs-cardinals-2026-08-14"),
            "notification_type": .string("pro_game_score"),
            "home_team": .string("Chicago Cubs"),
            "away_team": .string("St. Louis Cardinals"),
            "home_score": .number(3),
            "away_score": .number(0),
            "scoring_team": .string("Chicago Cubs"),
            "league": .string("MLB"),
            "home_badge_url": .string(cubsBadge),
            "away_badge_url": .string(cardsBadge)
        ]
        let historical = FanGeoProGameInboxSnapshot.from(
            payload: frozenPayload,
            notificationType: "pro_game_score",
            sourceType: "pro_game_notification",
            sourceID: "mlb-cubs-cardinals-2026-08-14"
        )
        expect(historical?.homeScore == 3 && historical?.awayScore == 0, "historical snapshot keeps stored scores")
        expect(historical?.identifiedScoringTeam == "Chicago Cubs", "historical snapshot keeps scoring team")
        expect(
            FanGeoProGameInboxSnapshot.from(
                payload: nil,
                notificationType: nil,
                sourceType: nil,
                sourceID: nil
            ) == nil,
            "title-only historical rows are not reconstructed by text parsing"
        )
        expect(
            FanGeoProGameInboxSnapshot.from(
                userInfo: ["title": "Chicago Cubs scored", "body": "Final Score"],
                notificationType: nil
            ) == nil,
            "generic title/body is not parsed into a snapshot"
        )

        let nestedSnapshot = FanGeoProGameInboxSnapshot.from(
            payload: [
                "data": .object([
                    "homeTeam": .string("Chicago Cubs"),
                    "awayTeam": .string("St. Louis Cardinals"),
                    "homeScore": .number(3),
                    "awayScore": .number(0),
                    "matchId": .string("mlb-cubs-cardinals-2026-08-14"),
                    "homeBadgeURL": .string(cubsBadge),
                    "awayBadgeURL": .string(cardsBadge)
                ])
            ],
            notificationType: "pro_game_score",
            sourceType: "pro_game_notification",
            sourceID: nil
        )
        expect(nestedSnapshot?.homeTeam == "Chicago Cubs", "nested/camelCase payload still decodes home team")
        expect(nestedSnapshot?.awayScore == 0 && nestedSnapshot?.homeScore == 3, "nested/camelCase payload still decodes scores")
        expect(nestedSnapshot?.isRenderable == true, "nested structured payload is a rich scoreboard")

        let longNameSnapshot = FanGeoProGameInboxSnapshot(
            kind: .score,
            matchID: scoreSnapshot.matchID,
            homeTeam: "A Very Long Professional Baseball Club Name That Must Truncate",
            awayTeam: "Another Excessively Long Visiting Club Name",
            homeScore: 4,
            awayScore: 3,
            scoringTeam: nil,
            league: "MLB",
            sport: "Baseball",
            matchStatus: "LIVE",
            clock: nil,
            homeBadgeURL: cubsBadge,
            awayBadgeURL: cardsBadge,
            homeProviderId: "135269",
            awayProviderId: "135272"
        )
        let longRows = FanGeoProGameInboxPresentation.scoreboardRows(for: longNameSnapshot)
        expect(longRows[0].score == 3 && longRows[1].score == 4, "long team names keep stored scores visible")
        expect(
            FanGeoProGameInboxPresentation.scoreColumnMinWidth >= 28,
            "score column stays reserved so long names cannot push scores off-screen"
        )

        let laterLiveScoresDoNotMutate = FanGeoProGameInboxSnapshot(
            kind: .score,
            matchID: historical?.matchID ?? scoreSnapshot.matchID,
            homeTeam: historical?.homeTeam ?? "Chicago Cubs",
            awayTeam: historical?.awayTeam ?? "St. Louis Cardinals",
            homeScore: 5,
            awayScore: 2,
            scoringTeam: "Chicago Cubs",
            league: "MLB",
            sport: "Baseball",
            matchStatus: "LIVE",
            clock: nil,
            homeBadgeURL: cubsBadge,
            awayBadgeURL: cardsBadge,
            homeProviderId: "135269",
            awayProviderId: "135272"
        )
        expect(historical?.homeScore == 3 && historical?.awayScore == 0, "historical snapshot remains 3-0")
        expect(laterLiveScoresDoNotMutate.homeScore == 5, "later live state is a different snapshot object")
        expect(historical?.homeScore != laterLiveScoresDoNotMutate.homeScore, "inbox card does not read current live_matches")

        expect(
            FanGeoActionCenterTeamNotificationPresentation.headerBadgeText(
                for: emmaPractice,
                languageCode: "en"
            ) == "NEW PRACTICE",
            "Team event NEW PRACTICE badge is unchanged"
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.usesTeamChrome(for: emmaPractice),
            "Team event chrome is unchanged by pro-game cards"
        )

        let coldUser = UUID()
        FanGeoActionCenterLocalVisibility.savePermanentDismissedKeys([], userId: coldUser)
        FanGeoActionCenterLocalVisibility.clearPendingSnooze(userId: coldUser)
        let inviteA = UUID()
        let inviteB = UUID()
        let inviteC = UUID()
        let inviteD = UUID()
        func coldInvite(_ id: UUID, name: String) -> FanGeoActionTeamInviteInput {
            FanGeoActionTeamInviteInput(
                invitationId: id,
                teamId: UUID(),
                teamName: name,
                sport: "Soccer",
                inviterDisplayName: "Pat",
                createdAt: Date()
            )
        }
        let threeInvites = [
            coldInvite(inviteA, name: "Alpha"),
            coldInvite(inviteB, name: "Bravo"),
            coldInvite(inviteC, name: "Charlie")
        ]
        let keyA = FanGeoActionCenterActionKey.teamInvite(inviteA)
        let keyB = FanGeoActionCenterActionKey.teamInvite(inviteB)
        let keyC = FanGeoActionCenterActionKey.teamInvite(inviteC)
        let keyD = FanGeoActionCenterActionKey.teamInvite(inviteD)
        let now = Date()

        let visible3 = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitations: threeInvites,
                isSignedInForSocial: true
            )
        )
        expect(visible3.actionNeededItems.count == 3, "1 Action Needed starts with 3 rows")
        expect(visible3.actionCenterBadgeCount == 3, "1 badge matches 3 visible rows")

        let afterOneSnoozeMap = FanGeoActionCenterLocalVisibility.applyingPendingSnooze(
            keys: [keyA],
            to: [:],
            now: now
        )
        FanGeoActionCenterLocalVisibility.savePendingSnooze(afterOneSnoozeMap, userId: coldUser, now: now)
        let snoozeOneKeys = FanGeoActionCenterLocalVisibility.pendingSnoozeKeysForProjection(
            inMemory: [:],
            userId: coldUser,
            now: now
        )
        let visible2 = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitations: threeInvites,
                isSignedInForSocial: true,
                sessionSnoozedPendingKeys: snoozeOneKeys
            )
        )
        expect(visible2.actionNeededItems.count == 2, "2 dismiss one → 2 visible")
        expect(visible2.actionNeededItems.contains { $0.id == keyA } == false, "2 dismissed row is hidden")
        expect(visible2.actionCenterBadgeCount == 2, "2 badge matches visible Action Needed after snooze")

        let rehydratedOne = FanGeoActionCenterLocalVisibility.pendingSnoozeKeysForProjection(
            inMemory: [:],
            userId: coldUser,
            now: now
        )
        let afterRelaunchOne = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitations: threeInvites,
                isSignedInForSocial: true,
                sessionSnoozedPendingKeys: rehydratedOne
            )
        )
        expect(afterRelaunchOne.actionNeededItems.count == 2, "3 terminate/rehydrate still 2 immediately")
        expect(
            FanGeoInboxChrome.actionNeededTabCount(items: afterRelaunchOne.actionNeededItems) == 2,
            "3 tab count matches immediately visible projection"
        )

        let afterAllSnoozeMap = FanGeoActionCenterLocalVisibility.applyingPendingSnooze(
            keys: [keyA, keyB, keyC],
            to: [:],
            now: now
        )
        FanGeoActionCenterLocalVisibility.savePendingSnooze(afterAllSnoozeMap, userId: coldUser, now: now)
        let caughtUp = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitations: threeInvites,
                isSignedInForSocial: true,
                sessionSnoozedPendingKeys: FanGeoActionCenterLocalVisibility.pendingSnoozeKeysForProjection(
                    inMemory: [:],
                    userId: coldUser,
                    now: now
                )
            )
        )
        expect(caughtUp.actionNeededItems.isEmpty, "4 dismiss all → caught-up list")
        expect(caughtUp.actionCenterBadgeCount == 0, "4 caught-up list has zero Inbox/bell badge")

        let coldCaughtUp = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitations: threeInvites,
                isSignedInForSocial: true,
                sessionSnoozedPendingKeys: FanGeoActionCenterLocalVisibility.pendingSnoozeKeysForProjection(
                    inMemory: [:],
                    userId: coldUser,
                    now: now
                )
            )
        )
        expect(coldCaughtUp.actionNeededItems.isEmpty, "5 terminate/rehydrate still caught-up immediately")
        expect(
            FanGeoInboxChrome.actionNeededTabCount(items: coldCaughtUp.actionNeededItems) == 0,
            "8 immediately visible projection drives the Action Needed tab count"
        )

        let remoteSameItems = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitations: threeInvites,
                isSignedInForSocial: true,
                sessionSnoozedPendingKeys: FanGeoActionCenterLocalVisibility.pendingSnoozeKeysForProjection(
                    inMemory: [:],
                    userId: coldUser,
                    now: now
                )
            )
        )
        expect(remoteSameItems.actionNeededItems.isEmpty, "6 remote reconcile with same dismissed items stays hidden")

        let withNewItem = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitations: threeInvites + [coldInvite(inviteD, name: "Delta")],
                isSignedInForSocial: true,
                sessionSnoozedPendingKeys: FanGeoActionCenterLocalVisibility.pendingSnoozeKeysForProjection(
                    inMemory: [:],
                    userId: coldUser,
                    now: now
                )
            )
        )
        expect(
            withNewItem.actionNeededItems.map(\.id) == [keyD],
            "7 genuinely new Action Needed item appears"
        )

        let secondCold = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitations: threeInvites,
                isSignedInForSocial: true,
                sessionSnoozedPendingKeys: FanGeoActionCenterLocalVisibility.pendingSnoozeKeysForProjection(
                    inMemory: [:],
                    userId: coldUser,
                    now: now
                )
            )
        )
        expect(
            coldCaughtUp.actionNeededItems.map(\.id) == secondCold.actionNeededItems.map(\.id),
            "10 repeated cold-start projection is deterministic"
        )

        let notificationDuringSnooze = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitations: threeInvites,
                isSignedInForSocial: true,
                sessionSnoozedPendingKeys: FanGeoActionCenterLocalVisibility.pendingSnoozeKeysForProjection(
                    inMemory: [:],
                    userId: coldUser,
                    now: now
                ),
                persistedNotifications: [
                    FanGeoActionItem(
                        id: "poke:cold-launch",
                        kind: .poke,
                        titleKey: "action_center_notification_title_passthrough_format",
                        titleFormatArgs: ["Poke"],
                        subtitleKey: "action_center_notification_subtitle_default",
                        destination: .accountPokes,
                        timestamp: now
                    )
                ],
                unreadNotificationIds: ["poke:cold-launch"]
            )
        )
        expect(
            notificationDuringSnooze.notificationItems.count == 1
                && notificationDuringSnooze.actionNeededItems.isEmpty,
            "Notifications remain visible while Action Needed stays caught-up"
        )

        let expiredSnooze = FanGeoActionCenterLocalVisibility.pendingSnoozeKeysForProjection(
            inMemory: [keyA: now.addingTimeInterval(-(FanGeoActionCenterLocalVisibility.pendingSnoozeTTL + 1))],
            userId: nil,
            now: now
        )
        expect(expiredSnooze.isEmpty, "expired local snooze does not hide a still-pending item")

        let ratingId = UUID()
        let ratingKey = FanGeoActionCenterActionKey.rateGame(ratingId)
        FanGeoActionCenterLocalVisibility.savePermanentDismissedKeys([ratingKey], userId: coldUser)
        let ratingCold = FanGeoActionCenterProjection.snapshot(
            from: .init(
                pendingRatings: [
                    FanGeoActionPendingRatingInput(
                        pickupGameId: ratingId,
                        organizerUserId: UUID(),
                        organizerName: "Pat",
                        organizerAvatarURL: nil,
                        gameTitle: "Pickup",
                        teamName: nil,
                        eventTypeLabel: nil,
                        matchupLabel: nil,
                        startAt: now
                    )
                ],
                isSignedInForSocial: true,
                dismissedActionKeys: FanGeoActionCenterLocalVisibility.dismissedKeysForProjection(
                    inMemory: [],
                    userId: coldUser
                )
            )
        )
        expect(ratingCold.actionNeededItems.isEmpty, "permanent Action Needed hide applies on first cold projection")

        let individualOnlySnooze = [keyA: now]
        FanGeoActionCenterLocalVisibility.savePendingSnooze(individualOnlySnooze, userId: coldUser, now: now)
        let countFallbackFirstPaint = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitationCount: 3,
                isSignedInForSocial: true,
                sessionSnoozedPendingKeys: FanGeoActionCenterLocalVisibility.pendingSnoozeKeysForProjection(
                    inMemory: [:],
                    userId: coldUser,
                    now: now
                )
            )
        )
        expect(
            countFallbackFirstPaint.actionNeededItems.isEmpty
                && countFallbackFirstPaint.actionCenterBadgeCount == 0,
            "5/9 count-fallback aggregate is hidden on first snapshot without remote rows"
        )
        expect(
            FanGeoActionCenterProjection.snapshot(
                from: .init(
                    teamInvitationCount: 3,
                    isSignedInForSocial: true,
                    sessionSnoozedPendingKeys: FanGeoActionCenterLocalVisibility.pendingSnoozeKeysForProjection(
                        inMemory: [:],
                        userId: coldUser,
                        now: now
                    )
                )
            ).actionNeededItems.isEmpty,
            "6 airplane-mode equivalent still hides snoozed aggregate"
        )

        let otherUser = UUID()
        FanGeoActionCenterLocalVisibility.clearPendingSnooze(userId: otherUser)
        let leaked = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitations: threeInvites,
                isSignedInForSocial: true,
                sessionSnoozedPendingKeys: FanGeoActionCenterLocalVisibility.pendingSnoozeKeysForProjection(
                    inMemory: [:],
                    userId: otherUser,
                    now: now
                )
            )
        )
        expect(leaked.actionNeededItems.count == 3, "10/11 wrong userId does not inherit another user's snooze")

        let unreadOnly = FanGeoActionCenterProjection.snapshot(
            from: .init(
                isSignedInForSocial: true,
                sessionSnoozedPendingKeys: [keyA],
                persistedNotifications: [
                    FanGeoActionItem(
                        id: "poke:badge-1",
                        kind: .poke,
                        titleKey: "action_center_notification_title_passthrough_format",
                        titleFormatArgs: ["Poke"],
                        subtitleKey: "action_center_notification_subtitle_default",
                        destination: .accountPokes,
                        timestamp: now
                    )
                ],
                unreadNotificationIds: ["poke:badge-1"]
            )
        )
        expect(
            unreadOnly.actionNeededItems.isEmpty
                && unreadOnly.unreadNotificationCount == 1
                && unreadOnly.actionCenterBadgeCount == 1,
            "badge: unread Notification 1 only → bell 1"
        )
        let visibleActionOnly = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitations: [coldInvite(inviteD, name: "Delta")],
                isSignedInForSocial: true
            )
        )
        expect(
            visibleActionOnly.actionNeededItems.count == 1
                && visibleActionOnly.unreadNotificationCount == 0
                && visibleActionOnly.actionCenterBadgeCount == 1,
            "badge: visible Action Needed 1 only → bell 1"
        )
        let bothVisible = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitations: [coldInvite(inviteD, name: "Delta")],
                isSignedInForSocial: true,
                persistedNotifications: unreadOnly.notificationItems,
                unreadNotificationIds: ["poke:badge-1"]
            )
        )
        expect(bothVisible.actionCenterBadgeCount == 2, "badge: unread 1 + visible Action Needed 1 → bell 2")
        let hiddenSnoozeOnly = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitations: threeInvites,
                isSignedInForSocial: true,
                sessionSnoozedPendingKeys: Set([keyA, keyB, keyC])
            )
        )
        expect(
            hiddenSnoozeOnly.actionNeededItems.isEmpty
                && hiddenSnoozeOnly.actionNeededBadgeCount == 0
                && hiddenSnoozeOnly.actionCenterBadgeCount == 0,
            "badge: snoozed hidden pending only → bell 0"
        )
        let expiredVisible = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitations: [coldInvite(inviteA, name: "Alpha")],
                isSignedInForSocial: true,
                sessionSnoozedPendingKeys: FanGeoActionCenterLocalVisibility.activePendingSnoozeKeys(
                    in: [keyA: now.addingTimeInterval(-(FanGeoActionCenterLocalVisibility.pendingSnoozeTTL + 1))],
                    now: now
                )
            )
        )
        expect(
            expiredVisible.actionNeededItems.count == 1
                && expiredVisible.actionCenterBadgeCount == 1,
            "badge: expired snooze becomes visible and badges again"
        )
        expect(
            FanGeoInboxChrome.envelopeBadgeCount(
                notificationsCount: unreadOnly.unreadNotificationCount,
                actionNeededCount: FanGeoInboxChrome.actionNeededTabCount(items: unreadOnly.actionNeededItems)
            ) == unreadOnly.actionCenterBadgeCount,
            "bell matches the visible Inbox envelope projection"
        )

        let clearAllUser = UUID()
        FanGeoActionCenterLocalVisibility.clearClearAllHidden(userId: clearAllUser)
        let inviteX = UUID()
        let inviteY = UUID()
        let inviteZ = UUID()
        let inviteNew = UUID()
        let threeClearInvites = [
            coldInvite(inviteX, name: "X"),
            coldInvite(inviteY, name: "Y"),
            coldInvite(inviteZ, name: "Z")
        ]
        let keysXYZ = [
            FanGeoActionCenterActionKey.teamInvite(inviteX),
            FanGeoActionCenterActionKey.teamInvite(inviteY),
            FanGeoActionCenterActionKey.teamInvite(inviteZ)
        ]
        let lastKnownXYZ = Set(keysXYZ)
        FanGeoActionCenterLocalVisibility.saveLastKnownPendingKeys(lastKnownXYZ, userId: clearAllUser)
        let hiddenXYZ = FanGeoActionCenterLocalVisibility.applyingClearAllHidden(
            visibleIds: keysXYZ,
            lastKnownPendingKeys: lastKnownXYZ,
            to: []
        )
        FanGeoActionCenterLocalVisibility.saveClearAllHiddenKeys(hiddenXYZ, userId: clearAllUser)
        expect(hiddenXYZ == lastKnownXYZ, "Clear All persists the three detailed Action Needed ids")

        let firstPaintAfterClearAll = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitations: threeClearInvites,
                isSignedInForSocial: true,
                clearAllHiddenActionKeys: FanGeoActionCenterLocalVisibility.clearAllHiddenKeysForProjection(
                    inMemory: [],
                    userId: clearAllUser
                ),
                lastKnownPendingActionKeys: FanGeoActionCenterLocalVisibility.lastKnownPendingKeysForProjection(
                    inMemory: [],
                    userId: clearAllUser
                )
            )
        )
        expect(firstPaintAfterClearAll.actionNeededItems.isEmpty, "5 first snapshot hides all 3 Clear All ids")
        expect(firstPaintAfterClearAll.actionCenterBadgeCount == 0, "8/9 Clear All → bell and visible count 0")
        expect(
            FanGeoInboxChrome.actionNeededTabCount(items: firstPaintAfterClearAll.actionNeededItems) == 0,
            "10 tab count is 0 after Clear All"
        )
        let repeatedPaint = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitations: threeClearInvites,
                isSignedInForSocial: true,
                clearAllHiddenActionKeys: FanGeoActionCenterLocalVisibility.clearAllHiddenKeysForProjection(
                    inMemory: [],
                    userId: clearAllUser
                ),
                lastKnownPendingActionKeys: FanGeoActionCenterLocalVisibility.lastKnownPendingKeysForProjection(
                    inMemory: [],
                    userId: clearAllUser
                )
            )
        )
        expect(
            repeatedPaint.actionNeededItems.isEmpty
                && repeatedPaint.actionNeededItems.map(\.id) == firstPaintAfterClearAll.actionNeededItems.map(\.id),
            "7 repeated first snapshot stays hidden"
        )
        let sameOldSource = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitations: threeClearInvites,
                isSignedInForSocial: true,
                clearAllHiddenActionKeys: hiddenXYZ,
                lastKnownPendingActionKeys: lastKnownXYZ
            )
        )
        expect(sameOldSource.actionNeededItems.isEmpty, "9 same old source ids remain hidden")

        let newInviteVisible = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitations: threeClearInvites + [coldInvite(inviteNew, name: "New")],
                isSignedInForSocial: true,
                clearAllHiddenActionKeys: hiddenXYZ,
                lastKnownPendingActionKeys: lastKnownXYZ
            )
        )
        expect(
            newInviteVisible.actionNeededItems.map(\.id)
                == [FanGeoActionCenterActionKey.teamInvite(inviteNew)],
            "10/15 new detailed team invite appears after Clear All"
        )
        expect(newInviteVisible.actionCenterBadgeCount == 1, "11 new ID badges")

        let staleAggregate = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitationCount: 3,
                isSignedInForSocial: true,
                clearAllHiddenActionKeys: FanGeoActionCenterLocalVisibility.clearAllHiddenKeysForProjection(
                    inMemory: [],
                    userId: clearAllUser
                ),
                lastKnownPendingActionKeys: FanGeoActionCenterLocalVisibility.lastKnownPendingKeysForProjection(
                    inMemory: [],
                    userId: clearAllUser
                )
            )
        )
        expect(
            staleAggregate.actionNeededItems.isEmpty
                && staleAggregate.actionCenterBadgeCount == 0,
            "A team-invite count fallback does not flash previously-cleared items"
        )

        let friendA = UUID()
        let friendB = UUID()
        let friendNew = UUID()
        let friendKeys = [
            FanGeoActionCenterActionKey.friendRequest(friendA),
            FanGeoActionCenterActionKey.friendRequest(friendB)
        ]
        func friendInput(_ id: UUID, name: String) -> FanGeoActionFriendRequestInput {
            FanGeoActionFriendRequestInput(
                friendshipId: id,
                requesterUserId: UUID(),
                displayName: name
            )
        }
        let hiddenFriends = FanGeoActionCenterLocalVisibility.applyingClearAllHidden(
            visibleIds: friendKeys,
            lastKnownPendingKeys: Set(friendKeys),
            to: []
        )
        expect(
            FanGeoActionCenterProjection.snapshot(
                from: .init(
                    friendRequestCount: 2,
                    isSignedInForSocial: true,
                    clearAllHiddenActionKeys: hiddenFriends,
                    lastKnownPendingActionKeys: Set(friendKeys)
                )
            ).actionNeededItems.isEmpty,
            "A friend-request aggregate fallback stays hidden after Clear All"
        )
        expect(
            FanGeoActionCenterProjection.snapshot(
                from: .init(
                    friendRequests: [
                        friendInput(friendA, name: "A"),
                        friendInput(friendB, name: "B"),
                        friendInput(friendNew, name: "New")
                    ],
                    isSignedInForSocial: true,
                    clearAllHiddenActionKeys: hiddenFriends,
                    lastKnownPendingActionKeys: Set(friendKeys)
                )
            ).actionNeededItems.map(\.id) == [FanGeoActionCenterActionKey.friendRequest(friendNew)],
            "B new friend request appears after Clear All"
        )

        let joinA = UUID()
        let joinB = UUID()
        let joinNew = UUID()
        let joinKeys = [
            FanGeoActionCenterActionKey.joinApproval(joinA),
            FanGeoActionCenterActionKey.joinApproval(joinB)
        ]
        func joinInput(_ id: UUID) -> FanGeoActionJoinApprovalInput {
            FanGeoActionJoinApprovalInput(
                requestId: id,
                pickupGameId: UUID(),
                requesterUserId: UUID(),
                requesterName: "Fan",
                gameTitle: "Pickup"
            )
        }
        let hiddenJoins = FanGeoActionCenterLocalVisibility.applyingClearAllHidden(
            visibleIds: joinKeys,
            lastKnownPendingKeys: Set(joinKeys),
            to: []
        )
        expect(
            FanGeoActionCenterProjection.snapshot(
                from: .init(
                    pendingJoinApprovalCount: 2,
                    isSignedInForSocial: true,
                    clearAllHiddenActionKeys: hiddenJoins,
                    lastKnownPendingActionKeys: Set(joinKeys)
                )
            ).actionNeededItems.isEmpty,
            "A join-approval aggregate fallback stays hidden after Clear All"
        )
        expect(
            FanGeoActionCenterProjection.snapshot(
                from: .init(
                    joinApprovals: [joinInput(joinA), joinInput(joinB), joinInput(joinNew)],
                    isSignedInForSocial: true,
                    clearAllHiddenActionKeys: hiddenJoins,
                    lastKnownPendingActionKeys: Set(joinKeys)
                )
            ).actionNeededItems.map(\.id) == [FanGeoActionCenterActionKey.joinApproval(joinNew)],
            "B new join approval appears after Clear All"
        )

        let otherClearUser = UUID()
        FanGeoActionCenterLocalVisibility.clearClearAllHidden(userId: otherClearUser)
        expect(
            FanGeoActionCenterProjection.snapshot(
                from: .init(
                    teamInvitations: threeClearInvites,
                    isSignedInForSocial: true,
                    clearAllHiddenActionKeys: FanGeoActionCenterLocalVisibility.clearAllHiddenKeysForProjection(
                        inMemory: [],
                        userId: otherClearUser
                    )
                )
            ).actionNeededItems.count == 3,
            "12/13 wrong user does not inherit Clear All state"
        )

        let stillSnoozeOnly = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitations: [coldInvite(inviteA, name: "Alpha")],
                isSignedInForSocial: true,
                sessionSnoozedPendingKeys: FanGeoActionCenterLocalVisibility.activePendingSnoozeKeys(
                    in: [keyA: now.addingTimeInterval(0)],
                    now: now
                )
            )
        )
        expect(stillSnoozeOnly.actionNeededItems.isEmpty, "14 individual X 60-minute snooze remains unchanged")
        expect(
            FanGeoActionCenterLocalVisibility.pendingSnoozeTTL == 60 * 60,
            "14 pending X TTL remains 60 minutes"
        )
        expect(
            !hiddenXYZ.contains(FanGeoActionCenterActionKey.teamInvitesAggregate),
            "Clear All does not persist a family-wide aggregate ban"
        )

        FanGeoActionCenterLocalVisibility.clearClearAllHidden(userId: clearAllUser)
        FanGeoActionCenterLocalVisibility.clearClearAllHidden(userId: otherClearUser)
        FanGeoActionCenterLocalVisibility.clearPendingSnooze(userId: otherUser)
        FanGeoActionCenterLocalVisibility.clearPendingSnooze(userId: coldUser)
        FanGeoActionCenterLocalVisibility.savePermanentDismissedKeys([], userId: coldUser)

        if failures == 0 {
            print("[ActionCenterTest] ALL PASSED")
        } else {
            print("[ActionCenterTest] FAILURES=\(failures)")
            assertionFailure("FanGeoActionCenterSelfTests failed: \(failures)")
        }
    }
}

enum FanGeoInboxLeadingArtworkSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[InboxLeadingArtworkTest] PASS \(name)")
            } else {
                failures += 1
                print("[InboxLeadingArtworkTest] FAIL \(name)")
            }
        }

        let teamId = UUID()
        let start = PickupGameModels.parseSupabaseTimestamptz("2026-08-18T05:27:00+00:00")
        let withTeamAndPlayer = FanGeoActionItem(
            id: "pickup_update:leading-team-player",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["IMC Team updated a Practice"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            timestamp: start,
            context: FanGeoActionContext(
                personName: "FanGeo",
                personAvatarURL: "https://example.test/fangeo.jpg",
                teamName: "IMC Team",
                eventTitle: "Practice",
                eventTypeLabel: "practice",
                locationLabel: "Draper, UT 84020",
                eventStartAt: start,
                pickupGameId: UUID(),
                teamId: teamId,
                sportLabel: "soccer",
                notificationType: "team_event_updated"
            )
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(for: withTeamAndPlayer) == .teamMark,
            "Practice Updated with teamId + player avatar uses Team"
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(for: withTeamAndPlayer) != .personAvatar,
            "player photo is not the primary leading image"
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(
                kind: .scheduleChange,
                teamId: teamId,
                personAvatarURL: "https://example.test/fangeo.jpg",
                isPendingRating: false,
                personName: "FanGeo",
                teamName: "IMC Team"
            ) == .teamMark,
            "helper and renderer stay consistent"
        )
        if let notice = FanGeoTeamEventNoticeBuilder.make(for: withTeamAndPlayer, languageCode: "en") {
            expect(
                notice.supportingRows.contains(where: { $0.kind == .player && $0.value == "FanGeo" }),
                "Player body row still shows the small player avatar identity"
            )
        } else {
            expect(false, "practice notice")
        }

        let missingLogo = withTeamAndPlayer
        expect(
            FanGeoActionCenterLeadingIdentity.source(for: missingLogo) == .teamMark,
            "missing uploaded logo still uses Team fallback mark, not player"
        )

        let namedNoId = FanGeoActionItem(
            id: "pickup_update:leading-named-no-id",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["IMC Team updated a Practice"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                personName: "FanGeo",
                personAvatarURL: "https://example.test/fangeo.jpg",
                teamName: "IMC Team",
                eventTitle: "Practice",
                eventTypeLabel: "practice",
                notificationType: "team_event_updated"
            )
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(for: namedNoId) == .kindGlyph,
            "teamName without teamId uses event/team fallback"
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(for: namedNoId) != .personAvatar,
            "teamName without teamId does not use player avatar"
        )

        let inferred = FanGeoTeamEventAffectedPlayerResolver.applyingAccountOwner(
            to: FanGeoActionItem(
                id: "pickup_update:leading-inferred",
                kind: .scheduleChange,
                titleKey: "action_center_event_changed_format",
                titleFormatArgs: ["IMC Team · Practice"],
                subtitleKey: "action_center_schedule_change_subtitle",
                destination: .scheduleActivity,
                context: FanGeoActionContext(
                    eventTitle: "IMC Team · Practice",
                    eventTypeLabel: "Practice",
                    notificationType: "team_event_updated"
                )
            ),
            displayName: "FanGeo",
            avatarURL: "https://example.test/fangeo.jpg",
            avatarThumbnailURL: nil
        )
        expect(inferred.context.teamId == nil, "legacy row does not invent teamId")
        expect(
            FanGeoActionCenterLeadingIdentity.source(for: inferred) != .personAvatar,
            "legacy Team-event row with owner avatar does not lead with the player"
        )

        expect(
            FanGeoActionCenterLeadingIdentity.source(
                kind: .friendRequest,
                teamId: nil,
                personAvatarURL: "https://example.test/friend.jpg",
                isPendingRating: false
            ) == .personAvatar,
            "friend/person-centric notification still uses person avatar"
        )

        let scoreItem = FanGeoActionItem(
            id: "pro_game:score:leading-control",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["Chicago Cubs scored"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                notificationType: "pro_game_score",
                proGameMatchId: "mlb-leading-control",
                proGameSnapshot: FanGeoProGameInboxSnapshot(
                    kind: .score,
                    matchID: "mlb-leading-control",
                    homeTeam: "Chicago Cubs",
                    awayTeam: "St. Louis Cardinals",
                    homeScore: 3,
                    awayScore: 0,
                    scoringTeam: "Chicago Cubs",
                    league: "MLB",
                    sport: "Baseball",
                    matchStatus: "LIVE",
                    clock: nil,
                    homeBadgeURL: nil,
                    awayBadgeURL: nil,
                    homeProviderId: nil,
                    awayProviderId: nil
                )
            )
        )
        expect(
            FanGeoProGameInboxPresentation.isProGame(scoreItem),
            "pro-game rich scoreboard identity is unchanged"
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(for: scoreItem) != .teamMark,
            "pro-game cards do not use Fan Team leading artwork"
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(for: scoreItem) != .personAvatar,
            "pro-game cards do not use player avatar as leading artwork"
        )

        let userId = UUID()
        FanGeoNotificationInboxStore.clearMemory(userId: userId)
        let durableId = FanGeoActionCenterActionKey.pickupUpdate(
            gameId: UUID(),
            instanceKey: "preserve-team"
        )
        let durable = FanGeoActionItem(
            id: durableId,
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["IMC Team updated a Practice"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "IMC Team",
                pickupGameId: UUID(),
                teamId: teamId,
                sportLabel: "soccer",
                notificationType: "team_event_updated"
            )
        )
        _ = FanGeoNotificationInboxStore.upsert(items: [durable], userId: userId)
        let live = FanGeoActionItem(
            id: durableId,
            kind: .scheduleChange,
            titleKey: "action_center_event_changed_format",
            titleFormatArgs: ["IMC Team · Practice"],
            subtitleKey: "action_center_schedule_change_subtitle",
            destination: .scheduleActivity,
            context: FanGeoActionContext(eventTitle: "IMC Team · Practice")
        )
        let afterLive = FanGeoNotificationInboxStore.upsert(items: [live], userId: userId)
        expect(afterLive.first?.teamId == teamId, "live upsert does not drop teamId")
        expect(afterLive.first?.teamName == "IMC Team", "live upsert does not drop teamName")

        let server = FanNotificationInboxServerRow(
            id: UUID(),
            notification_type: "team_event_updated",
            title: "IMC Team updated a Practice",
            body: "Practice",
            kind_raw: "scheduleChange",
            destination_raw: "scheduleActivity",
            source_type: nil,
            source_id: nil,
            team_id: nil,
            event_id: nil,
            actor_user_id: nil,
            payload: ["team_name": .string("IMC Team")],
            deduplication_key: durableId,
            created_at: Date(),
            read_at: nil,
            cleared_at: nil
        )
        let reconciled = FanGeoNotificationInboxStore.reconcileFromServer(rows: [server], userId: userId)
        expect(reconciled.first?.teamId == teamId, "inbox reconcile does not drop teamId")
        FanGeoNotificationInboxStore.clearMemory(userId: userId)

        if failures == 0 {
            print("[InboxLeadingArtworkTest] ALL PASSED")
        } else {
            print("[InboxLeadingArtworkTest] FAILURES=\(failures)")
            assertionFailure("FanGeoInboxLeadingArtworkSelfTests failed: \(failures)")
        }
    }
}

private extension FanGeoActionCenterProjection.Snapshot {
    var joinApprovalsBadge: Int {
        items.filter { $0.kind == .joinApproval }.reduce(0) { $0 + $1.count }
    }
}
#endif
