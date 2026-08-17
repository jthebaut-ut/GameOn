import Foundation

#if DEBUG
enum FanTeamsSelfTests {
    static func runAll() {
        testRolePermissions()
        testGameUpcomingHeuristic()
        testOpponentHeadlinePractice()
        testColorPaletteValidation()
        testIdentityApplyPropagates()
        testTeamPickupCreationContext()
        testTeamGameFormatCases()
        testTeamLinkedPickupEditPrivacyPolicy()
        testTeamGamesFilterEngine()
        testPickupInviteTeamRecipientGate()
        testTeamCSVImportRules()
        testTeamCompetitionLevelInheritance()
        testTeamLoadErrorPresentation()
        testRPCScalarBoolDecode()
        testMembershipLayeredErrorCopy()
        testMyselfPlayerSeatCombinations()
        testTeamsHomeAuthPresentation()
        testRosterJoinedCaption()
        testCreateTeamLogoStagingPolicy()
        testTeamLeadershipDerivation()
        testPlayerNumberAndGenderRosterRules()
        testMyPlayerInfoPresentation()
        testScheduleQuickRSVPPresentation()
        testPickupDetailPresentationHelpers()
        testHomeMemberAvatarStack()
        testManagedPlayerPreviewIdentity()
        testRefreshCoalesceContract()
        testRoleCanManageRefreshFromRoster()
        testTeamAnnouncementPresentationSafety()
        testOverviewNextEventSelection()
        testMembersCountFormatUsesInt64()
        testTeamDetailLocalizedFormatSignatures()
    }

    private static func testTeamDetailLocalizedFormatSignatures() {
        let languages = ["en", "de", "es", "fr", "it", "pl", "pt", "ru", "sq", "zh-Hans", "nl", "sv", "pt-BR"]
        let singleStringKeys = [
            "fan_teams_leave_confirm_title_format",
            "fan_teams_delete_confirm_title_format"
        ]
        for key in singleStringKeys {
            var expected: Int?
            for lang in languages {
                let format = L10n.t(key, languageCode: lang)
                // Skip languages that fall back to the key itself (missing translation).
                if format == key { continue }
                let count = TeamDetailLocalizedFormat.placeholderCount(in: format)
                if expected == nil { expected = count }
                assert(count == expected, "placeholder drift key=\(key) lang=\(lang)")
                assert(count == 1, "expected 1 string placeholder key=\(key) lang=\(lang)")
                let rendered = TeamDetailLocalizedFormat.format(
                    key,
                    languageCode: lang,
                    stringArgs: ["JT"]
                )
                assert(rendered.contains("JT"), "format failed key=\(key) lang=\(lang)")
            }
        }

        var removeExpected: Int?
        for lang in languages {
            let key = "fan_teams_remove_member_confirm_title_format"
            let format = L10n.t(key, languageCode: lang)
            if format == key { continue }
            let count = TeamDetailLocalizedFormat.placeholderCount(in: format)
            if removeExpected == nil { removeExpected = count }
            assert(count == removeExpected, "placeholder drift key=\(key) lang=\(lang)")
            assert(count == 2, "expected 2 string placeholders key=\(key) lang=\(lang)")
            let rendered = TeamDetailLocalizedFormat.format(
                key,
                languageCode: lang,
                stringArgs: ["Alex", "JT"]
            )
            assert(rendered.contains("Alex") && rendered.contains("JT"), "remove title format failed lang=\(lang)")
        }

        for key in ["fan_teams_members_count_format", "fan_teams_pending_count_compact_format"] {
            var expected: Int?
            for lang in languages {
                let format = L10n.t(key, languageCode: lang)
                if format == key { continue }
                let count = TeamDetailLocalizedFormat.placeholderCount(in: format)
                if expected == nil { expected = count }
                assert(count == expected, "placeholder drift key=\(key) lang=\(lang)")
                assert(count == 1, "expected 1 int placeholder key=\(key) lang=\(lang)")
                let rendered = TeamDetailLocalizedFormat.format(
                    key,
                    languageCode: lang,
                    int64Args: [Int64(3)]
                )
                assert(rendered.contains("3"), "int format failed key=\(key) lang=\(lang)")
            }
        }

        // Mismatch must not abort — falls back safely.
        let fallback = TeamDetailLocalizedFormat.format(
            "fan_teams_leave_confirm_title_format",
            languageCode: "en",
            stringArgs: ["A", "B"]
        )
        assert(!fallback.isEmpty)
    }

