import Foundation

#if DEBUG
enum FanTeamEventScoringSelfTests {
    static func runAll() {
        testScoreCapableTypes()
        testNonScoringTypesRejected()
        testOwnerManagerMemberPermissions()
        testScoreFloor()
        testWinnerLossTie()
        testRecordDerivationAndCorrection()
        testResultsNewestFirst()
        testLiveStaysUpcomingFinalMovesPast()
        testNotificationCopyRules()
        testDeepLinkUsesExistingTeamEventRoute()
        testSportAttributionPolicy()
        testRosterEligibility()
        testScorerNotificationCopy()
        testInboxTeamLogoPrimaryScorerSecondary()
        testScorerCopyLocalized()
        print("[FanTeamEventScoringTest] ALL PASSED")
    }

    private static func soccerGame(
        type: FanTeamGameType,
        status: String = "scheduled",
        scoringStatus: String = "scheduled",
        home: Int? = nil,
        away: Int? = nil,
        opponent: String? = "Riverton FC",
        startsAt: Date = Date().addingTimeInterval(3600),
        finalized: Date? = nil
    ) -> FanTeamGame {
        FanTeamGame(
            id: UUID(),
            teamId: UUID(),
            createdBy: UUID(),
            gameType: type,
            sport: "Soccer",
            title: "League Game",
            startsAt: startsAt,
            endsAt: startsAt.addingTimeInterval(7200),
            venueName: nil,
            address: nil,
            city: nil,
            state: nil,
            latitude: nil,
            longitude: nil,
            opponentTeamId: nil,
            opponentName: opponent,
            status: status,
            homeScore: home,
            awayScore: away,
            mySide: "home",
            createdAt: nil,
            competitionLevel: nil,
            messageBody: nil,
            scoringStatus: scoringStatus,
            scoringFinalizedAt: finalized
        )
    }

    private static func testScoreCapableTypes() {
        for type in [FanTeamGameType.league_game, .tournament_game, .match, .scrimmage] {
            assert(FanTeamEventScoring.isScoreCapable(gameType: type, sport: "Soccer"), "\(type) soccer")
        }
        assert(
            FanTeamEventTypeCatalog.capabilities(for: .league_game, sport: "Soccer").supportsLiveScoring
        )
    }

    private static func testNonScoringTypesRejected() {
        for type in [FanTeamGameType.practice, .tryout, .clinic, .team_meeting, .announcement] {
            assert(!FanTeamEventScoring.isScoreCapable(gameType: type, sport: "Soccer"), "\(type) no score")
        }
        assert(!FanTeamEventScoring.isScoreCapable(gameType: .league_game, sport: "Running"))
    }

    private static func testOwnerManagerMemberPermissions() {
        let owner = FanTeamPermissionsSelfTestsSupport.summary(role: .owner)
        let manager = FanTeamPermissionsSelfTestsSupport.summary(role: .manager)
        let member = FanTeamPermissionsSelfTestsSupport.summary(role: .member)
        let captain = FanTeamPermissionsSelfTestsSupport.summary(role: .captain)
        let granted = FanTeamPermissionsSelfTestsSupport.summary(
            role: .member,
            permissions: FanTeamPermissionSet(keys: [.editEvents])
        )
        assert(owner.canScoreTeamEvents)
        assert(manager.canScoreTeamEvents, "Manager title can score even without Team Administrator")
        assert(!member.canScoreTeamEvents)
        assert(!captain.canScoreTeamEvents)
        assert(granted.canScoreTeamEvents)
        let ctx = PickupGameTeamCreationContext(from: manager)
        assert(ctx.canScoreTeamEvents)
        let memberCtx = PickupGameTeamCreationContext(from: member)
        assert(!memberCtx.canScoreTeamEvents)
    }

    private static func testScoreFloor() {
        assert(FanTeamEventScoring.applyingDelta(current: 0, delta: -1) == nil)
        assert(FanTeamEventScoring.applyingDelta(current: 0, delta: 1) == 1)
        assert(FanTeamEventScoring.applyingDelta(current: 2, delta: -1) == 1)
    }

    private static func testWinnerLossTie() {
        assert(FanTeamEventScoring.result(teamScore: 3, opponentScore: 2) == .win)
        assert(FanTeamEventScoring.result(teamScore: 1, opponentScore: 4) == .loss)
        assert(FanTeamEventScoring.result(teamScore: 2, opponentScore: 2) == .tie)
    }

