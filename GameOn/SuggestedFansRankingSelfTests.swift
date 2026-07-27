import Foundation

#if DEBUG
/// Deterministic Suggested Fans ranking self-tests (mirrors 20260895 SQL formulas).
enum SuggestedFansRankingSelfTests {
    static func runAll() {
        var failures: [String] = []
        func expect(_ name: String, _ condition: @autoclosure () -> Bool) {
            if !condition() {
                failures.append(name)
                print("[SuggestedFansRankingTest] FAIL \(name)")
            }
        }

        // 1–2 mutual
        expect("mutual_1_is_800", SuggestedFansRanking.mutualFriendsScore(count: 1) == 800)
        expect("mutual_2_is_900", SuggestedFansRanking.mutualFriendsScore(count: 2) == 900)
        expect("mutual_3_is_1000", SuggestedFansRanking.mutualFriendsScore(count: 3) == 1_000)
        expect("mutual_4_caps_1100", SuggestedFansRanking.mutualFriendsScore(count: 4) == 1_100)
        expect("mutual_9_caps_1100", SuggestedFansRanking.mutualFriendsScore(count: 9) == 1_100)

        // 3–10 proximity
        expect("prox_1mi_700", SuggestedFansRanking.proximityScore(distanceMiles: 1) == 700)
        expect("prox_4mi_550", SuggestedFansRanking.proximityScore(distanceMiles: 4) == 550)
        expect("prox_8mi_400", SuggestedFansRanking.proximityScore(distanceMiles: 8) == 400)
        expect("prox_15mi_250", SuggestedFansRanking.proximityScore(distanceMiles: 15) == 250)
        expect("prox_25mi_150", SuggestedFansRanking.proximityScore(distanceMiles: 25) == 150)
        expect("prox_40mi_75", SuggestedFansRanking.proximityScore(distanceMiles: 40) == 75)
        expect("prox_46mi_0", SuggestedFansRanking.proximityScore(distanceMiles: 46) == 0)
        expect("prox_missing_0", SuggestedFansRanking.proximityScore(distanceMiles: nil) == 0)

        // 11–14 MY TEAM / ordinary teams
        let same = SuggestedFansRanking.myTeamScores(
            viewerPrimaryTeamId: "realmadrid",
            candidatePrimaryTeamId: "realmadrid",
            viewerFavoriteTeamIds: ["realmadrid", "barca"],
            candidateFavoriteTeamIds: ["realmadrid", "arsenal"]
        )
        expect("same_my_team_600", same.same == 600 && same.affinity == 0)
        expect("same_my_team_consumes", same.consumedTeamIds == ["realmadrid"])

        let affinity = SuggestedFansRanking.myTeamScores(
            viewerPrimaryTeamId: "realmadrid",
            candidatePrimaryTeamId: "arsenal",
            viewerFavoriteTeamIds: ["realmadrid"],
            candidateFavoriteTeamIds: ["realmadrid", "arsenal"]
        )
        expect("affinity_450", affinity.same == 0 && affinity.affinity == 450)
        expect(
            "ordinary_excludes_consumed",
            SuggestedFansRanking.ordinarySharedTeamsScore(
                sharedTeamIds: ["realmadrid", "chelsea"],
                consumedByMyTeam: affinity.consumedTeamIds
            ) == 300
        )
        expect(
            "ordinary_cap_525",
            SuggestedFansRanking.ordinarySharedTeamsScore(
                sharedTeamIds: ["a", "b", "c", "d", "e"],
                consumedByMyTeam: []
            ) == 525
        )
        expect(
            "no_double_count_same_my_team",
            SuggestedFansRanking.ordinarySharedTeamsScore(
                sharedTeamIds: ["realmadrid"],
                consumedByMyTeam: same.consumedTeamIds
            ) == 0
        )

        // 15–17 caps
        expect("pickup_1_750", SuggestedFansRanking.pickupGameScore(sharedCount: 1) == 750)
        expect("pickup_cap_1050", SuggestedFansRanking.pickupGameScore(sharedCount: 20) == 1_050)
        expect("watch_1_500", SuggestedFansRanking.watchPartyScore(sharedEventCount: 1) == 500)
        expect("watch_cap_700", SuggestedFansRanking.watchPartyScore(sharedEventCount: 20) == 700)
        expect("venue_1_250", SuggestedFansRanking.favoriteVenueScore(sharedVenueCount: 1) == 250)
        expect("venue_cap_400", SuggestedFansRanking.favoriteVenueScore(sharedVenueCount: 20) == 400)

        // 18–19 activity / XP / fallback raw helper
        expect("activity_7d_125", SuggestedFansRanking.recentActivityScore(updatedWithinDays: 3) == 125)
        expect("activity_30d_75", SuggestedFansRanking.recentActivityScore(updatedWithinDays: 20) == 75)
        expect("activity_old_0", SuggestedFansRanking.recentActivityScore(updatedWithinDays: 40) == 0)
        expect("xp_capped_100", SuggestedFansRanking.reputationScore(level: 50, totalXP: 1_000_000) == 100)
        expect("fallback_only_25", SuggestedFansRanking.fallbackScore(isEligibleFallback: true) == 25)
        expect(
            "fallback_zero_when_meaningful",
            SuggestedFansRanking.fallbackScore(isEligibleFallback: true, hasMeaningfulSignal: true) == 0
        )

        // ------------------------------------------------------------------
        // Fallback stacking rules (authoritative assemble / total)
        // ------------------------------------------------------------------

        // 1. fallback-only candidate = 25
        let fallbackOnly = SuggestedFansRanking.assemble(isEligibleFallback: true)
        expect("fallback_only_total_25", fallbackOnly.total == 25)
        expect("fallback_only_reason", fallbackOnly.strongestReason == .fallback)
        expect("fallback_only_authoritative_25", fallbackOnly.authoritativeFallback == 25)

        // 2. proximity candidate does NOT receive fallback
        let proxOnly = SuggestedFansRanking.assemble(
            proximity: SuggestedFansRanking.proximityScore(distanceMiles: 1),
            isEligibleFallback: true
        )
        expect("prox_no_fallback_total_700", proxOnly.total == 700)
        expect("prox_no_fallback_reason", proxOnly.strongestReason == .proximity)
        expect("prox_authoritative_fallback_0", proxOnly.authoritativeFallback == 0)

        // 3. mutual candidate does NOT receive fallback
        let mutualOnly = SuggestedFansRanking.assemble(
            mutualFriends: SuggestedFansRanking.mutualFriendsScore(count: 2),
            isEligibleFallback: true
        )
        expect("mutual_no_fallback_total_900", mutualOnly.total == 900)
        expect("mutual_no_fallback_reason", mutualOnly.strongestReason == .mutualFriends)

        // 4. MY TEAM candidate does NOT receive fallback
        let myTeamOnly = SuggestedFansRanking.assemble(myTeam: 600, isEligibleFallback: true)
        expect("my_team_no_fallback_total_600", myTeamOnly.total == 600)
        expect("my_team_no_fallback_reason", myTeamOnly.strongestReason == .myTeam)

        // 5. shared-team candidate does NOT receive fallback
        let sharedTeamOnly = SuggestedFansRanking.assemble(
            favoriteTeam: SuggestedFansRanking.ordinarySharedTeamsScore(
                sharedTeamIds: ["a", "b", "c"],
                consumedByMyTeam: []
            ),
            isEligibleFallback: true
        )
        expect("shared_team_no_fallback_total_450", sharedTeamOnly.total == 450)
        expect("shared_team_no_fallback_reason", sharedTeamOnly.strongestReason == .favoriteTeam)

        // 6. pickup candidate does NOT receive fallback
        let pickupOnly = SuggestedFansRanking.assemble(
            pickupGame: SuggestedFansRanking.pickupGameScore(sharedCount: 1),
            isEligibleFallback: true
        )
        expect("pickup_no_fallback_total_750", pickupOnly.total == 750)
        expect("pickup_no_fallback_reason", pickupOnly.strongestReason == .pickupGame)

        // 7. watch-party candidate does NOT receive fallback
        let watchOnly = SuggestedFansRanking.assemble(
            venueEvent: SuggestedFansRanking.watchPartyScore(sharedEventCount: 1),
            isEligibleFallback: true
        )
        expect("watch_no_fallback_total_500", watchOnly.total == 500)
        expect("watch_no_fallback_reason", watchOnly.strongestReason == .venueEvent)

        // 8. shared-venue candidate does NOT receive fallback
        let venueOnly = SuggestedFansRanking.assemble(
            favoriteVenue: SuggestedFansRanking.favoriteVenueScore(sharedVenueCount: 1),
            isEligibleFallback: true
        )
        expect("venue_no_fallback_total_250", venueOnly.total == 250)
        expect("venue_no_fallback_reason", venueOnly.strongestReason == .favoriteVenue)

        // 9. recent-activity candidate does NOT receive fallback
        let activityOnly = SuggestedFansRanking.assemble(
            recentActivity: SuggestedFansRanking.recentActivityScore(updatedWithinDays: 20),
            isEligibleFallback: true
        )
        expect("activity_no_fallback_total_75", activityOnly.total == 75)
        expect("activity_no_fallback_reason", activityOnly.strongestReason == .recentActivity)

        // 10. XP/reputation candidate does NOT receive fallback
        let xpOnly = SuggestedFansRanking.assemble(
            reputation: SuggestedFansRanking.reputationScore(level: 3, totalXP: 0),
            isEligibleFallback: true
        )
        expect("xp_no_fallback_total_15", xpOnly.total == 15)
        expect("xp_no_fallback_reason", xpOnly.strongestReason == .reputation)

        // 11. multi-signal total contains no hidden +25
        // Candidate A: 2 mutuals + 4mi + same MY TEAM + shared venue = 2300 (NOT 2325)
        let candidateA = SuggestedFansRanking.assemble(
            mutualFriends: SuggestedFansRanking.mutualFriendsScore(count: 2),
            proximity: SuggestedFansRanking.proximityScore(distanceMiles: 4),
            myTeam: 600,
            favoriteVenue: SuggestedFansRanking.favoriteVenueScore(sharedVenueCount: 1),
            isEligibleFallback: true
        )
        expect("multi_signal_a_2300", candidateA.total == 2_300)
        expect("multi_signal_a_no_fallback", candidateA.authoritativeFallback == 0)
        expect("multi_signal_a_strongest_mutual", candidateA.strongestReason == .mutualFriends)

        // Candidate B: 1mi + 3 ordinary shared teams = 1150 (NOT 1175)
        let candidateB = SuggestedFansRanking.assemble(
            proximity: SuggestedFansRanking.proximityScore(distanceMiles: 1),
            favoriteTeam: SuggestedFansRanking.ordinarySharedTeamsScore(
                sharedTeamIds: ["a", "b", "c"],
                consumedByMyTeam: []
            ),
            isEligibleFallback: true
        )
        expect("multi_signal_b_1150", candidateB.total == 1_150)
        expect("multi_signal_b_no_fallback", candidateB.authoritativeFallback == 0)

        // Proximity + recent activity within 45mi: 75 + 75 = 150, no fallback
        let proxActivity = SuggestedFansRanking.assemble(
            proximity: SuggestedFansRanking.proximityScore(distanceMiles: 40),
            recentActivity: SuggestedFansRanking.recentActivityScore(updatedWithinDays: 20),
            isEligibleFallback: true
        )
        expect("prox_40mi_activity_150", proxActivity.total == 150)
        expect("prox_40mi_activity_no_fallback", proxActivity.authoritativeFallback == 0)

        // Beyond 45mi with no other meaningful signals → fallback only
        let beyondRadius = SuggestedFansRanking.assemble(
            proximity: SuggestedFansRanking.proximityScore(distanceMiles: 46),
            isEligibleFallback: true
        )
        expect("beyond_45_fallback_25", beyondRadius.total == 25)
        expect("beyond_45_fallback_reason", beyondRadius.strongestReason == .fallback)

        // Stacking defense: even if raw fallback is incorrectly set alongside signals, total ignores it
        var stacked = SuggestedFansRanking.ComponentScores()
        stacked.mutualFriends = 800
        stacked.fallback = 25
        expect("stacked_raw_fallback_ignored_total", stacked.total == 800)
        expect("stacked_raw_fallback_ignored_reason", stacked.strongestReason == .mutualFriends)

        // 12. fallback reason only for fallback-only
        expect("fallback_reason_only_when_sole", fallbackOnly.strongestReason == .fallback)
        expect("fallback_reason_not_on_prox", proxOnly.strongestReason != .fallback)
        expect("fallback_reason_not_on_multi", candidateA.strongestReason != .fallback)

        // 20 legacy multi-signal add (no fallback field set)
        var components = SuggestedFansRanking.ComponentScores()
        components.mutualFriends = SuggestedFansRanking.mutualFriendsScore(count: 2)
        components.proximity = SuggestedFansRanking.proximityScore(distanceMiles: 4)
        components.myTeam = 600
        components.favoriteVenue = SuggestedFansRanking.favoriteVenueScore(sharedVenueCount: 1)
        expect("multi_signal_2300", components.total == 2_300)

        // 21 strongest reason
        expect("strongest_mutual", components.strongestReason == .mutualFriends)
        var proxPref = SuggestedFansRanking.ComponentScores()
        proxPref.proximity = 700
        proxPref.favoriteTeam = 300
        expect("strongest_proximity", proxPref.strongestReason == .proximity)

        // 22 exact distance not exposed via reason labels / ranking API surface
        expect("no_distance_in_reason_raw", SuggestedFansRanking.ReasonType.proximity.rawValue == "proximity")

        // 26–27 diversity
        let viewer = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let profiles = (0..<12).map { idx -> FriendSuggestionProfile in
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", idx + 1))!
            return FriendSuggestionProfile(
                userID: id,
                email: nil,
                displayName: "Fan\(idx)",
                handle: nil,
                avatarURL: nil,
                avatarThumbnailURL: nil,
                bio: nil,
                sharedFavoriteTeamsCount: 0,
                sharedEventInterestCount: 0,
                sharedPickupGameCount: 0,
                mutualFriendCount: 0,
                mutualFriendAvatars: [],
                score: Double(1_000 - idx * 10),
                reasonType: idx < 10 ? "mutual_friends" : "fallback",
                reasonLabel: idx < 10 ? "mutual" : "Fan on FanGeo"
            )
        }
        // Make last two weak fallback-only scores
        let withWeak = profiles.enumerated().map { idx, row -> FriendSuggestionProfile in
            guard idx >= 10 else { return row }
            return FriendSuggestionProfile(
                userID: row.userID,
                email: nil,
                displayName: row.displayName,
                handle: nil,
                avatarURL: nil,
                avatarThumbnailURL: nil,
                bio: nil,
                sharedFavoriteTeamsCount: 0,
                sharedEventInterestCount: 0,
                sharedPickupGameCount: 0,
                mutualFriendCount: 0,
                mutualFriendAvatars: [],
                score: 25,
                reasonType: "fallback",
                reasonLabel: "Fan on FanGeo"
            )
        }
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let diversified = SuggestedFansRanking.applyControlledDiversity(
            rankedByScoreDescending: withWeak,
            displayLimit: 10,
            viewerId: viewer,
            dayBucket: day
        )
        expect("diversity_returns_10", diversified.count == 10)
        expect(
            "diversity_keeps_top8",
            Array(diversified.prefix(8).map(\.userID)) == Array(withWeak.prefix(8).map(\.userID))
        )
        expect(
            "diversity_no_weak_fallback_in_slots",
            diversified.allSatisfy { $0.score > 25 }
        )
        let again = SuggestedFansRanking.applyControlledDiversity(
            rankedByScoreDescending: withWeak,
            displayLimit: 10,
            viewerId: viewer,
            dayBucket: day
        )
        expect("diversity_stable_same_day", diversified.map(\.userID) == again.map(\.userID))

        // Why precedence uses server reason when present
        let whyProfile = FriendSuggestionProfile(
            userID: viewer,
            email: nil,
            displayName: "A",
            handle: nil,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            bio: nil,
            sharedFavoriteTeamsCount: 3,
            sharedEventInterestCount: 0,
            sharedPickupGameCount: 0,
            mutualFriendCount: 2,
            mutualFriendAvatars: [],
            score: 1_500,
            reasonType: "mutual_friends",
            reasonLabel: "2 mutual fans"
        )
        let why = SuggestedFanWhyExplanation.make(from: whyProfile, max: 3)
        expect("why_leads_with_mutual", {
            guard case .mutualFans = why.first else { return false }
            return true
        }())

        // Fallback why copy only when server says fallback
        let whyFallback = FriendSuggestionProfile(
            userID: viewer,
            email: nil,
            displayName: "B",
            handle: nil,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            bio: nil,
            sharedFavoriteTeamsCount: 0,
            sharedEventInterestCount: 0,
            sharedPickupGameCount: 0,
            mutualFriendCount: 0,
            mutualFriendAvatars: [],
            score: 25,
            reasonType: "fallback",
            reasonLabel: "Fan on FanGeo"
        )
        let whyFb = SuggestedFanWhyExplanation.make(from: whyFallback, max: 3)
        expect("why_fallback_only_when_sole", whyFb.isEmpty)

        if failures.isEmpty {
            print("[SuggestedFansRankingTest] PASS")
        } else {
            print("[SuggestedFansRankingTest] FAILED count=\(failures.count) names=\(failures.joined(separator: ","))")
        }
    }
}
#endif
