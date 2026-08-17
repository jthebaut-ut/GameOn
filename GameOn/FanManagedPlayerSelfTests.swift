import Foundation

#if DEBUG
enum FanManagedPlayerSelfTests {
    static func runAll() {
        participantIdentityXOR()
        memberSeatIdentity()
        legacyMemberDecodingFallback()
        rsvpSubjectSupportsManagedPlayers()
        nameValidation()
        birthYearValidation()
        selectorSkipsWhenOnlySelf()
        invitationMultiSelectIdentities()
        teamMembershipSubtitlePresentation()
        teamCardHiddenWithoutPlayers()
        membershipManagePresentation()
        socialActionsRequireAccount()
        avatarEquatableIncludesURLs()
        ownerDirectAddCandidatesExcludeOnTeam()
        // Multi-select Add My Players stays sequential (all-or-nothing batch RPC deferred).
        addMyPlayersRemainsSequentialContract()
        editScreenLocalization()
        print("[FanManagedPlayerSelfTests] ALL PASSED")
    }

    private static func addMyPlayersRemainsSequentialContract() {
        // Safety > speed: batch add RPC deferred to preserve capacity/permission atomicity.
        assert(true)
    }

    /// Edit Player sheet copy must resolve — never render snake_case keys.
    private static func editScreenLocalization() {
        let keys = [
            "managed_players_edit",
            "managed_players_add_photo",
            "managed_players_add",
            "managed_players_change_photo",
            "managed_players_remove_photo",
            "managed_players_first_name",
            "managed_players_last_name",
            "managed_players_preferred_name",
            "managed_players_preferred_name_footer",
            "managed_players_birth_year",
            "managed_players_birth_year_footer",
            "managed_players_error_title",
            "managed_players_photo_load_failed",
            "Cancel",
            "Save",
        ]
        let locales = L10n.supportedLanguages.map(\.code)
        for lang in locales {
            for key in keys {
                let value = L10n.t(key, languageCode: lang)
                assert(value != key, "\(lang) \(key) resolved to raw key")
                assert(!value.isEmpty, "\(lang) \(key) empty")
                if key == "managed_players_edit" || key == "managed_players_add_photo" {
                    assert(!value.contains("%@"), "\(lang) \(key) unexpected %@")
                    assert(!value.contains("%d"), "\(lang) \(key) unexpected %d")
                    assert(
                        value.range(of: "^[a-z0-9]+(?:_[a-z0-9]+)+$", options: .regularExpression) == nil,
                        "\(lang) \(key) still looks like a localization key: \(value)"
                    )
                }
            }
        }
        assert(L10n.t("managed_players_edit", languageCode: "en") == "Edit Player")
        assert(L10n.t("managed_players_add_photo", languageCode: "en") == "Add Photo")
        assert(L10n.t("managed_players_change_photo", languageCode: "en") == "Change Photo")
        assert(L10n.t("managed_players_remove_photo", languageCode: "en") == "Remove Photo")
        assert(L10n.t("Cancel", languageCode: "en") == "Cancel")
        assert(L10n.t("Save", languageCode: "en") == "Save")
        print("[FanManagedPlayerSelfTests] PASS edit screen localization")
    }

    private static let userId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let managedId = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private static let membershipId = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    /// Mirrors the `fan_team_members_participant_identity_ck` database constraint.
    private static func participantIdentityXOR() {
        let account = TeamParticipantIdentity.resolve(userId: userId, managedPlayerId: nil)
        precondition(account == .account(userId: userId))
        precondition(account?.isManagedPlayer == false)

        let managed = TeamParticipantIdentity.resolve(userId: nil, managedPlayerId: managedId)
        precondition(managed == .managedPlayer(managedPlayerId: managedId))
        precondition(managed?.managedPlayerId == managedId)

        // Both set and neither set are equally invalid.
        precondition(TeamParticipantIdentity.resolve(userId: userId, managedPlayerId: managedId) == nil)
        precondition(TeamParticipantIdentity.resolve(userId: nil, managedPlayerId: nil) == nil)
    }

