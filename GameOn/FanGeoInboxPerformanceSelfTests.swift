import Foundation

#if DEBUG
enum FanGeoInboxPerformanceFixture {
    static func makeHundredRows(now: Date = Date()) -> [FanGeoActionItem] {
        var items: [FanGeoActionItem] = []
        items.reserveCapacity(100)
        let calendar = Calendar(identifier: .gregorian)
        func stamp(_ offsetHours: Int) -> Date {
            calendar.date(byAdding: .hour, value: -offsetHours, to: now) ?? now
        }

        for i in 0 ..< 25 {
            let teamId = UUID()
            items.append(
                FanGeoActionItem(
                    id: "pickup_update:perf-practice-\(i)",
                    kind: .scheduleChange,
                    titleKey: "action_center_notification_title_passthrough_format",
                    titleFormatArgs: ["Practice Updated"],
                    subtitleKey: "action_center_notification_subtitle_default",
                    destination: .scheduleActivity,
                    timestamp: stamp(i),
                    context: FanGeoActionContext(
                        personName: "FanGeo",
                        personAvatarURL: "https://example.test/player-\(i).jpg",
                        teamName: "ER basketball",
                        eventTitle: "Practice",
                        eventTypeLabel: "practice",
                        locationLabel: "Intermountain Medical Center Oncology Clinic, Salt Lake City, UT",
                        eventStartAt: stamp(i + 24),
                        pickupGameId: UUID(),
                        teamId: teamId,
                        sportLabel: "basketball",
                        notificationType: "team_event_updated",
                        managedPlayerId: UUID()
                    )
                )
            )
        }

        for i in 0 ..< 25 {
            let snapshot = FanGeoProGameInboxSnapshot(
                kind: .final,
                matchID: "perf-final-\(i)",
                homeTeam: "Salt Lake Bees",
                awayTeam: "El Paso Chihuahuas",
                homeScore: 8,
                awayScore: 2,
                scoringTeam: nil,
                league: "Pacific Coast League",
                sport: "Baseball",
                matchStatus: "FT",
                clock: nil,
                homeBadgeURL: "https://example.test/bees.png",
                awayBadgeURL: "https://example.test/chihuahuas.png",
                homeProviderId: "bees",
                awayProviderId: "chihuahuas"
            )
            items.append(
                FanGeoActionItem(
                    id: "pro_game:final:perf-\(i)",
                    kind: .scheduleChange,
                    titleKey: "action_center_notification_title_passthrough_format",
                    titleFormatArgs: ["Final Score"],
                    subtitleKey: "action_center_notification_subtitle_default",
                    destination: .scheduleActivity,
                    timestamp: stamp(25 + i),
                    context: FanGeoActionContext(
                        notificationType: "pro_game_final",
                        proGameMatchId: snapshot.matchID,
                        proGameSnapshot: snapshot
                    )
                )
            )
        }

        for i in 0 ..< 25 {
            items.append(
                FanGeoActionItem(
                    id: "pro_game:legacy:perf-\(i)",
                    kind: .scheduleChange,
                    titleKey: "action_center_notification_title_passthrough_format",
                    titleFormatArgs: ["Chicago Cubs scored"],
                    subtitleKey: "action_center_notification_subtitle_default",
                    destination: .scheduleActivity,
                    timestamp: stamp(50 + i),
                    context: FanGeoActionContext(notificationType: "pro_game_score")
                )
            )
        }

        for i in 0 ..< 25 {
            items.append(
                FanGeoActionItem(
                    id: "team:removed:perf-\(i)",
                    kind: .scheduleChange,
                    titleKey: "action_center_notification_title_passthrough_format",
                    titleFormatArgs: ["Removed from Team"],
                    subtitleKey: "action_center_notification_subtitle_default",
                    destination: .teamsHome,
                    timestamp: stamp(75 + i),
                    context: FanGeoActionContext(
                        teamName: "ER basketball",
                        teamId: UUID(),
                        sportLabel: "Basketball",
                        notificationType: "removed_from_team"
                    )
                )
            )
        }
        return items
    }
}

enum FanGeoInboxPerformanceSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[InboxPerfTest] PASS \(name)")
            } else {
                failures += 1
                print("[InboxPerfTest] FAIL \(name)")
            }
        }

        FanGeoNotificationInboxStore.resetPerformanceFlagsForTests()
        let userId = UUID()
        FanGeoNotificationInboxStore.clearMemory(userId: userId)

        let rows = FanGeoInboxPerformanceFixture.makeHundredRows()
        expect(rows.count == 100, "100-row fixture size")
        expect(Set(rows.map(\.id)).count == 100, "stable unique ForEach IDs")
        expect(
            rows.allSatisfy { !$0.id.isEmpty && UUID(uuidString: $0.id) == nil },
            "IDs are domain keys, not random UUIDs or offsets"
        )
        expect(FanGeoInboxChrome.usesLazyNotificationList, "Notifications list is lazy")
        expect(
            FanGeoInboxChrome.notificationListDisablesAnimations,
            "notification list does not animate the whole array"
        )

        let grouped = FanGeoInboxDateGrouping.groups(items: rows, languageCode: "en")
        expect(!grouped.isEmpty, "100-row fixture groups by date")
        expect(
            grouped.flatMap(\.entries).map(\.id) == rows.map(\.id),
            "grouping preserves notification order"
        )
        expect(
            grouped.allSatisfy { $0.entries.count == Set($0.entries.map(\.id)).count },
            "no duplicate IDs inside groups"
        )

        let practice = rows.first { $0.id.contains("practice") }!
        let unrelated = rows.first { $0.id.contains("final") }!
        expect(
            FanGeoInboxTeamEventCardLayout.usesTeamLogoAsPrimaryArtwork(for: practice),
            "practice rows keep Team leading artwork"
        )
        let tokenA = FanGeoInboxChrome.playerAvatarRefreshToken(for: practice)
        let tokenB = FanGeoInboxChrome.playerAvatarRefreshToken(for: practice)
        expect(tokenA == tokenB, "player avatar hydration uses a stable refresh token")
        expect(
            FanGeoInboxChrome.playerAvatarRefreshToken(for: unrelated) != tokenA
                || unrelated.context.personAvatarURL != practice.context.personAvatarURL,
            "player avatar hydration does not share identity with unrelated rows"
        )

        let practiceCardA = FanGeoActionCenterCard(
            item: practice,
            languageCode: "en",
            showsUnreadDot: true,
            timestampLabel: "Today",
            onSelect: {}
        )
        let practiceCardB = FanGeoActionCenterCard(
            item: practice,
            languageCode: "en",
            showsUnreadDot: true,
            timestampLabel: "Today",
            onSelect: {}
        )
        var hydratedUnrelated = unrelated
        hydratedUnrelated = FanGeoActionItem(
            id: unrelated.id,
            kind: unrelated.kind,
            titleKey: unrelated.titleKey,
            titleFormatArgs: unrelated.titleFormatArgs,
            subtitleKey: unrelated.subtitleKey,
            subtitleFormatArgs: unrelated.subtitleFormatArgs,
            destination: unrelated.destination,
            timestamp: unrelated.timestamp,
            count: unrelated.count,
            context: {
                var context = unrelated.context
                context.personAvatarURL = "https://example.test/other-hydrated.jpg"
                return context
            }(),
            ctaKeyOverride: unrelated.ctaKeyOverride
        )
        expect(practiceCardA == practiceCardB, "identical rows skip card rebuild")
        expect(
            practiceCardA != FanGeoActionCenterCard(
                item: hydratedUnrelated,
                languageCode: "en",
                showsUnreadDot: true,
                timestampLabel: "Today",
                onSelect: {}
            ),
            "artwork hydration on another row does not share this row identity"
        )
        expect(practice.id != hydratedUnrelated.id, "Team artwork hydration is targeted by row ID")

        let snapshotRow = rows.first { $0.id.contains("final") }!
        expect(
            FanGeoProGameInboxPresentation.isProGame(snapshotRow),
            "snapshot rows stay rich"
        )
        expect(
            FanGeoProGameInboxPresentation.usesGenericTitleRenderer(snapshotRow) == false,
            "rich snapshot is not re-parsed from title"
        )
        expect(
            snapshotRow.context.proGameSnapshot?.homeTeam == "Salt Lake Bees",
            "rich snapshot is parsed once at projection"
        )

        let legacy = rows.first { $0.id.contains("legacy") }!
        expect(
            FanGeoProGameInboxPresentation.usesGenericTitleRenderer(legacy),
            "legacy generic row stays lightweight"
        )
        expect(
            FanGeoProGameInboxSnapshot.from(
                userInfo: ["title": "Chicago Cubs scored"],
                notificationType: nil
            ) == nil,
            "legacy rows do not reconstruct snapshots"
        )

        let actionNeeded = FanGeoActionItem(
            id: "join:perf-independent",
            kind: .joinApproval,
            titleKey: "action_center_join_approval_title_one",
            subtitleKey: "action_center_join_approval_subtitle",
            destination: .goingHostingApprovals
        )
        let mixed = FanGeoActionCenterProjection.snapshot(
            from: .init(
                joinApprovals: [
                    FanGeoActionJoinApprovalInput(
                        requestId: UUID(),
                        pickupGameId: UUID(),
                        requesterUserId: UUID(),
                        requesterName: "Alex",
                        gameTitle: "Pickup",
                        teamName: nil
                    )
                ],
                pendingJoinApprovalCount: 1,
                isSignedInForSocial: true,
                persistedNotifications: rows,
                unreadNotificationIds: Set(rows.map(\.id)),
                clearedNotificationKeys: []
            )
        )
        expect(
            mixed.actionNeededItems.contains(where: { $0.kind == FanGeoActionKind.joinApproval }),
            "Action Needed stays independent of Notifications"
        )
        expect(
            mixed.notificationItems.count == 100,
            "Notifications stay independent of Action Needed"
        )
        expect(
            FanGeoInboxChrome.actionNeededTabCount(items: [actionNeeded]) == 1,
            "Action Needed tab count ignores notification rows"
        )
        expect(
            FanGeoInboxChrome.notificationsTabCount(unreadCount: 100) == 100,
            "Notifications unread is independent of Action Needed"
        )
        expect(
            FanGeoInboxChrome.envelopeBadgeCount(notificationsCount: 100, actionNeededCount: 1) == 101,
            "envelope aggregate uses both tab counts"
        )

        let first = FanGeoNotificationInboxStore.upsert(items: Array(rows.prefix(3)), userId: userId)
        FanGeoNotificationInboxStore.resetPerformanceFlagsForTests()
        let second = FanGeoNotificationInboxStore.upsert(items: Array(rows.prefix(3)), userId: userId)
        expect(first.map(\.id) == second.map(\.id), "repeat upsert keeps stable order")
        expect(
            FanGeoNotificationInboxStore.lastSaveSkippedAsDuplicate,
            "unchanged persist does not rewrite"
        )
        expect(
            FanGeoNotificationInboxStore.presentationEquals(first, second),
            "unchanged upsert does not change presentation"
        )

        let server = first.map { entry in
            FanNotificationInboxServerRow(
                id: UUID(),
                notification_type: entry.notificationType ?? "team_event_updated",
                title: entry.titleFormatArgs.first ?? "Practice Updated",
                body: entry.eventTitle ?? "",
                kind_raw: entry.kindRaw,
                destination_raw: entry.destinationRaw,
                source_type: nil,
                source_id: nil,
                team_id: entry.teamId,
                event_id: entry.pickupGameId,
                actor_user_id: nil,
                payload: nil,
                deduplication_key: entry.id,
                created_at: entry.createdAt,
                read_at: entry.isRead ? Date() : nil,
                cleared_at: nil
            )
        }
        _ = FanGeoNotificationInboxStore.reconcileFromServer(rows: server, userId: userId)
        FanGeoNotificationInboxStore.resetPerformanceFlagsForTests()
        let reconciledAgain = FanGeoNotificationInboxStore.reconcileFromServer(rows: server, userId: userId)
        expect(Set(reconciledAgain.map(\.id)) == Set(first.map(\.id)), "reconcile preserves stable IDs")
        expect(
            FanGeoNotificationInboxStore.lastReconcileDidChange == false,
            "unchanged reconcile does not publish"
        )

        let localBeforeFailure = FanGeoNotificationInboxStore.visibleEntries(userId: userId)
        expect(!localBeforeFailure.isEmpty, "local rows paint before remote reconcile")
        expect(
            FanGeoNotificationInboxStore.presentationEquals(
                localBeforeFailure,
                FanGeoNotificationInboxStore.visibleEntries(userId: userId)
            ),
            "reconcile failure path keeps local rows"
        )

        let timeA = FanGeoInboxTimeFormatting.shortTime(Date(), languageCode: "en")
        let timeB = FanGeoInboxTimeFormatting.shortTime(Date(), languageCode: "en")
        expect(!timeA.isEmpty && !timeB.isEmpty, "date formatter reuse stays available")

        expect(
            !SportsArtworkEnrichmentService.usesDirectTheSportsDBAPI,
            "no per-cell TheSportsDB fetch"
        )
        expect(
            DiscoverMapImageCache.Bucket.forPointSize(52) == .avatar,
            "Inbox marks use the small avatar decode bucket"
        )
        expect(
            DiscoverMapImageCache.Bucket.forPointSize(32) == .avatar,
            "pro-game 32pt logos use the small decode bucket"
        )
        expect(
            DiscoverMapImageCache.Bucket.forPointSize(52) == DiscoverMapImageCache.Bucket.forPointSize(32),
            "image requests coalesce into the same small decode bucket"
        )
        expect(
            FanGeoInboxPerformanceDebug.injectHundredRowFixture == false,
            "100-row fixture is not injected into production Inbox"
        )

        FanGeoNotificationInboxStore.clearMemory(userId: userId)
        expect(
            FanGeoNotificationInboxStore.visibleEntries(userId: userId).isEmpty,
            "fixture is not persisted after tests"
        )

        if failures == 0 {
            print("[InboxPerfTest] ALL PASSED")
        } else {
            print("[InboxPerfTest] FAILURES=\(failures)")
            assertionFailure("FanGeoInboxPerformanceSelfTests failed: \(failures)")
        }
    }
}
#endif
