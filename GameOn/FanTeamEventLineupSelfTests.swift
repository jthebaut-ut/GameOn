import Foundation

#if DEBUG
enum FanTeamEventLineupSelfTests {
    static func runAll() {
        testAuthorizationPolicy()
        testOrderingAndDedupe()
        testManagedPlayerLineupIdentity()
        testEligibilityBuckets()
        testSoccerPositionCatalog()
        testOtherSportCatalogs()
        testUnsupportedSportFallback()
        testPlayerNumberProjection()
        testCompactPreviewAndPositionDisplay()
        testPlayerParentOrdering()
        testLocalizationKeysPresent()
        testInvalidLineupRowsDropped()
    }

    private static func testInvalidLineupRowsDropped() {
        let valid = FanTeamLineupMemberDraft(
            userId: UUID(),
            lineupStatus: .starting,
            sortOrder: 0
        )
        let invalid = FanTeamLineupMemberDraft(
            userId: nil,
            managedPlayerId: nil,
            lineupStatus: .bench,
            sortOrder: 1
        )
        assert(!invalid.isStructurallyValid)
        assert(valid.isStructurallyValid)
        let kept = FanTeamLineupOrdering.deduped([valid, invalid])
        assert(kept.count == 1)
        assert(kept[0].participantKey == valid.participantKey)
        assert(kept[0].participantKey != FanTeamLineupMemberDraft.invalidParticipantKey)
    }

    private static func testAuthorizationPolicy() {
        assert(FanTeamLineupAuthorization.canManageLineup(role: .owner))
        assert(!FanTeamLineupAuthorization.canManageLineup(role: .manager))
        assert(!FanTeamLineupAuthorization.canManageLineup(role: .headCoach))
        assert(!FanTeamLineupAuthorization.canManageLineup(role: .assistantCoach))
        assert(!FanTeamLineupAuthorization.canManageLineup(role: .captain))
        assert(!FanTeamLineupAuthorization.canManageLineup(role: .assistantCaptain))
        assert(!FanTeamLineupAuthorization.canManageLineup(role: .member))
        assert(FanTeamLineupAuthorization.canManageLineup(permissions: .teamAdministrator))
        assert(FanTeamMemberRole.assistantCoach.canManageLineup)
        assert(!FanTeamMemberRole.captain.canManageLineup)
        assert(FanTeamLineupAuthorization.canViewPublished(isActiveTeamMember: true))
        assert(!FanTeamLineupAuthorization.canViewPublished(isActiveTeamMember: false))
        assert(FanTeamLineupAuthorization.canViewDraft(permissions: .teamAdministrator))
        assert(!FanTeamLineupAuthorization.canViewDraft(role: .captain))
    }

    private static func testOrderingAndDedupe() {
        let a = UUID()
        let b = UUID()
        let dup = [
            FanTeamLineupMemberDraft(userId: a, lineupStatus: .starting, sortOrder: 2),
            FanTeamLineupMemberDraft(userId: b, lineupStatus: .starting, sortOrder: 1),
            FanTeamLineupMemberDraft(userId: a, lineupStatus: .bench, sortOrder: 0),
        ]
        let unique = FanTeamLineupOrdering.deduped(dup)
        assert(unique.count == 2)
        assert(unique.first?.userId == a)
        let sorted = FanTeamLineupOrdering.sorted([
            FanTeamLineupMemberDraft(userId: a, lineupStatus: .starting, sortOrder: 5),
            FanTeamLineupMemberDraft(userId: b, lineupStatus: .starting, sortOrder: 1),
        ])
        assert(sorted.map(\.participantKey) == [b, a])
        let renumbered = FanTeamLineupOrdering.renumber(sorted)
        assert(renumbered.map(\.sortOrder) == [0, 1])
        assert(FanTeamLineupPlayerStatus.starting.sortGroup < FanTeamLineupPlayerStatus.bench.sortGroup)
    }