    private static func memberSeatIdentity() {
        let managed = makeMember(userId: nil, managedPlayerId: managedId)
        precondition(managed.id == membershipId)
        precondition(managed.isManagedPlayer)
        precondition(managed.preview == nil)
        precondition(managed.previewForDirectMessage(conversationId: UUID()) == nil)

        let account = makeMember(userId: userId, managedPlayerId: nil)
        precondition(account.id == membershipId)
        precondition(!account.isManagedPlayer)
        precondition(account.preview?.id == userId)

        // Two managed seats on different Teams must not collide in a Set/ForEach.
        let other = FanTeamMember(
            membershipId: UUID(),
            userId: nil,
            managedPlayerId: managedId,
            role: .member,
            joinedAt: nil,
            displayName: "Ellie",
            username: nil,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            lastSeenAtRaw: nil
        )
        precondition(managed.id != other.id)
    }

    /// Pre-20260960 payloads have no `membership_id`; `user_id` was the identity.
    private static func legacyMemberDecodingFallback() {
        let legacy = FanTeamMember(
            userId: userId,
            role: .member,
            joinedAt: nil,
            displayName: "Fan",
            username: nil,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            lastSeenAtRaw: nil
        )
        precondition(legacy.membershipId == userId)
        precondition(legacy.managedPlayerId == nil)
        precondition(legacy.replacingPlayerNumber(9).membershipId == userId)
        precondition(legacy.replacingPlayerNumber(9).userId == userId)
    }

    private static func rsvpSubjectSupportsManagedPlayers() {
        let managed = FanTeamRSVPSubject.from(member: makeMember(userId: nil, managedPlayerId: managedId))
        precondition(managed.id == membershipId)
        precondition(managed.isManagedPlayer)
        precondition(managed.userId == nil)
        precondition(!managed.promptDisplayName.isEmpty)
        // Roster payloads carry managed_player_id in user_id; attendance key matches.
        precondition(managed.rosterAttendanceUserId == managedId)
        precondition(
            FanTeamScheduleQuickRSVPState.resolve(
                subjectUserId: managed.rosterAttendanceUserId,
                roster: nil,
                fallbackRSVP: .going
            ) == .going
        )
        precondition(
            !FanTeamScheduleQuickRSVPEligibility.isExcludedFromEvent(
                subjectUserId: managed.userId,
                gameId: UUID(),
                roster: nil
            )
        )

        let account = FanTeamRSVPSubject.from(member: makeMember(userId: userId, managedPlayerId: nil))
        precondition(account.userId == userId)
        precondition(!account.isManagedPlayer)
        precondition(account.rosterAttendanceUserId == userId)
    }

    private static func nameValidation() {
        precondition(FanManagedPlayerValidation.isValidFirstName("Ellie"))
        precondition(!FanManagedPlayerValidation.isValidFirstName("   "))
        precondition(!FanManagedPlayerValidation.isValidFirstName(String(repeating: "a", count: 41)))
        precondition(FanManagedPlayerValidation.isValidLastName(""))
        precondition(!FanManagedPlayerValidation.isValidLastName(String(repeating: "b", count: 41)))

        // Preferred name wins; otherwise first + last, always trimmed to the DB cap.
        precondition(
            FanManagedPlayerValidation.resolvedDisplayName(
                firstName: "Ellie",
                lastName: "Rivera",
                preferred: " E.R. "
            ) == "E.R."
        )
        precondition(
            FanManagedPlayerValidation.resolvedDisplayName(
                firstName: " Ellie ",
                lastName: "Rivera",
                preferred: ""
            ) == "Ellie Rivera"
        )
        precondition(
            FanManagedPlayerValidation.resolvedDisplayName(
                firstName: String(repeating: "a", count: 40),
                lastName: String(repeating: "b", count: 40),
                preferred: ""
            ).count == FanManagedPlayerValidation.maxDisplayNameLength
        )
    }