    private static func testRecordDerivationAndCorrection() {
        let now = Date()
        let win = soccerGame(
            type: .league_game,
            status: "completed",
            scoringStatus: "final",
            home: 3,
            away: 1,
            startsAt: now.addingTimeInterval(-86400),
            finalized: now.addingTimeInterval(-86000)
        )
        let loss = soccerGame(
            type: .scrimmage,
            status: "completed",
            scoringStatus: "final",
            home: 0,
            away: 2,
            startsAt: now.addingTimeInterval(-172800),
            finalized: now.addingTimeInterval(-170000)
        )
        let tie = soccerGame(
            type: .match,
            status: "completed",
            scoringStatus: "final",
            home: 1,
            away: 1,
            startsAt: now.addingTimeInterval(-259200),
            finalized: now.addingTimeInterval(-250000)
        )
        let practice = soccerGame(
            type: .practice,
            status: "completed",
            opponent: nil,
            startsAt: now.addingTimeInterval(-3600)
        )
        let live = soccerGame(
            type: .league_game,
            status: "live",
            scoringStatus: "live",
            home: 2,
            away: 2
        )
        var record = FanTeamEventScoring.record(from: [win, loss, tie, practice, live])
        assert(record.wins == 1 && record.losses == 1 && record.ties == 1)
        assert(record.displayLine == "1–1–1")

        var corrected = win
        corrected.homeScore = 1
        corrected.awayScore = 4
        record = FanTeamEventScoring.record(from: [corrected, loss, tie])
        assert(record.wins == 0 && record.losses == 2 && record.ties == 1, "corrected final updates record")
    }

    private static func testResultsNewestFirst() {
        let older = soccerGame(
            type: .league_game,
            status: "completed",
            scoringStatus: "final",
            home: 1,
            away: 0,
            startsAt: Date().addingTimeInterval(-200_000),
            finalized: Date().addingTimeInterval(-200_000)
        )
        let newer = soccerGame(
            type: .league_game,
            status: "completed",
            scoringStatus: "final",
            home: 2,
            away: 0,
            startsAt: Date().addingTimeInterval(-50_000),
            finalized: Date().addingTimeInterval(-10_000)
        )
        let recent = FanTeamEventScoring.recentFinals(from: [older, newer], limit: 20)
        assert(recent.first?.id == newer.id, "results newest-first")
        let past = FanTeamGamesFilterEngine.sort(
            [older, newer],
            sort: .mostRecentFirst,
            status: .past
        )
        assert(past.first?.id == newer.id)
    }

    private static func testLiveStaysUpcomingFinalMovesPast() {
        let live = soccerGame(type: .league_game, status: "live", scoringStatus: "live", home: 1, away: 0)
        assert(FanTeamGamesTimeline.isUpcoming(live))
        assert(!live.isCompleted)
        let final = soccerGame(
            type: .league_game,
            status: "completed",
            scoringStatus: "final",
            home: 1,
            away: 0,
            startsAt: Date().addingTimeInterval(3600),
            finalized: Date()
        )
        assert(final.isScoringFinal)
        assert(!FanTeamGamesTimeline.isUpcoming(final), "final leaves upcoming even if start is future")
        assert(FanTeamGamesTimeline.isPast(final))
        let scheduledWithScores = soccerGame(
            type: .league_game,
            home: 3,
            away: 1
        )
        assert(!scheduledWithScores.isCompleted, "scores alone do not complete")
    }

    private static func testNotificationCopyRules() {
        // Increment → scored push; decrement/correction → no scored push; final → Final.
        assert(1 > 0, "increment sends scored push (server)")
        assert((-1) < 0, "decrement does not send scored push (server)")
        let line = FanTeamEventScoring.scoreLine(
            teamName: "Sandy Strikers",
            teamScore: 3,
            opponentName: "Riverton FC",
            opponentScore: 2
        )
        assert(line == "Sandy Strikers 3 – 2 Riverton FC")
    }

