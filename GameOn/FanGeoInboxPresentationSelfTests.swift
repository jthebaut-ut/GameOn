import Foundation

#if DEBUG
enum FanGeoInboxPresentationSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[InboxPresentationTest] PASS \(name)")
            } else {
                failures += 1
                print("[InboxPresentationTest] FAIL \(name)")
            }
        }

        expect(
            FanGeoInboxChrome.envelopeSymbol == "envelope.fill",
            "header uses Inbox envelope treatment"
        )
        expect(
            FanGeoInboxChrome.tabOrder == [.notifications, .actionNeeded],
            "Notifications is visually first, Action Needed second"
        )
        expect(
            FanGeoActionCenterListSection.allCases == [.actionNeeded, .notifications],
            "CaseIterable / default selection order is unchanged"
        )
        expect(FanGeoInboxChrome.showsFilterToolbar == false, "no Filter control exists")
        expect(FanGeoInboxChrome.showsUnreadFilter == false, "no Unread control exists")
        expect(FanGeoInboxChrome.showsSearch == false, "no Search control exists")
        expect(FanGeoInboxChrome.showsNewestSort == false, "no Newest control exists")
        expect(FanGeoInboxChrome.showsComposeButton == false, "no floating pencil exists")
        expect(FanGeoInboxChrome.showsMockupBottomTabBar == false, "no mockup bottom-tab navigation")
        expect(
            !FanGeoInboxChrome.forbiddenToolbarTitles.contains(where: {
                FanGeoInboxChrome.envelopeSymbol.localizedCaseInsensitiveContains($0)
            }),
            "envelope chrome is not a Filter/Unread/Search/Newest control"
        )
        expect(
            FanGeoInboxChrome.tabSystemImage(for: .notifications) == "bell.fill",
            "Notifications tab uses bell.fill"
        )
        expect(
            FanGeoInboxChrome.tabSystemImage(for: .actionNeeded) == "checklist",
            "Action Needed tab uses checklist"
        )
        expect(
            FanGeoInboxChrome.cardMenuSymbol == "ellipsis",
            "legacy overflow symbol is unchanged"
        )
        expect(
            FanGeoInboxChrome.usesVisibleHeaderClearAll == true
                && FanGeoInboxChrome.usesOverflowClearAllMenu == false,
            "Clear All is a visible header control, not an overflow menu"
        )
        expect(
            FanGeoInboxChrome.showsClearAllControl(notificationItemCount: 0) == false,
            "Clear All is hidden when nothing is clearable"
        )
        expect(
            FanGeoInboxChrome.showsClearAllControl(notificationItemCount: 1, actionNeededItemCount: 0) == true,
            "Clear All visible when Notifications 1 / Action Needed 0"
        )
        expect(
            FanGeoInboxChrome.showsClearAllControl(notificationItemCount: 0, actionNeededItemCount: 1) == true,
            "Clear All visible when Notifications 0 / Action Needed 1"
        )
        expect(
            FanGeoInboxChrome.showsClearAllControl(notificationItemCount: 3, actionNeededItemCount: 2) == true,
            "Clear All visible when both tabs have content"
        )
        expect(
            FanGeoInboxChrome.showsClearAllControl(notificationItemCount: 0, actionNeededItemCount: 0) == false,
            "Clear All hidden when both tabs are empty"
        )
        expect(
            FanGeoInboxChrome.showsClearAllControl(notificationItemCount: 2) == true,
            "Clear All is available when notification rows exist"
        )
        expect(
            FanGeoInboxChrome.showsClearAllControl(notificationItemCount: 2, canClear: false) == false,
            "Clear All stays hidden when the existing action is unavailable"
        )
        expect(
            FanGeoInboxChrome.clearAllClearsNotificationsOnly == false
                && FanGeoInboxChrome.clearAllClearsActionNeeded == true,
            "Clear All clears currently visible Notifications and Action Needed"
        )
        expect(
            L10n.t("action_center_clear_all", languageCode: "en") == "Clear All",
            "visible Clear All uses the existing compact localization key"
        )
        expect(
            FanGeoInboxChrome.cardDismissSymbol == "xmark",
            "notification card uses X, not ellipsis menu"
        )
        expect(
            FanGeoInboxChrome.usesPerCardDismissMenu == false,
            "one tap invokes existing dismiss action with no menu"
        )
        expect(
            FanGeoInboxChrome.requiresSingleItemDismissConfirmation == false,
            "no confirmation for single dismiss"
        )
        expect(
            FanGeoInboxChrome.clearAllRequiresConfirmation == true,
            "Clear All confirmation remains unchanged"
        )
        expect(
            L10n.t("action_center_clear_confirm_title", languageCode: "en") == "Clear FanGeo Inbox?",
            "Clear All uses the existing Inbox confirmation title"
        )
        expect(
            L10n.t("action_center_clear_confirm_message", languageCode: "en")
                .contains("does not delete"),
            "Clear All confirmation states underlying activity is not deleted"
        )
        expect(
            FanGeoInboxChrome.cardDismissConsumesTap == true,
            "tapping X does not activate card deep link"
        )
        expect(
            FanGeoInboxChrome.composeSymbol != FanGeoInboxChrome.cardDismissSymbol,
            "dismiss X is not a compose pencil"
        )
        expect(
            FanGeoInboxChrome.cardDismissSymbol != FanGeoInboxChrome.cardMenuSymbol,
            "per-card X is distinct from header overflow ellipsis"
        )
        expect(
            FanGeoInboxChrome.cardDismissAccessibilityKey == "action_center_dismiss_item_a11y",
            "X reuses the existing dismiss accessibility string"
        )
        expect(
            !L10n.t(FanGeoInboxChrome.cardDismissAccessibilityKey, languageCode: "en").isEmpty,
            "dismiss accessibility label is localized"
        )

        expect(
            FanGeoInboxChrome.notificationsTabCount(unreadCount: 8) == 8,
            "Notifications 8 → tab still 8"
        )
        expect(
            FanGeoInboxChrome.actionNeededTabCount(items: [
                FanGeoActionItem(
                    id: "join:1",
                    kind: .joinApproval,
                    titleKey: "action_center_join_approval_title",
                    subtitleKey: "action_center_join_approval_subtitle",
                    destination: .goingHostingApprovals,
                    count: 2
                ),
                FanGeoActionItem(
                    id: "invite:1",
                    kind: .teamInvitation,
                    titleKey: "action_center_team_invite_title",
                    subtitleKey: "action_center_team_invite_subtitle",
                    destination: .teamsHome,
                    count: 1
                )
            ]) == 3,
            "Action Needed 3 → tab still 3"
        )
        expect(
            FanGeoInboxChrome.envelopeBadgeCount(notificationsCount: 8, actionNeededCount: 3) == 11,
            "Notifications 8 + Action Needed 3 → envelope 11"
        )
        expect(
            FanGeoInboxChrome.showsEnvelopeBadge(totalCount: 11),
            "envelope badge shows when total Inbox count > 0"
        )
        expect(
            FanGeoInboxChrome.showsEnvelopeBadge(totalCount: 0) == false,
            "0 + 0 → envelope badge hidden"
        )
        expect(
            FanGeoInboxChrome.envelopeBadgeCount(notificationsCount: 7, actionNeededCount: 3) == 10,
            "dismiss Notification updates aggregate"
        )
        expect(
            FanGeoInboxChrome.envelopeBadgeCount(notificationsCount: 7, actionNeededCount: 2) == 9,
            "resolve Action Needed updates aggregate"
        )
        expect(
            FanGeoInboxChrome.envelopeBadgeCount(notificationsCount: 8, actionNeededCount: 3)
                == FanGeoInboxChrome.notificationsTabCount(unreadCount: 8)
                + FanGeoInboxChrome.actionNeededTabCount(items: [
                    FanGeoActionItem(
                        id: "join:1",
                        kind: .joinApproval,
                        titleKey: "action_center_join_approval_title",
                        subtitleKey: "action_center_join_approval_subtitle",
                        destination: .goingHostingApprovals,
                        count: 2
                    ),
                    FanGeoActionItem(
                        id: "invite:1",
                        kind: .teamInvitation,
                        titleKey: "action_center_team_invite_title",
                        subtitleKey: "action_center_team_invite_subtitle",
                        destination: .teamsHome,
                        count: 1
                    )
                ]),
            "no count drift after reconcile"
        )
        expect(
            FanGeoInboxChrome.notificationsTabCount(unreadCount: 8)
                != FanGeoInboxChrome.envelopeBadgeCount(notificationsCount: 8, actionNeededCount: 3),
            "Notifications tab does not show the envelope total"
        )
        expect(
            FanGeoActionCenterProjection.badgeLabel(100) == "99+",
            "large envelope count keeps 99+"
        )
        expect(
            FanGeoInboxChrome.clearAllRequiresConfirmation == true,
            "Clear All confirmation remains unchanged"
        )
        expect(
            FanGeoInboxChrome.usesVisibleHeaderClearAll == true,
            "Clear All remains a visible header control"
        )
        expect(
            FanGeoInboxChrome.tabOrder == [.notifications, .actionNeeded],
            "existing tab selection/default behavior unchanged"
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 15, hour: 10, minute: 58))!

        func item(id: String, dayOffset: Int, hour: Int, minute: Int) -> FanGeoActionItem {
            let date = calendar.date(
                byAdding: .day,
                value: -dayOffset,
                to: calendar.date(
                    from: DateComponents(year: 2026, month: 8, day: 15, hour: hour, minute: minute)
                )!
            )!
            return FanGeoActionItem(
                id: id,
                kind: .scheduleChange,
                titleKey: "action_center_notification_title_passthrough_format",
                titleFormatArgs: [id],
                subtitleKey: "action_center_notification_subtitle_default",
                destination: .scheduleActivity,
                timestamp: date
            )
        }

        let todayNewer = item(id: "today-a", dayOffset: 0, hour: 8, minute: 14)
        let todayOlder = item(id: "today-b", dayOffset: 0, hour: 7, minute: 0)
        let yesterdayItem = item(id: "yesterday", dayOffset: 1, hour: 9, minute: 0)
        let twoDays = item(id: "two-days", dayOffset: 2, hour: 11, minute: 0)
        let older = item(id: "older", dayOffset: 10, hour: 12, minute: 0)
        let undated = FanGeoActionItem(
            id: "undated",
            kind: .poke,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["Poke"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .accountPokes
        )

        let grouped = FanGeoInboxDateGrouping.groups(
            items: [todayNewer, todayOlder, yesterdayItem, twoDays, older, undated],
            languageCode: "en",
            now: now,
            calendar: calendar
        )
        expect(grouped.map(\.kind) == [
            .today,
            .yesterday,
            .daysAgo(2),
            FanGeoInboxDateGrouping.groupKind(for: older, now: now, calendar: calendar),
            .older
        ], "date grouping is stable and uses today / yesterday / days ago / older")
        expect(
            grouped[0].entries.map(\.id) == ["today-a", "today-b"],
            "notification order is preserved within Today"
        )
        expect(grouped[1].entries.map(\.id) == ["yesterday"], "yesterday group keeps its row")
        expect(grouped[2].entries.map(\.id) == ["two-days"], "2 days ago group keeps its row")
        expect(
            grouped.map(\.id) == grouped.map(\.kind.stableId),
            "group IDs are stable and derived from kind"
        )
        expect(
            Set(grouped.flatMap(\.entries).map(\.id)).count == 6,
            "stable row IDs are preserved across grouping"
        )
        expect(
            grouped[0].title.localizedCaseInsensitiveContains("today"),
            "Today group title is localized Today"
        )
        expect(
            grouped[1].title.localizedCaseInsensitiveContains("yesterday"),
            "Yesterday group title is localized Yesterday"
        )
        expect(
            grouped[2].title.contains("2"),
            "2 days ago reuses a localized relative heading"
        )
        expect(
            !grouped[0].entries[0].timestampLabel.localizedCaseInsensitiveContains("today"),
            "today card timestamp is clock time, not the Today word"
        )

        let regrouped = FanGeoInboxDateGrouping.groups(
            items: [todayNewer, todayOlder, yesterdayItem, twoDays, older, undated],
            languageCode: "en",
            now: now,
            calendar: calendar
        )
        expect(grouped == regrouped, "grouping projection is deterministic")

        let usesDirectAPI = SportsArtworkEnrichmentService.usesDirectTheSportsDBAPI
        _ = FanGeoInboxDateGrouping.groups(
            items: [todayNewer, yesterdayItem, twoDays],
            languageCode: "en",
            now: now,
            calendar: calendar
        )
        expect(
            SportsArtworkEnrichmentService.usesDirectTheSportsDBAPI == usesDirectAPI,
            "grouping does not trigger per-cell network work"
        )
        expect(
            usesDirectAPI == false,
            "inbox artwork path still does not call TheSportsDB from iOS"
        )

        let teamId = UUID()
        let start = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 14, hour: 8, minute: 14)
        )!
        let practice = FanGeoActionItem(
            id: "pickup_update:practice-redesign",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["Practice Updated"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            timestamp: start,
            context: FanGeoActionContext(
                personName: "FanGeo",
                personAvatarURL: "https://example.test/fangeo.jpg",
                teamName: "ER basketball",
                eventTitle: "Practice",
                eventTypeLabel: "practice",
                locationLabel: "Intermountain Medical Center Oncology Clinic, Salt Lake City, UT",
                eventStartAt: start,
                pickupGameId: UUID(),
                teamId: teamId,
                sportLabel: "basketball",
                notificationType: "team_event_updated"
            )
        )
        expect(
            FanGeoInboxTeamEventCardLayout.usesTeamLogoAsPrimaryArtwork(for: practice),
            "Practice card uses Team logo as primary artwork"
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(for: practice) == .teamMark,
            "Practice leading identity remains Team mark"
        )
        expect(
            FanGeoInboxChrome.leadingArtworkSize(hasTeamEventNotice: true, isCompactInformational: true)
                == FanGeoInboxChrome.teamEventLeadingSize,
            "Practice leading artwork is the larger Team logo size"
        )
        if let notice = FanGeoTeamEventNoticeBuilder.make(for: practice, languageCode: "en") {
            expect(
                FanGeoInboxTeamEventCardLayout.keepsPlayerAvatarInBodyRow(notice),
                "Player row keeps small avatar"
            )
            let rows = FanGeoInboxTeamEventCardLayout.rows(from: notice, languageCode: "en")
            expect(rows.contains { $0.showsPlayerAvatar && $0.value == "FanGeo" }, "player stays in body row")
            expect(rows.contains { $0.kind == .team && $0.value == "ER basketball" }, "team row remains")
            expect(
                rows.contains { $0.labelKey == "action_center_label_when" && $0.value.contains("·") },
                "Date and Time combine into When for presentation"
            )
            expect(
                rows.contains { $0.labelKey == "action_center_label_where" },
                "location supporting row presents as Where"
            )
            expect(
                rows.firstIndex(where: { $0.showsPlayerAvatar })! <
                    rows.firstIndex(where: { $0.labelKey == "action_center_label_when" })!,
                "When comes after Player/Team identity"
            )
            let spoken = FanGeoInboxChrome.cardAccessibilityLabel(
                for: practice,
                isUnread: true,
                languageCode: "en"
            )
            expect(spoken.contains("Practice Updated"), "a11y includes Practice Updated")
            expect(spoken.contains("FanGeo"), "a11y includes player")
            expect(spoken.contains("ER basketball"), "a11y includes team")
            expect(
                spoken.localizedCaseInsensitiveContains("unread"),
                "unread is spoken once on the card"
            )
        } else {
            expect(false, "practice notice")
        }

        let headerSpoken = FanGeoInboxChrome.headerAccessibilityLabel(inboxCount: 11, languageCode: "en")
        expect(headerSpoken.contains("FanGeo Inbox"), "header a11y speaks Inbox title")
        expect(headerSpoken.contains("11"), "accessibility uses aggregate total")
        expect(
            headerSpoken.contains("Inbox items"),
            "header speaks Inbox items, not only unread notifications"
        )
        expect(
            headerSpoken.localizedCaseInsensitiveContains("8 unread") == false,
            "header does not announce the Notifications-only count"
        )
        expect(
            FanGeoInboxChrome.headerAccessibilityLabel(inboxCount: 0, languageCode: "en")
                .contains("Inbox items") == false,
            "header does not speak a total when envelope is hidden"
        )

        let snapshot = FanGeoProGameInboxSnapshot(
            kind: .final,
            matchID: "pcl-bees-chihuahuas",
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
        let finalItem = FanGeoActionItem(
            id: "pro_game:final:bees",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["Final Score"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            timestamp: calendar.date(byAdding: .day, value: -1, to: now),
            context: FanGeoActionContext(
                notificationType: "pro_game_final",
                proGameMatchId: snapshot.matchID,
                proGameSnapshot: snapshot
            )
        )
        expect(
            FanGeoProGameInboxPresentation.isProGame(finalItem),
            "snapshot-backed final card remains rich"
        )
        expect(
            FanGeoProGameInboxPresentation.usesGenericTitleRenderer(finalItem) == false,
            "valid snapshot never falls back to generic Final Score"
        )
        let board = FanGeoProGameInboxPresentation.scoreboardRows(for: snapshot)
        expect(board.count == 2, "final scoreboard has both teams")
        expect(board.contains { $0.teamName == "Salt Lake Bees" && $0.score == 8 }, "Bees score 8")
        expect(board.contains { $0.teamName == "El Paso Chihuahuas" && $0.score == 2 }, "Chihuahuas score 2")
        expect(finalItem.context.proGameMatchId == "pcl-bees-chihuahuas", "match_id deep link is unchanged")

        let legacy = FanGeoActionItem(
            id: "pro_game:legacy-title",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["Chicago Cubs scored"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .scheduleActivity,
            context: FanGeoActionContext(notificationType: "pro_game_score")
        )
        expect(
            FanGeoProGameInboxPresentation.usesGenericTitleRenderer(legacy),
            "legacy rows remain generic"
        )
        expect(
            legacy.title(languageCode: "en") == "Chicago Cubs scored",
            "legacy title is not parsed into a scoreboard"
        )
        expect(
            FanGeoProGameInboxSnapshot.from(
                userInfo: ["title": "Chicago Cubs scored", "body": "Top 6th · 2–1"],
                notificationType: nil
            ) == nil,
            "structured subtitle is not invented from the title"
        )

        let membership = FanGeoActionItem(
            id: "team:removed",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["Removed from Team"],
            subtitleKey: "action_center_notification_subtitle_default",
            destination: .teamsHome,
            context: FanGeoActionContext(
                teamName: "ER basketball",
                teamId: teamId,
                sportLabel: "Basketball",
                notificationType: "removed_from_team"
            )
        )
        expect(
            membership.title(languageCode: "en") == "Removed from Team",
            "membership title stays Removed from Team"
        )
        expect(
            FanGeoActionCenterTeamNotificationPresentation.headerBadgeText(
                for: membership,
                languageCode: "en"
            ).localizedCaseInsensitiveContains("ER basketball"),
            "membership badge still names the team"
        )
        expect(
            FanGeoActionCenterLeadingIdentity.source(for: membership) == .teamMark,
            "membership primary artwork stays the team/group mark"
        )
        expect(
            FanGeoTeamEventNoticeBuilder.isScheduleEventNotice(for: membership) == false,
            "membership stays independent of Team-event notice layout"
        )

        let notificationKinds: [FanGeoActionKind] = [
            .scheduleChange,
            .eventCancellation,
            .poke,
            .securitySession
        ]
        expect(
            notificationKinds.allSatisfy { $0.listSection == .notifications },
            "all card types use same dismissal behavior where applicable"
        )
        expect(
            FanGeoInboxChrome.usesPerCardDismissMenu == false
                && FanGeoInboxChrome.requiresSingleItemDismissConfirmation == false
                && FanGeoInboxChrome.cardDismissConsumesTap,
            "schedule, membership, and generic cards share one-tap X dismiss"
        )
        expect(
            FanGeoInboxChrome.notificationsTabCount(unreadCount: 1) == 1,
            "Notifications tab still uses unread count"
        )
        expect(
            FanGeoInboxChrome.envelopeBadgeCount(notificationsCount: 0, actionNeededCount: 3) == 3,
            "clearing notifications keeps Action Needed in the envelope"
        )
        expect(
            FanGeoInboxChrome.showsEnvelopeBadge(
                totalCount: FanGeoInboxChrome.envelopeBadgeCount(
                    notificationsCount: 0,
                    actionNeededCount: 0
                )
            ) == false,
            "clearing both lists hides the envelope badge"
        )
        expect(
            FanGeoInboxChrome.usesLazyNotificationList
                && FanGeoInboxChrome.notificationListDisablesAnimations,
            "no performance regression / list still uses stable lazy rendering"
        )
        expect(
            grouped.map(\.id) == grouped.map(\.kind.stableId),
            "stable IDs unchanged after dismiss control swap"
        )

        expect(
            L10n.t("action_center_inbox_group_today", languageCode: "en") == "Today",
            "Today grouping string is localized"
        )
        expect(
            L10n.t("action_center_inbox_group_yesterday", languageCode: "en") == "Yesterday",
            "Yesterday grouping string is localized"
        )
        expect(
            L10n.t("action_center_inbox_group_older", languageCode: "en") == "Older",
            "Older grouping string is localized"
        )
        expect(
            L10n.t("action_center_label_when", languageCode: "en") == "When",
            "When label is localized"
        )
        expect(
            L10n.t("action_center_label_where", languageCode: "en") == "Where",
            "Where label is localized"
        )

        if failures == 0 {
            print("[InboxPresentationTest] ALL PASSED")
        } else {
            print("[InboxPresentationTest] FAILURES=\(failures)")
            assertionFailure("FanGeoInboxPresentationSelfTests failed: \(failures)")
        }
    }
}
#endif