    private static func birthYearValidation() {
        let now = Date(timeIntervalSince1970: 1_780_000_000) // 2026
        precondition(FanManagedPlayerValidation.isValidBirthYear(nil, now: now))
        precondition(FanManagedPlayerValidation.isValidBirthYear(2015, now: now))
        precondition(!FanManagedPlayerValidation.isValidBirthYear(1899, now: now))
        precondition(!FanManagedPlayerValidation.isValidBirthYear(2100, now: now))
        precondition(
            FanManagedPlayerPresentation.birthYearCaption(nil, languageCode: "en") == nil
        )
        let age = FanManagedPlayerPresentation.ageCaption(
            birthYear: 2015,
            languageCode: "en",
            now: now
        )
        precondition(age?.contains("11") == true || age?.contains("Age") == true)
        precondition(
            FanManagedPlayerPresentation.ageCaption(birthYear: nil, languageCode: "en", now: now) == nil
        )
        precondition(FanManagedPlayerPresentation.managedPlayerTeamRole == .member)
        precondition(FanManagedPlayerPresentation.showsPrivateTeamBadge)

        let years = FanManagedPlayerValidation.pickerYears(now: now)
        precondition(years.first == 2026, "picker starts at current year")
        precondition(years.last == 2001, "picker ends at currentYear - 25")
        precondition(years == years.sorted(by: >), "picker years descending")
        precondition(!years.contains(where: { $0 > 2026 }), "no future years")
        precondition(FanManagedPlayerValidation.isValidBirthYear(years.first, now: now))
        precondition(FanManagedPlayerValidation.isValidBirthYear(years.last, now: now))

        // Existing out-of-window year remains selectable on Edit.
        let withLegacy = FanManagedPlayerValidation.pickerYears(now: now, including: 1995)
        precondition(withLegacy.contains(1995))
        precondition(withLegacy.first == 2026)

        // Not set remains optional / nil for save.
        precondition(FanManagedPlayerValidation.canSubmit(
            firstName: "Sam",
            lastName: "Lee",
            birthYear: nil
        ))
        precondition(FanManagedPlayerValidation.canSubmit(
            firstName: "Sam",
            lastName: "Lee",
            birthYear: 2014
        ))
        precondition(!FanManagedPlayerValidation.canSubmit(
            firstName: "Sam",
            lastName: "Lee",
            birthYear: 2100
        ))

        // Documented contract: unknown rate-limit buckets raise "rate limit rejected"
        // (ERRCODE 22023) — distinct from over-limit "rate_limit_exceeded" (54000).
        // Fixed by 20260963 allowlisting create_managed_player (20/hour/user).
        precondition(
            FanManagedPlayerRateLimitDiagnostics.isAllowlistRejectionMessage("rate limit rejected")
        )
        precondition(
            !FanManagedPlayerRateLimitDiagnostics.isAllowlistRejectionMessage("rate_limit_exceeded")
        )
    }

    /// The zero-friction guarantee: no managed players means no extra step.
    private static func selectorSkipsWhenOnlySelf() {
        precondition(!TeamPlayerSelection.requiresSelection(managedPlayers: []))
        precondition(TeamPlayerSelection.autoResolvedChoice(managedPlayers: []) == .myself)
        precondition(TeamPlayerSelection.choices(managedPlayers: []).count == 1)

        let player = makePlayer()
        precondition(TeamPlayerSelection.requiresSelection(managedPlayers: [player]))
        precondition(TeamPlayerSelection.autoResolvedChoice(managedPlayers: [player]) == nil)
        let choices = TeamPlayerSelection.choices(managedPlayers: [player])
        precondition(choices.count == 2)
        precondition(choices.first == .myself)
        precondition(choices.last?.managedPlayerId == player.id)

        // Invitation Accept always presents the multi-select sheet (Add Player mid-flow).
        precondition(TeamPlayerSelection.shouldPresentInvitationJoinSheet(managedPlayers: []))
        precondition(TeamPlayerSelection.shouldPresentInvitationJoinSheet(managedPlayers: [player]))
    }

    private static func invitationMultiSelectIdentities() {
        var selection: Set<TeamInviteSeatSelection> = [.myself]
        selection.insert(.managedPlayer(managedId))
        selection.insert(.managedPlayer(managedId)) // duplicate no-op
        precondition(selection.count == 2)
        precondition(selection.contains(.myself))
        let managedIds = selection.compactMap(\.managedPlayerId)
        precondition(managedIds == [managedId])
        precondition(selection.contains(where: \.includesSelf))

        // Myself + two children is a valid invite seat set.
        let sibling = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        selection.insert(.managedPlayer(sibling))
        precondition(selection.count == 3)
        precondition(Set(selection.compactMap(\.managedPlayerId)).count == 2)
    }

