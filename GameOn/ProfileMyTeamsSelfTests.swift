import Foundation

#if DEBUG
nonisolated private final class MyTeamsCoalescerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

enum ProfileMyTeamsSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[ProfileMyTeamsTest] PASS \(name)")
            } else {
                failures += 1
                print("[ProfileMyTeamsTest] FAIL \(name)")
            }
        }

        expect(FanTeamProfileVisibility.productDefault == .everyone, "default visibility is everyone")
        expect(FanTeamProfileVisibility.legacyProductDefault == .onlyMe, "legacy default was only_me")
        expect(FanTeamProfileVisibility.parse("everyone") == .everyone, "parse everyone")
        expect(FanTeamProfileVisibility.parse("friends") == .friends, "parse friends")
        expect(FanTeamProfileVisibility.parse("team_members") == .teamMembers, "parse team_members")
        expect(FanTeamProfileVisibility.parse("only_me") == .onlyMe, "parse only_me")
        expect(FanTeamProfileVisibility.allCases.count == 4, "four persisted visibility values")
        expect(FanTeamProfileVisibility.everyone.editProfileChipSystemImage == "person.2.fill", "everyone chip icon")
        expect(FanTeamProfileVisibility.friends.editProfileChipSystemImage == "person.3.fill", "friends chip icon")
        expect(FanTeamProfileVisibility.teamMembers.editProfileChipSystemImage == "shield.fill", "team members chip icon")
        expect(FanTeamProfileVisibility.onlyMe.editProfileChipSystemImage == "lock.fill", "only me chip icon")
        expect(
            L10n.t("profile_my_teams_visibility_friends", languageCode: "en").contains("FanGeo")
                || L10n.t("profile_my_teams_visibility_friends", languageCode: "en").contains("Fans"),
            "friends chip copy is Fans on FanGeo"
        )
        expect(
            L10n.t("profile_my_teams_visibility_help", languageCode: "en").lowercased().contains("public profile"),
            "help copy mentions public profile"
        )
        expect(FanTeamProfileVisibility.parse("bogus") == .everyone, "unknown → product default everyone")
        expect(FanTeamProfileVisibility.parse(nil) == .everyone, "nil → product default everyone")
        expect(FanTeamProfileVisibility.parse("") == .everyone, "empty → product default everyone")

        let everyoneCaption = ProfileMyTeamsPresentation.ownerVisibilityCaption(
            visibility: .everyone,
            languageCode: "en"
        )
        expect(everyoneCaption.contains("Everyone"), "owner caption includes Everyone")
        expect(!everyoneCaption.localizedCaseInsensitiveContains("only me"), "default caption is not Only Me")

        let membership = ProfileFanTeamMembership(
            teamId: UUID(),
            name: "Avalanche U14 Girls",
            sport: "soccer",
            logoURL: nil,
            logoThumbnailURL: nil,
            colorHex: "#22C25A",
            role: .member,
            viewerCanOpen: false
        )
        let a11y = ProfileMyTeamsPresentation.accessibilityLabel(
            membership: membership,
            languageCode: "en",
            opensTeam: false
        )
        expect(a11y.contains("Avalanche U14 Girls"), "a11y name")
        expect(a11y.contains("Member") || a11y.lowercased().contains("member"), "a11y role")
        expect(!a11y.lowercased().contains("favorite"), "not Favorite Teams wording")

        let openA11y = ProfileMyTeamsPresentation.accessibilityLabel(
            membership: membership,
            languageCode: "en",
            opensTeam: true
        )
        expect(openA11y.contains("Opens Team"), "a11y opens team")

        let narrow = ProfileMyTeamsCarouselLayout.cardWidth(containerWidth: 320)
        let wide = ProfileMyTeamsCarouselLayout.cardWidth(containerWidth: 428)
        expect(narrow >= ProfileMyTeamsCarouselLayout.minCardWidth, "SE-width card >= min")
        expect(narrow <= ProfileMyTeamsCarouselLayout.maxCardWidth, "SE-width card <= max")
        expect(wide >= narrow, "Pro Max cards not narrower than SE")
        expect(
            ProfileMyTeamsCarouselLayout.visibleCardCount > 2
                && ProfileMyTeamsCarouselLayout.visibleCardCount < 3.5,
            "visible card count targets ~2.5–3"
        )

        let caption = ProfileMyTeamsPresentation.ownerVisibilityCaption(
            visibility: .friends,
            languageCode: "en"
        )
        expect(
            caption.contains("Fans") || caption.contains("FanGeo") || caption.contains("Friends"),
            "owner caption includes friends audience"
        )

        expect(
            !PublicProfileSectionVisibility.showsMyFanTeams(
                data: hiddenStub(),
                isSelfPreview: false
            ),
            "empty public memberships hidden"
        )

        let withTeams = stub(with: [membership])
        expect(
            PublicProfileSectionVisibility.showsMyFanTeams(data: withTeams, isSelfPreview: false),
            "non-empty memberships shown"
        )

        // Favorite Teams remain a separate concept — My Teams section does not use favoriteTeams.
        expect(withTeams.favoriteTeams.isEmpty, "stub has no favorite teams")
        expect(!withTeams.fanTeamMemberships.isEmpty, "stub has Fan Team memberships")

        // A/B: primary Favorite Team (Jazz) and FanGeo membership (JT) can coexist.
        let jazzID = "nba.utah_jazz"
        let jazz = FavoriteTeam(
            id: jazzID,
            name: "Utah Jazz",
            sport: .basketball,
            league: "NBA",
            region: "NBA",
            kind: .team,
            shortCode: "UTA",
            searchAliases: [],
            fallbackSymbol: "sportscourt",
            badgeRed: 0.0,
            badgeGreen: 0.2,
            badgeBlue: 0.5
        )
        let both = PublicUserProfileData(
            userId: UUID(),
            displayName: "Fan",
            publicHandleLine: "",
            profileCreatedAt: nil,
            bio: nil,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            totalXP: 0,
            reputation: FanReputationEngine.evaluate(FanReputationSignals(fanXP: .rookie)),
            organizerStats: nil,
            favoriteTeams: [jazz],
            primaryFavoriteTeamID: jazzID,
            nationalTeam: nil,
            profileBackgroundKey: .fangeo,
            isBusinessAccount: false,
            hasResolvedIdentity: false,
            isPubliclyVisible: false,
            isDiscoverableByFans: false,
            memberSinceLabel: nil,
            openToItems: [],
            mutualFansCount: 0,
            mutualFanAvatars: [],
            sharedTeamsCount: 0,
            venueCount: 0,
            venueCards: [],
            homeCrowd: nil,
            homeCityDisplayLine: nil,
            pickupHostedCount: 0,
            pickupJoinedCount: 0,
            lastPickupGameCreatedAt: nil,
            socialHighlightLabels: [],
            personalityTags: [],
            sharedTeamNames: [],
            lastSeenAtRaw: nil,
            fanTeamMemberships: [membership],
            myTeamsProfileVisibility: .everyone,
            genderRaw: nil
        )
        expect(both.primaryFavoriteTeamID == jazzID, "A: Favorite Team primary stays Jazz")
        expect(both.explicitPrimaryFavoriteTeam?.name == "Utah Jazz", "A: Favorite Team resolves Jazz")
        expect(PublicProfileSectionVisibility.showsMyTeam(data: both), "A: public Favorite Team section shown")
        expect(both.fanTeamMemberships.contains(where: { $0.name.contains("Avalanche") }), "B: FanGeo membership present")
        expect(
            PublicProfileSectionVisibility.showsMyFanTeams(data: both, isSelfPreview: false),
            "both: FanGeo My Teams visible"
        )
        // Changing FanGeo memberships must not clear primary favorite id.
        let afterLeave = both.replacingFanTeamMemberships([], visibility: .onlyMe)
        expect(afterLeave.primaryFavoriteTeamID == jazzID, "E: leave FanGeo → Favorite Team unchanged")
        expect(afterLeave.favoriteTeams.map(\.id) == [jazzID], "E: favorite teams unchanged")
        expect(PublicProfileSectionVisibility.showsMyTeam(data: afterLeave), "E: Favorite Team still shown")
        expect(
            !PublicProfileSectionVisibility.showsMyFanTeams(data: afterLeave, isSelfPreview: false),
            "G: zero FanGeo → public My Teams hidden"
        )

        // Labels must not collapse the two concepts.
        let favoriteTeamLabel = L10n.t("my_team", languageCode: "en")
        let myTeamsLabel = L10n.t("profile_my_teams_title", languageCode: "en")
        expect(favoriteTeamLabel == "Favorite Team", "label Favorite Team (primary pro club)")
        expect(myTeamsLabel == "My Teams", "label My Teams plural")
        expect(favoriteTeamLabel != myTeamsLabel, "Favorite Team ≠ My Teams labels")
        expect(
            L10n.t("profile_my_teams_subtitle", languageCode: "en") == "Teams I'm part of",
            "subtitle Teams I'm part of"
        )
        expect(
            L10n.t("profile_favorite_team_subtitle", languageCode: "en")
                .localizedCaseInsensitiveContains("professional"),
            "Favorite Team subtitle clarifies professional club"
        )

        // Section order keeps Favorite Team before FanGeo My Teams.
        expect(
            PublicProfileBelowHeroSectionOrder.myTeam.rawValue
                < PublicProfileBelowHeroSectionOrder.myFanTeams.rawValue,
            "public order: Favorite Team before FanGeo My Teams"
        )
        expect(
            PublicProfileBelowHeroSectionOrder.myFanTeams.rawValue
                < PublicProfileBelowHeroSectionOrder.teamsIFollow.rawValue,
            "public order: FanGeo My Teams before Teams I Follow"
        )

        runRefreshPresentationTests(expect: expect)

        if failures == 0 {
            print("[ProfileMyTeamsTest] ALL PASSED")
        } else {
            print("[ProfileMyTeamsTest] FAILURES=\(failures)")
            assertionFailure("ProfileMyTeamsSelfTests failed: \(failures)")
        }
    }

    private static func runRefreshPresentationTests(expect: (Bool, String) -> Void) {
        let owner = sampleTeam(name: "FanGeo Badminton Team", role: .owner, accessVia: .account)
        let manager = sampleTeam(name: "JT", role: .manager, accessVia: .account)
        let member = sampleTeam(name: "Oak Baseball", role: .member, accessVia: .account)
        let guardian = sampleTeam(
            name: "Via Emma",
            role: .member,
            accessVia: .managedPlayer,
            viaNames: ["Emma"]
        )

        expect(
            MyTeamsRefreshPresentation.shouldKeepCachedTeams(hasCachedTeams: true),
            "cached teams remain after refresh failure"
        )
        expect(
            !MyTeamsRefreshPresentation.shouldPresentBlockingAlert(
                trigger: .automaticProfileHydration,
                hasCachedTeams: true,
                isHostTabSelected: false,
                isCancellation: false,
                isMissingAuth: false
            ),
            "cached + automatic Profile hydration → no blocking modal"
        )
        expect(
            !MyTeamsRefreshPresentation.shouldPresentBlockingAlert(
                trigger: .automaticTeamsHome,
                hasCachedTeams: true,
                isHostTabSelected: false,
                isCancellation: false,
                isMissingAuth: false
            ),
            "cached + hidden Teams tab → no blocking modal"
        )
        expect(
            MyTeamsRefreshPresentation.shouldShowSectionRetry(
                hasCachedTeams: false,
                isCancellation: false,
                isMissingAuth: false,
                didFail: true
            ),
            "no cache + refresh failure → section retry"
        )
        expect(
            !MyTeamsRefreshPresentation.shouldShowSectionRetry(
                hasCachedTeams: true,
                isCancellation: false,
                isMissingAuth: false,
                didFail: true
            ),
            "cached + failure → no section retry replacing cards"
        )
        expect(
            !MyTeamsRefreshPresentation.shouldPresentBlockingAlert(
                trigger: .automaticProfileHydration,
                hasCachedTeams: false,
                isHostTabSelected: true,
                isCancellation: true,
                isMissingAuth: false
            ),
            "cancellation → no user-facing error"
        )
        expect(
            !MyTeamsRefreshPresentation.shouldStartAutomaticFetch(
                hasAuthUser: false,
                isLoggedIn: false,
                isSessionRestoring: false,
                isSafeLogout: false
            ),
            "auth not ready → skip fetch"
        )
        expect(
            !MyTeamsRefreshPresentation.shouldStartAutomaticFetch(
                hasAuthUser: true,
                isLoggedIn: true,
                isSessionRestoring: true,
                isSafeLogout: false
            ),
            "session restoring → defer fetch"
        )
        expect(
            MyTeamsRefreshPresentation.shouldStartAutomaticFetch(
                hasAuthUser: true,
                isLoggedIn: true,
                isSessionRestoring: false,
                isSafeLogout: false
            ),
            "settled fan session → fetch allowed"
        )
        expect(
            !MyTeamsRefreshPresentation.shouldPublishSummaries(
                current: [owner, manager, member],
                incoming: [owner, manager, member]
            ),
            "identical server result → no redundant publish"
        )
        expect(
            MyTeamsRefreshPresentation.shouldPublishSummaries(
                current: [owner],
                incoming: [owner, guardian]
            ),
            "guardian team appearing is a real publish"
        )
        expect(guardian.accessVia == .managedPlayer, "guardian/managed-player access via preserved")
        expect(guardian.viaManagedPlayerNames == ["Emma"], "Via player labels preserved")
        expect(owner.myRole == .owner, "owner role unchanged")
        expect(manager.myRole == .manager, "manager role unchanged")
        expect(member.myRole == .member, "joined member role unchanged")

        let memberships = FanTeamsService.profileMemberships(from: [guardian, owner, member, manager])
        expect(memberships.contains(where: { $0.role == .owner && $0.name == owner.name }), "profile cards keep owner")
        expect(memberships.contains(where: { $0.role == .manager }), "profile cards keep manager")
        expect(memberships.contains(where: { $0.role == .member }), "profile cards keep joined member")

        expect(
            !MyTeamsRefreshPresentation.blocksProfileScrolling(
                refreshPending: true,
                presentingBlockingAlert: false
            ),
            "Profile remains scrollable while refresh is pending"
        )
        expect(
            !MyTeamsRefreshPresentation.shouldRefetchDespiteCache(hasFreshCache: true, force: false),
            "warm revisit respects fresh cache"
        )
        expect(
            MyTeamsRefreshPresentation.shouldRefetchDespiteCache(hasFreshCache: true, force: true),
            "Retry still refetches"
        )

        let authId = UUID()
        ProfilePhase1PersonalizationCache.storeMyTeams([owner, manager, member], for: authId)
        expect(
            ProfilePhase1PersonalizationCache.cachedMyTeamsIfFresh(for: authId)?.count == 3,
            "cached teams + successful store remain visible"
        )
        expect(
            ProfilePhase1PersonalizationCache.cachedMyTeamsRegardlessOfAge(for: authId)?.count == 3,
            "stale-or-fresh cache still holds teams after failure path"
        )
        ProfilePhase1PersonalizationCache.invalidateMyTeams(for: authId)
    }

    static func runCoalescerSuite() async {
        await MyTeamsInFlightCoalescer.resetForTests()
        let box = MyTeamsCoalescerCounter()
        let sample = sampleTeam(name: "Coalesce", role: .owner, accessVia: .account)
        async let first = MyTeamsInFlightCoalescer.run {
            box.increment()
            try await Task.sleep(nanoseconds: 80_000_000)
            return [sample]
        }
        async let second = MyTeamsInFlightCoalescer.run {
            box.increment()
            try await Task.sleep(nanoseconds: 80_000_000)
            return [sample]
        }
        do {
            let (a, b) = try await (first, second)
            precondition(box.count == 1, "duplicate Profile appearance must share one in-flight request")
            precondition(a.teams.count == 1 && b.teams.count == 1, "both waiters receive teams")
            print("[ProfileMyTeamsTest] PASS coalescer single in-flight")
        } catch {
            assertionFailure("coalescer suite failed: \(error)")
        }
        await MyTeamsInFlightCoalescer.resetForTests()
    }

    private static func sampleTeam(
        name: String,
        role: FanTeamMemberRole,
        accessVia: FanTeamListAccessVia,
        viaNames: [String] = []
    ) -> FanTeamSummary {
        FanTeamSummary(
            id: UUID(),
            name: name,
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
            createdAt: nil,
            accessVia: accessVia,
            viaManagedPlayerNames: viaNames
        )
    }

    private static func hiddenStub() -> PublicUserProfileData {
        PublicUserProfileData(
            userId: UUID(),
            displayName: "Fan",
            publicHandleLine: "",
            profileCreatedAt: nil,
            bio: nil,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            totalXP: 0,
            reputation: FanReputationEngine.evaluate(FanReputationSignals(fanXP: .rookie)),
            organizerStats: nil,
            favoriteTeams: [],
            primaryFavoriteTeamID: nil,
            nationalTeam: nil,
            profileBackgroundKey: .fangeo,
            isBusinessAccount: false,
            hasResolvedIdentity: false,
            isPubliclyVisible: false,
            isDiscoverableByFans: false,
            memberSinceLabel: nil,
            openToItems: [],
            mutualFansCount: 0,
            mutualFanAvatars: [],
            sharedTeamsCount: 0,
            venueCount: 0,
            venueCards: [],
            homeCrowd: nil,
            homeCityDisplayLine: nil,
            pickupHostedCount: 0,
            pickupJoinedCount: 0,
            lastPickupGameCreatedAt: nil,
            socialHighlightLabels: [],
            personalityTags: [],
            sharedTeamNames: [],
            lastSeenAtRaw: nil,
            fanTeamMemberships: [],
            myTeamsProfileVisibility: .onlyMe,
            genderRaw: nil
        )
    }

    private static func stub(with memberships: [ProfileFanTeamMembership]) -> PublicUserProfileData {
        hiddenStub().replacingFanTeamMemberships(memberships, visibility: .friends)
    }
}
#endif
