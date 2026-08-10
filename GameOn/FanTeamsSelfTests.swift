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
        testRosterJoinedCaption()
        testCreateTeamLogoStagingPolicy()
        testTeamLeadershipDerivation()
        testPlayerNumberAndGenderRosterRules()
        testPickupDetailPresentationHelpers()
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
            genderRaw: "female"
        )
        assert(withNumber.playerNumber == 18)
        assert(withNumber.rosterGender == .female)
        assert(withNumber.replacingPlayerNumber(nil).playerNumber == nil)
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
        let captain = member(role: .captain, name: "Captain")
        let ordinary = member(role: .member, name: "Member")

        let leaders = FanTeamLeadership.leaders(
            from: [ordinary, managerB, captain, owner, managerA]
        )
        assert(leaders.count == 3)
        assert(leaders[0].role == .owner)
        assert(leaders[0].displayName == "Owner")
        assert(leaders[1].role == .manager && leaders[1].displayName == "Manager B")
        assert(leaders[2].role == .manager && leaders[2].displayName == "Manager A")
        assert(!leaders.contains(where: { $0.role == .member || $0.role == .captain }))

        let ownerOnly = FanTeamLeadership.leaders(from: [ordinary, owner, captain])
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
        assert(!FanTeamLeadership.isLeadershipRole(.captain))
        assert(!FanTeamLeadership.isLeadershipRole(.member))

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

        assert(PickupBulkImportTeamRules.defaultGameFormat(isTeamSourced: true) == .league_game)
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
            ) == false
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
                competitionLevel: competitionLevel
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

        // J/K: active secondary indicator + clear preserves status
        var cleared = upcomingOnly
        cleared.gameType = .match
        cleared.datePreset = .thisWeek
        cleared.competitionLevel = .youth
        assert(cleared.hasActiveSecondaryFilters)
        assert(cleared.activeSecondaryFilterCount == 3)
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
    }

    private static func testTeamLinkedPickupEditPrivacyPolicy() {
        // Normal create defaults Public; Team Schedule Game defaults Private.
        assert(PickupGameEditPrivacyPolicy.defaultIsPublicForNewGame(isTeamSourcedCreate: false) == true)
        assert(PickupGameEditPrivacyPolicy.defaultIsPublicForNewGame(isTeamSourcedCreate: true) == false)
        // Organizer form selection always wins on save (including Team create → Public).
        assert(PickupGameEditPrivacyPolicy.resolvedIsVisible(formIsPublic: true) == true)
        assert(PickupGameEditPrivacyPolicy.resolvedIsVisible(formIsPublic: false) == false)
    }

    private static func testTeamGameFormatCases() {
        assert(GameType.pickupOrganizerCases.contains(.pickup))
        assert(GameType.pickupOrganizerCases.contains(.league_game))
        assert(GameType.fanTeamOrganizerCases.contains(.league_game))
        assert(GameType.fanTeamOrganizerCases.contains(.match)) // legacy
        assert(!GameType.pickupOrganizerCases.contains(.match))
        assert(!GameType.fanTeamOrganizerCases.contains(.pickup))
        assert(GameType.defaultForTeamCreate == .league_game)
        assert(GameType.defaultForNormalCreate == .pickup)
        assert(GameType.parse("League Game") == .league_game)
        assert(GameType.parse("tournament") == .tournament_game)
        assert(PickupCompetitionLevel.parse("College / University") == .college_university)
        assert(PickupCompetitionLevel.parse(nil) == nil)
        // Team Event deferred — not a GameType case in v1.
        assert(GameType(rawValue: "team_event") == nil)
        assert(GameType.fanTeamLinkableCases.contains(.tryout))
        assert(!GameType.fanTeamLinkableCases.contains(.pickup))

        // Dynamic schedule intro title + summary label (Team and normal Pickup share helpers).
        let expectedIntro: [(GameType, String)] = [
            (.pickup, "Schedule a Pickup Game"),
            (.practice, "Schedule a Practice"),
            (.scrimmage, "Schedule a Scrimmage"),
            (.league_game, "Schedule a League Game"),
            (.tournament_game, "Schedule a Tournament Game"),
            (.tryout, "Schedule a Tryout"),
            (.clinic, "Schedule a Clinic"),
            (.match, "Schedule a Match"),
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
        assert(selected.scheduleFormIntroTitle(languageCode: "en") == "Schedule a League Game")

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
        assert(!FanTeamMemberRole.captain.canManageTeam)
        assert(!FanTeamMemberRole.member.canManageTeam)
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
        for role in [FanTeamMemberRole.manager, .captain, .member] {
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
        assert(dmPreview.dmConversationId != nil)
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
            competitionLevel: .college_university
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
            competitionLevel: nil
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
            competitionLevel: nil
        )
        assert(practice.gameType == .practice)
        assert(practice.opponentName == nil)
        assert(practice.mySide == "solo")
        assert(GameType.match.rawValue == "match")
    }
}
#endif