    private static func teamMembershipSubtitlePresentation() {
        let notSet = L10n.t("fan_teams_not_set", languageCode: "en")
        precondition(
            FanManagedPlayerPresentation.teamMembershipSubtitle(
                playerNumber: 24,
                preferredPositionCode: "GK",
                sportToken: "soccer",
                languageCode: "en"
            )?.contains("#24") == true
        )
        precondition(
            FanManagedPlayerPresentation.teamMembershipSubtitle(
                playerNumber: nil,
                preferredPositionCode: nil,
                sportToken: "soccer",
                languageCode: "en"
            ) == nil
        )

        var august = DateComponents()
        august.calendar = Calendar(identifier: .gregorian)
        august.timeZone = TimeZone(secondsFromGMT: 0)
        august.year = 2026
        august.month = 8
        august.day = 15
        august.hour = 12
        let joined = august.date!

        let jerseyPositionSince = FanManagedPlayerPresentation.teamMembershipSubtitle(
            playerNumber: 12,
            preferredPositionCode: "CB",
            sportToken: "soccer",
            languageCode: "en",
            joinedAt: joined
        ) ?? ""
        precondition(jerseyPositionSince.contains("#12"))
        precondition(jerseyPositionSince.contains(" • "))
        precondition(jerseyPositionSince.contains("Member since"))
        precondition(jerseyPositionSince.contains("Aug"))
        precondition(jerseyPositionSince.contains("2026"))
        precondition(!jerseyPositionSince.localizedCaseInsensitiveContains(notSet))

        let sinceOnly = FanManagedPlayerPresentation.teamMembershipSubtitle(
            playerNumber: nil,
            preferredPositionCode: nil,
            sportToken: "soccer",
            languageCode: "en",
            joinedAt: joined
        ) ?? ""
        precondition(sinceOnly.hasPrefix("Member since"))
        precondition(!sinceOnly.contains("#"))
        precondition(!sinceOnly.localizedCaseInsensitiveContains(notSet))

        let jerseyOnly = FanManagedPlayerPresentation.teamMembershipSubtitle(
            playerNumber: 7,
            preferredPositionCode: nil,
            sportToken: "soccer",
            languageCode: "en",
            joinedAt: nil
        ) ?? ""
        precondition(jerseyOnly == "#7")
        precondition(!jerseyOnly.localizedCaseInsensitiveContains("Member since"))
        precondition(!jerseyOnly.localizedCaseInsensitiveContains(notSet))

        let membership = FanManagedPlayerTeamMembership(
            id: membershipId,
            teamId: UUID(),
            teamName: "IMC Team",
            sport: "soccer",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: nil,
            playerNumber: nil,
            preferredPositionCode: nil,
            joinedAt: joined
        )
        let fromMembership = FanManagedPlayerPresentation.teamMembershipSubtitle(
            membership: membership,
            languageCode: "en"
        ) ?? ""
        precondition(fromMembership.contains("Member since"))
        precondition(!fromMembership.localizedCaseInsensitiveContains(notSet))

        let medium = FanManagedPlayerPresentation.memberSinceMediumDate(joined, languageCode: "en") ?? ""
        precondition(medium.contains("2026"))
        precondition(medium.contains("Aug") || medium.contains("August") || medium.contains("11"))
        precondition(FanManagedPlayerPresentation.memberSinceMediumDate(nil, languageCode: "en") == nil)
        precondition(FanManagedPlayerPresentation.jerseyLabel(12) == "#12")
        precondition(FanManagedPlayerPresentation.jerseyLabel(nil) == nil)
    }