    /// Managed seats share every lineup code path with accounts, keyed on
    /// `managedPlayerId` instead of `userId` (20260961).
    private static func testManagedPlayerLineupIdentity() {
        let child = UUID()
        let adult = UUID()
        let managed = FanTeamLineupMemberDraft(
            userId: nil,
            managedPlayerId: child,
            lineupStatus: .starting,
            positionCode: "GK",
            sortOrder: 0
        )
        assert(managed.participantKey == child)
        assert(managed.userId == nil)
        assert(managed.isManagedPlayer)
        assert(managed.id == child)

        // XOR: an account row never carries a managed id.
        let account = FanTeamLineupMemberDraft(
            userId: adult,
            managedPlayerId: child,
            lineupStatus: .bench
        )
        assert(account.managedPlayerId == nil)
        assert(account.participantKey == adult)

        // Only the identity that is set is encoded for save_fan_team_event_lineup.
        guard let data = try? JSONEncoder().encode(managed),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            assertionFailure("managed lineup draft must encode")
            return
        }
        assert(json["managed_player_id"] != nil)
        assert(json["user_id"] == nil, "managed rows must not send a user_id")

        let seat = FanTeamMember(
            membershipId: UUID(),
            userId: nil,
            managedPlayerId: child,
            role: .member,
            joinedAt: Date(),
            displayName: "Ellie R.",
            username: nil,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            lastSeenAtRaw: nil,
            playerNumber: 12,
            preferredPositionCode: "GK",
            genderRaw: nil
        )
        assert(seat.participantKey == child)