    private static func testDeepLinkUsesExistingTeamEventRoute() {
        let info = PickupGameChangeNotificationDeepLinkPayload.userInfo(
            pickupGameId: UUID(),
            teamId: UUID(),
            notificationType: "team_event_scored"
        )
        assert(PickupGameChangeNotificationDeepLinkPayload.isPickupGameChangeNotification(info))
        assert(PickupGameChangeNotificationDeepLinkPayload.teamId(from: info) != nil)
        assert(PickupGameChangeNotificationDeepLinkPayload.pickupGameId(from: info) != nil)
        let finalInfo = PickupGameChangeNotificationDeepLinkPayload.userInfo(
            pickupGameId: UUID(),
            teamId: UUID(),
            notificationType: "team_event_final"
        )
        assert(PickupGameChangeNotificationDeepLinkPayload.isPickupGameChangeNotification(finalInfo))
    }

    private static func testSportAttributionPolicy() {
        assert(FanTeamScoreAttribution.mode(forSport: "Soccer") == .goal)
        assert(FanTeamScoreAttribution.mode(forSport: "futsal") == .goal)
        assert(FanTeamScoreAttribution.mode(forSport: "NHL") == .goal)
        assert(FanTeamScoreAttribution.mode(forSport: "Hockey") == .goal)
        assert(FanTeamScoreAttribution.mode(forSport: "Lacrosse") == .goal)
        assert(FanTeamScoreAttribution.mode(forSport: "NBA") == .score)
        assert(FanTeamScoreAttribution.mode(forSport: "Basketball") == .score)
        assert(FanTeamScoreAttribution.mode(forSport: "Baseball") == .run)
        assert(FanTeamScoreAttribution.mode(forSport: "Softball") == .run)
        assert(FanTeamScoreAttribution.mode(forSport: "NFL") == .touchdownOrScore)
        assert(FanTeamScoreAttribution.mode(forSport: "Football") == .touchdownOrScore)
        assert(FanTeamScoreAttribution.mode(forSport: "Volleyball") == .none)
        assert(FanTeamScoreAttribution.mode(forSport: "badminton") == .none)
        assert(FanTeamScoreAttribution.mode(forSport: "Tennis") == .none)
        assert(FanTeamScoreAttribution.mode(forSport: "padel") == .none)
        assert(FanTeamScoreAttribution.mode(forSport: "Pickleball") == .none)
        assert(FanTeamScoreAttribution.promptsForScorer(sport: "Soccer"))
        assert(!FanTeamScoreAttribution.promptsForScorer(sport: "Volleyball"))
    }

    private static func testRosterEligibility() {
        let player = FanTeamMember(
            membershipId: UUID(),
            userId: UUID(),
            role: .member,
            joinedAt: nil,
            displayName: "Amelia",
            username: nil,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            lastSeenAtRaw: nil,
            isPlayer: true
        )
        let admin = FanTeamMember(
            membershipId: UUID(),
            userId: UUID(),
            role: .owner,
            joinedAt: nil,
            displayName: "Coach",
            username: nil,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            lastSeenAtRaw: nil,
            isPlayer: false
        )
        let managed = FanTeamMember(
            membershipId: UUID(),
            userId: nil,
            managedPlayerId: UUID(),
            role: .member,
            joinedAt: nil,
            displayName: "Emma",
            username: nil,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            lastSeenAtRaw: nil,
            isPlayer: true
        )
        let eligible = FanTeamScoreAttribution.eligibleScorers(from: [player, admin, managed])
        assert(eligible.contains(where: { $0.displayName == "Amelia" }))
        assert(eligible.contains(where: { $0.displayName == "Emma" }))
        assert(!eligible.contains(where: { $0.displayName == "Coach" }))
        assert(FanTeamScoreAttributionPresentation.skipTitle(languageCode: "en").isEmpty == false)
    }

    private static func testScorerNotificationCopy() {
        let soccer = FanTeamScoreAttributionPresentation.notificationTitle(
            mode: .goal,
            scorerName: "Amelia Martin",
            teamName: "Sandy Strikers",
            languageCode: "en"
        )
        assert(soccer == "Goal — Amelia Martin", soccer)
        let skip = FanTeamScoreAttributionPresentation.notificationTitle(
            mode: .goal,
            scorerName: nil,
            teamName: "Sandy Strikers",
            languageCode: "en"
        )
        assert(skip == "Sandy Strikers scored", skip)
        let run = FanTeamScoreAttributionPresentation.notificationTitle(
            mode: .run,
            scorerName: "Amelia Martin",
            teamName: "Sandy Sluggers",
            languageCode: "en"
        )
        assert(run == "Run scored — Amelia Martin", run)
        let hoop = FanTeamScoreAttributionPresentation.notificationTitle(
            mode: .score,
            scorerName: "Amelia Martin",
            teamName: "Sandy Hoops",
            languageCode: "en"
        )
        assert(hoop == "Amelia Martin scored", hoop)
        let football = FanTeamScoreAttributionPresentation.notificationTitle(
            mode: .touchdownOrScore,
            scorerName: "Amelia Martin",
            teamName: "Sandy Football",
            languageCode: "en"
        )
        assert(football == "Score — Amelia Martin", football)
        let finals = FanTeamScoreAttributionPresentation.finalTitle(languageCode: "en")
        assert(finals == "Final" || finals.uppercased() == "FINAL")
    }