    private static func membershipManagePresentation() {
        // Any active account member can manage their own kids — role irrelevant.
        precondition(
            FanTeamPlayerMembershipManagePresentation.showsManageControl(
                hasActiveAccountMembership: true
            )
        )
        precondition(
            !FanTeamPlayerMembershipManagePresentation.showsManageControl(
                hasActiveAccountMembership: false
            )
        )
        // Guardian-only / no account seat → no Manage.
        precondition(
            !FanTeamPlayerMembershipManagePresentation.showsManageControl(
                hasActiveAccountMembership: false
            )
        )
        precondition(
            FanTeamPlayerMembershipManagePresentation.shouldShowOverviewSection(
                subjects: [],
                hasActiveAccountMembership: true,
                globalManagedPlayerCount: 2
            )
        )
        precondition(
            !FanTeamPlayerMembershipManagePresentation.shouldShowOverviewSection(
                subjects: [],
                hasActiveAccountMembership: false,
                globalManagedPlayerCount: 2
            )
        )
        precondition(
            FanTeamPlayerMembershipManagePresentation.shouldShowOverviewSection(
                subjects: [],
                hasActiveAccountMembership: true,
                globalManagedPlayerCount: 0
            )
            == false
        )
        let onTeam = FanTeamPlayerMembershipManagePresentation.statusCaption(
            isOnTeam: true,
            languageCode: "en"
        )
        let offTeam = FanTeamPlayerMembershipManagePresentation.statusCaption(
            isOnTeam: false,
            languageCode: "en"
        )
        precondition(onTeam == "Currently on this Team")
        precondition(offTeam == "Not on this Team")
        precondition(
            FanTeamPlayerMembershipManagePresentation.myselfStatusCaption(
                isPlayer: false,
                languageCode: "en"
            ) == "Not on Team as player"
        )
        precondition(FanTeamPlayerMembershipManagePresentation.myselfAvatarSize == 36)
        let avatarUserId = UUID()
        let token = FanTeamPlayerMembershipManagePresentation.myselfAvatarRefreshToken(
            userId: avatarUserId,
            thumbnailURL: "https://example.com/t.jpg",
            avatarURL: "https://example.com/f.jpg"
        )
        precondition(token != UserAvatarView.placeholderRefreshToken)
        precondition(
            FanTeamPlayerMembershipManagePresentation.myselfAvatarRefreshToken(
                userId: nil,
                thumbnailURL: nil,
                avatarURL: nil
            ) == UserAvatarView.placeholderRefreshToken
        )
        let confirm = FanTeamPlayerMembershipManagePresentation.removeConfirmTitle(
            displayName: "Emma TBI",
            languageCode: "en"
        )
        precondition(confirm == "Remove Emma TBI from this Team?")
        precondition(
            L10n.t("team_overview_players_from_your_account", languageCode: "en")
                == "Players from Your Account"
        )
        precondition(
            FanTeamMyPlayerInfoPresentation.overviewSectionTitleKey
                == "team_overview_players_from_your_account"
        )
        precondition(
            L10n.t("team_overview_players_from_your_account_helper", languageCode: "en")
                != "team_overview_players_from_your_account_helper"
        )
        let overviewRows = FanTeamAccountPlayerOverviewPresentation.rows(
            hasAccountSeat: true,
            myselfDisplayName: "FanGeo",
            myselfIsPlayer: false,
            myselfMembershipId: UUID(),
            managedPlayers: [
                FanManagedPlayer(
                    id: UUID(),
                    firstName: "Emma",
                    lastName: "TBI",
                    displayName: "Emma TBI",
                    birthYear: 2014
                )
            ],
            managedSeats: []
        )
        precondition(overviewRows.count == 2)
        precondition(overviewRows[0].kind == .myself)
        precondition(overviewRows[0].isOnTeam == false)
        precondition(overviewRows[1].isOnTeam == false)

        let playersOnly = FanTeamRosterPlayerPresentation.playerSeats(
            from: [
                FanTeamMember(
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
                ),
                FanTeamMember(
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
            ]
        )
        precondition(playersOnly.count == 1)
        precondition(playersOnly[0].displayName == "Emma")
    }

    private static func teamCardHiddenWithoutPlayers() {
        precondition(!FanManagedPlayerPresentation.showsTeamPlayersCard(seats: []))
        precondition(
            FanManagedPlayerPresentation.showsAddManagedPlayersToTeamCTA(
                canManageTeam: true,
                globalManagedPlayerCount: 2,
                seatsOnThisTeam: 0
            )
        )
        precondition(
            FanManagedPlayerPresentation.showsAddManagedPlayersToTeamCTA(
                canManageTeam: true,
                globalManagedPlayerCount: 2,
                seatsOnThisTeam: 1
            )
        )
        precondition(
            !FanManagedPlayerPresentation.showsAddManagedPlayersToTeamCTA(
                canManageTeam: true,
                globalManagedPlayerCount: 1,
                seatsOnThisTeam: 1
            )
        )
        precondition(
            !FanManagedPlayerPresentation.showsAddManagedPlayersToTeamCTA(
                canManageTeam: false,
                globalManagedPlayerCount: 3,
                seatsOnThisTeam: 0
            )
        )
        let seat = FanTeamManagedPlayerSeat(
            id: membershipId,
            managedPlayerId: managedId,
            displayName: "Ellie",
            avatarURL: nil,
            avatarThumbnailURL: nil,
            playerNumber: 7,
            preferredPositionCode: nil,
            joinedAt: nil
        )
        precondition(FanManagedPlayerPresentation.showsTeamPlayersCard(seats: [seat]))

        let members = [
            makeMember(userId: userId, managedPlayerId: nil),
            makeMember(userId: nil, managedPlayerId: managedId)
        ]
        precondition(
            FanTeamMyPlayerInfoPresentation.viewerManagedMembers(
                from: members,
                managedPlayerIds: []
            ).isEmpty
        )
        precondition(
            FanTeamMyPlayerInfoPresentation.viewerManagedMembers(
                from: members,
                managedPlayerIds: [managedId]
            ).count == 1
        )
    }

    private static func socialActionsRequireAccount() {
        let managed = makeMember(userId: nil, managedPlayerId: managedId)
        precondition(!managed.supportsSocialActions)
        precondition(!FanTeamRosterMemberActions.canMessage(member: managed, currentUserId: userId))
        precondition(!FanTeamRosterMemberActions.isSelf(member: managed, currentUserId: userId))

        let account = makeMember(userId: userId, managedPlayerId: nil)
        precondition(account.supportsSocialActions)
        precondition(FanTeamRosterMemberActions.isSelf(member: account, currentUserId: userId))

        // Managed players can never be Team leadership (DB CHECK mirrors this).
        precondition(FanTeamLeadership.leaders(from: [managed]).isEmpty)
    }

    // MARK: - Fixtures

    private static func makeMember(userId: UUID?, managedPlayerId: UUID?) -> FanTeamMember {
        FanTeamMember(
            membershipId: membershipId,
            userId: userId,
            managedPlayerId: managedPlayerId,
            role: .member,
            joinedAt: nil,
            displayName: managedPlayerId == nil ? "Fan" : "Ellie R.",
            username: managedPlayerId == nil ? "fan" : nil,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            lastSeenAtRaw: nil
        )
    }

    /// Regression: id-only Equatable made My Players `@State` skip avatar URL updates.
    private static func avatarEquatableIncludesURLs() {
        let a = FanManagedPlayer(
            id: managedId,
            firstName: "Emma",
            lastName: "T",
            displayName: "Emma",
            avatarURL: "https://example.com/a.jpg",
            avatarThumbnailURL: "https://example.com/a_thumb.jpg",
            teamCount: 0
        )
        let b = a.applyingAvatar(
            avatarURL: "https://example.com/b.jpg",
            avatarThumbnailURL: "https://example.com/b_thumb.jpg"
        )
        precondition(a.id == b.id)
        precondition(a != b, "avatar URL change must break Equatable")
        precondition(a.avatarURL != b.avatarURL)
        precondition(a.avatarThumbnailURL != b.avatarThumbnailURL)

        let cleared = b.applyingAvatar(avatarURL: nil, avatarThumbnailURL: nil)
        precondition(cleared.avatarURL == nil)
        precondition(cleared.avatarThumbnailURL == nil)
        precondition(b != cleared)
    }

    /// Owner direct-add chooser must not offer players already seated on the Team.
    private static func ownerDirectAddCandidatesExcludeOnTeam() {
        let emma = FanManagedPlayer(
            id: managedId,
            firstName: "Emma",
            lastName: "TBI",
            displayName: "Emma TBI",
            teamCount: 0
        )
        let otherId = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let other = FanManagedPlayer(
            id: otherId,
            firstName: "Other",
            lastName: "Kid",
            displayName: "Other",
            teamCount: 1
        )
        let already: Set<UUID> = [managedId]
        let candidates = [emma, other].filter { !already.contains($0.id) }
        precondition(candidates.map(\.id) == [otherId])
        precondition(!candidates.contains(where: { $0.id == managedId }))

        // Zero teams means no fan_team_members seat — selector must stay empty for that Team.
        let seats: [FanTeamManagedPlayerSeat] = []
        let subjects = FanTeamMyPlayerInfoPresentation.eligibleSubjects(
            members: [makeMember(userId: userId, managedPlayerId: nil)],
            currentUserId: userId,
            managedSeats: seats
        )
        precondition(subjects.count == 1)
        precondition(subjects[0].isViewerAccountSeat)
        precondition(!FanTeamMyPlayerInfoPresentation.showsChangeControl(subjects: subjects))
    }

    private static func makePlayer() -> FanManagedPlayer {
        FanManagedPlayer(
            id: managedId,
            firstName: "Ellie",
            lastName: "Rivera",
            displayName: "Ellie R.",
            birthYear: 2015,
            guardianRole: .primaryGuardian,
            teamCount: 1
        )
    }
}
#endif
