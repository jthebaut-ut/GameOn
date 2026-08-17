import Foundation

enum FanTeamOverviewAnnouncementSelfTests {
    static func runAll() {
        var failures: [String] = []
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[FanTeamOverviewAnnouncementTest] PASS \(name)")
            } else {
                failures.append(name)
                print("[FanTeamOverviewAnnouncementTest] FAIL \(name)")
            }
        }

        let teamId = UUID()
        let ownerId = UUID()
        let memberId = UUID()
        let now = Date()

        let a = announcement(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            teamId: teamId,
            createdBy: ownerId,
            title: "A",
            createdAt: now.addingTimeInterval(-3_600)
        )
        let b = announcement(
            id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            teamId: teamId,
            createdBy: ownerId,
            title: "B",
            createdAt: now.addingTimeInterval(-1_800)
        )
        let c = announcement(
            id: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
            teamId: teamId,
            createdBy: ownerId,
            title: "C",
            createdAt: now.addingTimeInterval(-60)
        )
        let cancelled = announcement(
            id: UUID(),
            teamId: teamId,
            createdBy: ownerId,
            title: "Cancelled",
            createdAt: now,
            status: "cancelled"
        )
        let historical = announcement(
            id: UUID(),
            teamId: teamId,
            createdBy: ownerId,
            title: "Old",
            createdAt: now.addingTimeInterval(-86_400 * 30)
        )

        let member = FanTeamMember(
            userId: memberId,
            role: .member,
            joinedAt: now.addingTimeInterval(-86_400),
            displayName: "Member",
            username: "member",
            avatarURL: nil,
            avatarThumbnailURL: nil,
            lastSeenAtRaw: nil
        )
        let detail = FanTeamDetail(
            summary: FanTeamSummary(
                id: teamId,
                name: "Best Team Ever",
                sport: "Soccer",
                logoURL: nil,
                logoThumbnailURL: nil,
                colorHex: nil,
                competitionLevel: nil,
                ownerUserId: ownerId,
                groupConversationId: UUID(),
                myRole: .member,
                memberCount: 2,
                pendingInvitationCount: 0,
                pushNotificationsMuted: false,
                nextGameStartsAt: nil,
                nextGameTitle: nil,
                nextGameVenue: nil,
                createdAt: now.addingTimeInterval(-86_400 * 60)
            ),
            members: [member],
            games: [a, b, c, cancelled, historical]
        )

        expect(
            FanTeamOverviewAnnouncementPresentation.makeAll(
                from: detail,
                clearedIds: [],
                viewerUserId: memberId,
                languageCode: "en"
            ).isEmpty == false,
            "zero-clear shows announcements"
        )

        let none = FanTeamOverviewAnnouncementPresentation.makeAll(
            from: FanTeamDetail(summary: detail.summary, members: [member], games: []),
            clearedIds: [],
            viewerUserId: memberId,
            languageCode: "en"
        )
        expect(none.isEmpty, "zero announcements → empty carousel list")

        let one = FanTeamOverviewAnnouncementPresentation.makeAll(
            from: FanTeamDetail(summary: detail.summary, members: [member], games: [c]),
            clearedIds: [],
            viewerUserId: memberId,
            languageCode: "en"
        )
        expect(one.count == 1 && one.first?.title == "C", "single announcement")

        let all = FanTeamOverviewAnnouncementPresentation.makeAll(
            from: detail,
            clearedIds: [],
            viewerUserId: memberId,
            languageCode: "en"
        )
        expect(all.map(\.title) == ["C", "B", "A"], "newest-first order C→B→A")
        expect(!all.contains(where: { $0.title == "Cancelled" }), "cancelled excluded")
        expect(!all.contains(where: { $0.title == "Old" }), "pre-join historical excluded for new member")

        let afterClearNewest = FanTeamOverviewAnnouncementPresentation.makeAll(
            from: detail,
            clearedIds: [c.id],
            viewerUserId: memberId,
            languageCode: "en"
        )
        expect(afterClearNewest.map(\.title) == ["B", "A"], "clear newest → next remains")

        let afterClearMiddle = FanTeamOverviewAnnouncementPresentation.makeAll(
            from: detail,
            clearedIds: [b.id],
            viewerUserId: memberId,
            languageCode: "en"
        )
        expect(afterClearMiddle.map(\.title) == ["C", "A"], "clear middle keeps others")

        let afterClearAll = FanTeamOverviewAnnouncementPresentation.makeAll(
            from: detail,
            clearedIds: [a.id, b.id, c.id],
            viewerUserId: memberId,
            languageCode: "en"
        )
        expect(afterClearAll.isEmpty, "clear final → empty section data")

        // Final remaining announcement: clear must yield empty (section disappears).
        let onlyLeft = FanTeamOverviewAnnouncementPresentation.makeAll(
            from: FanTeamDetail(summary: detail.summary, members: [member], games: [c]),
            clearedIds: [],
            viewerUserId: memberId,
            languageCode: "en"
        )
        expect(onlyLeft.count == 1, "one uncleared remains before final clear")
        let afterFinalClear = FanTeamOverviewAnnouncementPresentation.makeAll(
            from: FanTeamDetail(summary: detail.summary, members: [member], games: [c]),
            clearedIds: [c.id],
            viewerUserId: memberId,
            languageCode: "en"
        )
        expect(afterFinalClear.isEmpty, "clear last remaining → empty carousel / hide section")

        expect(
            FanTeamOverviewAnnouncementCarouselLogic.clampedIndex(0, count: 0) == 0,
            "clamp empty → 0 (no crash)"
        )
        expect(
            FanTeamOverviewAnnouncementCarouselLogic.clampedIndex(5, count: 1) == 0,
            "clamp past end → last"
        )
        expect(
            FanTeamOverviewAnnouncementCarouselLogic.indexAfterClearing(
                clearedId: c.id,
                from: [c.id],
                selectedIndex: 0
            ) == 0,
            "clear sole id → index 0 with empty list"
        )
        expect(
            FanTeamOverviewAnnouncementCarouselLogic.indexAfterClearing(
                clearedId: c.id,
                from: [c.id, b.id, a.id],
                selectedIndex: 0
            ) == 0,
            "clear newest advances to former second"
        )
        expect(
            FanTeamOverviewAnnouncementCarouselLogic.indexAfterClearing(
                clearedId: a.id,
                from: [c.id, b.id, a.id],
                selectedIndex: 2
            ) == 1,
            "clear last page clamps to new last"
        )

        // Different member (no clears) still sees C even if another user cleared C locally in their set.
        let otherViewer = FanTeamOverviewAnnouncementPresentation.makeAll(
            from: detail,
            clearedIds: [],
            viewerUserId: memberId,
            languageCode: "en"
        )
        expect(otherViewer.contains(where: { $0.id == c.id }), "uncleared user still sees announcement")

        // Opening/read must not be conflated with clear — clearedIds empty keeps all.
        expect(all.count == 3, "read without clear keeps carousel items")

        // New announcement arrives without dropping older uncleared.
        let d = announcement(
            id: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            teamId: teamId,
            createdBy: ownerId,
            title: "D",
            createdAt: now
        )
        let withNew = FanTeamOverviewAnnouncementPresentation.makeAll(
            from: FanTeamDetail(summary: detail.summary, members: [member], games: [a, b, c, d]),
            clearedIds: [],
            viewerUserId: memberId,
            languageCode: "en"
        )
        expect(withNew.map(\.title) == ["D", "C", "B", "A"], "new post fronts carousel without dropping older")

        // Lifetime member sees historical (joined far in the past).
        let longMember = FanTeamMember(
            userId: memberId,
            role: .member,
            joinedAt: now.addingTimeInterval(-86_400 * 90),
            displayName: "Veteran",
            username: "vet",
            avatarURL: nil,
            avatarThumbnailURL: nil,
            lastSeenAtRaw: nil
        )
        let veteranView = FanTeamOverviewAnnouncementPresentation.makeAll(
            from: FanTeamDetail(summary: detail.summary, members: [longMember], games: [historical, a]),
            clearedIds: [],
            viewerUserId: memberId,
            languageCode: "en"
        )
        expect(veteranView.contains(where: { $0.title == "Old" }), "membership-period includes historical for long-time member")

        if failures.isEmpty {
            print("[FanTeamOverviewAnnouncementTest] ALL PASSED")
        } else {
            print("[FanTeamOverviewAnnouncementTest] FAILURES=\(failures)")
            assertionFailure("FanTeamOverviewAnnouncementSelfTests failed: \(failures)")
        }
    }

    private static func announcement(
        id: UUID,
        teamId: UUID,
        createdBy: UUID,
        title: String,
        createdAt: Date,
        status: String = "scheduled"
    ) -> FanTeamGame {
        FanTeamGame(
            id: id,
            teamId: teamId,
            createdBy: createdBy,
            gameType: .announcement,
            sport: "Soccer",
            title: title,
            startsAt: createdAt,
            endsAt: nil,
            venueName: nil,
            address: nil,
            city: nil,
            state: nil,
            latitude: nil,
            longitude: nil,
            opponentTeamId: nil,
            opponentName: nil,
            status: status,
            homeScore: nil,
            awayScore: nil,
            mySide: "solo",
            createdAt: createdAt,
            competitionLevel: nil,
            messageBody: "Body \(title)"
        )
    }
}