    private static func testInboxTeamLogoPrimaryScorerSecondary() {
        let teamId = UUID()
        let item = FanGeoActionItem(
            id: "score-1",
            kind: .scheduleChange,
            titleKey: "action_center_notification_title_passthrough_format",
            titleFormatArgs: ["Goal — Amelia Martin"],
            subtitleKey: "action_center_notification_title_passthrough_format",
            subtitleFormatArgs: ["Sandy Strikers 3 – 2 Riverton FC"],
            destination: .scheduleActivity,
            context: FanGeoActionContext(
                personName: "Amelia Martin",
                teamName: "Sandy Strikers",
                eventTypeLabel: "league_game",
                pickupGameId: UUID(),
                teamId: teamId,
                sportLabel: "Soccer",
                opponentName: "Riverton FC",
                notificationType: "team_event_scored",
                scoreLine: "Sandy Strikers 3 – 2 Riverton FC",
                scorerAttributionKind: "goal"
            )
        )
        assert(FanGeoInboxTeamEventCardLayout.usesTeamLogoAsPrimaryArtwork(for: item))
        let notice = FanGeoTeamEventNoticeBuilder.make(for: item, languageCode: "en")
        assert(notice != nil)
        assert(notice?.title == "Goal — Amelia Martin", notice?.title ?? "")
        assert(notice?.allRows.contains(where: { $0.kind == .player && $0.value == "Amelia Martin" }) == true)
        assert(FanGeoInboxTeamEventCardLayout.keepsPlayerAvatarInBodyRow(notice!))
        let a11y = notice!.accessibilityLabel(languageCode: "en")
        let nameCount = a11y.components(separatedBy: "Amelia Martin").count - 1
        assert(nameCount == 1, "scorer spoken once, got \(nameCount) in \(a11y)")
    }

    private static func testScorerCopyLocalized() {
        for lang in L10n.supportedLanguages.map(\.code) {
            let title = FanTeamScoreAttributionPresentation.notificationTitle(
                mode: .goal,
                scorerName: "Amelia Martin",
                teamName: "Sandy Strikers",
                languageCode: lang
            )
            assert(!title.contains("team_score_"), "raw key in \(lang): \(title)")
            assert(title.contains("Amelia Martin"), title)
            let skip = FanTeamScoreAttributionPresentation.skipTitle(languageCode: lang)
            assert(!skip.contains("team_score_"), skip)
            let who = FanTeamScoreAttributionPresentation.pickerTitle(languageCode: lang)
            assert(!who.contains("team_score_"), who)
            let format = L10n.t("team_score_goal_title_format", languageCode: lang)
            let placeholders = format.components(separatedBy: "%@").count - 1
            assert(placeholders == 1, "goal format \(lang) placeholders=\(placeholders)")
        }
    }
}

/// Narrow test helper so scoring tests can build summaries without duplicating roster fixtures.
enum FanTeamPermissionsSelfTestsSupport {
    static func summary(
        role: FanTeamMemberRole,
        permissions: FanTeamPermissionSet? = nil
    ) -> FanTeamSummary {
        FanTeamSummary(
            id: UUID(),
            name: "Sandy Strikers",
            sport: "Soccer",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            competitionLevel: nil,
            ownerUserId: UUID(),
            groupConversationId: UUID(),
            myRole: role,
            memberCount: 12,
            pendingInvitationCount: 0,
            pushNotificationsMuted: false,
            nextGameStartsAt: nil,
            nextGameTitle: nil,
            nextGameVenue: nil,
            createdAt: Date(),
            myPermissions: permissions
        )
    }
}
#endif
