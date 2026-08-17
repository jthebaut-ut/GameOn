import Foundation
import UserNotifications

#if DEBUG
enum FanGeoNotificationInboxSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[FanNotificationInboxTest] PASS \(name)")
            } else {
                failures += 1
                print("[FanNotificationInboxTest] FAIL \(name)")
            }
        }

        let userId = UUID()
        FanGeoNotificationInboxStore.clearMemory(userId: userId)

        let gameId = UUID()
        let eventId = UUID()
        let dedupe = FanGeoActionCenterActionKey.pickupUpdate(
            gameId: gameId,
            instanceKey: eventId.uuidString
        )

        let item = FanGeoActionItem(
            id: dedupe,
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["Practice time changed"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            timestamp: Date(),
            context: FanGeoActionContext(
                eventTitle: "Practice",
                pickupGameId: gameId,
                teamId: UUID()
            )
        )

        let afterUpsert = FanGeoNotificationInboxStore.upsert(items: [item], userId: userId)
        expect(afterUpsert.count == 1, "APNs ingest upserts one notification")
        expect(afterUpsert.first?.isRead == false, "new notification unread")

        _ = FanGeoNotificationInboxStore.upsert(items: [item], userId: userId)
        expect(
            FanGeoNotificationInboxStore.visibleEntries(userId: userId).count == 1,
            "duplicate APNs ingest does not duplicate"
        )

        _ = FanGeoNotificationInboxStore.markRead(ids: [dedupe], userId: userId)
        expect(
            FanGeoNotificationInboxStore.visibleEntries(userId: userId).first?.isRead == true,
            "mark read"
        )

        let actionNeededStillSeparate = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitationCount: 1,
                isSignedInForSocial: true,
                persistedNotifications: FanGeoNotificationInboxStore.visibleEntries(userId: userId)
                    .compactMap { $0.asActionItem() },
                unreadNotificationIds: [],
                clearedNotificationKeys: []
            )
        )
        expect(
            actionNeededStillSeparate.actionNeededItems.contains(where: { $0.kind == .teamInvitation }),
            "Action Needed remains independent of notification inbox"
        )

        _ = FanGeoNotificationInboxStore.clear(ids: [dedupe], userId: userId)
        expect(
            FanGeoNotificationInboxStore.visibleEntries(userId: userId).isEmpty,
            "clear removes notification from visible inbox"
        )
        expect(
            FanGeoActionCenterProjection.snapshot(
                from: .init(
                    teamInvitationCount: 1,
                    isSignedInForSocial: true
                )
            ).actionNeededItems.contains(where: { $0.kind == .teamInvitation }),
            "clear notification does not complete Action Needed"
        )

        // Server reconcile prefers shared dedupe key.
        FanGeoNotificationInboxStore.clearMemory(userId: userId)
        _ = FanGeoNotificationInboxStore.upsert(items: [item], userId: userId)
        let serverRow = FanNotificationInboxServerRow(
            id: UUID(),
            notification_type: "time_changed",
            title: "Team updated the time",
            body: "Practice",
            kind_raw: "scheduleChange",
            destination_raw: "scheduleActivity",
            source_type: "pickup_game_change_notification",
            source_id: eventId.uuidString,
            team_id: item.context.teamId,
            event_id: gameId,
            actor_user_id: nil,
            payload: ["deduplication_key": .string(dedupe)],
            deduplication_key: dedupe,
            created_at: Date().addingTimeInterval(-60),
            read_at: Date(),
            cleared_at: nil
        )
        let reconciled = FanGeoNotificationInboxStore.reconcileFromServer(
            rows: [serverRow],
            userId: userId
        )
        expect(reconciled.count == 1, "server+local reconcile does not duplicate")
        expect(reconciled.first?.isRead == true, "server read_at wins")
        expect(
            reconciled.first?.id == FanGeoActionCenterActionKey.sanitize(dedupe),
            "stable id is dedupe key"
        )
        expect(reconciled.first?.teamId == item.context.teamId, "server reconcile keeps teamId")

        let durableTeamId = UUID()
        let durablePractice = FanGeoActionItem(
            id: FanGeoActionCenterActionKey.pickupUpdate(
                gameId: gameId,
                instanceKey: "live-stomp"
            ),
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["IMC Team updated a Practice"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                teamName: "IMC Team",
                eventTitle: "Practice",
                pickupGameId: gameId,
                teamId: durableTeamId,
                sportLabel: "soccer",
                notificationType: "team_event_updated"
            )
        )
        FanGeoNotificationInboxStore.clearMemory(userId: userId)
        _ = FanGeoNotificationInboxStore.upsert(items: [durablePractice], userId: userId)
        let liveWithoutTeamId = FanGeoActionItem(
            id: durablePractice.id,
            kind: .scheduleChange,
            titleKey: "action_center_event_changed_format",
            titleFormatArgs: ["IMC Team · Practice"],
            subtitleKey: "action_center_schedule_change_subtitle",
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                eventTitle: "IMC Team · Practice",
                eventTypeLabel: "Practice",
                pickupGameId: gameId
            )
        )
        let afterLiveUpsert = FanGeoNotificationInboxStore.upsert(
            items: [liveWithoutTeamId],
            userId: userId
        )
        expect(
            afterLiveUpsert.first?.teamId == durableTeamId,
            "live upsert does not drop durable teamId"
        )
        expect(
            afterLiveUpsert.first?.teamName == "IMC Team",
            "live upsert does not drop durable teamName"
        )
        expect(
            afterLiveUpsert.first?.sportLabel == "soccer",
            "live upsert does not drop durable sportLabel"
        )
        if let preserved = afterLiveUpsert.first?.asActionItem() {
            expect(
                FanGeoActionCenterLeadingIdentity.source(for: preserved) == .teamMark,
                "preserved teamId still selects Team leading artwork"
            )
        } else {
            expect(false, "preserved live upsert maps to an action item")
        }

        let serverMissingTeamId = FanNotificationInboxServerRow(
            id: UUID(),
            notification_type: "team_event_updated",
            title: "IMC Team updated a Practice",
            body: "Practice",
            kind_raw: "scheduleChange",
            destination_raw: "scheduleActivity",
            source_type: "pickup_game_change_notification",
            source_id: gameId.uuidString,
            team_id: nil,
            event_id: gameId,
            actor_user_id: nil,
            payload: ["team_name": .string("IMC Team")],
            deduplication_key: durablePractice.id,
            created_at: Date(),
            read_at: nil,
            cleared_at: nil
        )
        let mergedMissingServerTeam = FanGeoNotificationInboxStore.reconcileFromServer(
            rows: [serverMissingTeamId],
            userId: userId
        )
        expect(
            mergedMissingServerTeam.first?.teamId == durableTeamId,
            "inbox reconcile does not drop teamId when the server row omits it"
        )

        // Newest-first ordering.
        let older = FanNotificationInboxServerRow(
            id: UUID(),
            notification_type: "created",
            title: "Older",
            body: "A",
            kind_raw: "scheduleChange",
            destination_raw: "scheduleActivity",
            source_type: nil,
            source_id: nil,
            team_id: nil,
            event_id: nil,
            actor_user_id: nil,
            payload: nil,
            deduplication_key: "pickup_update:\(UUID().uuidString.lowercased()):\(UUID().uuidString.lowercased())",
            created_at: Date().addingTimeInterval(-3600),
            read_at: nil,
            cleared_at: nil
        )
        let newer = FanNotificationInboxServerRow(
            id: UUID(),
            notification_type: "created",
            title: "Newer",
            body: "B",
            kind_raw: "scheduleChange",
            destination_raw: "scheduleActivity",
            source_type: nil,
            source_id: nil,
            team_id: nil,
            event_id: nil,
            actor_user_id: nil,
            payload: nil,
            deduplication_key: "pickup_update:\(UUID().uuidString.lowercased()):\(UUID().uuidString.lowercased())",
            created_at: Date(),
            read_at: nil,
            cleared_at: nil
        )
        FanGeoNotificationInboxStore.clearMemory(userId: userId)
        let ordered = FanGeoNotificationInboxStore.reconcileFromServer(
            rows: [older, newer],
            userId: userId
        )
        expect(ordered.first?.eventTitle == "Newer" || ordered.first?.titleFormatArgs.first == "Newer",
               "pagination/order newest-first")

        let badge = FanGeoActionCenterProjection.snapshot(
            from: .init(
                joinApprovals: [
                    FanGeoActionJoinApprovalInput(
                        requestId: UUID(),
                        pickupGameId: gameId,
                        requesterUserId: UUID(),
                        requesterName: "Sam",
                        gameTitle: "Game",
                        startAt: Date()
                    )
                ],
                pendingJoinApprovalCount: 1,
                isSignedInForSocial: true,
                persistedNotifications: ordered.compactMap { $0.asActionItem() },
                unreadNotificationIds: Set(ordered.filter { !$0.isRead }.map(\.id))
            )
        )
        expect(badge.goingBadgeCount == 0, "Inbox snapshot never drives the Going tab badge")
        expect(badge.actionCenterBadgeCount >= 2, "bell = actions + unread notifications")

        FanGeoNotificationInboxStore.clearMemory(userId: userId)

        let teamIdForInbox = UUID()
        let richRow = FanNotificationInboxServerRow(
            id: UUID(),
            notification_type: "team_event_time_changed",
            title: "JT updated the time",
            body: "Practice",
            kind_raw: "scheduleChange",
            destination_raw: "scheduleActivity",
            source_type: "pickup_game_change_notification",
            source_id: gameId.uuidString,
            team_id: teamIdForInbox,
            event_id: gameId,
            actor_user_id: nil,
            payload: [
                "team_name": .string("JT"),
                "game_format": .string("practice"),
                "title": .string("Practice"),
                "before_start": .string("2026-08-16T01:00:00+00:00"),
                "after_start": .string("2026-08-16T02:30:00+00:00"),
                "after_location": .string("Draper, UT 84020"),
                "change_kinds": .array([.string("start")])
            ],
            deduplication_key: FanGeoActionCenterActionKey.pickupUpdate(
                gameId: gameId,
                instanceKey: UUID().uuidString
            ),
            created_at: Date(),
            read_at: nil,
            cleared_at: nil
        )
        let richEntry = FanGeoNotificationInboxEntry.from(serverRow: richRow)
        expect(richEntry.teamName == "JT", "inbox hydrates Team name from payload")
        expect(richEntry.eventTypeLabel == "practice", "inbox hydrates game_format")
        expect(richEntry.notificationType == "team_event_time_changed", "inbox keeps notification_type")
        expect(richEntry.changeDetails.count == 1, "inbox hydrates time change detail")
        expect(richEntry.eventTitle == "Practice", "inbox event title is payload title, not log line")
        if let richItem = richEntry.asActionItem() {
            expect(
                richItem.title(languageCode: "en") == "Practice Updated",
                "inbox Team row renders event-type title"
            )
            expect(
                FanGeoActionCenterTeamNotificationPresentation.headerBadgeText(
                    for: richItem,
                    languageCode: "en"
                ) == "PRACTICE UPDATED",
                "inbox Team event header is PRACTICE UPDATED"
            )
            expect(
                FanGeoActionCenterTeamNotificationPresentation.usesTeamChrome(for: richItem),
                "inbox Team row uses Team chrome"
            )
            expect(
                FanGeoActionCenterTeamNotificationPresentation.summaryLine(
                    for: richItem,
                    languageCode: "en"
                ) == nil,
                "inbox Team event does not use combined summaryLine"
            )
            if let notice = FanGeoTeamEventNoticeBuilder.make(for: richItem, languageCode: "en") {
                expect(
                    notice.changeRows.contains(where: {
                        $0.kind == .time && $0.displayValue(languageCode: "en").contains("→")
                    }),
                    "inbox time change shows old → new"
                )
                expect(
                    !notice.allRows.contains(where: {
                        $0.displayValue(languageCode: "en").localizedCaseInsensitiveContains(" at ")
                    }),
                    "inbox notice has no combined date-at-time"
                )
            } else {
                expect(false, "inbox Team time notice")
            }
        } else {
            expect(false, "inbox Team row maps to action item")
        }
        expect(richEntry.personName == nil, "time change without player keys does not invent a player")
        expect(richEntry.managedPlayerId == nil, "time change without managed_player_id stays nil")
        expect(richEntry.isManagedPlayer != true, "time change without managed flag is not managed")

        let emmaManagedId = UUID()
        let emmaInboxRow = FanNotificationInboxServerRow(
            id: UUID(),
            notification_type: "team_event_created",
            title: "IMC Team scheduled a Practice",
            body: "Practice",
            kind_raw: "scheduleChange",
            destination_raw: "scheduleActivity",
            source_type: "pickup_game_change_notification",
            source_id: gameId.uuidString,
            team_id: teamIdForInbox,
            event_id: gameId,
            actor_user_id: nil,
            payload: [
                "team_name": .string("IMC Team"),
                "game_format": .string("practice"),
                "title": .string("Practice"),
                "after_start": .string("2026-08-18T05:27:00+00:00"),
                "after_location": .string("Draper, UT"),
                "managed_player_id": .string(emmaManagedId.uuidString),
                "managed_player_name": .string("Emma"),
                "is_managed_player": .bool(true),
                "managed_player_avatar_url": .string("https://example.test/emma.jpg")
            ],
            deduplication_key: FanGeoActionCenterActionKey.pickupUpdate(
                gameId: gameId,
                instanceKey: "emma-created"
            ),
            created_at: Date(),
            read_at: nil,
            cleared_at: nil
        )
        let emmaInboxEntry = FanGeoNotificationInboxEntry.from(serverRow: emmaInboxRow)
        expect(emmaInboxEntry.personName == "Emma", "inbox hydrates managed_player_name")
        expect(emmaInboxEntry.managedPlayerId == emmaManagedId, "inbox hydrates managed_player_id")
        expect(emmaInboxEntry.isManagedPlayer == true, "inbox hydrates is_managed_player")
        expect(
            emmaInboxEntry.personAvatarURL == "https://example.test/emma.jpg",
            "inbox hydrates managed player avatar"
        )
        if let emmaItem = emmaInboxEntry.asActionItem() {
            expect(emmaItem.title(languageCode: "en") == "New Practice", "inbox created title is New Practice")
            expect(
                FanGeoActionCenterTeamNotificationPresentation.headerBadgeText(
                    for: emmaItem,
                    languageCode: "en"
                ) == "NEW PRACTICE",
                "inbox created badge is NEW PRACTICE"
            )
            expect(
                FanGeoActionCenterLeadingIdentity.source(for: emmaItem) == .teamMark,
                "inbox practice update prefers team logo as primary artwork"
            )
            expect(
                FanGeoActionCenterLeadingIdentity.source(for: emmaItem) != .personAvatar,
                "inbox practice update does not use player avatar as leading artwork"
            )
            expect(emmaItem.destination == .scheduleActivity, "inbox practice update tap destination unchanged")
            if let notice = FanGeoTeamEventNoticeBuilder.make(for: emmaItem, languageCode: "en") {
                expect(
                    notice.supportingRows.contains(where: { $0.kind == .player && $0.value == "Emma" }),
                    "inbox created shows Emma"
                )
                expect(
                    notice.supportingRows.contains(where: { $0.kind == .team && $0.value == "IMC Team" }),
                    "inbox created shows Team"
                )
            } else {
                expect(false, "inbox Emma created notice")
            }
        } else {
            expect(false, "inbox Emma row maps to action item")
        }

        if let encoded = try? JSONEncoder().encode(richEntry),
           var object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
            object.removeValue(forKey: "isManagedPlayer")
            object.removeValue(forKey: "managedPlayerId")
            object.removeValue(forKey: "personAvatarThumbnailURL")
            if let stripped = try? JSONSerialization.data(withJSONObject: object),
               let decoded = try? JSONDecoder().decode(FanGeoNotificationInboxEntry.self, from: stripped) {
                expect(decoded.isManagedPlayer != true, "old cache without isManagedPlayer still decodes")
                expect(
                    decoded.asActionItem()?.context.isManagedPlayer == false,
                    "old cache maps to account-owner fallback, not a managed player"
                )
            } else {
                expect(false, "old cache rows without managed-player keys still decode")
            }
        } else {
            expect(false, "old cache encode produced JSON")
        }

        let pickupRow = FanNotificationInboxServerRow(
            id: UUID(),
            notification_type: "time_changed",
            title: "Jonathan updated the time",
            body: "Pickup Game",
            kind_raw: "scheduleChange",
            destination_raw: "scheduleActivity",
            source_type: "pickup_game_change_notification",
            source_id: nil,
            team_id: nil,
            event_id: UUID(),
            actor_user_id: nil,
            payload: [
                "title": .string("Pickup Game"),
                "before_start": .string("2026-08-16T01:00:00+00:00"),
                "after_start": .string("2026-08-16T02:30:00+00:00")
            ],
            deduplication_key: FanGeoActionCenterActionKey.pickupUpdate(
                gameId: UUID(),
                instanceKey: UUID().uuidString
            ),
            created_at: Date(),
            read_at: nil,
            cleared_at: nil
        )
        let pickupEntry = FanGeoNotificationInboxEntry.from(serverRow: pickupRow)
        expect(pickupEntry.teamName == nil, "pickup without Team has no team name")
        expect(pickupEntry.changeDetails.isEmpty, "pickup without Team keeps generic mapping")
        expect(pickupEntry.eventTitle == "Jonathan updated the time", "pickup keeps server title fallback")
        if let pickupItem = pickupEntry.asActionItem() {
            expect(
                pickupItem.title(languageCode: "en") == "Jonathan updated the time",
                "pickup without Team stays generic"
            )
            expect(
                !FanGeoActionCenterTeamNotificationPresentation.usesTeamChrome(for: pickupItem),
                "pickup without Team does not use Team chrome"
            )
        } else {
            expect(false, "pickup row maps to action item")
        }

        let endRow = FanNotificationInboxServerRow(
            id: UUID(),
            notification_type: "time_changed",
            title: "JT updated the time",
            body: "Practice",
            kind_raw: "scheduleChange",
            destination_raw: "scheduleActivity",
            source_type: "pickup_game_change_notification",
            source_id: gameId.uuidString,
            team_id: teamIdForInbox,
            event_id: gameId,
            actor_user_id: nil,
            payload: [
                "team_name": .string("JT"),
                "game_format": .string("practice"),
                "title": .string("Practice"),
                "before_start": .string("2026-08-20T00:00:00+00:00"),
                "after_start": .string("2026-08-20T00:00:00+00:00"),
                "before_end": .string("2026-08-20T01:30:00+00:00"),
                "after_end": .string("2026-08-20T02:00:00+00:00"),
                "change_kinds": .array([.string("end")])
            ],
            deduplication_key: FanGeoActionCenterActionKey.pickupUpdate(
                gameId: gameId,
                instanceKey: UUID().uuidString
            ),
            created_at: Date(),
            read_at: nil,
            cleared_at: nil
        )
        let endEntry = FanGeoNotificationInboxEntry.from(serverRow: endRow)
        expect(
            endEntry.changeDetails.contains(where: { $0.labelKey == "action_center_change_end_time" }),
            "inbox hydrates before_end / after_end"
        )
        if let endItem = endEntry.asActionItem(),
           let notice = FanGeoTeamEventNoticeBuilder.make(for: endItem, languageCode: "en") {
            expect(
                notice.changeRows.contains(where: {
                    $0.kind == .time && $0.displayValue(languageCode: "en").contains("→")
                }),
                "end-only inbox notice shows time range old → new"
            )
        } else {
            expect(false, "end-only inbox notice")
        }

        // Membership-loss reconcile: server-cleared JT rows disappear; other
        // Team + standalone Pickup remain; Removed from Team stays; unread drops.
        FanGeoNotificationInboxStore.clearMemory(userId: userId)
        let jtTeamId = UUID()
        let imcTeamId = UUID()
        let jtPractice = FanGeoActionItem(
            id: "team_practice:\(jtTeamId.uuidString.lowercased()):created",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["Practice created"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            timestamp: Date().addingTimeInterval(-3600),
            context: FanGeoActionContext(
                eventTitle: "Practice",
                teamId: jtTeamId,
                notificationType: "created"
            )
        )
        let jtAnnouncement = FanGeoActionItem(
            id: "team_announce:\(jtTeamId.uuidString.lowercased()):1",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["Team Announcement"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            timestamp: Date().addingTimeInterval(-1800),
            context: FanGeoActionContext(
                eventTitle: "Team Announcement",
                teamId: jtTeamId,
                notificationType: "announcement"
            )
        )
        let imcChanged = FanGeoActionItem(
            id: "team_imc:\(imcTeamId.uuidString.lowercased()):changed",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["League Game changed"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            timestamp: Date().addingTimeInterval(-900),
            context: FanGeoActionContext(
                eventTitle: "League Game",
                teamId: imcTeamId,
                notificationType: "time_changed"
            )
        )
        let pickupStandalone = FanGeoActionItem(
            id: FanGeoActionCenterActionKey.pickupUpdate(
                gameId: UUID(),
                instanceKey: UUID().uuidString
            ),
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["Pickup time changed"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            timestamp: Date().addingTimeInterval(-600),
            context: FanGeoActionContext(
                eventTitle: "Pickup",
                pickupGameId: UUID()
            )
        )
        _ = FanGeoNotificationInboxStore.upsert(
            items: [jtPractice, jtAnnouncement, imcChanged, pickupStandalone],
            userId: userId
        )
        expect(
            FanGeoNotificationInboxStore.visibleEntries(userId: userId).count == 4,
            "pre-removal inbox has JT + IMC + pickup"
        )

        let removedDedupe = "team_removed:\(jtTeamId.uuidString.lowercased()):\(userId.uuidString.lowercased()):\(UUID().uuidString.lowercased())"
        let imcDedupe = "team_imc:\(imcTeamId.uuidString.lowercased()):changed"
        let removedRow = FanNotificationInboxServerRow(
            id: UUID(),
            notification_type: "removed_from_team",
            title: "Removed from Team",
            body: "You are no longer a member of JT.",
            kind_raw: "scheduleChange",
            destination_raw: "teamsHome",
            source_type: "member_change",
            source_id: UUID().uuidString,
            team_id: jtTeamId,
            event_id: nil,
            actor_user_id: nil,
            payload: [
                "team_id": .string(jtTeamId.uuidString),
                "team_name": .string("JT"),
                "safe_destination": .string("teamsHome")
            ],
            deduplication_key: removedDedupe,
            created_at: Date(),
            read_at: nil,
            cleared_at: nil
        )
        let imcRow = FanNotificationInboxServerRow(
            id: UUID(),
            notification_type: "time_changed",
            title: "League Game changed",
            body: "IMC Team",
            kind_raw: "scheduleChange",
            destination_raw: "scheduleActivity",
            source_type: "pickup_game_change_notification",
            source_id: UUID().uuidString,
            team_id: imcTeamId,
            event_id: UUID(),
            actor_user_id: nil,
            payload: ["team_name": .string("IMC Team")],
            deduplication_key: imcDedupe,
            created_at: Date().addingTimeInterval(-900),
            read_at: nil,
            cleared_at: nil
        )
        let afterRemoval = FanGeoNotificationInboxStore.reconcileFromServer(
            rows: [removedRow, imcRow],
            userId: userId,
            pageLimit: 50
        )
        expect(
            afterRemoval.contains(where: {
                ($0.notificationType ?? "").lowercased() == "removed_from_team"
            }),
            "Removed from Team remains after membership-loss reconcile"
        )
        expect(
            afterRemoval.contains(where: { $0.teamId == imcTeamId }),
            "other Team notification remains"
        )
        expect(
            afterRemoval.contains(where: { $0.teamId == nil && $0.eventTitle == "Pickup" }),
            "standalone Pickup remains"
        )
        expect(
            !afterRemoval.contains(where: {
                $0.teamId == jtTeamId && ($0.notificationType ?? "") != "removed_from_team"
            }),
            "old JT Team notifications are gone"
        )
        expect(
            afterRemoval.first(where: {
                ($0.notificationType ?? "").lowercased() == "removed_from_team"
            })?.destinationRaw == FanGeoActionDestination.teamsHome.rawValue,
            "Removed from Team destinations Teams list"
        )

        let resurrect = FanGeoNotificationInboxStore.upsert(
            items: [jtPractice, jtAnnouncement],
            userId: userId
        )
        expect(
            !resurrect.contains(where: {
                $0.teamId == jtTeamId && ($0.notificationType ?? "") != "removed_from_team"
            }),
            "live upsert cannot resurrect server-cleared JT rows"
        )

        let unreadAfter = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitationCount: 1,
                isSignedInForSocial: true,
                persistedNotifications: FanGeoNotificationInboxStore.visibleEntries(userId: userId)
                    .compactMap { $0.asActionItem() },
                unreadNotificationIds: Set(
                    FanGeoNotificationInboxStore.visibleEntries(userId: userId)
                        .filter { !$0.isRead }
                        .map(\.id)
                )
            )
        )
        expect(
            unreadAfter.unreadNotificationCount == FanGeoNotificationInboxStore
                .visibleEntries(userId: userId)
                .filter { !$0.isRead }
                .count,
            "bell unread matches remaining visible notifications"
        )
        expect(
            unreadAfter.actionNeededItems.contains(where: { $0.kind == .teamInvitation }),
            "unrelated Action Needed remains after Team inbox clear"
        )

        let historicalRow = FanNotificationInboxServerRow(
            id: UUID(),
            notification_type: "time_changed",
            title: "IMC Team · Practice changed",
            body: "Aug 17, 2026 at 11:27 PM",
            kind_raw: "scheduleChange",
            destination_raw: "scheduleActivity",
            source_type: "pickup_game_change_notification",
            source_id: UUID().uuidString,
            team_id: nil,
            event_id: UUID(),
            actor_user_id: nil,
            payload: [
                "payload": .object([
                    "after_start": .string("2026-08-18T05:27:00+00:00"),
                    "before_start": .string("2026-08-18T04:27:00+00:00"),
                    "after_location": .string("Draper, UT 84020"),
                    "game_format": .string("practice")
                ]),
                "change_kinds": .string("start")
            ],
            deduplication_key: FanGeoActionCenterActionKey.pickupUpdate(
                gameId: UUID(),
                instanceKey: UUID().uuidString
            ),
            created_at: Date(),
            read_at: nil,
            cleared_at: nil
        )
        let historicalEntry = FanGeoNotificationInboxEntry.from(serverRow: historicalRow)
        expect(historicalEntry.teamName == "IMC Team", "historical nested payload recovers Team name")
        expect(
            historicalEntry.changeDetails.contains(where: {
                $0.labelKey == "action_center_change_time" && $0.oldValue != nil && $0.newValue != nil
            }),
            "historical nested before/after start is decoded"
        )
        if let historicalItem = historicalEntry.asActionItem() {
            expect(
                FanGeoTeamEventNoticeBuilder.make(for: historicalItem, languageCode: "en") != nil,
                "historical durable row selects Team-event notice"
            )
            expect(
                historicalItem.title(languageCode: "en") == "Practice Updated",
                "historical durable row title is Practice Updated"
            )
            expect(
                FanGeoActionCenterTeamNotificationPresentation.summaryLine(
                    for: historicalItem,
                    languageCode: "en"
                ) == nil,
                "historical durable row has no legacy summaryLine"
            )
            if let notice = FanGeoTeamEventNoticeBuilder.make(for: historicalItem, languageCode: "en") {
                expect(
                    notice.changeRows.contains(where: {
                        $0.kind == .time && $0.displayValue(languageCode: "en").contains("→")
                    }),
                    "historical durable row shows Time old → new"
                )
                expect(
                    !notice.allRows.contains(where: {
                        $0.displayValue(languageCode: "en").localizedCaseInsensitiveContains(" at ")
                    }),
                    "historical durable row has no combined date-at-time"
                )
                expect(
                    notice.supportingRows.filter { $0.kind == .time }.isEmpty,
                    "historical Time change is not also a supporting row"
                )
            }
        } else {
            expect(false, "historical durable row maps to action item")
        }

        let cubsBadge = "https://www.thesportsdb.com/images/media/team/badge/cubs.png"
        let cardsBadge = "https://www.thesportsdb.com/images/media/team/badge/cardinals.png"
        let scoreRow = FanNotificationInboxServerRow(
            id: UUID(),
            notification_type: "pro_game_score",
            title: "Chicago Cubs scored",
            body: "St. Louis Cardinals 0 - 3 Chicago Cubs",
            kind_raw: "scheduleChange",
            destination_raw: "scheduleActivity",
            source_type: "pro_game_notification",
            source_id: "mlb-cubs-cardinals-2026-08-14",
            team_id: nil,
            event_id: nil,
            actor_user_id: nil,
            payload: [
                "match_id": .string("mlb-cubs-cardinals-2026-08-14"),
                "notification_type": .string("pro_game_score"),
                "home_team": .string("Chicago Cubs"),
                "away_team": .string("St. Louis Cardinals"),
                "home_score": .number(3),
                "away_score": .number(0),
                "scoring_team": .string("Chicago Cubs"),
                "league": .string("MLB"),
                "sport": .string("Baseball"),
                "match_status": .string("LIVE"),
                "home_badge_url": .string(cubsBadge),
                "away_badge_url": .string(cardsBadge),
                "home_provider_id": .string("135269"),
                "away_provider_id": .string("135272")
            ],
            deduplication_key: "pro_game:score:mlb-cubs-cardinals-2026-08-14:0-3",
            created_at: Date(),
            read_at: nil,
            cleared_at: nil
        )
        let scoreEntry = FanGeoNotificationInboxEntry.from(serverRow: scoreRow)
        expect(scoreEntry.proGameSnapshot?.homeTeam == "Chicago Cubs", "inbox score row stores home team")
        expect(scoreEntry.proGameSnapshot?.awayTeam == "St. Louis Cardinals", "inbox score row stores away team")
        expect(
            scoreEntry.proGameSnapshot?.homeScore == 3 && scoreEntry.proGameSnapshot?.awayScore == 0,
            "inbox score row stores both scores"
        )
        expect(scoreEntry.proGameSnapshot?.homeBadgeURL == cubsBadge, "inbox score row stores provider artwork URL")
        expect(scoreEntry.proGameSnapshot?.identifiedScoringTeam == "Chicago Cubs", "inbox score row keeps scoring team")
        if let scoreItem = scoreEntry.asActionItem() {
            expect(scoreItem.context.proGameMatchId == "mlb-cubs-cardinals-2026-08-14", "inbox score row keeps deep link id")
            expect(
                FanGeoProGameInboxPresentation.usesGenericTitleRenderer(scoreItem) == false,
                "valid inbox snapshot never falls through to generic Final Score renderer"
            )
            expect(
                FanGeoProGameInboxPresentation.isProGame(scoreItem),
                "pro-game inbox cards are unchanged"
            )
            expect(
                FanGeoActionCenterLeadingIdentity.source(for: scoreItem) != .teamMark,
                "pro-game inbox cards do not use fan-team leading artwork"
            )
            let rows = FanGeoProGameInboxPresentation.scoreboardRows(for: scoreItem.context.proGameSnapshot!)
            expect(rows[0].teamName == "St. Louis Cardinals" && rows[1].teamName == "Chicago Cubs", "inbox scoreboard shows both team names")
            expect(rows[0].score == 0 && rows[1].score == 3, "inbox scoreboard shows both stored scores")
            let art = FanGeoProGameInboxPresentation.artworkIdentities(for: scoreItem.context.proGameSnapshot!)
            expect(art.away.badgeURL == cardsBadge && art.home.badgeURL == cubsBadge, "both artwork identities are passed to the renderer")
            expect(
                FanGeoProGameInboxPresentation.footerLine(
                    for: scoreItem.context.proGameSnapshot!,
                    languageCode: "en"
                ) == "Chicago Cubs scored",
                "inbox score card names scoring team"
            )
            expect(
                !FanGeoActionCenterTeamNotificationPresentation.usesTeamChrome(for: scoreItem),
                "pro-game inbox row does not use Team event chrome"
            )
        } else {
            expect(false, "inbox score row maps to action item")
        }

        let missingScorerRow = FanNotificationInboxServerRow(
            id: UUID(),
            notification_type: "pro_game_score",
            title: "Score update",
            body: "St. Louis Cardinals 0 - 3 Chicago Cubs",
            kind_raw: "scheduleChange",
            destination_raw: "scheduleActivity",
            source_type: "pro_game_notification",
            source_id: "mlb-cubs-cardinals-2026-08-14",
            team_id: nil,
            event_id: nil,
            actor_user_id: nil,
            payload: [
                "match_id": .string("mlb-cubs-cardinals-2026-08-14"),
                "home_team": .string("Chicago Cubs"),
                "away_team": .string("St. Louis Cardinals"),
                "home_score": .string("3"),
                "away_score": .string("0")
            ],
            deduplication_key: "pro_game:score:mlb-cubs-cardinals-2026-08-14:missing-scorer",
            created_at: Date(),
            read_at: nil,
            cleared_at: nil
        )
        let missingScorer = FanGeoNotificationInboxEntry.from(serverRow: missingScorerRow).proGameSnapshot
        expect(missingScorer?.identifiedScoringTeam == nil, "inbox does not guess scoring team")
        expect(
            missingScorer.map { FanGeoProGameInboxPresentation.footerLine(for: $0, languageCode: "en") }
                == "Score updated",
            "inbox without scoring team shows Score updated"
        )

        let finalRow = FanNotificationInboxServerRow(
            id: UUID(),
            notification_type: "pro_game_final",
            title: "Final Score",
            body: "St. Louis Cardinals 0 - 3 Chicago Cubs",
            kind_raw: "scheduleChange",
            destination_raw: "scheduleActivity",
            source_type: "pro_game_notification",
            source_id: "mlb-cubs-cardinals-2026-08-14",
            team_id: nil,
            event_id: nil,
            actor_user_id: nil,
            payload: [
                "match_id": .string("mlb-cubs-cardinals-2026-08-14"),
                "home_team": .string("Chicago Cubs"),
                "away_team": .string("St. Louis Cardinals"),
                "home_score": .number(3),
                "away_score": .number(0),
                "league": .string("MLB"),
                "home_badge_url": .string(cubsBadge),
                "away_badge_url": .string(cardsBadge)
            ],
            deduplication_key: "pro_game:final:mlb-cubs-cardinals-2026-08-14:0-3",
            created_at: Date(),
            read_at: nil,
            cleared_at: nil
        )
        let finalSnapshot = FanGeoNotificationInboxEntry.from(serverRow: finalRow).proGameSnapshot
        expect(finalSnapshot?.homeTeam == "Chicago Cubs" && finalSnapshot?.awayTeam == "St. Louis Cardinals", "final inbox row has both teams")
        expect(finalSnapshot?.homeScore == 3 && finalSnapshot?.awayScore == 0, "final inbox row has both scores")
        expect(finalSnapshot?.winnerTeamName == "Chicago Cubs", "final inbox row derives winner from snapshot scores")

        let drawRow = FanNotificationInboxServerRow(
            id: UUID(),
            notification_type: "pro_game_final",
            title: "Final Score",
            body: "Arsenal 1 - 1 Chelsea",
            kind_raw: "scheduleChange",
            destination_raw: "scheduleActivity",
            source_type: "pro_game_notification",
            source_id: "epl-draw",
            team_id: nil,
            event_id: nil,
            actor_user_id: nil,
            payload: [
                "match_id": .string("epl-draw"),
                "home_team": .string("Arsenal"),
                "away_team": .string("Chelsea"),
                "home_score": .number(1),
                "away_score": .number(1)
            ],
            deduplication_key: "pro_game:final:epl-draw:1-1",
            created_at: Date(),
            read_at: nil,
            cleared_at: nil
        )
        expect(
            FanGeoNotificationInboxEntry.from(serverRow: drawRow).proGameSnapshot?.finalOutcome == .draw,
            "tied final inbox row is a draw"
        )

        let titleOnlyRow = FanNotificationInboxServerRow(
            id: UUID(),
            notification_type: "schedule_change",
            title: "Chicago Cubs scored",
            body: "Final Score",
            kind_raw: "scheduleChange",
            destination_raw: "scheduleActivity",
            source_type: nil,
            source_id: nil,
            team_id: nil,
            event_id: nil,
            actor_user_id: nil,
            payload: nil,
            deduplication_key: "push_notification:legacy-cubs",
            created_at: Date(),
            read_at: nil,
            cleared_at: nil
        )
        let titleOnlyEntry = FanGeoNotificationInboxEntry.from(serverRow: titleOnlyRow)
        expect(titleOnlyEntry.proGameSnapshot == nil, "legacy title-only rows stay generic")
        expect(titleOnlyEntry.eventTitle == "Chicago Cubs scored", "legacy title is not rewritten by parsing")
        if let titleOnlyItem = titleOnlyEntry.asActionItem() {
            expect(
                FanGeoProGameInboxPresentation.usesGenericTitleRenderer(titleOnlyItem),
                "legacy title-only row uses generic renderer"
            )
            expect(
                titleOnlyItem.title(languageCode: "en") == "Chicago Cubs scored",
                "legacy generic headline remains the stored title"
            )
        } else {
            expect(false, "legacy title-only row still maps to an action item")
        }

        let nestedServerRow = FanNotificationInboxServerRow(
            id: UUID(),
            notification_type: "pro_game_final",
            title: "Final Score",
            body: "St. Louis Cardinals 0 - 3 Chicago Cubs",
            kind_raw: "scheduleChange",
            destination_raw: "scheduleActivity",
            source_type: "pro_game_notification",
            source_id: "mlb-cubs-cardinals-2026-08-14",
            team_id: nil,
            event_id: nil,
            actor_user_id: nil,
            payload: [
                "payload": .object([
                    "homeTeam": .string("Chicago Cubs"),
                    "awayTeam": .string("St. Louis Cardinals"),
                    "homeScore": .number(3),
                    "awayScore": .number(0),
                    "matchId": .string("mlb-cubs-cardinals-2026-08-14")
                ])
            ],
            deduplication_key: "pro_game:final:mlb-cubs-cardinals-2026-08-14:nested",
            created_at: Date(),
            read_at: nil,
            cleared_at: nil
        )
        let nestedEntry = FanGeoNotificationInboxEntry.from(serverRow: nestedServerRow)
        expect(nestedEntry.proGameSnapshot?.isRenderable == true, "nested server payload still becomes a rich scoreboard")
        if let nestedItem = nestedEntry.asActionItem() {
            expect(
                FanGeoProGameInboxPresentation.usesGenericTitleRenderer(nestedItem) == false,
                "nested snapshot payload does not fall through to generic Final Score"
            )
            expect(nestedItem.context.proGameMatchId == "mlb-cubs-cardinals-2026-08-14", "nested payload keeps match_id deep link")
        } else {
            expect(false, "nested snapshot payload maps to an action item")
        }

        let ingestUserInfo: [AnyHashable: Any] = [
            "source": "pro_game_notification",
            "notification_type": "pro_game_score",
            "match_id": "mlb-cubs-cardinals-2026-08-14",
            "home_team": "Chicago Cubs",
            "away_team": "St. Louis Cardinals",
            "home_score": "3",
            "away_score": "0",
            "scoring_team": "Chicago Cubs",
            "league": "MLB",
            "home_badge_url": cubsBadge,
            "away_badge_url": cardsBadge,
            "inbox_dedupe_key": "pro_game:score:mlb-cubs-cardinals-2026-08-14:0-3"
        ]
        let ingestContent = UNMutableNotificationContent()
        ingestContent.title = "Chicago Cubs scored"
        ingestContent.body = "St. Louis Cardinals 0 - 3 Chicago Cubs"
        if let ingested = FanGeoNotificationInboxIngest.makeItem(
            userInfo: ingestUserInfo,
            content: ingestContent
        ) {
            expect(ingested.context.proGameSnapshot?.homeScore == 3, "APNs ingest stores score snapshot")
            expect(ingested.context.proGameSnapshot?.awayTeam == "St. Louis Cardinals", "APNs ingest stores both teams")
            expect(ingested.context.proGameMatchId == "mlb-cubs-cardinals-2026-08-14", "APNs ingest keeps match id")
            expect(
                ingested.destination == .scheduleActivity,
                "APNs ingest keeps existing pro-game destination"
            )
            expect(
                FanGeoProGameInboxPresentation.usesGenericTitleRenderer(ingested) == false,
                "APNs snapshot ingest uses the rich scoreboard, not generic title"
            )
            let roundtripUserId = UUID()
            FanGeoNotificationInboxStore.clearMemory(userId: roundtripUserId)
            _ = FanGeoNotificationInboxStore.upsert(items: [ingested], userId: roundtripUserId)
            let stored = FanGeoNotificationInboxStore.visibleEntries(userId: roundtripUserId).first
            expect(stored?.proGameSnapshot?.homeScore == 3, "stored inbox snapshot remains 3-0")
            expect(stored?.proGameSnapshot?.awayScore == 0, "stored inbox snapshot does not read live state")
        } else {
            expect(false, "structured pro-game APNs ingest creates an inbox item")
        }

        if let teamEventItem = historicalEntry.asActionItem() {
            expect(
                teamEventItem.title(languageCode: "en") == "Practice Updated",
                "Team event notification cards remain Practice Updated"
            )
            expect(
                FanGeoActionCenterTeamNotificationPresentation.usesTeamChrome(for: teamEventItem),
                "Team event notification chrome is unchanged"
            )
            expect(
                FanGeoActionCenterLeadingIdentity.source(for: teamEventItem) != .personAvatar,
                "historical practice card does not use player avatar as leading artwork"
            )
        } else {
            expect(false, "Team event historical row still maps to an action item")
        }
        expect(
            !SportsArtworkEnrichmentService.usesDirectTheSportsDBAPI,
            "inbox artwork path does not call TheSportsDB from iOS"
        )
        expect(FanGeoInboxChrome.showsFilterToolbar == false, "inbox store path has no Filter chrome")
        expect(FanGeoInboxChrome.showsComposeButton == false, "inbox store path has no compose pencil")
        let groupedInbox = FanGeoInboxDateGrouping.groups(items: [item], languageCode: "en")
        expect(groupedInbox.count == 1, "single notification still groups")
        expect(
            groupedInbox.first?.entries.map(\.id) == [item.id],
            "grouping preserves stable notification row IDs"
        )

        let dupUser = UUID()
        FanGeoNotificationInboxStore.clearMemory(userId: dupUser)
        func dupServerRow(title: String, createdAt: Date, dedupe: String) -> FanNotificationInboxServerRow {
            FanNotificationInboxServerRow(
                id: UUID(),
                notification_type: "created",
                title: title,
                body: "B",
                kind_raw: "scheduleChange",
                destination_raw: "scheduleActivity",
                source_type: nil,
                source_id: nil,
                team_id: nil,
                event_id: nil,
                actor_user_id: nil,
                payload: nil,
                deduplication_key: dedupe,
                created_at: createdAt,
                read_at: nil,
                cleared_at: nil
            )
        }
        let uniqueOlder = dupServerRow(
            title: "Unique Older",
            createdAt: Date().addingTimeInterval(-120),
            dedupe: "dup-test:unique-older"
        )
        let uniqueNewer = dupServerRow(
            title: "Unique Newer",
            createdAt: Date().addingTimeInterval(-30),
            dedupe: "dup-test:unique-newer"
        )
        let uniqueResult = FanGeoNotificationInboxStore.reconcileFromServer(
            rows: [uniqueOlder, uniqueNewer],
            userId: dupUser
        )
        expect(uniqueResult.count == 2, "1 unique IDs keep both rows")
        expect(uniqueResult.map(\.id) == [
            FanGeoActionCenterActionKey.sanitize("dup-test:unique-newer"),
            FanGeoActionCenterActionKey.sanitize("dup-test:unique-older")
        ], "1 unique IDs keep newest-first order")
        expect(
            uniqueResult.map { $0.titleFormatArgs.first } == ["Unique Newer", "Unique Older"],
            "1 unique IDs keep titles unchanged"
        )

        FanGeoNotificationInboxStore.clearMemory(userId: dupUser)
        let sharedDedupe = "dup-test:shared-key"
        let olderDup = dupServerRow(
            title: "Older Duplicate",
            createdAt: Date().addingTimeInterval(-90),
            dedupe: sharedDedupe
        )
        let newerDup = dupServerRow(
            title: "Newer Duplicate",
            createdAt: Date().addingTimeInterval(-10),
            dedupe: sharedDedupe
        )
        let serverDupForward = FanGeoNotificationInboxStore.reconcileFromServer(
            rows: [olderDup, newerDup],
            userId: dupUser
        )
        expect(serverDupForward.count == 1, "2 duplicate server IDs collapse to one row")
        expect(
            serverDupForward.first?.titleFormatArgs.first == "Newer Duplicate",
            "2/4 newer timestamp wins when older is first"
        )

        FanGeoNotificationInboxStore.clearMemory(userId: dupUser)
        let serverDupReversed = FanGeoNotificationInboxStore.reconcileFromServer(
            rows: [newerDup, olderDup],
            userId: dupUser
        )
        expect(serverDupReversed.count == 1, "2 duplicate server IDs reversed still one row")
        expect(
            serverDupReversed.first?.titleFormatArgs.first == "Newer Duplicate",
            "4 newer timestamp wins when newer is first"
        )

        FanGeoNotificationInboxStore.clearMemory(userId: dupUser)
        let olderLocal = FanGeoNotificationInboxEntry.from(serverRow: olderDup)
        let newerLocal = FanGeoNotificationInboxEntry.from(serverRow: newerDup)
        FanGeoNotificationInboxStore.save(entries: [olderLocal, newerLocal], userId: dupUser)
        let afterLocalDedupe = FanGeoNotificationInboxStore.upsert(items: [], userId: dupUser)
        expect(afterLocalDedupe.count == 1, "3 duplicate local cache IDs collapse without crash")
        expect(
            afterLocalDedupe.first?.titleFormatArgs.first == "Newer Duplicate",
            "3/4 local cache keeps newer timestamp"
        )

        FanGeoNotificationInboxStore.clearMemory(userId: dupUser)
        let firstPass = FanGeoNotificationInboxStore.reconcileFromServer(
            rows: [olderDup, newerDup, uniqueOlder],
            userId: dupUser
        )
        let secondPass = FanGeoNotificationInboxStore.reconcileFromServer(
            rows: [olderDup, newerDup, uniqueOlder],
            userId: dupUser
        )
        expect(firstPass.count == 2, "5 repeated reconcile keeps unique+deduped count")
        expect(
            firstPass.map(\.id) == secondPass.map(\.id)
                && firstPass.map { $0.titleFormatArgs.first } == secondPass.map { $0.titleFormatArgs.first },
            "5 repeated reconcile with same duplicates is deterministic"
        )
        expect(
            firstPass.map { $0.titleFormatArgs.first } == ["Newer Duplicate", "Unique Older"],
            "6 order after dedupe stays newest-first"
        )

        let clearedDup = FanGeoNotificationInboxStore.clear(
            ids: [sharedDedupe],
            userId: dupUser
        )
        expect(
            clearedDup.map { $0.titleFormatArgs.first } == ["Unique Older"],
            "7 dismiss still removes only the cleared id"
        )
        expect(
            FanGeoActionCenterProjection.snapshot(
                from: .init(
                    teamInvitationCount: 1,
                    isSignedInForSocial: true,
                    persistedNotifications: FanGeoNotificationInboxStore.visibleEntries(userId: dupUser)
                        .compactMap { $0.asActionItem() }
                )
            ).actionNeededItems.contains(where: { $0.kind == .teamInvitation }),
            "7 Action Needed remains independent after duplicate reconcile"
        )
        FanGeoNotificationInboxStore.clearMemory(userId: dupUser)

        let clearAllUser = UUID()
        FanGeoNotificationInboxStore.clearMemory(userId: clearAllUser)
        let notifA = FanGeoActionItem(
            id: "pickup_update:clear-all-a",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["A"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            timestamp: Date()
        )
        let notifB = FanGeoActionItem(
            id: "pickup_update:clear-all-b",
            kind: .poke,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["B"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .accountPokes,
            timestamp: Date()
        )
        _ = FanGeoNotificationInboxStore.upsert(items: [notifA, notifB], userId: clearAllUser)
        expect(
            FanGeoInboxChrome.showsClearAllControl(
                notificationItemCount: FanGeoNotificationInboxStore.visibleEntries(userId: clearAllUser).count
            ),
            "Clear All available when notification rows exist"
        )
        let beforeClearAll = FanGeoNotificationInboxStore.visibleEntries(userId: clearAllUser)
        expect(beforeClearAll.count == 2, "Clear All cancel path keeps rows")
        let afterClearAll = FanGeoNotificationInboxStore.clearAll(userId: clearAllUser)
        expect(afterClearAll.isEmpty, "confirmed Clear All reuses existing notifications clear path")
        expect(
            FanGeoInboxChrome.showsClearAllControl(
                notificationItemCount: afterClearAll.count,
                actionNeededItemCount: 0
            ) == false,
            "Clear All hidden when both visible lists are empty"
        )
        expect(
            FanGeoInboxChrome.showsClearAllControl(
                notificationItemCount: 0,
                actionNeededItemCount: 2
            ),
            "Clear All remains visible when only Action Needed has rows"
        )
        let actionNeededAfterClearAll = FanGeoActionCenterProjection.snapshot(
            from: .init(
                teamInvitationCount: 2,
                isSignedInForSocial: true,
                persistedNotifications: afterClearAll.compactMap { $0.asActionItem() }
            )
        )
        expect(
            actionNeededAfterClearAll.actionNeededItems.contains(where: { $0.kind == .teamInvitation }),
            "notification-store clearAll does not resolve Action Needed"
        )
        expect(
            FanGeoInboxChrome.notificationsTabCount(unreadCount: 0) == 0
                && FanGeoInboxChrome.envelopeBadgeCount(
                    notificationsCount: 0,
                    actionNeededCount: FanGeoInboxChrome.actionNeededTabCount(
                        items: actionNeededAfterClearAll.actionNeededItems
                    )
                ) == actionNeededAfterClearAll.actionNeededItems.reduce(0) { $0 + $1.count },
            "tab and envelope counts update immediately after confirmed Clear All"
        )
        let coldAfterClearAll = FanGeoNotificationInboxStore.visibleEntries(userId: clearAllUser)
        expect(coldAfterClearAll.isEmpty, "cold relaunch does not resurrect locally-cleared notifications")

        FanGeoNotificationInboxStore.clearMemory(userId: clearAllUser)
        let dupClearId = "pickup_update:clear-all-dup"
        let olderClearDup = FanNotificationInboxServerRow(
            id: UUID(),
            notification_type: "team_event_updated",
            title: "Older Clear Dup",
            body: "Practice",
            kind_raw: "scheduleChange",
            destination_raw: "scheduleActivity",
            source_type: nil,
            source_id: nil,
            team_id: nil,
            event_id: nil,
            actor_user_id: nil,
            payload: [:],
            deduplication_key: dupClearId,
            created_at: Date().addingTimeInterval(-60),
            read_at: nil,
            cleared_at: nil
        )
        let newerClearDup = FanNotificationInboxServerRow(
            id: UUID(),
            notification_type: "team_event_updated",
            title: "Newer Clear Dup",
            body: "Practice",
            kind_raw: "scheduleChange",
            destination_raw: "scheduleActivity",
            source_type: nil,
            source_id: nil,
            team_id: nil,
            event_id: nil,
            actor_user_id: nil,
            payload: [:],
            deduplication_key: dupClearId,
            created_at: Date(),
            read_at: nil,
            cleared_at: nil
        )
        _ = FanGeoNotificationInboxStore.reconcileFromServer(
            rows: [olderClearDup, newerClearDup],
            userId: clearAllUser
        )
        expect(
            FanGeoNotificationInboxStore.visibleEntries(userId: clearAllUser).count == 1,
            "duplicate IDs still collapse before Clear All"
        )
        expect(
            FanGeoNotificationInboxStore.clearAll(userId: clearAllUser).isEmpty,
            "duplicate IDs do not affect Clear All"
        )
        FanGeoNotificationInboxStore.clearMemory(userId: clearAllUser)

        if failures == 0 {
            print("[FanNotificationInboxTest] ALL PASSED")
        } else {
            print("[FanNotificationInboxTest] FAILURES=\(failures)")
            assertionFailure("FanGeoNotificationInboxSelfTests failed: \(failures)")
        }
    }
}
#endif