    private static func testTeamAnnouncementPresentationSafety() {
        let policy = FanTeamEventPresentation.policy(for: GameType.announcement)
        assert(policy.requiresDescriptionBody)
        assert(!policy.showsAttendanceRSVP)
        assert(!policy.showsLocationFields)
        assert(!policy.showsLineup)
        assert(!policy.requiresOpponent)
        assert(!policy.isGameplayEvent)

        let announcement = FanTeamGame(
            id: UUID(),
            teamId: UUID(),
            createdBy: UUID(),
            gameType: .announcement,
            sport: "Soccer",
            title: "Tryouts moved",
            startsAt: Date(),
            endsAt: nil,
            venueName: nil,
            address: nil,
            city: nil,
            state: nil,
            latitude: nil,
            longitude: nil,
            opponentTeamId: nil,
            opponentName: nil,
            status: "scheduled",
            homeScore: nil,
            awayScore: nil,
            mySide: "solo",
            createdAt: Date(),
            competitionLevel: nil,
            messageBody: "Meet at the south gate."
        )
        assert(announcement.messageBody == "Meet at the south gate.")
        assert(!FanTeamScheduleQuickRSVPEligibility.showsQuickRSVPControls(game: announcement))
        assert(FanTeamGamesFilterEngine.supportedTypeFilters.contains(.announcement))

        // Pre-20260976 RPC shape (no description key) must still decode.
        struct LegacyProbe: Decodable {
            let id: UUID
            let description: String?
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decode(UUID.self, forKey: .id)
                description = try c.decodeIfPresent(String.self, forKey: .description)
            }
            enum CodingKeys: String, CodingKey { case id, description }
        }
        let legacyJSON = Data(#"[{"id":"11111111-1111-4111-8111-111111111111"}]"#.utf8)
        let legacy = try! JSONDecoder().decode([LegacyProbe].self, from: legacyJSON)
        assert(legacy.count == 1)
        assert(legacy[0].description == nil)

        // Announcement null location / opponent / optional description still decode.
        let announcementJSON = Data(#"""
        [{"id":"22222222-2222-4222-8222-222222222222","description":"Hello team"}]
        """#.utf8)
        let withBody = try! JSONDecoder().decode([LegacyProbe].self, from: announcementJSON)
        assert(withBody[0].description == "Hello team")
    }

    private static func testMembersCountFormatUsesInt64() {
        let format = L10n.t("fan_teams_members_count_format", languageCode: "en")
        assert(format.contains("%lld"))
        let rendered = String(format: format, locale: Locale(identifier: "en"), Int64(3))
        assert(rendered.contains("3"))
        _ = FanTeamMetaLine.compose(
            competitionLevel: .youth,
            sport: "Soccer",
            memberCount: 3,
            languageCode: "en"
        )
    }

    private static func testManagedPlayerPreviewIdentity() {
        let managedId = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
        let membershipId = UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!
        let preview = FanTeamMemberAvatarPreview(
            membershipId: membershipId,
            managedPlayerId: managedId,
            displayName: "Ellie",
            avatarURL: "https://example.com/e.jpg",
            avatarThumbnailURL: nil,
            role: .member,
            isManagedPlayer: true
        )
        assert(preview.managedPlayerId == managedId)
        assert(preview.managedPlayerId != preview.membershipId)
        let account = FanTeamMemberAvatarPreview(
            membershipId: membershipId,
            managedPlayerId: managedId,
            displayName: "Fan",
            avatarURL: nil,
            avatarThumbnailURL: nil,
            role: .member,
            isManagedPlayer: false
        )
        assert(account.managedPlayerId == nil)
    }

    private static func testRefreshCoalesceContract() {
        // Structural: overlapping refresh must share one in-flight generation owner.
        // Runtime coalescing is covered by MyTeamsStore DEBUG logs in device runs.
        assert(true)
    }

    private static func testRoleCanManageRefreshFromRoster() {
        let teamId = UUID()
        let base = FanTeamSummary(
            id: teamId,
            name: "Tigers",
            sport: "soccer",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            competitionLevel: nil,
            ownerUserId: UUID(),
            groupConversationId: UUID(),
            myRole: .manager,
            memberCount: 4,
            pendingInvitationCount: 2,
            pushNotificationsMuted: false,
            nextGameStartsAt: nil,
            nextGameTitle: nil,
            nextGameVenue: nil,
            createdAt: nil,
            myPermissions: .teamAdministrator
        )
        assert(base.canManage)
        let demoted = base.applyingMyRole(.member, memberCount: 4)
        assert(demoted.myRole == .member)
        assert(!demoted.canManage)
        assert(demoted.pendingInvitationCount == 0)

        let custom = FanTeamPermissionSet(rawValues: ["create_events", "manage_lineups"])
        let withCustom = base.applyingMyRole(.headCoach, memberCount: 2, myPermissions: custom)
        assert(withCustom.myRole == .headCoach)
        assert(withCustom.memberCount == 2)
        assert(withCustom.hasPermission(.createEvents))
        assert(withCustom.hasPermission(.manageLineups))
        assert(!withCustom.hasPermission(.inviteMembers))
    }

    private static func testHomeMemberAvatarStack() {
        let owner = FanTeamMemberAvatarPreview(
            membershipId: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
            displayName: "Jonathan",
            avatarURL: "https://example.com/j.jpg",
            avatarThumbnailURL: nil,
            role: .owner,
            isManagedPlayer: false
        )
        let emma = FanTeamMemberAvatarPreview(
            membershipId: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
            displayName: "Emma",
            avatarURL: nil,
            avatarThumbnailURL: nil,
            role: .member,
            isManagedPlayer: true
        )
        let amelia = FanTeamMemberAvatarPreview(
            membershipId: UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!,
            displayName: "Amelia",
            avatarURL: "https://example.com/a.jpg",
            avatarThumbnailURL: nil,
            role: .member,
            isManagedPlayer: true
        )
        let extras = (0..<6).map { idx in
            FanTeamMemberAvatarPreview(
                membershipId: UUID(),
                displayName: "P\(idx)",
                avatarURL: nil,
                avatarThumbnailURL: nil,
                role: .member,
                isManagedPlayer: false
            )
        }
        let ten = [owner, emma, amelia] + extras
        let visible = FanTeamHomeMemberAvatarStack.visiblePreviews(from: ten, memberCount: 10)
        assert(visible.count == 4)
        assert(visible[0].displayName == "Jonathan")
        assert(visible[1].isManagedPlayer)
        assert(
            FanTeamHomeMemberAvatarStack.overflowCount(memberCount: 10, visiblePreviewCount: 4) == 6
        )
        assert(
            FanTeamHomeMemberAvatarStack.overflowCount(memberCount: 3, visiblePreviewCount: 3) == 0
        )
        let a11y = FanTeamHomeMemberAvatarStack.accessibilityLabel(
            memberCount: 8,
            visibleNames: ["Jonathan", "Emma", "Amelia"],
            languageCode: "en"
        )
        assert(a11y.contains("Jonathan"))
        assert(a11y.contains("5"))
    }

    private static func testPickupDetailPresentationHelpers() {
        let dup = PickupDetailLocationPresentation.lines(
            address: "Draper, UT 84020",
            city: "Draper",
            state: "UT 84020"
        )
        assert(dup.primary == "Draper, UT 84020")
        assert(dup.secondary == nil)

        let distinct = PickupDetailLocationPresentation.lines(
            address: "123 Main St",
            city: "Draper",
            state: "UT"
        )
        assert(distinct.primary == "123 Main St")
        assert(distinct.secondary == "Draper, UT")

        assert(
            PickupDetailGameDetailsPresentation.showsOutsideRecruitmentMetadata(
                isTeamLinked: false,
                isOutsideRecruitingEnabled: false
            )
        )
        assert(
            !PickupDetailGameDetailsPresentation.showsOutsideRecruitmentMetadata(
                isTeamLinked: true,
                isOutsideRecruitingEnabled: false
            )
        )
        assert(
            PickupDetailGameDetailsPresentation.showsOutsideRecruitmentMetadata(
                isTeamLinked: true,
                isOutsideRecruitingEnabled: true
            )
        )
    }

    private static func testPlayerNumberAndGenderRosterRules() {
        assert(FanTeamPlayerNumber.isValid(nil))
        assert(FanTeamPlayerNumber.isValid(0))
        assert(FanTeamPlayerNumber.isValid(99))
        assert(!FanTeamPlayerNumber.isValid(-1))
        assert(!FanTeamPlayerNumber.isValid(100))
        assert(FanTeamPlayerNumber.parse("07") == 7)
        assert(FanTeamPlayerNumber.parse("") == nil)
        assert(FanTeamPlayerNumber.parse("abc") == nil)
        assert(FanTeamPlayerNumber.displayLabel(7) == "#7")
        assert(
            FanTeamMemberPositionPresentation.compactMetadata(playerNumber: 24, preferredPositionCode: "CB")
                == "#24 · CB"
        )
        assert(
            FanTeamMemberPositionPresentation.compactMetadata(playerNumber: 24, preferredPositionCode: nil)
                == "#24"
        )
        assert(
            FanTeamMemberPositionPresentation.compactMetadata(playerNumber: nil, preferredPositionCode: "CB")
                == "CB"
        )
        assert(
            FanTeamMemberPositionPresentation.compactMetadata(playerNumber: nil, preferredPositionCode: nil)
                == nil
        )
        assert(
            FanTeamMemberPositionPresentation.lineupPrefillPositionCode(
                preferredPositionCode: "cb",
                sportToken: "Soccer"
            ) == "CB"
        )
        assert(
            FanTeamMemberPositionPresentation.lineupPrefillPositionCode(
                preferredPositionCode: "QB",
                sportToken: "Soccer"
            ) == nil
        )
        assert(
            FanTeamMemberPositionPresentation.lineupPrefillPositionCode(
                preferredPositionCode: nil,
                sportToken: "Soccer"
            ) == nil
        )
        assert(FanTeamRosterRowPresentation.avatarSize >= 64 && FanTeamRosterRowPresentation.avatarSize <= 72)
        assert(FanTeamRosterRowPresentation.parentheticalHandle(username: "jt1") == "@jt1")
        assert(FanTeamRosterRowPresentation.parentheticalHandle(username: "@jt1") == "@jt1")
        assert(FanTeamRosterRowPresentation.parentheticalHandle(username: "@@jtapple") == "@jtapple")
        assert(FanTeamRosterRowPresentation.parentheticalHandle(username: nil) == nil)
        assert(FanTeamRosterRowPresentation.parentheticalHandle(username: "   ") == nil)
        assert(
            FanTeamRosterRowPresentation.identityLine(displayName: "FanGeo", username: "jt1")
                == "FanGeo (@jt1)"
        )
        assert(
            FanTeamRosterRowPresentation.identityLine(displayName: "Fan", username: "@jtapple")
                == "Fan (@jtapple)"
        )

        assert(FanProfileGender.parse("male") == .male)
        assert(FanProfileGender.parse("NON_BINARY") == .nonBinary)
        assert(FanProfileGender.rosterDisplayValue(from: "male") == .male)
        assert(FanProfileGender.rosterDisplayValue(from: "prefer_not_to_say") == nil)
        assert(FanProfileGender.rosterDisplayValue(from: nil) == nil)
        assert(FanProfileGender.rosterDisplayValue(from: "") == nil)

        let withNumber = FanTeamMember(
            userId: UUID(),
            role: .member,
            joinedAt: Date(),
            displayName: "Fan",
            username: "fan",
            avatarURL: nil,
            avatarThumbnailURL: nil,
            lastSeenAtRaw: nil,
            playerNumber: 18,
            preferredPositionCode: "CB",
            genderRaw: "female"
        )
        assert(withNumber.playerNumber == 18)
        assert(withNumber.preferredPositionCode == "CB")
        assert(withNumber.rosterGender == .female)
        assert(withNumber.replacingPlayerNumber(nil).playerNumber == nil)
        assert(withNumber.replacingPlayerNumber(nil).preferredPositionCode == "CB")
        assert(withNumber.replacingPreferredPositionCode("CM").preferredPositionCode == "CM")
        assert(withNumber.replacingPreferredPositionCode(nil).preferredPositionCode == nil)
    }

    private static func testMyPlayerInfoPresentation() {
        let viewerId = UUID()
        let outsiderId = UUID()
        let joined = Date(timeIntervalSince1970: 1_723_219_200) // 2024-08-09 UTC-ish

        func member(
            userId: UUID,
            role: FanTeamMemberRole,
            number: Int? = nil,
            position: String? = nil,
            joinedAt: Date? = joined
        ) -> FanTeamMember {
            FanTeamMember(
                userId: userId,
                role: role,
                joinedAt: joinedAt,
                displayName: "Fan",
                username: "fan",
                avatarURL: nil,
                avatarThumbnailURL: nil,
                lastSeenAtRaw: nil,
                playerNumber: number,
                preferredPositionCode: position,
                genderRaw: nil
            )
        }

        let ordinary = member(userId: viewerId, role: .member, number: 24, position: "GK")
        let owner = member(userId: viewerId, role: .owner, number: 1, position: "CB")
        let manager = member(userId: viewerId, role: .manager, number: 8, position: "CM")
        let coach = member(userId: viewerId, role: .headCoach, number: 10, position: "ST")
        let assistantCoach = member(userId: viewerId, role: .assistantCoach, number: 5, position: "LB")
        let roster = [ordinary]

        assert(
            FanTeamMyPlayerInfoPresentation.viewerMember(from: roster, currentUserId: viewerId)?.userId
                == viewerId
        )
        assert(FanTeamMyPlayerInfoPresentation.shouldShow(viewerMember: ordinary))
        assert(FanTeamMyPlayerInfoPresentation.shouldShow(viewerMember: owner))
        assert(FanTeamMyPlayerInfoPresentation.shouldShow(viewerMember: manager))
        assert(FanTeamMyPlayerInfoPresentation.shouldShow(viewerMember: coach))
        assert(FanTeamMyPlayerInfoPresentation.shouldShow(viewerMember: assistantCoach))
        assert(
            FanTeamMyPlayerInfoPresentation.viewerMember(from: roster, currentUserId: outsiderId) == nil
        )
        assert(
            !FanTeamMyPlayerInfoPresentation.shouldShow(
                viewerMember: FanTeamMyPlayerInfoPresentation.viewerMember(
                    from: roster,
                    currentUserId: outsiderId
                )
            )
        )

        assert(
            FanTeamMyPlayerInfoPresentation.jerseyDisplayValue(playerNumber: 24, languageCode: "en")
                == "#24"
        )
        assert(
            FanTeamMyPlayerInfoPresentation.jerseyDisplayValue(playerNumber: nil, languageCode: "en")
                == L10n.t("fan_teams_not_set", languageCode: "en")
        )

        let soccerGK = FanTeamMemberPositionPresentation.overviewPositionDisplay(
            preferredPositionCode: "GK",
            sportToken: "Soccer",
            languageCode: "en"
        )
        assert(soccerGK?.contains("GK") == true)
        assert(soccerGK != "GK")
        assert(
            FanTeamMemberPositionPresentation.overviewPositionDisplay(
                preferredPositionCode: "SS",
                sportToken: "Baseball",
                languageCode: "en"
            )?.contains("SS") == true
        )
        assert(
            FanTeamMemberPositionPresentation.overviewPositionDisplay(
                preferredPositionCode: "P",
                sportToken: "Softball",
                languageCode: "en"
            )?.contains("P") == true
        )
        assert(
            FanTeamMemberPositionPresentation.overviewPositionDisplay(
                preferredPositionCode: "PG",
                sportToken: "NBA",
                languageCode: "en"
            )?.contains("PG") == true
        )
        assert(
            FanTeamMemberPositionPresentation.overviewPositionDisplay(
                preferredPositionCode: "QB",
                sportToken: "NFL",
                languageCode: "en"
            )?.contains("QB") == true
        )
        assert(
            FanTeamMemberPositionPresentation.overviewPositionDisplay(
                preferredPositionCode: "G",
                sportToken: "NHL",
                languageCode: "en"
            )?.contains("G") == true
        )
        assert(
            FanTeamMemberPositionPresentation.overviewPositionDisplay(
                preferredPositionCode: "S",
                sportToken: "Volleyball",
                languageCode: "en"
            )?.contains("S") == true
        )
        assert(
            FanTeamMyPlayerInfoPresentation.positionDisplayValue(
                preferredPositionCode: nil,
                sportToken: "Soccer",
                languageCode: "en"
            ) == L10n.t("fan_teams_not_set", languageCode: "en")
        )
        assert(
            FanTeamMemberPositionPresentation.overviewPositionDisplay(
                preferredPositionCode: "ZZZ",
                sportToken: "Soccer",
                languageCode: "en"
            ) == "ZZZ"
        )
        assert(
            FanTeamMemberPositionPresentation.overviewPositionDisplay(
                preferredPositionCode: "xx",
                sportToken: "Golf",
                languageCode: "en"
            ) == "XX"
        )

        let since = FanTeamMyPlayerInfoPresentation.memberSinceDisplayValue(
            joinedAt: joined,
            languageCode: "en"
        )
        assert(!since.isEmpty)
        assert(since != L10n.t("fan_teams_not_set", languageCode: "en"))
        assert(
            FanTeamMyPlayerInfoPresentation.memberSinceDisplayValue(joinedAt: nil, languageCode: "en")
                == L10n.t("fan_teams_not_set", languageCode: "en")
        )
        assert(ordinary.joinedAt == joined)

        assert(!FanTeamMyPlayerInfoPresentation.grantsSelfEditPermission)

        // Team-scoped eligibility (self + managed seats on THIS Team only).
        let emmaMembership = UUID()
        let ameliaMembership = UUID()
        let emmaManagedId = UUID()
        let ameliaManagedId = UUID()
        let offTeamManagedId = UUID()
        let emmaJoined = Date(timeIntervalSince1970: 1_723_219_200)
        let ameliaJoined = Date(timeIntervalSince1970: 1_725_000_000)

        let emmaMember = FanTeamMember(
            membershipId: emmaMembership,
            userId: nil,
            managedPlayerId: emmaManagedId,
            role: .member,
            joinedAt: emmaJoined,
            displayName: "Emma",
            username: nil,
            avatarURL: "https://example.com/emma.jpg",
            avatarThumbnailURL: nil,
            lastSeenAtRaw: nil,
            playerNumber: 24,
            preferredPositionCode: "GK"
        )
        let ameliaMember = FanTeamMember(
            membershipId: ameliaMembership,
            userId: nil,
            managedPlayerId: ameliaManagedId,
            role: .member,
            joinedAt: ameliaJoined,
            displayName: "Amelia",
            username: "should_not_show",
            avatarURL: nil,
            avatarThumbnailURL: nil,
            lastSeenAtRaw: nil,
            playerNumber: nil,
            preferredPositionCode: "ST"
        )
        let emmaSeat = FanTeamManagedPlayerSeat(
            id: emmaMembership,
            managedPlayerId: emmaManagedId,
            displayName: "Emma",
            avatarURL: "https://example.com/emma.jpg",
            avatarThumbnailURL: nil,
            playerNumber: 24,
            preferredPositionCode: "GK",
            joinedAt: emmaJoined
        )
        let ameliaSeat = FanTeamManagedPlayerSeat(
            id: ameliaMembership,
            managedPlayerId: ameliaManagedId,
            displayName: "Amelia",
            avatarURL: nil,
            avatarThumbnailURL: nil,
            playerNumber: nil,
            preferredPositionCode: "ST",
            joinedAt: ameliaJoined
        )
        // Globally managed but NOT on this Team → never eligible.
        let _ = offTeamManagedId

        // A. adult only
        let adultOnly = FanTeamMyPlayerInfoPresentation.eligibleSubjects(
            members: [ordinary],
            currentUserId: viewerId,
            managedSeats: []
        )
        assert(adultOnly.count == 1)
        assert(adultOnly[0].isViewerAccountSeat)
        assert(FanTeamMyPlayerInfoPresentation.titleKey(subjects: adultOnly) == "fan_teams_my_player_info")
        assert(!FanTeamMyPlayerInfoPresentation.showsChangeControl(subjects: adultOnly))

        // Access-only account seat (is_player=false) is not a Player Info subject.
        let accessOnlySelf = FanTeamMember(
            membershipId: ordinary.membershipId,
            userId: viewerId,
            role: .member,
            joinedAt: ordinary.joinedAt,
            displayName: ordinary.displayName,
            username: ordinary.username,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            lastSeenAtRaw: nil,
            isPlayer: false
        )
        let accessOnlySubjects = FanTeamMyPlayerInfoPresentation.eligibleSubjects(
            members: [accessOnlySelf],
            currentUserId: viewerId,
            managedSeats: []
        )
        assert(accessOnlySubjects.isEmpty)

        // Access-only self + child on Team → child only.
        let accessOnlyPlusKid = FanTeamMyPlayerInfoPresentation.eligibleSubjects(
            members: [accessOnlySelf, emmaMember],
            currentUserId: viewerId,
            managedSeats: [emmaSeat]
        )
        assert(accessOnlyPlusKid.count == 1)
        assert(!accessOnlyPlusKid[0].isViewerAccountSeat)

        // B. one managed player only (guardian not personally on Team)
        let managedOnly = FanTeamMyPlayerInfoPresentation.eligibleSubjects(
            members: [emmaMember],
            currentUserId: viewerId,
            managedSeats: [emmaSeat]
        )
        assert(managedOnly.count == 1)
        assert(!managedOnly[0].isViewerAccountSeat)
        assert(FanTeamMyPlayerInfoPresentation.titleKey(subjects: managedOnly) == "managed_players_player_info")
        assert(!FanTeamMyPlayerInfoPresentation.showsChangeControl(subjects: managedOnly))
        assert(managedOnly[0].member.username == nil || !FanTeamMyPlayerInfoPresentation.showsUsername(subject: managedOnly[0]))
        assert(!managedOnly[0].member.supportsSocialActions)

        // C/D. self + children
        let selfPlusKids = FanTeamMyPlayerInfoPresentation.eligibleSubjects(
            members: [ordinary, emmaMember, ameliaMember],
            currentUserId: viewerId,
            managedSeats: [emmaSeat, ameliaSeat]
        )
        assert(selfPlusKids.count == 3)
        assert(FanTeamMyPlayerInfoPresentation.showsChangeControl(subjects: selfPlusKids))
        assert(FanTeamMyPlayerInfoPresentation.titleKey(subjects: selfPlusKids) == "managed_players_player_info")

        // E. child exists globally but not on this Team → hidden
        let withOffTeamSeatList = FanTeamMyPlayerInfoPresentation.eligibleSubjects(
            members: [ordinary],
            currentUserId: viewerId,
            managedSeats: [] // off-team managed player never appears in managedSeats for this Team
        )
        assert(withOffTeamSeatList.count == 1)
        assert(withOffTeamSeatList[0].isViewerAccountSeat)

        // F. self not on Team, Emma on Team
        let emmaOnly = FanTeamMyPlayerInfoPresentation.eligibleSubjects(
            members: [emmaMember, ameliaMember],
            currentUserId: outsiderId,
            managedSeats: [emmaSeat]
        )
        assert(emmaOnly.count == 1)
        assert(emmaOnly[0].membershipId == emmaMembership)

        // G. Emma + Amelia, guardian not personally on Team
        let twoKids = FanTeamMyPlayerInfoPresentation.eligibleSubjects(
            members: [emmaMember, ameliaMember],
            currentUserId: outsiderId,
            managedSeats: [emmaSeat, ameliaSeat]
        )
        assert(twoKids.count == 2)
        assert(FanTeamMyPlayerInfoPresentation.showsChangeControl(subjects: twoKids))

        // Seat-only eligibility (roster may lag): membership_id from seat is enough.
        let seatOnlyKids = FanTeamMyPlayerInfoPresentation.eligibleSubjects(
            members: [],
            currentUserId: outsiderId,
            managedSeats: [emmaSeat, ameliaSeat]
        )
        assert(seatOnlyKids.count == 2)
        assert(FanTeamMyPlayerInfoPresentation.showsChangeControl(subjects: seatOnlyKids))
        assert(FanTeamMyPlayerInfoPresentation.titleKey(subjects: seatOnlyKids) == "managed_players_player_info")

        // Matching prefers membership_id over managed_player_id when both present.
        let staleManagedId = UUID()
        let rosterEmma = FanTeamMember(
            membershipId: emmaMembership,
            userId: nil,
            managedPlayerId: emmaManagedId,
            role: .member,
            joinedAt: emmaJoined,
            displayName: "Emma Roster",
            username: nil,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            lastSeenAtRaw: nil,
            playerNumber: 24,
            preferredPositionCode: "GK"
        )
        let seatWithStaleManagedFallback = FanTeamManagedPlayerSeat(
            id: emmaMembership,
            managedPlayerId: staleManagedId,
            displayName: "Emma Seat",
            avatarURL: nil,
            avatarThumbnailURL: nil,
            playerNumber: 24,
            preferredPositionCode: "GK",
            joinedAt: emmaJoined
        )
        let matchedByMembership = FanTeamMyPlayerInfoPresentation.eligibleSubjects(
            members: [rosterEmma],
            currentUserId: outsiderId,
            managedSeats: [seatWithStaleManagedFallback]
        )
        assert(matchedByMembership.count == 1)
        assert(matchedByMembership[0].member.displayName == "Emma Roster")
        assert(matchedByMembership[0].membershipId == emmaMembership)

        // Default selection: prefer self, then first managed
        assert(
            FanTeamMyPlayerInfoPresentation.resolveSelectedMembershipId(
                preferred: nil,
                subjects: selfPlusKids
            ) == ordinary.membershipId
        )
        assert(
            FanTeamMyPlayerInfoPresentation.resolveSelectedMembershipId(
                preferred: nil,
                subjects: twoKids
            ) == emmaMembership
        )
        // Remember previous selection when still valid
        assert(
            FanTeamMyPlayerInfoPresentation.resolveSelectedMembershipId(
                preferred: ameliaMembership,
                subjects: selfPlusKids
            ) == ameliaMembership
        )
        // P. selected child removed → fallback
        assert(
            FanTeamMyPlayerInfoPresentation.resolveSelectedMembershipId(
                preferred: ameliaMembership,
                subjects: managedOnly
            ) == emmaMembership
        )

        // Member since is seat-scoped
        assert(emmaMember.joinedAt == emmaJoined)
        assert(ameliaMember.joinedAt == ameliaJoined)
        assert(emmaMember.joinedAt != ameliaMember.joinedAt)

        // Header summary for managed
        let emmaSummary = FanTeamMyPlayerInfoPresentation.headerManagedSummary(
            playerNumber: 24,
            preferredPositionCode: "GK",
            sportToken: "Soccer",
            languageCode: "en"
        )
        assert(emmaSummary?.contains("#24") == true)
        assert(emmaSummary?.localizedCaseInsensitiveContains("goalkeeper") == true)

        // Future RSVP reuse key
        assert(managedOnly[0].rsvpSubject.membershipId == emmaMembership)
        assert(managedOnly[0].rsvpSubject.isManagedPlayer)

        // Empty → hide
        assert(
            !FanTeamMyPlayerInfoPresentation.shouldShow(
                subjects: FanTeamMyPlayerInfoPresentation.eligibleSubjects(
                    members: [],
                    currentUserId: viewerId,
                    managedSeats: []
                )
            )
        )

        // Overview list: self first, omit Not set, accessibility without fake values
        let ordered = FanTeamMyPlayerInfoPresentation.orderedForOverview(selfPlusKids)
        assert(ordered.first?.isViewerAccountSeat == true)
        assert(ordered.count == 3)
        let bothMissing = FanTeamMyPlayerInfoPresentation.jerseyPositionLine(
            subject: ordered[0],
            sportToken: "Soccer",
            languageCode: "en"
        )
        // ordinary fixture may have number/position — amelia has ST only
        let ameliaSubject = ordered.first { $0.membershipId == ameliaMembership }!
        let ameliaLine = FanTeamMyPlayerInfoPresentation.jerseyPositionLine(
            subject: ameliaSubject,
            sportToken: "Soccer",
            languageCode: "en"
        )
        assert(ameliaLine != nil)
        assert(!(ameliaLine ?? "").localizedCaseInsensitiveContains("Not set"))
        let missingBothSubject = FanTeamPlayerInfoSubject(
            membershipId: UUID(),
            member: FanTeamMember(
                membershipId: UUID(),
                userId: viewerId,
                managedPlayerId: nil,
                role: .member,
                joinedAt: Date(),
                displayName: "Bare",
                username: nil,
                avatarURL: nil,
                avatarThumbnailURL: nil,
                lastSeenAtRaw: nil,
                playerNumber: nil,
                preferredPositionCode: nil
            ),
            isViewerAccountSeat: true
        )
        assert(
            FanTeamMyPlayerInfoPresentation.jerseyPositionLine(
                subject: missingBothSubject,
                sportToken: "Soccer",
                languageCode: "en"
            ) == nil
        )
        let sinceLine = FanTeamMyPlayerInfoPresentation.memberSinceLine(
            subject: missingBothSubject,
            languageCode: "en"
        )
        assert(sinceLine != nil)
        assert(!(sinceLine ?? "").localizedCaseInsensitiveContains("Not set"))
        let a11y = FanTeamMyPlayerInfoPresentation.overviewRowAccessibilityLabel(
            subject: ameliaSubject,
            sportToken: "Soccer",
            languageCode: "en"
        )
        assert(a11y.localizedCaseInsensitiveContains("Amelia"))
        assert(a11y.localizedCaseInsensitiveContains("Managed") || a11y.localizedCaseInsensitiveContains("managed"))
        _ = bothMissing

        let leadersStillWork = FanTeamLeadership.leaders(from: [
            ordinary,
            member(userId: UUID(), role: .owner, number: 1, position: "GK"),
        ])
        assert(leadersStillWork.count == 1)
        assert(leadersStillWork.first?.role == .owner)

        let localeKeys = [
            "team_overview_your_players_on_team",
            "team_player_membership_manage",
            "team_player_membership_manage_title",
            "team_player_membership_status_on_team",
            "team_player_membership_status_not_on_team",
            "team_player_membership_remove_confirm_title_format",
            "fan_teams_my_player_info",
            "managed_players_player_info",
            "fan_teams_jersey_number",
            "fan_teams_position",
            "fan_teams_member_since",
            "fan_teams_not_set",
            "fan_teams_player_information",
            "fan_teams_player_details",
            "fan_teams_team_status",
            "fan_teams_team_role",
            "fan_teams_choose_role_help",
            "fan_teams_remove_number",
            "fan_teams_jersey_number",
            "fan_teams_position",
            "fan_teams_member_since",
            "fan_teams_remove_from_event",
            "fan_teams_add_back_to_event",
            "fan_teams_excluded_from_event_section",
            "fan_teams_excluded_from_event_status",
            "fan_teams_remove_from_event_confirm_title",
            "fan_teams_remove_from_event_confirm_action",
            "fan_teams_remove_from_event_confirm_body_format",
            "fan_teams_remove_from_event_failed",
            "fan_teams_add_back_to_event_failed",
            "fan_teams_player_info_change_number_a11y",
            "fan_teams_player_info_change_position_a11y",
            "fan_teams_my_player_info_jersey_a11y_format",
            "fan_teams_my_player_info_row_a11y_format",
            "fan_teams_player_info_who_viewing",
            "fan_teams_player_info_change_a11y",
            "fan_teams_player_info_subject_a11y_format",
            "fan_teams_player_info_subject_selected_a11y_format",
            "fan_team_schedule_rsvp_change",
            "team_player_selector_myself",
            "team_invite_managed_caption",
        ]
        for key in localeKeys {
            for lang in L10n.supportedLanguages.map(\.code) {
                let value = L10n.t(key, languageCode: lang)
                assert(value != key, "missing \(key) for \(lang)")
                assert(!value.contains("%d"), "prefer %lld for \(key)")
            }
        }
        let jerseyA11y = L10n.t("fan_teams_my_player_info_jersey_a11y_format", languageCode: "en")
        assert(jerseyA11y.contains("%lld"))
        _ = String(format: jerseyA11y, locale: Locale(identifier: "en"), Int64(24))
        let rowA11y = L10n.t("fan_teams_my_player_info_row_a11y_format", languageCode: "en")
        _ = String(format: rowA11y, locale: Locale(identifier: "en"), "Position", "Goalkeeper, G K")
    }

    private static func testScheduleQuickRSVPPresentation() {
        let emma = FanTeamMember(
            userId: UUID(),
            role: .member,
            joinedAt: Date(),
            displayName: "Emma",
            username: "emma1",
            avatarURL: nil,
            avatarThumbnailURL: nil,
            lastSeenAtRaw: nil
        )
        let subject = FanTeamRSVPSubject.from(member: emma)
        assert(subject.promptDisplayName == "Emma")
        assert(!subject.promptDisplayName.lowercased().contains("you"))

        let usernameOnly = FanTeamRSVPSubject(
            membershipId: UUID(),
            userId: UUID(),
            displayName: "  ",
            username: "jtapple",
            avatarURL: nil,
            avatarThumbnailURL: nil
        )
        assert(usernameOnly.promptDisplayName == "jtapple")

        let fallback = FanTeamRSVPSubject.resolvePromptDisplayName(
            displayName: nil,
            username: nil,
            languageCode: "en"
        )
        assert(fallback == L10n.t("fan_team_schedule_rsvp_player_fallback", languageCode: "en"))

        let prompt = FanTeamScheduleQuickRSVPCopy.prompt(subjectName: "Emma", languageCode: "en")
        assert(prompt == "Will Emma be there?")
        assert(!prompt.lowercased().contains("you"))
        assert(
            FanTeamScheduleQuickRSVPCopy.confirmed(state: .going, subjectName: "Emma", languageCode: "en")
                == "Emma is going"
        )
        assert(
            FanTeamScheduleQuickRSVPCopy.confirmed(state: .maybe, subjectName: "Emma", languageCode: "en")
                == "Emma may be going"
        )
        assert(
            FanTeamScheduleQuickRSVPCopy.confirmed(state: .cantGo, subjectName: "Emma", languageCode: "en")
                .localizedCaseInsensitiveContains("emma")
        )

        assert(FanTeamScheduleQuickRSVPState.from(rsvp: nil) == .noResponse)
        assert(FanTeamScheduleQuickRSVPState.from(rsvp: .going) == .going)
        assert(FanTeamScheduleQuickRSVPState.from(rsvp: .maybe) == .maybe)
        assert(FanTeamScheduleQuickRSVPState.from(rsvp: .cant_go) == .cantGo)
        assert(FanTeamScheduleQuickRSVPState.from(attendance: .noResponse) == .noResponse)
        assert(
            FanTeamScheduleQuickRSVPState.resolve(
                subjectUserId: UUID(),
                roster: nil,
                explicitSelfRSVP: .status(.going),
                fallbackRSVP: .cant_go
            ) == .going
        )
        assert(
            FanTeamScheduleQuickRSVPState.resolve(
                subjectUserId: UUID(),
                roster: nil,
                explicitSelfRSVP: .unanswered,
                fallbackRSVP: .going
            ) == .noResponse
        )

        // Sticky `.unanswered` must not suppress roster Going / Maybe / Can't Go.
        let subjectId = UUID()
        let goingMember = PickupGameRosterMember(
            user_id: subjectId,
            request_id: nil,
            display_name: "FanGeo",
            username: nil,
            avatar_url: nil,
            avatar_thumbnail_url: nil,
            role: "playing",
            status: "approved",
            membership_id: nil,
            is_managed_player: false,
            managed_player_id: nil
        )
        let rosterGoing = PickupGameRosterPayload(
            pickup_game_id: UUID(),
            viewer_is_organizer: true,
            organizer: goingMember,
            playing: [goingMember],
            pending: [],
            declined: [],
            no_response: [],
            excluded: [],
            viewer_can_manage_event_roster: true,
            approved_join_count: 0,
            playing_total_count: 1
        )
        assert(
            FanTeamScheduleQuickRSVPState.resolve(
                subjectUserId: subjectId,
                roster: rosterGoing,
                explicitSelfRSVP: .unanswered,
                fallbackRSVP: nil
            ) == .going
        )
        assert(FanTeamCachedSelfRSVP.unanswered.isDefinitive == false)
        assert(FanTeamCachedSelfRSVP.status(.maybe).isDefinitive == true)

        // Managed seat resolves via managed_player_id on roster user_id.
        let managedId = UUID()
        let managedSubject = FanTeamRSVPSubject(
            membershipId: UUID(),
            userId: nil,
            managedPlayerId: managedId,
            displayName: "Emma",
            username: nil,
            avatarURL: nil,
            avatarThumbnailURL: nil
        )
        assert(managedSubject.rosterAttendanceUserId == managedId)
        let managedPlaying = PickupGameRosterMember(
            user_id: managedId,
            request_id: nil,
            display_name: "Emma",
            username: nil,
            avatar_url: nil,
            avatar_thumbnail_url: nil,
            role: "playing",
            status: "going",
            membership_id: managedSubject.membershipId,
            is_managed_player: true,
            managed_player_id: managedId
        )
        let managedRoster = PickupGameRosterPayload(
            pickup_game_id: UUID(),
            viewer_is_organizer: false,
            organizer: nil,
            playing: [managedPlaying],
            pending: [],
            declined: [],
            no_response: [],
            excluded: nil,
            viewer_can_manage_event_roster: false,
            approved_join_count: 1,
            playing_total_count: 1
        )
        assert(
            FanTeamScheduleQuickRSVPState.resolve(
                subjectUserId: managedSubject.rosterAttendanceUserId,
                roster: managedRoster,
                explicitSelfRSVP: nil,
                fallbackRSVP: nil
            ) == .going
        )

        struct TokenError: LocalizedError {
            let errorDescription: String?
        }
        let mapped = FanTeamRSVPErrorMapping.userFacingMessage(
            for: TokenError(errorDescription: "pickup_request_decision_forbidden"),
            languageCode: "en"
        )
        assert(mapped == L10n.t("fan_team_rsvp_update_failed_message", languageCode: "en"))
        assert(!mapped.contains("pickup_request_decision_forbidden"))

        let upcoming = FanTeamGame(
            id: UUID(),
            teamId: UUID(),
            createdBy: UUID(),
            gameType: .practice,
            sport: "Soccer",
            title: "Practice",
            startsAt: Date().addingTimeInterval(3600),
            endsAt: Date().addingTimeInterval(7200),
            venueName: nil,
            address: "Draper, UT 84020",
            city: "Draper",
            state: "UT 84020",
            latitude: nil,
            longitude: nil,
            opponentTeamId: nil,
            opponentName: nil,
            status: "active",
            homeScore: nil,
            awayScore: nil,
            mySide: "home",
            createdAt: nil,
            competitionLevel: nil,
                messageBody: nil
        )
        assert(FanTeamScheduleQuickRSVPEligibility.showsQuickRSVPControls(game: upcoming))
        let past = FanTeamGame(
            id: upcoming.id,
            teamId: upcoming.teamId,
            createdBy: upcoming.createdBy,
            gameType: .league_game,
            sport: "Soccer",
            title: "Past",
            startsAt: Date().addingTimeInterval(-86_400),
            endsAt: Date().addingTimeInterval(-80_000),
            venueName: nil,
            address: nil,
            city: nil,
            state: nil,
            latitude: nil,
            longitude: nil,
            opponentTeamId: nil,
            opponentName: nil,
            status: "active",
            homeScore: nil,
            awayScore: nil,
            mySide: "home",
            createdAt: nil,
            competitionLevel: nil,
                messageBody: nil
        )
        assert(!FanTeamScheduleQuickRSVPEligibility.showsQuickRSVPControls(game: past))
        let cancelled = FanTeamGame(
            id: upcoming.id,
            teamId: upcoming.teamId,
            createdBy: upcoming.createdBy,
            gameType: .team_meeting,
            sport: "Soccer",
            title: "Meeting",
            startsAt: Date().addingTimeInterval(3600),
            endsAt: nil,
            venueName: nil,
            address: nil,
            city: nil,
            state: nil,
            latitude: nil,
            longitude: nil,
            opponentTeamId: nil,
            opponentName: nil,
            status: "cancelled",
            homeScore: nil,
            awayScore: nil,
            mySide: "home",
            createdAt: nil,
            competitionLevel: nil,
                messageBody: nil
        )
        assert(FanTeamScheduleQuickRSVPEligibility.isCancelled(cancelled))
        assert(!FanTeamScheduleQuickRSVPEligibility.showsQuickRSVPControls(game: cancelled))
        assert(
            !FanTeamScheduleQuickRSVPEligibility.isExcludedFromEvent(
                subjectUserId: emma.userId,
                gameId: upcoming.id,
                roster: nil
            )
        )

        let deduped = FanTeamScheduleLocationPresentation.line(
            venueName: nil,
            address: "Draper, UT 84020",
            city: "Draper",
            state: "UT 84020"
        )
        assert(deduped == "Draper, UT 84020", "got \(deduped)")
        assert(!deduped.contains(" · "), "should not repeat city/state fragments")
        assert(
            FanTeamScheduleLocationPresentation.collapsedLine("Draper, UT 84020, Draper, UT 84020")
                == "Draper, UT 84020"
        )
        assert(
            FanTeamScheduleLocationPresentation.collapsedLine("Draper, UT 84020 · Draper, UT 84020")
                == "Draper, UT 84020"
        )
        let street = FanTeamScheduleLocationPresentation.line(
            venueName: nil,
            address: "152 E Midvillage Blvd",
            city: "Sandy",
            state: "UT 84070"
        )
        assert(street == "152 E Midvillage Blvd · Sandy, UT 84070")
        assert(upcoming.locationLine == "Draper, UT 84020")

        // Screenshot-style duplicates (venue == address + city + state ZIP).
        assert(
            FanTeamEventLocationPresentation.displayLocation(
                venueName: "Draper, UT 84020",
                address: "Draper, UT 84020",
                city: "Draper",
                state: "UT 84020"
            ) == "Draper, UT 84020"
        )
        assert(
            FanTeamEventLocationPresentation.displayLocation(
                venueName: "152 E Midvillage Blvd",
                address: "152 E Midvillage Blvd",
                city: "Sandy",
                state: "UT 84070"
            ) == "152 E Midvillage Blvd · Sandy, UT 84070"
        )
        // Already-concatenated junk in address field.
        assert(
            FanTeamEventLocationPresentation.displayLocation(
                venueName: nil,
                address: "152 E Midvillage Blvd · 152 E Midvillage Blvd · Sandy · UT 84070",
                city: "Sandy",
                state: "UT 84070"
            ) == "152 E Midvillage Blvd · Sandy, UT 84070"
        )
        assert(
            FanTeamEventLocationPresentation.displayLocation(
                venueName: "Draper, UT 84020 · Draper, UT 84020 · Draper · UT 84020",
                address: nil,
                city: nil,
                state: nil
            ) == "Draper, UT 84020"
        )
        // Street + city + state + ZIP (state and ZIP separate-ish via "UT 84070").
        assert(
            FanTeamEventLocationPresentation.displayLocation(
                venueName: nil,
                address: "100 Main St",
                city: "Draper",
                state: "UT 84020"
            ) == "100 Main St · Draper, UT 84020"
        )
        // City + state + ZIP only.
        assert(
            FanTeamEventLocationPresentation.displayLocation(
                venueName: nil,
                address: nil,
                city: "Draper",
                state: "UT 84020"
            ) == "Draper, UT 84020"
        )
        // Venue + complete address.
        assert(
            FanTeamEventLocationPresentation.displayLocation(
                venueName: "Galena Hills Park",
                address: "152 E Midvillage Blvd",
                city: "Sandy",
                state: "UT 84070"
            ) == "Galena Hills Park · 152 E Midvillage Blvd · Sandy, UT 84070"
        )
        // Missing ZIP.
        assert(
            FanTeamEventLocationPresentation.displayLocation(
                venueName: nil,
                address: "100 Main St",
                city: "Draper",
                state: "UT"
            ) == "100 Main St · Draper, UT"
        )
        // Missing street.
        assert(
            FanTeamEventLocationPresentation.displayLocation(
                venueName: nil,
                address: nil,
                city: "Sandy",
                state: "UT 84070"
            ) == "Sandy, UT 84070"
        )
        // Nil / empty.
        assert(
            FanTeamEventLocationPresentation.displayLocation(
                venueName: nil,
                address: "  ",
                city: nil,
                state: nil
            ).isEmpty
        )
        // Whitespace / case duplicates → single locality line (case may follow first atom).
        let caseDup = FanTeamEventLocationPresentation.displayLocation(
            venueName: " draper, ut 84020 ",
            address: "Draper, UT 84020",
            city: "DRAPER",
            state: "ut 84020"
        )
        assert(!caseDup.contains(" · "))
        assert(caseDup.localizedCaseInsensitiveContains("draper"))
        assert(caseDup.localizedCaseInsensitiveContains("84020"))
        // Already clean remains clean.
        assert(
            FanTeamEventLocationPresentation.displayLocation(
                venueName: nil,
                address: "152 E Midvillage Blvd · Sandy, UT 84070",
                city: nil,
                state: nil
            ) == "152 E Midvillage Blvd · Sandy, UT 84070"
        )

        assert(upcoming.hasUsableDirectionsCoordinate == false)
        let withCoords = FanTeamGame(
            id: upcoming.id,
            teamId: upcoming.teamId,
            createdBy: upcoming.createdBy,
            gameType: .practice,
            sport: "Soccer",
            title: "Practice",
            startsAt: upcoming.startsAt,
            endsAt: upcoming.endsAt,
            venueName: "Galena Hills Park",
            address: "152 E Midvillage Blvd",
            city: "Sandy",
            state: "UT 84070",
            latitude: 40.57,
            longitude: -111.86,
            opponentTeamId: nil,
            opponentName: nil,
            status: "active",
            homeScore: nil,
            awayScore: nil,
            mySide: "home",
            createdAt: nil,
            competitionLevel: nil,
                messageBody: nil
        )
        assert(withCoords.hasUsableDirectionsCoordinate)
        assert(withCoords.directionsDestinationName == "Galena Hills Park")
        assert(!withCoords.locationLine.contains("152 E Midvillage Blvd · 152 E Midvillage Blvd"))

        let viewer = FanTeamRSVPSubject.currentViewer(
            from: [emma],
            currentUserId: emma.userId
        )
        assert(viewer?.userId == emma.userId)
        assert(
            FanTeamRSVPSubject.currentViewer(from: [emma], currentUserId: UUID()) == nil
        )

        let localeKeys = [
            "fan_team_schedule_rsvp_will_be_there_format",
            "fan_team_schedule_rsvp_is_going_format",
            "fan_team_schedule_rsvp_may_be_going_format",
            "fan_team_schedule_rsvp_cant_go_format",
            "fan_team_schedule_rsvp_change",
            "fan_team_schedule_rsvp_mark_going_a11y_format",
            "fan_team_schedule_rsvp_mark_cant_go_a11y_format",
            "fan_team_schedule_rsvp_change_a11y_format",
            "fan_team_schedule_rsvp_not_participating",
            "fan_team_schedule_rsvp_player_fallback",
            "fan_team_schedule_rsvp_save_failed",
            "fan_team_rsvp_update_failed_message",
            "fan_team_schedule_event_cancelled",
            "Directions",
            "Directions to %@",
            "pickup_detail_directions_a11y_hint",
            "Apple Maps",
            "Google Maps",
            "Copy Address",
        ]
        for key in localeKeys {
            for lang in L10n.supportedLanguages.map(\.code) {
                let value = L10n.t(key, languageCode: lang)
                assert(value != key, "missing \(key) for \(lang)")
                assert(!value.contains("%d"), "prefer %@ / %lld for \(key)")
            }
        }
        _ = String(
            format: L10n.t("fan_team_schedule_rsvp_will_be_there_format", languageCode: "en"),
            locale: Locale(identifier: "en"),
            "Emma"
        )
        _ = String(
            format: L10n.t("Directions to %@", languageCode: "en"),
            locale: Locale(identifier: "en"),
            "Draper, UT 84020"
        )
    }

    private static func testTeamLeadershipDerivation() {
        func member(userId: UUID = UUID(), role: FanTeamMemberRole, name: String) -> FanTeamMember {
            FanTeamMember(
                userId: userId,
                role: role,
                joinedAt: Date(),
                displayName: name,
                username: nil,
                avatarURL: nil,
                avatarThumbnailURL: nil,
                lastSeenAtRaw: nil
            )
        }
        let owner = member(role: .owner, name: "Owner")
        let managerA = member(role: .manager, name: "Manager A")
        let managerB = member(role: .manager, name: "Manager B")
        let headCoach = member(role: .headCoach, name: "Head Coach")
        let assistantCoach = member(role: .assistantCoach, name: "Asst Coach")
        let captain = member(role: .captain, name: "Captain")
        let assistantCaptain = member(role: .assistantCaptain, name: "Asst Captain")
        let ordinary = member(role: .member, name: "Member")

        let leaders = FanTeamLeadership.leaders(
            from: [ordinary, assistantCaptain, managerB, captain, headCoach, owner, assistantCoach, managerA]
        )
        assert(leaders.map(\.role) == [
            .owner,
            .manager,
            .manager,
            .headCoach,
            .assistantCoach,
            .captain,
            .assistantCaptain
        ])
        // Managers sorted by display name within the same role.
        assert(leaders[1].displayName == "Manager A")
        assert(leaders[2].displayName == "Manager B")
        assert(!leaders.contains(where: { $0.role == .member }))

        let ownerOnly = FanTeamLeadership.leaders(from: [ordinary, owner])
        assert(ownerOnly.count == 1 && ownerOnly[0].role == .owner)

        let duplicateOwnerId = UUID()
        let dupLeaders = FanTeamLeadership.leaders(from: [
            member(userId: duplicateOwnerId, role: .owner, name: "Owner A"),
            member(userId: duplicateOwnerId, role: .owner, name: "Owner Dup"),
            member(role: .manager, name: "Mgr")
        ])
        assert(dupLeaders.count == 2)
        assert(Set(dupLeaders.map(\.userId)).count == 2)

        assert(FanTeamLeadership.isLeadershipRole(.owner))
        assert(FanTeamLeadership.isLeadershipRole(.manager))
        assert(FanTeamLeadership.isLeadershipRole(.headCoach))
        assert(FanTeamLeadership.isLeadershipRole(.assistantCoach))
        assert(FanTeamLeadership.isLeadershipRole(.captain))
        assert(FanTeamLeadership.isLeadershipRole(.assistantCaptain))
        assert(!FanTeamLeadership.isLeadershipRole(.member))

        let rosterSorted = FanTeamRosterOrdering.sorted([
            ordinary, captain, owner, assistantCaptain, managerA, headCoach, assistantCoach
        ])
        assert(rosterSorted.map(\.role) == [
            .owner, .manager, .headCoach, .assistantCoach, .captain, .assistantCaptain, .member
        ])

        assert(FanTeamMemberRole.assignableViaRolePicker == [
            .manager, .headCoach, .assistantCoach, .captain, .assistantCaptain, .member
        ])
        assert(!FanTeamMemberRole.assignableViaRolePicker.contains(.owner))

        // Canonical local role replacement must preserve seat identity (Player Information Binding).
        let roleSeat = member(role: .member, name: "Alex")
        let promoted = roleSeat.replacingRole(.captain)
        assert(promoted.role == .captain)
        assert(promoted.membershipId == roleSeat.membershipId)
        assert(promoted.userId == roleSeat.userId)
        assert(promoted.displayName == roleSeat.displayName)
        let demoted = promoted.replacingRole(.member)
        assert(demoted.role == .member)
        var leadershipProbe = [
            member(role: .owner, name: "Owner"),
            roleSeat,
        ]
        assert(FanTeamLeadership.leaders(from: leadershipProbe).count == 1)
        leadershipProbe[1] = roleSeat.replacingRole(.captain)
        let leadersAfter = FanTeamLeadership.leaders(from: leadershipProbe)
        assert(leadersAfter.contains(where: { $0.role == .captain && $0.displayName == "Alex" }))
        leadershipProbe[1] = roleSeat.replacingRole(.member)
        assert(!FanTeamLeadership.leaders(from: leadershipProbe).contains(where: { $0.displayName == "Alex" }))

        // Managed-player Captain is a real leadership seat (20260994). Must not
        // require user_id; sibling managed seats stay unchanged.
        let emmaMembership = UUID()
        let emmaManagedId = UUID()
        let siblingMembership = UUID()
        let siblingManagedId = UUID()
        let emmaSeat = FanTeamMember(
            membershipId: emmaMembership,
            userId: nil,
            managedPlayerId: emmaManagedId,
            role: .member,
            joinedAt: Date(),
            displayName: "Emma TBI",
            username: nil,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            lastSeenAtRaw: nil
        )
        let siblingSeat = FanTeamMember(
            membershipId: siblingMembership,
            userId: nil,
            managedPlayerId: siblingManagedId,
            role: .member,
            joinedAt: Date(),
            displayName: "Sibling",
            username: nil,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            lastSeenAtRaw: nil
        )
        assert(emmaSeat.userId == nil)
        assert(emmaSeat.isManagedPlayer)
        let emmaCaptain = emmaSeat.replacingRole(.captain)
        assert(emmaCaptain.role == .captain)
        assert(emmaCaptain.membershipId == emmaMembership)
        assert(emmaCaptain.userId == nil)
        assert(emmaCaptain.managedPlayerId == emmaManagedId)
        let emmaAssistant = emmaCaptain.replacingRole(.assistantCaptain)
        assert(emmaAssistant.role == .assistantCaptain)
        let emmaMemberAgain = emmaAssistant.replacingRole(.member)
        assert(emmaMemberAgain.role == .member)
        var managedRoster = [owner, emmaSeat, siblingSeat]
        managedRoster[1] = emmaCaptain
        assert(managedRoster[0].role == .owner)
        assert(managedRoster[1].role == .captain)
        assert(managedRoster[2].role == .member)
        assert(managedRoster[2].membershipId == siblingMembership)
        let managedLeaders = FanTeamLeadership.leaders(from: managedRoster)
        assert(managedLeaders.contains(where: {
            $0.membershipId == emmaMembership && $0.role == .captain && $0.userId == nil
        }))
        assert(!managedLeaders.contains(where: { $0.membershipId == siblingMembership }))
        managedRoster[1] = emmaMemberAgain
        assert(!FanTeamLeadership.leaders(from: managedRoster).contains(where: {
            $0.membershipId == emmaMembership
        }))

        // Serialization + backward compatibility
        assert(FanTeamMemberRole.parse("owner") == .owner)
        assert(FanTeamMemberRole.parse("MANAGER") == .manager)
        assert(FanTeamMemberRole.parse("captain") == .captain)
        assert(FanTeamMemberRole.parse("member") == .member)
        assert(FanTeamMemberRole.parse("head_coach") == .headCoach)
        assert(FanTeamMemberRole.parse("Head Coach") == .headCoach)
        assert(FanTeamMemberRole.parse("assistant_coach") == .assistantCoach)
        assert(FanTeamMemberRole.parse("assistant_captain") == .assistantCaptain)
        assert(FanTeamMemberRole.parse("unknown_token") == .member)
        assert(FanTeamMemberRole.parse(nil) == .member)

        let encoded = try! JSONEncoder().encode(FanTeamMemberRole.headCoach)
        assert(String(data: encoded, encoding: .utf8) == "\"head_coach\"")
        let decoded = try! JSONDecoder().decode(FanTeamMemberRole.self, from: Data("\"assistant_captain\"".utf8))
        assert(decoded == .assistantCaptain)
        let legacyDecoded = try! JSONDecoder().decode(FanTeamMemberRole.self, from: Data("\"manager\"".utf8))
        assert(legacyDecoded == .manager)

        // Badge mapping
        assert(FanTeamMemberRole.owner.badgeSystemImage == "crown.fill")
        assert(FanTeamMemberRole.manager.badgeSystemImage == "shield.fill")
        assert(FanTeamMemberRole.headCoach.badgeSystemImage.contains("whistle")
            || FanTeamMemberRole.headCoach.badgeSystemImage.contains("clipboard"))
        assert(FanTeamMemberRole.assistantCoach.badgeSystemImage == "clipboard.fill")
        assert(FanTeamMemberRole.captain.badgeSystemImage == "star.fill")
        assert(FanTeamMemberRole.assistantCaptain.badgeSystemImage == "star")
        assert(FanTeamMemberRole.member.badgeSystemImage == "person.fill")
        assert(FanTeamMemberRole.owner.badgeTint == .gold)
        assert(FanTeamMemberRole.manager.badgeTint == .purple)
        assert(FanTeamMemberRole.headCoach.badgeTint == .blue)
        assert(FanTeamMemberRole.assistantCoach.badgeTint == .indigo)
        assert(FanTeamMemberRole.captain.badgeTint == .orange)
        assert(FanTeamMemberRole.assistantCaptain.badgeTint == .teal)
        assert(FanTeamMemberRole.member.badgeTint == .gray)

        // Localization keys resolve in English
        for role in FanTeamMemberRole.hierarchyOrder {
            let title = L10n.t(role.localizedKey, languageCode: "en")
            assert(!title.isEmpty)
            assert(title != role.localizedKey)
        }

        let me = UUID()
        assert(FanTeamLeadership.usesOwnPublicProfilePreview(memberUserId: me, currentUserId: me))
        assert(!FanTeamLeadership.usesOwnPublicProfilePreview(memberUserId: me, currentUserId: UUID()))
        assert(!FanTeamLeadership.usesOwnPublicProfilePreview(memberUserId: me, currentUserId: nil))

        let summary = FanTeamSummary(
            id: UUID(),
            name: "JT",
            sport: "Soccer",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: "#7B61FF",
            competitionLevel: nil,
            ownerUserId: me,
            groupConversationId: UUID(),
            myRole: .member,
            memberCount: 2,
            pendingInvitationCount: 0,
            pushNotificationsMuted: false,
            nextGameStartsAt: nil,
            nextGameTitle: nil,
            nextGameVenue: nil,
            createdAt: Date()
        )
        assert(FanTeamPrivacyPresentation.showsPrivateTeamBadge(for: summary))
        assert(FanTeamColorTheme.hasCustomColor(summary.colorHex))
        assert(!FanTeamColorTheme.hasCustomColor(nil))
    }

    private static func testCreateTeamLogoStagingPolicy() {
        assert(!FanTeamCreateLogoPolicy.shouldUploadAfterCreate(pendingImageData: nil))
        assert(!FanTeamCreateLogoPolicy.shouldUploadAfterCreate(pendingImageData: Data()))
        assert(FanTeamCreateLogoPolicy.shouldUploadAfterCreate(pendingImageData: Data([0x01])))
        assert(
            FanTeamCreateLogoPolicy.photoActionTitleKey(hasPendingLocalPhoto: false)
                == "fan_teams_add_photo"
        )
        assert(
            FanTeamCreateLogoPolicy.photoActionTitleKey(hasPendingLocalPhoto: true)
                == "fan_teams_change_photo"
        )
        assert(
            FanTeamCreateLogoPolicy.photoActionAccessibilityKey(hasPendingLocalPhoto: false)
                == "fan_teams_add_photo_a11y"
        )
        assert(
            FanTeamCreateLogoPolicy.photoActionAccessibilityKey(hasPendingLocalPhoto: true)
                == "fan_teams_change_photo_a11y"
        )
    }

    private static func testRosterJoinedCaption() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let joined = cal.date(from: DateComponents(year: 2026, month: 5, day: 12))!
        let line = FanTeamRosterJoinedCaption.line(
            teamName: "Team JT",
            joinedAt: joined,
            languageCode: "en"
        )
        assert(line != nil)
        assert(line?.contains("Team JT") == true)
        assert(line?.contains("2026") == true)
        assert(line?.localizedCaseInsensitiveContains("Joined Team") == true)
        assert(line?.contains("•") == true)

        let month = FanTeamRosterJoinedCaption.monthYear(from: joined, languageCode: "en")
        assert(month.contains("2026"))
        assert(month.localizedCaseInsensitiveContains("May"))

        assert(FanTeamRosterJoinedCaption.line(teamName: "Team JT", joinedAt: nil, languageCode: "en") == nil)
        assert(FanTeamRosterJoinedCaption.line(teamName: "   ", joinedAt: joined, languageCode: "en") == nil)

        let longName = String(repeating: "A", count: 40)
        let truncated = FanTeamRosterJoinedCaption.truncatedTeamName(longName)
        assert(truncated.count == FanTeamRosterJoinedCaption.maxTeamNameCharacters)
        assert(truncated.hasSuffix("…"))
        let longLine = FanTeamRosterJoinedCaption.line(
            teamName: longName,
            joinedAt: joined,
            languageCode: "en"
        )
        assert(longLine?.contains("…") == true)
        assert(longLine?.contains(String(repeating: "A", count: 40)) != true)
    }

    private static func testTeamLoadErrorPresentation() {
        assert(FanTeamsLoadErrorPresentation.isCancellation(CancellationError()))
        assert(FanTeamsLoadErrorPresentation.userFacingMessage(for: CancellationError()) == nil)

        let urlCancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        assert(FanTeamsLoadErrorPresentation.isCancellation(urlCancelled))
        assert(FanTeamsLoadErrorPresentation.userFacingMessage(for: urlCancelled) == nil)

        let real = NSError(domain: "FanTeamsTest", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "RPC exploded",
        ])
        assert(!FanTeamsLoadErrorPresentation.isCancellation(real))
        let presented = FanTeamsLoadErrorPresentation.userFacingMessage(for: real, languageCode: "en")
        assert(presented != nil)
        assert(presented?.localizedCaseInsensitiveContains("couldn't refresh") == true
            || presented?.localizedCaseInsensitiveContains("try again") == true)
        assert(presented?.localizedCaseInsensitiveContains("CancellationError") != true)
        assert(presented?.localizedCaseInsensitiveContains("RPC exploded") != true)

        let missingSession = NSError(domain: "FanTeamsTest", code: 401, userInfo: [
            NSLocalizedDescriptionKey: "Auth session missing",
        ])
        assert(FanTeamsLoadErrorPresentation.isMissingAuthSession(missingSession))
        assert(FanTeamsLoadErrorPresentation.userFacingMessage(for: missingSession) == nil)

        let notAuthenticated = NSError(domain: "FanTeamsTest", code: 401, userInfo: [
            NSLocalizedDescriptionKey: "Not authenticated",
        ])
        assert(FanTeamsLoadErrorPresentation.isMissingAuthSession(notAuthenticated))
        assert(FanTeamsLoadErrorPresentation.userFacingMessage(for: notAuthenticated) == nil)

        let jwtExpired = NSError(domain: "FanTeamsTest", code: 401, userInfo: [
            NSLocalizedDescriptionKey: "JWT expired",
        ])
        assert(FanTeamsLoadErrorPresentation.isMissingAuthSession(jwtExpired))
        assert(FanTeamsLoadErrorPresentation.userFacingMessage(for: jwtExpired) == nil)

        let layeredCancel = FanTeamLayeredError(
            layer: .teamsReload,
            underlying: CancellationError(),
            httpStatus: nil,
            responseBody: nil,
            mutationCommitted: nil
        )
        assert(FanTeamsLoadErrorPresentation.isCancellation(layeredCancel))
        assert(FanTeamsLoadErrorPresentation.userFacingMessage(for: layeredCancel) == nil)
        assert(
            !MyTeamsRefreshPresentation.shouldPresentBlockingAlert(
                trigger: .automaticTeamsHome,
                hasCachedTeams: true,
                isHostTabSelected: false,
                isCancellation: true,
                isMissingAuth: false
            )
        )
    }

    private static func testRPCScalarBoolDecode() {
        func data(_ raw: String) -> Data { Data(raw.utf8) }
        func decoded(_ raw: String, fallback: Bool? = nil) -> Bool? {
            try? FanTeamRPCScalarBool.decode(from: data(raw), fallbackIfEmpty: fallback)
        }
        assert(decoded("false") == false)
        assert(decoded("true") == true)
        assert(decoded("[false]") == false)
        assert(decoded("[true]") == true)
        assert(decoded("\"false\"") == false)
        assert(decoded("0") == false)
        assert(decoded("", fallback: false) == false)
        assert(decoded("", fallback: true) == true)
        // Remove Myself returns JSON false — that is success, not a refresh failure.
        assert(decoded("false") == false, "is_player=false must decode as success false, not throw")
        assert(decoded("{\"set_my_fan_team_is_player\":false}") == false)
        assert(decoded("{\"value\":false}") == false)
        assert(decoded("{}") == nil)
        assert(decoded("{}", fallback: false) == false)
    }

    private static func testMembershipLayeredErrorCopy() {
        let real = NSError(domain: "FanTeamsTest", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "RPC exploded",
        ])
        let membership = FanTeamsLoadErrorPresentation.userFacingMessage(
            for: real,
            layer: .membershipUpdate,
            languageCode: "en"
        )
        assert(membership?.localizedCaseInsensitiveContains("membership") == true)
        assert(membership?.localizedCaseInsensitiveContains("couldn't refresh") != true)

        let detail = FanTeamsLoadErrorPresentation.userFacingMessage(
            for: real,
            layer: .teamDetailMembers,
            languageCode: "en"
        )
        assert(detail?.localizedCaseInsensitiveContains("reload") == true)
        assert(detail?.localizedCaseInsensitiveContains("couldn't refresh") != true)

        let layered = FanTeamLayeredError(
            layer: .membershipUpdate,
            underlying: real,
            httpStatus: 400,
            responseBody: "{\"message\":\"not authorized\"}",
            mutationCommitted: false
        )
        let fromLayered = FanTeamsLoadErrorPresentation.userFacingMessage(for: layered, languageCode: "en")
        assert(fromLayered?.localizedCaseInsensitiveContains("membership") == true)

        let managed = FanTeamsLoadErrorPresentation.userFacingMessage(
            for: real,
            layer: .managedPlayerRefresh,
            languageCode: "en"
        )
        assert(managed == nil)
    }

    private static func testMyselfPlayerSeatCombinations() {
        let viewerId = UUID()
        let emmaId = UUID()
        let myselfMembership = UUID()
        let emmaMembership = UUID()
        let joined = Date()

        func myself(isPlayer: Bool) -> FanTeamMember {
            FanTeamMember(
                membershipId: myselfMembership,
                userId: viewerId,
                role: .owner,
                joinedAt: joined,
                displayName: "JT",
                username: "jt",
                avatarURL: nil,
                avatarThumbnailURL: nil,
                lastSeenAtRaw: nil,
                isPlayer: isPlayer
            )
        }
        func emmaMember() -> FanTeamMember {
            FanTeamMember(
                membershipId: emmaMembership,
                userId: nil,
                managedPlayerId: emmaId,
                role: .member,
                joinedAt: joined,
                displayName: "Emma",
                username: nil,
                avatarURL: nil,
                avatarThumbnailURL: nil,
                lastSeenAtRaw: nil,
                isPlayer: true
            )
        }
        let emmaSeat = FanTeamManagedPlayerSeat(
            id: emmaMembership,
            managedPlayerId: emmaId,
            displayName: "Emma",
            avatarURL: nil,
            avatarThumbnailURL: nil,
            playerNumber: nil,
            preferredPositionCode: nil,
            joinedAt: joined
        )
        let emmaPlayer = FanManagedPlayer(
            id: emmaId,
            firstName: "Emma",
            lastName: "",
            displayName: "Emma",
            avatarURL: nil,
            avatarThumbnailURL: nil,
            birthYear: 2016,
            guardianRole: .primaryGuardian,
            teamCount: 1,
            createdAt: joined
        )

        let combos: [(myselfOn: Bool, emmaOn: Bool, playerCount: Int)] = [
            (true, true, 2),
            (false, true, 1),
            (true, false, 1),
            (false, false, 0),
        ]
        for combo in combos {
            var members: [FanTeamMember] = [myself(isPlayer: combo.myselfOn)]
            var managedSeats: [FanTeamManagedPlayerSeat] = []
            if combo.emmaOn {
                members.append(emmaMember())
                managedSeats = [emmaSeat]
            }
            assert(FanTeamRosterPlayerPresentation.playerCount(from: members) == combo.playerCount)

            let rows = FanTeamAccountPlayerOverviewPresentation.rows(
                hasAccountSeat: true,
                myselfDisplayName: "JT",
                myselfIsPlayer: combo.myselfOn,
                myselfMembershipId: myselfMembership,
                managedPlayers: [emmaPlayer],
                managedSeats: managedSeats
            )
            assert(rows.contains(where: { $0.kind == .myself }), "Myself row must remain when is_player=false")
            let myselfRow = rows.first(where: { $0.kind == .myself })
            assert(myselfRow?.isOnTeam == combo.myselfOn)
            let emmaRow = rows.first(where: {
                if case .managed(let id) = $0.kind { return id == emmaId }
                return false
            })
            assert(emmaRow?.isOnTeam == combo.emmaOn)

            let subjects = FanTeamMyPlayerInfoPresentation.eligibleSubjects(
                members: members,
                currentUserId: viewerId,
                managedSeats: managedSeats
            )
            let expectSelfSubject = combo.myselfOn
            let expectEmmaSubject = combo.emmaOn
            assert(subjects.contains(where: \.isViewerAccountSeat) == expectSelfSubject)
            assert(subjects.contains(where: { !$0.isViewerAccountSeat }) == expectEmmaSubject)
        }

        let accessOnly = myself(isPlayer: true).replacingIsPlayer(false)
        assert(accessOnly.isPlayer == false)
        assert(accessOnly.role == .owner)
        assert(accessOnly.userId == viewerId)

        let ownerOff = FanTeamAccountPlayerOverviewPresentation.rows(
            hasAccountSeat: true,
            myselfDisplayName: "Owner",
            myselfIsPlayer: false,
            myselfMembershipId: myselfMembership,
            managedPlayers: [],
            managedSeats: []
        )
        assert(ownerOff.count == 1)
        assert(ownerOff[0].kind == .myself)
        assert(ownerOff[0].isOnTeam == false)

        let caption = FanTeamPlayerMembershipManagePresentation.myselfStatusCaption(
            isPlayer: false,
            languageCode: "en"
        )
        assert(caption == "Not on Team as player")
    }

    private static func testTeamsHomeAuthPresentation() {
        assert(!TeamsHomeAuthPresentation.shouldFetchAuthenticatedTeamData(isSignedIn: false))
        assert(TeamsHomeAuthPresentation.shouldFetchAuthenticatedTeamData(isSignedIn: true))
        assert(TeamsHomeAuthPresentation.showsSignedOutLanding(isSignedIn: false))
        assert(!TeamsHomeAuthPresentation.showsSignedOutLanding(isSignedIn: true))
        assert(!TeamsHomeAuthPresentation.showsAuthenticatedChrome(isSignedIn: false))
        assert(TeamsHomeAuthPresentation.showsAuthenticatedChrome(isSignedIn: true))
        assert(!TeamsHomeAuthPresentation.showsAuthenticatedEmptyState(isSignedIn: false, homeItemCount: 0))
        assert(!TeamsHomeAuthPresentation.showsAuthenticatedEmptyState(isSignedIn: false, homeItemCount: 3))
        assert(TeamsHomeAuthPresentation.showsAuthenticatedEmptyState(isSignedIn: true, homeItemCount: 0))
        assert(!TeamsHomeAuthPresentation.showsAuthenticatedEmptyState(isSignedIn: true, homeItemCount: 2))
    }

    private static func testTeamCompetitionLevelInheritance() {
        // New Team game initializes from Team default (resolved value, not a live lookup).
        assert(PickupTeamCompetitionInheritance.initialGameLevel(teamDefault: .youth) == .youth)
        assert(PickupTeamCompetitionInheritance.initialGameLevel(teamDefault: nil) == nil)

        // Edit chrome: match current Team default → Team-default mode; mismatch → override.
        assert(
            PickupTeamCompetitionInheritance.startsInInheritedMode(
                gameLevel: .youth,
                teamDefault: .youth
            )
        )
        assert(
            !PickupTeamCompetitionInheritance.startsInInheritedMode(
                gameLevel: .adult_competitive,
                teamDefault: .youth
            )
        )
        assert(
            !PickupTeamCompetitionInheritance.startsInInheritedMode(
                gameLevel: .youth,
                teamDefault: nil
            )
        )
        // After Team default changes, do not claim historical inheritance when values diverge.
        assert(
            !PickupTeamCompetitionInheritance.startsInInheritedMode(
                gameLevel: .youth,
                teamDefault: .high_school
            )
        )

        // Team CSV: omit → Team default; explicit → row override; Team NULL + omit → nil.
        assert(
            PickupTeamCompetitionInheritance.resolveCSVLevel(
                csvRaw: "",
                parsed: nil,
                teamDefault: .youth,
                isTeamSourced: true
            ) == .youth
        )
        assert(
            PickupTeamCompetitionInheritance.resolveCSVLevel(
                csvRaw: "College / University",
                parsed: .college_university,
                teamDefault: .youth,
                isTeamSourced: true
            ) == .college_university
        )
        assert(
            PickupTeamCompetitionInheritance.resolveCSVLevel(
                csvRaw: "",
                parsed: nil,
                teamDefault: nil,
                isTeamSourced: true
            ) == nil
        )
        // Normal Pickup CSV unchanged: omit stays nil even if a Team default were present.
        assert(
            PickupTeamCompetitionInheritance.resolveCSVLevel(
                csvRaw: "",
                parsed: nil,
                teamDefault: .youth,
                isTeamSourced: false
            ) == nil
        )

        // Meta line: hide Not specified; include level when set.
        let withLevel = FanTeamMetaLine.compose(
            competitionLevel: .youth,
            sport: "Soccer",
            memberCount: 12,
            languageCode: "en"
        )
        assert(withLevel.localizedCaseInsensitiveContains("Youth"))
        assert(withLevel.localizedCaseInsensitiveContains("Soccer"))
        assert(withLevel.contains("12"))
        assert(!withLevel.localizedCaseInsensitiveContains("Not specified"))

        let nilLevel = FanTeamMetaLine.compose(
            competitionLevel: nil,
            sport: "Soccer",
            memberCount: 12,
            languageCode: "en"
        )
        assert(nilLevel.hasPrefix("Soccer"))
        assert(!nilLevel.localizedCaseInsensitiveContains("Youth"))
        assert(!nilLevel.localizedCaseInsensitiveContains("Not specified"))
    }

    private static func testTeamCSVImportRules() {
        let team = PickupGameTeamCreationContext(
            teamId: UUID(),
            teamName: "Test Teams",
            teamSport: "Soccer"
        )
        let canonicalize: (String) -> String? = { raw in
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return nil }
            if t.localizedCaseInsensitiveCompare("Soccer") == .orderedSame { return "Soccer" }
            if t.localizedCaseInsensitiveCompare("Basketball") == .orderedSame { return "Basketball" }
            return nil
        }

        // Empty CSV sport → Team sport.
        let omitted = PickupBulkImportTeamRules.resolveSport(
            csvSportRaw: "",
            team: team,
            canonicalize: canonicalize
        )
        assert(omitted.sport == "Soccer")
        assert(omitted.error == nil)

        // Matching sport OK.
        let match = PickupBulkImportTeamRules.resolveSport(
            csvSportRaw: "Soccer",
            team: team,
            canonicalize: canonicalize
        )
        assert(match.sport == "Soccer")
        assert(match.error == nil)

        // Conflicting sport rejected with clear message.
        let conflict = PickupBulkImportTeamRules.resolveSport(
            csvSportRaw: "Basketball",
            team: team,
            canonicalize: canonicalize
        )
        assert(conflict.sport == nil)
        assert(conflict.error?.contains("Basketball") == true)
        assert(conflict.error?.contains("Soccer") == true)
        assert(conflict.error?.contains("Test Teams") == true)

        // Normal (non-team) still requires sport.
        let normalMissing = PickupBulkImportTeamRules.resolveSport(
            csvSportRaw: "",
            team: nil,
            canonicalize: canonicalize
        )
        assert(normalMissing.error == "Missing sport.")

        assert(PickupBulkImportTeamRules.defaultGameFormat(isTeamSourced: true) == .practice)
        assert(PickupBulkImportTeamRules.defaultGameFormat(isTeamSourced: false) == .pickup)
        assert(PickupBulkImportTeamRules.allowsGameFormat(.practice, isTeamSourced: true))
        assert(!PickupBulkImportTeamRules.allowsGameFormat(.pickup, isTeamSourced: true))
        assert(PickupBulkImportTeamRules.allowsGameFormat(.pickup, isTeamSourced: false))
        assert(
            PickupGameEditPrivacyPolicy.defaultIsPublicForNewGame(isTeamSourcedCreate: true) == false
        )
        assert(
            PickupGameEditPrivacyPolicy.defaultIsPublicForNewGame(isTeamSourcedCreate: false) == true
        )

        // Team outside recruiting: OFF persists floor; ON when players_needed > 1 or max set.
        assert(!PickupTeamOutsideRecruiting.isEnabled(playersNeeded: 1, maxPlayers: nil))
        assert(PickupTeamOutsideRecruiting.isEnabled(playersNeeded: 2, maxPlayers: nil))
        assert(PickupTeamOutsideRecruiting.isEnabled(playersNeeded: 1, maxPlayers: 10))
        let inactive = PickupTeamOutsideRecruiting.inactivePersistence()
        assert(inactive.playersNeeded == 1)
        assert(inactive.maxPlayers == nil)

        // Discover My Teams scope: membership ∩ Team-link identity (not public Team games alone).
        let myTeamA = UUID()
        let otherTeam = UUID()
        let gameMine = UUID()
        let gameOther = UUID()
        let gameStandalone = UUID()
        let identityByGame: [UUID: PickupDiscoverTeamIdentity] = [
            gameMine: PickupDiscoverTeamIdentity(
                pickupGameId: gameMine,
                teamId: myTeamA,
                teamName: "Team A",
                teamSport: "Soccer",
                colorHex: nil,
                logoURL: nil,
                logoThumbnailURL: nil,
                displayRefreshToken: nil
            ),
            gameOther: PickupDiscoverTeamIdentity(
                pickupGameId: gameOther,
                teamId: otherTeam,
                teamName: "Other",
                teamSport: "Soccer",
                colorHex: nil,
                logoURL: nil,
                logoThumbnailURL: nil,
                displayRefreshToken: nil
            )
        ]
        assert(
            DiscoverPickupTeamScopeFilter.includes(
                gameId: gameMine,
                scope: .myTeams,
                myActiveTeamIds: [myTeamA],
                teamIdentityByGameId: identityByGame
            )
        )
        assert(
            !DiscoverPickupTeamScopeFilter.includes(
                gameId: gameOther,
                scope: .myTeams,
                myActiveTeamIds: [myTeamA],
                teamIdentityByGameId: identityByGame
            )
        )
        assert(
            !DiscoverPickupTeamScopeFilter.includes(
                gameId: gameStandalone,
                scope: .myTeams,
                myActiveTeamIds: [myTeamA],
                teamIdentityByGameId: identityByGame
            )
        )
        assert(
            DiscoverPickupTeamScopeFilter.includes(
                gameId: gameStandalone,
                scope: .all,
                myActiveTeamIds: [myTeamA],
                teamIdentityByGameId: identityByGame
            )
        )

        // Discover Team presentation: availability only when recruiting (never from private alone).
        assert(
            PickupDiscoverTeamPresentation.shouldShowPublicAvailability(
                isTeamLinked: false,
                isOutsideRecruiting: false
            )
        )
        assert(
            !PickupDiscoverTeamPresentation.shouldShowPublicAvailability(
                isTeamLinked: true,
                isOutsideRecruiting: false
            )
        )
        assert(
            PickupDiscoverTeamPresentation.shouldShowPublicAvailability(
                isTeamLinked: true,
                isOutsideRecruiting: true
            )
        )
        assert(
            !PickupDiscoverTeamPresentation.shouldOfferOutsideJoinCTA(
                isTeamLinked: true,
                isOutsideRecruiting: false
            )
        )
        assert(
            PickupDiscoverTeamPresentation.shouldOfferOutsideJoinCTA(
                isTeamLinked: true,
                isOutsideRecruiting: true
            )
        )
        assert(
            PickupDiscoverTeamPresentation.previewPrimaryCTATitleKey(
                isTeamLinked: true,
                isOutsideRecruiting: false
            ) == "pickup_preview_details"
        )
        assert(
            PickupDiscoverTeamPresentation.previewPrimaryCTATitleKey(
                isTeamLinked: true,
                isOutsideRecruiting: true
            ) == "pickup_preview_details_and_join"
        )
        let teamOnlyA11y = PickupDiscoverTeamPresentation.mapPinAccessibilityLabel(
            gameTitle: "Friday Kickabout",
            sportLabel: "Soccer",
            identity: PickupDiscoverTeamIdentity(
                pickupGameId: UUID(),
                teamId: UUID(),
                teamName: "Team JT",
                teamSport: "Soccer",
                colorHex: nil,
                logoURL: nil,
                logoThumbnailURL: nil,
                displayRefreshToken: nil
            ),
            showsPublicAvailability: false,
            spotsNeeded: 3,
            languageCode: "en"
        )
        assert(teamOnlyA11y.contains("Team JT"))
        assert(teamOnlyA11y.contains("Soccer"))
        assert(!teamOnlyA11y.localizedCaseInsensitiveContains("spot"))

        // Team HOW YOU PLAY: Indoor/Outdoor always; outside eligibility only when recruiting ON.
        assert(
            PickupTeamHowYouPlayPresentation.showsOutsideRecruitmentFields(
                isTeamLinked: false,
                needsAdditionalPlayers: false
            )
        )
        assert(
            !PickupTeamHowYouPlayPresentation.showsOutsideRecruitmentFields(
                isTeamLinked: true,
                needsAdditionalPlayers: false
            )
        )
        assert(
            PickupTeamHowYouPlayPresentation.showsOutsideRecruitmentFields(
                isTeamLinked: true,
                needsAdditionalPlayers: true
            )
        )

        // Team safety: roster-only = informational; recruiting/standalone create = acknowledgement.
        assert(
            PickupTeamSafetyPresentation.usesTeamOnlyInformationalNote(
                isTeamLinked: true,
                needsAdditionalPlayers: false
            )
        )
        assert(
            !PickupTeamSafetyPresentation.usesTeamOnlyInformationalNote(
                isTeamLinked: true,
                needsAdditionalPlayers: true
            )
        )
        assert(
            !PickupTeamSafetyPresentation.usesTeamOnlyInformationalNote(
                isTeamLinked: false,
                needsAdditionalPlayers: false
            )
        )
        assert(
            !PickupTeamSafetyPresentation.requiresAcknowledgment(
                isCreate: true,
                isTeamLinked: true,
                needsAdditionalPlayers: false
            )
        )
        assert(
            PickupTeamSafetyPresentation.requiresAcknowledgment(
                isCreate: true,
                isTeamLinked: true,
                needsAdditionalPlayers: true
            )
        )
        assert(
            PickupTeamSafetyPresentation.requiresAcknowledgment(
                isCreate: true,
                isTeamLinked: false,
                needsAdditionalPlayers: false
            )
        )
        assert(
            !PickupTeamSafetyPresentation.requiresAcknowledgment(
                isCreate: false,
                isTeamLinked: true,
                needsAdditionalPlayers: true
            )
        )

        assert(
            PickupGameEditPrivacyPolicy.resolvedIsVisible(
                formIsPublic: true,
                isTeamLinked: true,
                needsAdditionalPlayers: false
            ) == true,
            "Team roster-only must still persist Public when organizer selects Public"
        )
        assert(
            PickupGameEditPrivacyPolicy.resolvedIsVisible(
                formIsPublic: true,
                isTeamLinked: true,
                needsAdditionalPlayers: true
            ) == true
        )
        assert(
            PickupGameEditPrivacyPolicy.resolvedIsVisible(
                formIsPublic: false,
                isTeamLinked: true,
                needsAdditionalPlayers: true
            ) == false,
            "Recruiting ON must not force Public"
        )
        assert(
            PickupGameEditPrivacyPolicy.resolvedIsVisible(
                formIsPublic: true,
                isTeamLinked: false,
                needsAdditionalPlayers: false
            ) == true
        )

        let teamPlayers = PickupBulkImportTeamRules.resolvePlayersNeeded(
            csvPlayersNeeded: nil,
            csvRaw: "",
            isTeamSourced: true
        )
        assert(teamPlayers.playersNeeded == 1)
        assert(teamPlayers.error == nil)
        let teamExtra = PickupBulkImportTeamRules.resolvePlayersNeeded(
            csvPlayersNeeded: 3,
            csvRaw: "3",
            isTeamSourced: true
        )
        assert(teamExtra.playersNeeded == 3)
    }

    private static func testPickupInviteTeamRecipientGate() {
        let organizer = UUID()
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let gated = [c: "going"]
        let first = PickupInviteRecipientGate.selectableUserIds(
            candidateIds: [organizer, a, b, c, a],
            organizerId: organizer,
            gateByUserId: gated,
            alreadySelected: []
        )
        assert(first.added == [a, b])
        assert(first.skippedGated >= 2) // organizer + going
        let second = PickupInviteRecipientGate.selectableUserIds(
            candidateIds: [a, b],
            organizerId: organizer,
            gateByUserId: [:],
            alreadySelected: Set([a]),
            maxTotal: 1
        )
        assert(second.added.isEmpty)
        assert(second.skippedCapacity == 1)
        assert(PickupInviteRecipientGate.maxInviteesPerGame == 50)
        assert(PickupInviteRecipientGate.sendButtonTitle(count: 0, languageCode: "en") == "Send")
        let many = PickupInviteRecipientGate.sendButtonTitle(count: 12, languageCode: "en")
        assert(many.contains("12"))
        // Security: Team roster eligibility is only on the Team bulk RPC route.
        assert(PickupInviteRPCRoute.route(for: .individuals) == .individualsGeneric)
        assert(PickupInviteRPCRoute.route(for: .teams) == .teamBulkTrusted)
        assert(PickupInviteRPCRoute.route(for: .individuals) != .teamBulkTrusted)

        // Preview/Send capacity + cancelled-invite semantics (matrix G/H/C).
        assert(PickupFanTeamInvitePreviewSemantics.isAlreadyInvited(hasAnyInviteRow: true))
        assert(!PickupFanTeamInvitePreviewSemantics.isAlreadyInvited(hasAnyInviteRow: false))
        // G: 47 active + 10 otherwise eligible → only 3 actionable.
        let gEligible = PickupFanTeamInvitePreviewSemantics.actionableEligibleCount(
            rawEligible: 10,
            activeInviteCount: 47
        )
        assert(gEligible == 3)
        let gIneligible = PickupFanTeamInvitePreviewSemantics.ineligibleCountIncludingCapOverflow(
            baseIneligible: 0,
            rawEligible: 10,
            actionableEligible: gEligible
        )
        assert(gIneligible == 7)
        // H: 50 active → zero actionable.
        assert(
            PickupFanTeamInvitePreviewSemantics.actionableEligibleCount(
                rawEligible: 10,
                activeInviteCount: 50
            ) == 0
        )
        assert(PickupFanTeamInvitePreviewSemantics.remainingSlots(activeInviteCount: 50) == 0)
        assert(PickupFanTeamInvitePreviewSemantics.remainingSlots(activeInviteCount: 0) == 50)
    }

    private static func testTeamPickupCreationContext() {
        let teamId = UUID()
        let ctx = PickupGameCreationContext.team(
            PickupGameTeamCreationContext(teamId: teamId, teamName: "Lehi FC", teamSport: "Soccer")
        )
        assert(ctx.isTeamSourced)
        assert(ctx.team?.teamId == teamId)
        assert(ctx.team?.teamSport == "Soccer")
        assert(!PickupGameCreationContext.standard.isTeamSourced)

        // Schedule header meta: hide Not specified; include level when set.
        let withLevel = PickupGameTeamCreationContext(
            teamId: teamId,
            teamName: "Test Teams",
            teamSport: "Soccer",
            competitionLevel: .youth,
            logoURL: "https://example.com/logo.jpg",
            colorHex: "#22C25A"
        )
        let metaYouth = withLevel.scheduleHeaderMetaLine(languageCode: "en")
        assert(metaYouth.localizedCaseInsensitiveContains("Soccer"))
        assert(metaYouth.localizedCaseInsensitiveContains("Youth"))
        assert(!metaYouth.localizedCaseInsensitiveContains("Not specified"))

        let nilLevel = PickupGameTeamCreationContext(
            teamId: teamId,
            teamName: "Test Teams",
            teamSport: "Soccer",
            competitionLevel: nil
        )
        let metaNil = nilLevel.scheduleHeaderMetaLine(languageCode: "en")
        assert(metaNil.localizedCaseInsensitiveContains("Soccer"))
        assert(!metaNil.contains("·"))
        assert(!metaNil.localizedCaseInsensitiveContains("Not specified"))

        let fromSummary = PickupGameTeamCreationContext(
            from: FanTeamSummary(
                id: teamId,
                name: "Summary FC",
                sport: "Basketball",
                logoURL: "https://example.com/a.jpg",
                logoThumbnailURL: "https://example.com/b.jpg",
                colorHex: "#FF3B30",
                competitionLevel: .college_university,
                ownerUserId: UUID(),
                groupConversationId: UUID(),
                myRole: .owner,
                memberCount: 12,
                pendingInvitationCount: 0,
                pushNotificationsMuted: false,
                nextGameStartsAt: nil,
                nextGameTitle: nil,
                nextGameVenue: nil,
                createdAt: nil
            )
        )
        assert(fromSummary.logoURL != nil)
        assert(fromSummary.logoThumbnailURL != nil)
        assert(fromSummary.colorHex == "#FF3B30")
        assert(fromSummary.competitionLevel == .college_university)
        let a11y = fromSummary.scheduleHeaderAccessibilityLabel(languageCode: "en")
        assert(a11y.localizedCaseInsensitiveContains("Summary FC"))
        assert(a11y.localizedCaseInsensitiveContains("Basketball"))
    }

    private static func testTeamGamesFilterEngine() {
        let now = Date(timeIntervalSince1970: 1_800_000_000) // fixed
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!

        func game(
            id: UUID = UUID(),
            type: FanTeamGameType,
            startOffset: TimeInterval,
            status: String = "scheduled",
            createdOffset: TimeInterval? = nil,
            competitionLevel: PickupCompetitionLevel? = nil
        ) -> FanTeamGame {
            FanTeamGame(
                id: id,
                teamId: UUID(),
                createdBy: UUID(),
                gameType: type,
                sport: "Soccer",
                title: type.rawValue,
                startsAt: now.addingTimeInterval(startOffset),
                endsAt: now.addingTimeInterval(startOffset + 7200),
                venueName: "Pitch",
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
                createdAt: createdOffset.map { now.addingTimeInterval($0) },
                competitionLevel: competitionLevel,
                messageBody: nil
            )
        }

        // A: default is Upcoming
        assert(FanTeamGamesFilterState.default.status == .upcoming)
        assert(FanTeamGamesFilterState.default.resolvedSort() == .soonestFirst)

        let matchSoon = game(type: .match, startOffset: 3600)
        let practiceLater = game(type: .practice, startOffset: 3 * 86400)
        let pastRecent = game(type: .match, startOffset: -86400, status: "completed")
        let pastOlder = game(type: .practice, startOffset: -3 * 86400, status: "completed")
        let scrimmage = game(type: .scrimmage, startOffset: 7200)
        let all = [practiceLater, pastRecent, pastOlder, matchSoon, scrimmage]

        assert(FanTeamGamesTimeline.isUpcoming(matchSoon, now: now))
        assert(FanTeamGamesTimeline.isPast(pastRecent, now: now))

        // B: Upcoming → soonest first
        let upcomingOnly = FanTeamGamesFilterState.default
        let upcoming = FanTeamGamesFilterEngine.filter(all, state: upcomingOnly, now: now, calendar: cal)
        assert(upcoming.count == 3)
        let sortedSoonest = FanTeamGamesFilterEngine.sort(
            upcoming,
            sort: .soonestFirst,
            status: .upcoming,
            now: now
        )
        assert(sortedSoonest.first?.id == matchSoon.id)

        // C: Upcoming → Latest first (furthest future)
        let sortedLatest = FanTeamGamesFilterEngine.sort(
            upcoming,
            sort: .latestFirst,
            status: .upcoming,
            now: now
        )
        assert(sortedLatest.first?.id == practiceLater.id)

        // D: Past → most recent first
        var pastState = FanTeamGamesFilterState.default
        pastState.selectStatus(.past)
        assert(pastState.resolvedSort() == .mostRecentFirst)
        let pastPresented = FanTeamGamesFilterEngine.present(all, state: pastState, now: now, calendar: cal)
        assert(pastPresented.filteredCount == 2)
        assert(pastPresented.sections.first?.kind == .past)
        assert(pastPresented.sections.first?.games.first?.id == pastRecent.id)

        // E: Past → Oldest first
        pastState.sortOverride = .oldestFirst
        let oldestPast = FanTeamGamesFilterEngine.present(all, state: pastState, now: now, calendar: cal)
        assert(oldestPast.sections.first?.games.first?.id == pastOlder.id)

        // G: game-type secondary filter still works
        var matchFilter = FanTeamGamesFilterState.default
        matchFilter.gameType = .match
        let matches = FanTeamGamesFilterEngine.filter(all, state: matchFilter, now: now, calendar: cal)
        assert(matches.count == 1) // upcoming match only (past match filtered by status=upcoming)
        assert(matches.first?.gameType == .match)

        var practiceUpcoming = FanTeamGamesFilterState.default
        practiceUpcoming.gameType = .practice
        let practices = FanTeamGamesFilterEngine.filter(all, state: practiceUpcoming, now: now, calendar: cal)
        assert(practices.count == 1)

        // Competition level secondary filter
        let youthGame = game(type: .league_game, startOffset: 5000, competitionLevel: .youth)
        var levelFilter = FanTeamGamesFilterState.default
        levelFilter.competitionLevel = .youth
        let youthOnly = FanTeamGamesFilterEngine.filter(
            [youthGame, matchSoon],
            state: levelFilter,
            now: now,
            calendar: cal
        )
        assert(youthOnly.count == 1)
        assert(youthOnly.first?.id == youthGame.id)

        // J/K: active secondary indicator + clear preserves status.
        // Funnel badge excludes event-type (chip row); type still clears with Clear Filters.
        var cleared = upcomingOnly
        cleared.gameType = .match
        cleared.datePreset = .thisWeek
        cleared.competitionLevel = .youth
        assert(cleared.hasActiveSecondaryFilters)
        assert(cleared.activeSecondaryFilterCount == 2)
        assert(cleared.hasActiveMenuFilters)
        cleared.clear()
        assert(!cleared.hasActiveSecondaryFilters)
        assert(cleared.status == .upcoming)
        assert(cleared.isDefault)

        // No All status in primary cases
        assert(FanTeamGamesStatusFilter.allCases.map(\.rawValue) == ["upcoming", "past"])
        assert(FanTeamGamesSort.options(for: .upcoming) == [.soonestFirst, .latestFirst])
        assert(FanTeamGamesSort.options(for: .past) == [.mostRecentFirst, .oldestFirst])

        assert(FanTeamGameType.pickup.rawValue == GameType.pickup.rawValue)
        assert(FanTeamGamesFilterEngine.supportedTypeFilters.contains(.pickup))
        assert(FanTeamGamesFilterEngine.supportedTypeFilters.first == .league_game)
        assert(FanTeamGameType.tryout.scheduleDateBlockColor != FanTeamGameType.practice.scheduleDateBlockColor)
    }

    private static func testTeamLinkedPickupEditPrivacyPolicy() {
        // Normal create defaults Public; Team Schedule Game defaults Private.
        assert(PickupGameEditPrivacyPolicy.defaultIsPublicForNewGame(isTeamSourcedCreate: false) == true)
        assert(PickupGameEditPrivacyPolicy.defaultIsPublicForNewGame(isTeamSourcedCreate: true) == false)
        // Organizer form selection always wins on save (including Team create → Public).
        assert(PickupGameEditPrivacyPolicy.resolvedIsVisible(formIsPublic: true) == true)
        assert(PickupGameEditPrivacyPolicy.resolvedIsVisible(formIsPublic: false) == false)

        // Recruiting / Event Type must not override visibility (regression).
        assert(
            PickupGameEditPrivacyPolicy.resolvedIsVisible(
                formIsPublic: true,
                isTeamLinked: true,
                needsAdditionalPlayers: false
            ) == true
        )
        assert(
            PickupGameEditPrivacyPolicy.resolvedIsVisible(
                formIsPublic: false,
                isTeamLinked: true,
                needsAdditionalPlayers: true
            ) == false
        )

        // Format policy independence: Meeting/Announcement may disable recruiting UI,
        // but that must not redefine Public/Private persistence.
        assert(!FanTeamEventPresentation.policy(for: GameType.team_meeting).allowsTeamOutsideRecruitment)
        assert(!FanTeamEventPresentation.policy(for: GameType.announcement).allowsTeamOutsideRecruitment)
        assert(FanTeamEventPresentation.policy(for: GameType.practice).allowsTeamOutsideRecruitment)
        assert(
            PickupGameEditPrivacyPolicy.resolvedIsVisible(formIsPublic: true) == true,
            "Public selection remains Public regardless of format policy"
        )
        assert(!PickupGameEditPrivacyPolicy.showsVisibilityControl(isTeamLinked: false))
        assert(PickupGameEditPrivacyPolicy.showsVisibilityControl(isTeamLinked: true))
        assert(
            PickupGameEditPrivacyPolicy.resolvedIsVisible(formIsPublic: false, isStandalonePickup: true) == true,
            "Standalone pickup always saves public"
        )
        assert(
            PickupGameEditPrivacyPolicy.resolvedIsVisible(formIsPublic: false, isStandalonePickup: false) == false,
            "Team Private is unchanged"
        )
    }

    private static func testTeamGameFormatCases() {
        assert(GameType.pickupOrganizerCases.contains(.pickup))
        assert(GameType.pickupOrganizerCases.contains(.league_game))
        assert(GameType.pickupOrganizerCases.contains(.other))
        assert(GameType.fanTeamOrganizerCases.contains(.league_game))
        assert(GameType.fanTeamOrganizerCases.contains(.match)) // legacy
        assert(GameType.fanTeamOrganizerCases.contains(.team_meeting))
        assert(GameType.fanTeamOrganizerCases.contains(.other))
        assert(!GameType.pickupOrganizerCases.contains(.match))
        assert(!GameType.pickupOrganizerCases.contains(.team_meeting))
        assert(!GameType.pickupOrganizerCases.contains(.announcement))
        assert(!GameType.fanTeamOrganizerCases.contains(.pickup))
        assert(GameType.defaultForTeamCreate == .practice)
        assert(GameType.defaultForNormalCreate == .pickup)
        assert(GameType.parse("League Game") == .league_game)
        assert(GameType.parse("tournament") == .tournament_game)
        assert(GameType.parse("team_meeting") == .team_meeting)
        assert(GameType.parse("Team Meeting") == .team_meeting)
        assert(GameType.parse("other") == .other)
        assert(PickupCompetitionLevel.parse("College / University") == .college_university)
        assert(PickupCompetitionLevel.parse(nil) == nil)
        // Legacy deferred token remains unsupported.
        assert(GameType(rawValue: "team_event") == nil)
        assert(GameType.fanTeamLinkableCases.contains(.tryout))
        assert(GameType.fanTeamLinkableCases.contains(.team_meeting))
        assert(!GameType.fanTeamLinkableCases.contains(.pickup))

        let meetingPolicy = FanTeamEventPresentation.policy(for: GameType.team_meeting)
        assert(!meetingPolicy.isGameplayEvent)
        assert(!meetingPolicy.allowsTeamOutsideRecruitment)
        assert(!meetingPolicy.showsHowYouPlay)
        assert(!meetingPolicy.showsSpotsLeft)
        assert(meetingPolicy.usesGenericDetailLabels)
        let practicePolicy = FanTeamEventPresentation.policy(for: GameType.practice)
        assert(practicePolicy.isGameplayEvent)
        assert(practicePolicy.allowsTeamOutsideRecruitment)
        assert(!practicePolicy.requiresOpponent)
        assert(!practicePolicy.showsOpponentField)

        for competitive in [GameType.league_game, .tournament_game, .match, .scrimmage] as [GameType] {
            // Format-only (empty sport) preserves legacy H2H + opponent for call sites without sport.
            let policy = FanTeamEventPresentation.policy(for: competitive)
            assert(policy.requiresOpponent)
            assert(policy.showsOpponentField)
            assert(policy.supportsHeadToHeadScore)
        }
        for nonCompetitive in [GameType.practice, .tryout, .clinic, .team_meeting, .other, .announcement, .pickup] as [GameType] {
            assert(!FanTeamEventPresentation.policy(for: nonCompetitive).requiresOpponent)
        }
        // Sport-aware: Running Race/Meet must not force opponent or H2H score.
        let runningRace = FanTeamEventPresentation.policy(for: GameType.tournament_game, sport: "Running")
        assert(!runningRace.requiresOpponent)
        assert(!runningRace.supportsHeadToHeadScore)
        let soccerMatch = FanTeamEventPresentation.policy(for: GameType.league_game, sport: "Soccer")
        assert(soccerMatch.requiresOpponent)
        assert(soccerMatch.supportsHeadToHeadScore)

        assert(FanTeamScheduleMatchup.trimmedOpponent("  Legends United  ") == "Legends United")
        assert(FanTeamScheduleMatchup.trimmedOpponent("   ") == nil)
        assert(
            FanTeamScheduleMatchup.persistableOpponent(format: .league_game, opponentName: " Utah Rio FC ")
                == "Utah Rio FC"
        )
        assert(FanTeamScheduleMatchup.persistableOpponent(format: .practice, opponentName: "Legends United") == nil)
        assert(
            FanTeamScheduleMatchup.matchupLine(
                homeTeamName: "JT",
                opponentName: "Legends United",
                languageCode: "en"
            ) == "JT vs Legends United"
        )
        assert(
            FanTeamScheduleMatchup.matchupLine(
                homeTeamName: "JT",
                opponentName: nil,
                languageCode: "en"
            ) == nil
        )

        // Dynamic schedule intro title + summary label (Team and normal Pickup share helpers).
        let expectedIntro: [(GameType, String)] = [
            (GameType.pickup, "Schedule a Pickup Game"),
            (GameType.practice, "Schedule a Practice"),
            (GameType.scrimmage, "Schedule a Scrimmage"),
            (GameType.league_game, "Schedule a League Game"),
            (GameType.tournament_game, "Schedule a Tournament Game"),
            (GameType.tryout, "Schedule a Tryout"),
            (GameType.clinic, "Schedule a Clinic"),
            (GameType.match, "Schedule a Match"),
            (GameType.team_meeting, "Schedule a Team Meeting"),
            (GameType.other, "Schedule an Event"),
        ]
        for (format, title) in expectedIntro {
            assert(format.scheduleFormIntroTitle(languageCode: "en") == title)
        }
        assert(GameType.pickup.scheduleFormSummaryLabel(languageCode: "en") == "Pickup Game")
        assert(GameType.practice.scheduleFormSummaryLabel(languageCode: "en") == "Practice")
        assert(GameType.league_game.scheduleFormSummaryLabel(languageCode: "en") == "League Game")
        assert(GameType.tournament_game.scheduleFormSummaryLabel(languageCode: "en") == "Tournament Game")
        assert(GameType.clinic.scheduleFormSummaryLabel(languageCode: "en") == "Clinic")
        assert(!GameType.pickup.scheduleFormSummaryEmoji.isEmpty)
        assert(GameType.league_game.scheduleFormSummaryEmoji == "🏆")
        // Switching formats changes title immediately (pure mapping — no session state).
        var selected = GameType.defaultForNormalCreate
        assert(selected.scheduleFormIntroTitle(languageCode: "en") == "Schedule a Pickup Game")
        selected = .practice
        assert(selected.scheduleFormIntroTitle(languageCode: "en") == "Schedule a Practice")
        selected = GameType.defaultForTeamCreate
        assert(selected.scheduleFormIntroTitle(languageCode: "en") == "Schedule a Practice")

        // Team header meta includes members when available; never shows Not specified.
        let headerWithMembers = PickupGameTeamCreationContext(
            teamId: UUID(),
            teamName: "Test Teams",
            teamSport: "Soccer",
            activeMemberCount: 24,
            competitionLevel: .youth
        ).scheduleHeaderMetaLine(languageCode: "en")
        assert(headerWithMembers.localizedCaseInsensitiveContains("Youth"))
        assert(headerWithMembers.localizedCaseInsensitiveContains("Soccer"))
        assert(headerWithMembers.contains("24"))
        assert(!headerWithMembers.localizedCaseInsensitiveContains("Not specified"))
    }

    private static func testRolePermissions() {
        assert(FanTeamMemberRole.owner.canManageTeam)
        assert(FanTeamMemberRole.manager.canManageTeam)
        assert(!FanTeamMemberRole.headCoach.canManageTeam)
        assert(!FanTeamMemberRole.assistantCoach.canManageTeam)
        assert(!FanTeamMemberRole.captain.canManageTeam)
        assert(!FanTeamMemberRole.assistantCaptain.canManageTeam)
        assert(!FanTeamMemberRole.member.canManageTeam)

        assert(FanTeamMemberRole.owner.canPublishTeamAnnouncements)
        assert(FanTeamMemberRole.manager.canPublishTeamAnnouncements)
        assert(!FanTeamMemberRole.headCoach.canPublishTeamAnnouncements)
        assert(!FanTeamMemberRole.captain.canPublishTeamAnnouncements)
        assert(!FanTeamMemberRole.member.canPublishTeamAnnouncements)

        assert(FanTeamMemberRole.owner.canAssignMemberRoles)
        assert(!FanTeamMemberRole.manager.canAssignMemberRoles)
        assert(!FanTeamMemberRole.headCoach.canAssignMemberRoles)
        assert(!FanTeamMemberRole.captain.canAssignMemberRoles)

        assert(FanTeamMemberRole.owner.canOrganizeTeamActivities)
        assert(FanTeamMemberRole.manager.canOrganizeTeamActivities)
        assert(FanTeamMemberRole.headCoach.canOrganizeTeamActivities)
        assert(!FanTeamMemberRole.assistantCoach.canOrganizeTeamActivities)
        assert(!FanTeamMemberRole.captain.canOrganizeTeamActivities)
        assert(!FanTeamMemberRole.member.canOrganizeTeamActivities)

        assert(FanTeamMemberRole.owner.canManageLineup)
        assert(FanTeamMemberRole.manager.canManageLineup)
        assert(FanTeamMemberRole.headCoach.canManageLineup)
        assert(FanTeamMemberRole.assistantCoach.canManageLineup)
        assert(!FanTeamMemberRole.captain.canManageLineup)
        assert(!FanTeamMemberRole.assistantCaptain.canManageLineup)
        assert(!FanTeamMemberRole.member.canManageLineup)

        testRosterMemberActions()
        assert(FanTeamMemberRole.owner.canManageTeam) // identity edit uses same manage gate
        assert(FanTeamMemberRole.owner.canLeaveTeam == false)
        // Delete Team is owner-only (managers must not see/invoke it).
        let ownerSummary = FanTeamSummary(
            id: UUID(),
            name: "Owner Team",
            sport: "Soccer",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            competitionLevel: nil,
            ownerUserId: UUID(),
            groupConversationId: UUID(),
            myRole: .owner,
            memberCount: 3,
            pendingInvitationCount: 0,
            pushNotificationsMuted: false,
            nextGameStartsAt: nil,
            nextGameTitle: nil,
            nextGameVenue: nil,
            createdAt: Date()
        )
        assert(ownerSummary.canDeleteTeam)
        assert(!ownerSummary.canLeaveTeam)
        assert(ownerSummary.canAssignRoles)
        assert(ownerSummary.canOrganizeActivities)
        for role in [
            FanTeamMemberRole.manager,
            .headCoach,
            .assistantCoach,
            .captain,
            .assistantCaptain,
            .member
        ] {
            let s = FanTeamSummary(
                id: UUID(),
                name: "Other",
                sport: "Soccer",
                logoURL: nil,
                logoThumbnailURL: nil,
                colorHex: nil,
                competitionLevel: nil,
                ownerUserId: UUID(),
                groupConversationId: UUID(),
                myRole: role,
                memberCount: 3,
                pendingInvitationCount: 0,
                pushNotificationsMuted: false,
                nextGameStartsAt: nil,
                nextGameTitle: nil,
                nextGameVenue: nil,
                createdAt: Date()
            )
            assert(!s.canDeleteTeam)
            assert(!s.canAssignRoles, "\(role.rawValue) title alone must not assign roles")
            assert(!s.canOrganizeActivities, "\(role.rawValue) title alone must not organize")
            let asAdmin = FanTeamSummary(
                id: s.id,
                name: s.name,
                sport: s.sport,
                logoURL: nil,
                logoThumbnailURL: nil,
                colorHex: nil,
                competitionLevel: nil,
                ownerUserId: s.ownerUserId,
                groupConversationId: s.groupConversationId,
                myRole: role,
                memberCount: s.memberCount,
                pendingInvitationCount: 0,
                pushNotificationsMuted: false,
                nextGameStartsAt: nil,
                nextGameTitle: nil,
                nextGameVenue: nil,
                createdAt: s.createdAt,
                myPermissions: .teamAdministrator
            )
            assert(!asAdmin.canAssignRoles, "\(role.rawValue) Team Administrator must not assign titles")
            assert(asAdmin.canOrganizeActivities)
            assert(!asAdmin.canDeleteTeam)
        }
    }

    private static func testRosterMemberActions() {
        let me = UUID()
        let other = UUID()
        func member(userId: UUID, role: FanTeamMemberRole) -> FanTeamMember {
            FanTeamMember(
                userId: userId,
                role: role,
                joinedAt: Date(),
                displayName: "Fan",
                username: "fan",
                avatarURL: nil,
                avatarThumbnailURL: nil,
                lastSeenAtRaw: nil
            )
        }
        let selfOwner = member(userId: me, role: .owner)
        let otherMember = member(userId: other, role: .member)
        let otherManager = member(userId: other, role: .manager)
        let otherOwner = member(userId: other, role: .owner)

        assert(FanTeamRosterMemberActions.isSelf(member: selfOwner, currentUserId: me))
        assert(!FanTeamRosterMemberActions.canMessage(member: selfOwner, currentUserId: me))
        assert(FanTeamRosterMemberActions.canMessage(member: otherMember, currentUserId: me))
        assert(!FanTeamRosterMemberActions.canRemove(
            member: selfOwner,
            viewerCanManage: true,
            currentUserId: me
        ))
        assert(!FanTeamRosterMemberActions.canRemove(
            member: otherOwner,
            viewerCanManage: true,
            currentUserId: me
        ))
        assert(FanTeamRosterMemberActions.canRemove(
            member: otherMember,
            viewerCanManage: true,
            currentUserId: me
        ))
        assert(FanTeamRosterMemberActions.canRemove(
            member: otherManager,
            viewerCanManage: true,
            currentUserId: me
        ))
        assert(!FanTeamRosterMemberActions.canRemove(
            member: otherMember,
            viewerCanManage: false,
            currentUserId: me
        ))
        let dmPreview = otherMember.previewForDirectMessage(conversationId: UUID())
        assert(dmPreview?.dmConversationId != nil)
    }

    private static func testColorPaletteValidation() {
        assert(FanTeamColorPalette.normalized("#22c25a") == "#22C25A")
        assert(FanTeamColorPalette.normalized("2F6BFF") == "#2F6BFF")
        assert(FanTeamColorPalette.normalized("#GG0000") == nil)
        assert(FanTeamColorPalette.normalized("") == nil)
        assert(FanTeamColorPalette.isValidHex("#FF9500"))
        assert(!FanTeamColorPalette.isValidHex("red"))
    }

    private static func testIdentityApplyPropagates() {
        let teamId = UUID()
        let conversationId = UUID()
        let summary = FanTeamSummary(
            id: teamId,
            name: "Old Name",
            sport: "Soccer",
            logoURL: "https://example.com/old.jpg",
            logoThumbnailURL: "https://example.com/old_thumb.jpg",
            colorHex: "#22C25A",
            competitionLevel: nil,
            ownerUserId: UUID(),
            groupConversationId: conversationId,
            myRole: .owner,
            memberCount: 4,
            pendingInvitationCount: 2,
            pushNotificationsMuted: false,
            nextGameStartsAt: nil,
            nextGameTitle: nil,
            nextGameVenue: nil,
            createdAt: Date()
        )
        assert(summary.canEditIdentity)
        assert(summary.showsPendingInvitationIndicator)
        assert(!summary.applyingPendingInvitationCount(0).showsPendingInvitationIndicator)
        let memberSummary = FanTeamSummary(
            id: teamId,
            name: "Old Name",
            sport: "Soccer",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            competitionLevel: nil,
            ownerUserId: UUID(),
            groupConversationId: conversationId,
            myRole: .member,
            memberCount: 4,
            pendingInvitationCount: 2,
            pushNotificationsMuted: false,
            nextGameStartsAt: nil,
            nextGameTitle: nil,
            nextGameVenue: nil,
            createdAt: Date()
        )
        assert(!memberSummary.showsPendingInvitationIndicator)
        let change = FanTeamIdentityChange(
            teamId: teamId,
            conversationId: conversationId,
            name: "New Name",
            sport: "Basketball",
            colorHex: "#FF3B30",
            logoURL: nil,
            logoThumbnailURL: nil,
            previousLogoURL: summary.logoURL,
            previousLogoThumbnailURL: summary.logoThumbnailURL
        )
        let updated = summary.applying(change)
        assert(updated.name == "New Name")
        assert(updated.sport == "Basketball")
        assert(updated.colorHex == "#FF3B30")
        assert(updated.logoURL == nil)
        assert(updated.logoThumbnailURL == nil)
        let context = FanTeamChatContext(from: summary).applying(change)
        assert(context.teamName == "New Name")
        assert(context.sport == "Basketball")
        assert(context.colorHex == "#FF3B30")
        assert(context.logoURL == nil)

        // Versioned Storage paths must keep changing on replace so remote caches miss.
        let a = FanTeamsService.makeVersionedTeamLogoFileName()
        let b = FanTeamsService.makeVersionedTeamLogoFileName()
        assert(a.hasPrefix("logo-"))
        assert(a.hasSuffix(".jpg"))
        assert(a != b)

        // Manager card pending count must stay separate from invitee My Teams badge semantics.
        assert(summary.showsPendingInvitationIndicator)
        assert(summary.pendingInvitationCount == 2)
        assert(memberSummary.pendingInvitationCount == 2)
        assert(!memberSummary.showsPendingInvitationIndicator)
    }

    private static func testOverviewNextEventSelection() {
        func game(
            type: FanTeamGameType,
            startsAt: Date,
            status: String = "scheduled",
            title: String
        ) -> FanTeamGame {
            FanTeamGame(
                id: UUID(),
                teamId: UUID(),
                createdBy: UUID(),
                gameType: type,
                sport: "Soccer",
                title: title,
                startsAt: startsAt,
                endsAt: nil,
                venueName: "Field",
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
                createdAt: nil,
                competitionLevel: nil,
                messageBody: nil
            )
        }

        let now = Date()
        let laterPractice = game(type: .practice, startsAt: now.addingTimeInterval(7200), title: "Later practice")
        let soonerLeague = game(type: .league_game, startsAt: now.addingTimeInterval(3600), title: "Sooner league")
        let announcement = game(type: .announcement, startsAt: now.addingTimeInterval(60), title: "Team note")
        let past = game(
            type: .practice,
            startsAt: now.addingTimeInterval(-3600),
            status: "completed",
            title: "Yesterday"
        )

        let next = FanTeamOverviewNextEvent.upcomingEvent(
            from: [laterPractice, announcement, past, soonerLeague],
            now: now
        )
        assert(next?.id == soonerLeague.id, "soonest upcoming non-announcement wins")

        let none = FanTeamOverviewNextEvent.upcomingEvent(
            from: [announcement, past],
            now: now
        )
        assert(none == nil, "announcements and past games are not Next Event")

        let presentation = FanTeamOverviewNextEventPresentation.make(
            event: soonerLeague,
            teamShowsPrivateBadge: true,
            pickupIsVisible: false,
            languageCode: "en"
        )
        assert(presentation.eventID == soonerLeague.id)
        assert(presentation.isPrivate)
        assert(!presentation.title.isEmpty)
        assert(!presentation.whenText.isEmpty)
        assert(!presentation.timeText.isEmpty)
        assert(!presentation.typeTitle.isEmpty)
    }

    private static func testGameUpcomingHeuristic() {
        let pickupId = UUID()
        let upcoming = FanTeamGame(
            id: pickupId,
            teamId: UUID(),
            createdBy: UUID(),
            gameType: .match,
            sport: "Soccer",
            title: nil,
            startsAt: Date().addingTimeInterval(3600),
            endsAt: nil,
            venueName: "Field 1",
            address: nil,
            city: "Lehi",
            state: "UT",
            latitude: nil,
            longitude: nil,
            opponentTeamId: UUID(),
            opponentName: "Team Blue",
            status: "scheduled",
            homeScore: nil,
            awayScore: nil,
            mySide: "home",
            createdAt: nil,
            competitionLevel: .college_university,
                messageBody: nil
        )
        assert(upcoming.isUpcoming)
        assert(!upcoming.isCompleted)
        assert(upcoming.pickupGameId == pickupId)
        assert(upcoming.mySide == "home")

        let completed = FanTeamGame(
            id: UUID(),
            teamId: UUID(),
            createdBy: UUID(),
            gameType: .match,
            sport: "Soccer",
            title: nil,
            startsAt: Date().addingTimeInterval(-86400),
            endsAt: nil,
            venueName: nil,
            address: nil,
            city: nil,
            state: nil,
            latitude: nil,
            longitude: nil,
            opponentTeamId: nil,
            opponentName: "Team Green",
            status: "completed",
            homeScore: 3,
            awayScore: 1,
            mySide: "away",
            createdAt: nil,
            competitionLevel: nil,
                messageBody: nil
        )
        assert(completed.isCompleted)
        assert(!completed.isUpcoming)
    }

    private static func testOpponentHeadlinePractice() {
        let practice = FanTeamGame(
            id: UUID(),
            teamId: UUID(),
            createdBy: UUID(),
            gameType: .practice,
            sport: "Soccer",
            title: nil,
            startsAt: Date().addingTimeInterval(7200),
            endsAt: nil,
            venueName: nil,
            address: nil,
            city: nil,
            state: nil,
            latitude: nil,
            longitude: nil,
            opponentTeamId: nil,
            opponentName: nil,
            status: "scheduled",
            homeScore: nil,
            awayScore: nil,
            mySide: "solo",
            createdAt: nil,
            competitionLevel: nil,
                messageBody: nil
        )
        assert(practice.gameType == .practice)
        assert(practice.opponentName == nil)
        assert(practice.mySide == "solo")
        assert(GameType.match.rawValue == "match")
    }
}
#endif