        let projected = FanTeamLineupPresentation.project(
            members: [managed, managed],
            teamMembersById: [child: seat],
            attendanceById: [child: .going],
            rosterMembersById: [:],
            currentUserId: adult
        )
        assert(projected.count == 1, "duplicate managed seats must collapse")
        assert(projected[0].displayName == "Ellie R.")
        assert(projected[0].numberLabel == "#12")
        assert(projected[0].attendance == .going)
        assert(projected[0].isManagedPlayer)
        assert(!projected[0].isCurrentUser, "a managed player is never the signed-in user")
    }

    private static func testEligibilityBuckets() {
        assert(
            FanTeamLineupEligibility.bucket(for: .going, showAllTeamMembers: false) == .going
        )
        assert(
            FanTeamLineupEligibility.bucket(for: .maybe, showAllTeamMembers: false) == .maybe
        )
        assert(
            FanTeamLineupEligibility.bucket(for: .cantGo, showAllTeamMembers: false) == nil
        )
        assert(
            FanTeamLineupEligibility.bucket(for: .noResponse, showAllTeamMembers: false) == nil
        )
        assert(
            FanTeamLineupEligibility.bucket(for: .cantGo, showAllTeamMembers: true) == .otherTeamMembers
        )
        assert(
            FanTeamLineupEligibility.bucket(for: nil, showAllTeamMembers: true) == .otherTeamMembers
        )
        assert(FanTeamLineupEligibility.showsNoLongerAttendingWarning(attendance: .cantGo))
        assert(!FanTeamLineupEligibility.showsNoLongerAttendingWarning(attendance: .going))
        assert(FanTeamLineupEligibility.showsSecondaryRSVPChip(attendance: .maybe))
        assert(!FanTeamLineupEligibility.showsSecondaryRSVPChip(attendance: .going))
    }

    private static func testSoccerPositionCatalog() {
        let groups = FanTeamSportPositions.groups(forSportToken: "Soccer")
        assert(!groups.isEmpty)
        let codes = Set(FanTeamSportPositions.positions(forSportToken: "Soccer").map(\.code))
        for required in ["GK", "LB", "CB", "RB", "LWB", "RWB", "CDM", "CM", "CAM", "LM", "RM", "LW", "RW", "CF", "ST", "DEF", "MID", "FWD"] {
            assert(codes.contains(required), "missing soccer position \(required)")
        }
        assert(FanTeamSportPositions.position(code: "cam", sportToken: "Soccer")?.code == "CAM")
        assert(FanTeamSportPositions.position(code: " cb ", sportToken: "Soccer")?.code == "CB")
        assert(FanTeamSportPositions.isValid(code: nil, sportToken: "Soccer"))
        assert(FanTeamSportPositions.isValid(code: "ST", sportToken: "Soccer"))
        assert(FanTeamSportPositions.isValid(code: "gk", sportToken: "Soccer"))
        assert(!FanTeamSportPositions.isValid(code: "ZZZ", sportToken: "Soccer"))
        assert(!FanTeamSportPositions.isValid(code: "QB", sportToken: "Soccer"))
        assert(!FanTeamSportPositions.isValid(code: "HELLO", sportToken: "Soccer"))
        assert(FanTeamSportPositions.soccerFormations.contains("4-3-3"))
    }

    private static func testOtherSportCatalogs() {
        let baseball = Set(FanTeamSportPositions.positions(forSportToken: "Baseball").map(\.code))
        for code in ["P", "C", "1B", "2B", "3B", "SS", "LF", "CF", "RF", "DH"] {
            assert(baseball.contains(code), "missing baseball \(code)")
        }
        assert(FanTeamSportPositions.groups(forSportToken: "Baseball").count >= 3)
        let basketball = Set(FanTeamSportPositions.positions(forSportToken: "NBA").map(\.code))
        for code in ["PG", "SG", "SF", "PF", "C"] {
            assert(basketball.contains(code), "missing basketball \(code)")
        }
        assert(FanTeamSportPositions.groups(forSportToken: "NBA").count == 3)
        let football = Set(FanTeamSportPositions.positions(forSportToken: "NFL").map(\.code))
        for code in ["QB", "RB", "WR", "TE", "OL", "DL", "LB", "CB", "S", "K", "P"] {
            assert(football.contains(code), "missing football \(code)")
        }
        assert(FanTeamSportPositions.groups(forSportToken: "NFL").count == 3)
        let hockey = Set(FanTeamSportPositions.positions(forSportToken: "NHL").map(\.code))
        for code in ["G", "LD", "RD", "C", "LW", "RW"] {
            assert(hockey.contains(code), "missing hockey \(code)")
        }
        assert(FanTeamSportPositions.groups(forSportToken: "NHL").count == 3)
        let volleyball = Set(FanTeamSportPositions.positions(forSportToken: "Volleyball").map(\.code))
        for code in ["S", "OH", "OPP", "MB", "L", "DS"] {
            assert(volleyball.contains(code), "missing volleyball \(code)")
        }
        assert(FanTeamSportPositions.groups(forSportToken: "Volleyball").count == 4)
        assert(FanTeamSportPositions.supportsPositions(forSportToken: "Softball"))
        assert(FanTeamSportPositions.isValid(code: "PG", sportToken: "NBA"))
        assert(!FanTeamSportPositions.isValid(code: "GK", sportToken: "NBA"))
        assert(FanTeamSportPositions.isValid(code: "SS", sportToken: "Baseball"))
        assert(FanTeamSportPositions.isValid(code: "G", sportToken: "NHL"))
        assert(FanTeamSportPositions.isValid(code: "L", sportToken: "Volleyball"))
        assert(FanTeamSportPositions.isValid(code: "QB", sportToken: "NFL"))
        assert(!FanTeamSportPositions.isValid(code: "GK", sportToken: "NFL"))
    }

    private static func testUnsupportedSportFallback() {
        assert(!FanTeamSportPositions.supportsPositions(forSportToken: "Golf"))
        assert(FanTeamSportPositions.groups(forSportToken: "Tennis").isEmpty)
        assert(FanTeamSportPositions.isValid(code: nil, sportToken: "Golf"))
        assert(!FanTeamSportPositions.isValid(code: "GK", sportToken: "Golf"))
        assert(!FanTeamSportPositions.isValid(code: "HELLO", sportToken: "Golf"))
        // Starting/Bench still valid without positions.
        let row = FanTeamLineupMemberDraft(userId: UUID(), lineupStatus: .starting, positionCode: nil)
        assert(row.positionCode == nil)
        assert(row.lineupStatus == .starting)
    }

    private static func testPlayerNumberProjection() {
        let userId = UUID()
        let teamMember = FanTeamMember(
            userId: userId,
            role: .member,
            joinedAt: Date(),
            displayName: "Emma Garcia",
            username: "emma",
            avatarURL: nil,
            avatarThumbnailURL: nil,
            lastSeenAtRaw: nil,
            playerNumber: 10,
            preferredPositionCode: "CB",
            genderRaw: nil
        )
        let draft = FanTeamLineupMemberDraft(
            userId: userId,
            lineupStatus: .starting,
            positionCode: "CAM",
            sortOrder: 0
        )
        let projected = FanTeamLineupPresentation.project(
            members: [draft, draft],
            teamMembersById: [userId: teamMember],
            attendanceById: [userId: .maybe],
            rosterMembersById: [:],
            currentUserId: userId
        )
        assert(projected.count == 1, "duplicate lineup user ids must collapse")
        assert(projected[0].numberLabel == "#10")
        assert(projected[0].displayName == "Emma Garcia")
        assert(projected[0].positionCode == "CAM", "event lineup position stays independent of Team default")
        assert(projected[0].isCurrentUser)
        assert(projected[0].attendance == .maybe)

        let prefill = FanTeamMemberPositionPresentation.lineupPrefillPositionCode(
            preferredPositionCode: teamMember.preferredPositionCode,
            sportToken: "Soccer"
        )
        assert(prefill == "CB")
        let afterTeamDefaultChange = teamMember.replacingPreferredPositionCode("CM")
        assert(afterTeamDefaultChange.preferredPositionCode == "CM")
        assert(draft.positionCode == "CAM", "existing lineup draft is not mutated by Team default change")

        // Starting/Bench mutation must not clear event position.
        var moved = draft
        moved.lineupStatus = .bench
        assert(moved.positionCode == "CAM")
        moved.lineupStatus = .starting
        assert(moved.positionCode == "CAM")

        let withoutNumber = FanTeamLineupPresentation.project(
            members: [draft],
            teamMembersById: [
                userId: teamMember.replacingPlayerNumber(nil)
            ],
            attendanceById: [userId: .cantGo],
            rosterMembersById: [:],
            currentUserId: nil
        )
        assert(withoutNumber[0].numberLabel == nil)
        assert(
            FanTeamLineupPresentation.noLongerAttendingCount(
                members: [draft],
                attendanceById: [userId: .cantGo]
            ) == 1
        )
    }

    private static func testCompactPreviewAndPositionDisplay() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let d = UUID()
        let e = UUID()
        func member(_ id: UUID, name: String, number: Int) -> FanTeamMember {
            FanTeamMember(
                userId: id,
                role: .member,
                joinedAt: Date(),
                displayName: name,
                username: nil,
                avatarURL: nil,
                avatarThumbnailURL: nil,
                lastSeenAtRaw: nil,
                playerNumber: number,
                preferredPositionCode: nil,
                genderRaw: nil
            )
        }
        let lineup = FanTeamEventLineup(
            id: UUID(),
            teamId: UUID(),
            pickupGameId: UUID(),
            status: .published,
            formation: "4-3-3",
            publishedAt: Date(),
            publishedBy: nil,
            updatedAt: Date(),
            viewerCanManage: true,
            members: [
                FanTeamLineupMemberDraft(userId: a, lineupStatus: .starting, positionCode: "GK", sortOrder: 0),
                FanTeamLineupMemberDraft(userId: b, lineupStatus: .starting, positionCode: "LB", sortOrder: 1),
                FanTeamLineupMemberDraft(userId: c, lineupStatus: .starting, positionCode: "ST", sortOrder: 2),
                FanTeamLineupMemberDraft(userId: d, lineupStatus: .bench, positionCode: "CM", sortOrder: 0),
                FanTeamLineupMemberDraft(userId: e, lineupStatus: .bench, positionCode: nil, sortOrder: 1),
            ]
        )
        let teamById: [UUID: FanTeamMember] = [
            a: member(a, name: "Keeper", number: 1),
            b: member(b, name: "Left Back", number: 3),
            c: member(c, name: "Striker", number: 9),
            d: member(d, name: "Mid", number: 8),
            e: member(e, name: "Extra", number: 12),
        ]
        let preview = FanTeamLineupPresentation.compactPreviewPlayers(
            from: lineup,
            teamMembersById: teamById,
            attendanceById: [:],
            rosterMembersById: [:],
            currentUserId: nil,
            limit: 4
        )
        assert(preview.visible.count == 4)
        assert(preview.hiddenCount == 1)
        assert(preview.visible.map(\.participantKey) == [a, b, c, d], "Starting then Bench order")
        assert(preview.visible[0].positionCode == "GK")
        assert(preview.visible[1].numberLabel == "#3")

        assert(FanTeamLineupPresentation.displayPositionCode(positionCode: "lb", sportToken: "Soccer") == "LB")
        assert(FanTeamLineupPresentation.displayPositionCode(positionCode: "SS", sportToken: "Baseball") == "SS")
        assert(FanTeamLineupPresentation.displayPositionCode(positionCode: "PG", sportToken: "NBA") == "PG")
        assert(FanTeamLineupPresentation.displayPositionCode(positionCode: "QB", sportToken: "NFL") == "QB")
        assert(FanTeamLineupPresentation.displayPositionCode(positionCode: "RD", sportToken: "NHL") == "RD")
        assert(FanTeamLineupPresentation.displayPositionCode(positionCode: "OH", sportToken: "Volleyball") == "OH")
        assert(FanTeamLineupPresentation.displayPositionCode(positionCode: "xx", sportToken: "Golf") == "XX")
        assert(FanTeamLineupPresentation.displayPositionCode(positionCode: nil, sportToken: "Soccer") == nil)
        assert(FanTeamLineupPresentation.displayPositionCode(positionCode: "  ", sportToken: "Soccer") == nil)

        let a11y = FanTeamLineupPresentation.accessibilityRowLabel(
            player: FanTeamLineupPlayerPresentation(
                userId: b,
                displayName: "Fan",
                avatarURL: nil,
                avatarThumbnailURL: nil,
                playerNumber: 24,
                attendance: .going,
                lineupStatus: .bench,
                positionCode: "LB",
                sortOrder: 0,
                isCurrentUser: false
            ),
            sportToken: "Soccer",
            languageCode: "en"
        )
        assert(a11y.contains("24"))
        assert(a11y.contains("Fan"))
        assert(a11y.lowercased().contains("back") || a11y.contains("LB"))
        assert(a11y.contains("Bench"))
        assert(FanTeamLineupPublicationStatus.published.shortLocalizedKey == "fan_team_lineup_published_short")
    }

    private static func testPlayerParentOrdering() {
        let gk = UUID()
        let st = UUID()
        let lb = UUID()
        let unassigned = UUID()
        let sub = UUID()
        func member(_ id: UUID, name: String) -> FanTeamMember {
            FanTeamMember(
                userId: id,
                role: .member,
                joinedAt: Date(),
                displayName: name,
                username: nil,
                avatarURL: nil,
                avatarThumbnailURL: nil,
                lastSeenAtRaw: nil,
                playerNumber: nil,
                preferredPositionCode: nil,
                genderRaw: nil
            )
        }
        let lineup = FanTeamEventLineup(
            id: UUID(),
            teamId: UUID(),
            pickupGameId: UUID(),
            status: .published,
            formation: "4-3-3",
            publishedAt: Date(),
            publishedBy: nil,
            updatedAt: Date(),
            viewerCanManage: false,
            members: [
                FanTeamLineupMemberDraft(userId: st, lineupStatus: .starting, positionCode: "ST", sortOrder: 0),
                FanTeamLineupMemberDraft(userId: sub, lineupStatus: .bench, positionCode: "CM", sortOrder: 0),
                FanTeamLineupMemberDraft(userId: unassigned, lineupStatus: .starting, positionCode: nil, sortOrder: 1),
                FanTeamLineupMemberDraft(userId: lb, lineupStatus: .starting, positionCode: "LB", sortOrder: 2),
                FanTeamLineupMemberDraft(userId: gk, lineupStatus: .starting, positionCode: "GK", sortOrder: 3),
            ]
        )
        let teamById: [UUID: FanTeamMember] = [
            gk: member(gk, name: "Keeper"),
            st: member(st, name: "Striker"),
            lb: member(lb, name: "Left Back"),
            unassigned: member(unassigned, name: "Flex"),
            sub: member(sub, name: "Bench Mid"),
        ]
        let ordered = FanTeamLineupPresentation.playerParentOrderedPlayers(
            from: lineup,
            sportToken: "Soccer",
            teamMembersById: teamById,
            attendanceById: [:],
            rosterMembersById: [:],
            currentUserId: gk
        )
        assert(ordered.map(\.userId) == [gk, lb, st, unassigned, sub])
        assert(FanTeamLineupPresentation.isHighlightedForViewer(ordered[0]))
        assert(
            FanTeamLineupPresentation.playerParentPositionBadge(
                player: ordered[0],
                sportToken: "Soccer",
                languageCode: "en"
            ) == "GK"
        )
        assert(
            FanTeamLineupPresentation.playerParentPositionBadge(
                player: ordered[4],
                sportToken: "Soccer",
                languageCode: "en"
            ) == L10n.t("fan_team_lineup_sub_badge", languageCode: "en")
        )
        assert(
            FanTeamLineupPresentation.playerParentPositionTitle(
                player: ordered[4],
                sportToken: "Soccer",
                languageCode: "en"
            ) == L10n.t("fan_team_lineup_substitute", languageCode: "en")
        )
    }

    private static func testLocalizationKeysPresent() {
        let keys = [
            "fan_team_lineup_title",
            "fan_team_lineup_create",
            "fan_team_lineup_edit",
            "fan_team_lineup_view",
            "fan_team_lineup_starting",
            "fan_team_lineup_bench",
            "fan_team_lineup_add_players",
            "fan_team_lineup_publish",
            "fan_team_lineup_save_draft",
            "fan_team_lineup_status_draft",
            "fan_team_lineup_status_published",
            "fan_team_lineup_published_short",
            "fan_team_lineup_published_by_team",
            "fan_team_lineup_your_position",
            "fan_team_lineup_substitute",
            "fan_team_lineup_sub_badge",
            "fan_team_lineup_unassigned_badge",
            "fan_team_lineup_player_count_format",
            "fan_team_lineup_positions_manager_note",
            "fan_team_lineup_counts_format",
            "fan_team_lineup_more_format",
            "fan_team_lineup_section_count_format",
            "fan_team_lineup_section_a11y_format",
            "fan_team_lineup_formation",
            "fan_team_lineup_no_position",
            "fan_team_lineup_select_position",
            "fan_team_lineup_move_to_starting",
            "fan_team_lineup_move_to_bench",
            "fan_team_lineup_remove",
            "fan_team_lineup_no_longer_attending",
            "fan_team_lineup_no_longer_attending_count_format",
            "fan_team_lineup_no_response_count_format",
            "fan_team_position_gk",
            "fan_team_position_cb",
            "fan_team_position_cam",
            "fan_team_position_st",
            "fan_teams_set_player_position",
            "fan_teams_change_player_position",
            "fan_teams_remove_player_position",
            "fan_teams_player_position",
            "fan_teams_set_player_position_failed",
            "fan_teams_player_position_current_a11y_format",
            "fan_team_lineup_set_position",
            "fan_team_lineup_change_position",
            "fan_team_lineup_clear_position",
            "fan_team_lineup_team_default",
            "fan_team_lineup_team_default_format",
            "fan_team_lineup_reset_to_team_default",
            "fan_team_lineup_position_control_change_a11y_format",
            "fan_team_lineup_position_control_set_a11y",
            "fan_team_position_group_pitcher_catcher",
            "fan_team_position_group_guards",
            "fan_team_position_group_offense",
            "fan_team_position_group_special_teams",
        ]
        for key in keys {
            let en = L10n.t(key, languageCode: "en")
            assert(en != key, "missing localization key \(key)")
            assert(!en.contains("%d"), "prefer %lld for \(key)")
        }
        let countFormat = L10n.t("fan_team_lineup_no_longer_attending_count_format", languageCode: "en")
        assert(countFormat.contains("%lld"))
        _ = String(format: countFormat, locale: Locale(identifier: "en"), Int64(1))
        let counts = L10n.t("fan_team_lineup_counts_format", languageCode: "en")
        assert(counts.contains("%lld"))
        _ = String(format: counts, locale: Locale(identifier: "en"), Int64(11), Int64(5))
        let more = L10n.t("fan_team_lineup_more_format", languageCode: "en")
        assert(more.contains("%lld"))
        _ = String(format: more, locale: Locale(identifier: "en"), Int64(8))
        let section = L10n.t("fan_team_lineup_section_count_format", languageCode: "en")
        _ = String(format: section, locale: Locale(identifier: "en"), "Starting", Int64(11))
        let sectionA11y = L10n.t("fan_team_lineup_section_a11y_format", languageCode: "en")
        _ = String(format: sectionA11y, locale: Locale(identifier: "en"), "Bench", Int64(5))
    }
}
#endif
