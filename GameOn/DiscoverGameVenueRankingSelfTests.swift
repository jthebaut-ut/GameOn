import Foundation

#if DEBUG
enum DiscoverGameVenueRankingSelfTests {
    static func runAll() {
        var failures: [String] = []
        func expect(_ name: String, _ ok: @autoclosure () -> Bool) {
            if !ok() {
                failures.append(name)
                print("[DiscoverGameVenueRankingTest] FAIL \(name)")
            }
        }

        // Example 1 — Venue A LIVE trending vs Venue B active
        let venueAEnergy = DiscoverGameVenueRanking.gameSpecificEnergy(
            goingCount: 10,
            vibeCounts: [VenueMapEnergyScore.vibeAtmosphere: 5],
            uniqueCommenterCount: 0,
            isLiveNow: true
        )
        // 10*5=50 + 5*4=20 + LIVE 15 = 85
        expect("ex1_venue_a_85_trending", venueAEnergy == 85)
        expect(
            "ex1_venue_a_tier",
            VenueMapEnergyScore.tier(for: venueAEnergy) == .trending
        )

        let venueBEnergy = DiscoverGameVenueRanking.gameSpecificEnergy(
            goingCount: 4,
            vibeCounts: [VenueMapEnergyScore.vibeTV: 3],
            uniqueCommenterCount: 0,
            isLiveNow: false
        )
        // 4*5=20 + 3*3=9 = 29
        expect("ex1_venue_b_29_active", venueBEnergy == 29)
        expect(
            "ex1_venue_b_tier",
            VenueMapEnergyScore.tier(for: venueBEnergy) == .active
        )

        let idA = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let idB = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let rankedAB = DiscoverGameVenueRanking.rank([
            .init(
                id: idB,
                venueName: "Venue B",
                gameSpecificEnergy: venueBEnergy,
                goingCount: 4,
                distanceMiles: 1,
                isLiveNow: false,
                venueEventID: nil
            ),
            .init(
                id: idA,
                venueName: "Venue A",
                gameSpecificEnergy: venueAEnergy,
                goingCount: 10,
                distanceMiles: 5,
                isLiveNow: true,
                venueEventID: nil
            )
        ])
        expect("ex1_a_ranks_above_b", rankedAB.map(\.id) == [idA, idB])

        // Example 2 — unrelated game must not contaminate
        let franceSpainOnly = DiscoverGameVenueRanking.gameSpecificEnergy(
            goingCount: 1,
            vibeCounts: [:],
            uniqueCommenterCount: 0,
            isLiveNow: false
        )
        expect("ex2_france_spain_only_5", franceSpainOnly == 5)
        expect(
            "ex2_starting_tier",
            VenueMapEnergyScore.tier(for: franceSpainOnly) == .starting
        )
        // Other game 100 is never passed into gameSpecificEnergy — isolation by construction.
        expect(
            "ex2_no_contamination",
            DiscoverGameVenueRanking.gameSpecificEnergy(
                activity: .init(
                    goingCount: 1, atmosphereCount: 0, crowdedCount: 0, tvCount: 0,
                    soundCount: 0, seatingCount: 0, uniqueCommenterCount: 0, isLiveNow: false
                )
            ) == 5
        )

        // Example 3 — five tiers display order
        let energies = [80, 62, 45, 18, 5]
        let ids = (0..<5).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0 + 1))! }
        let five = DiscoverGameVenueRanking.rank(
            zip(ids, energies).enumerated().map { idx, pair in
                DiscoverGameVenueRanking.Candidate(
                    id: pair.0,
                    venueName: "V\(idx)",
                    gameSpecificEnergy: pair.1,
                    goingCount: 0,
                    distanceMiles: Double(idx),
                    isLiveNow: false,
                    venueEventID: nil
                )
            }
        )
        expect("ex3_order_ids", five.map(\.gameSpecificEnergy) == energies)
        expect(
            "ex3_tiers",
            five.map(\.tier) == [.trending, .trending, .hot, .active, .starting]
        )

        // Example 4 — seven venues → top 5 only
        let sevenEnergies = [90, 80, 70, 60, 50, 40, 30]
        let sevenIds = (0..<7).map { UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", $0 + 1))! }
        let top5 = DiscoverGameVenueRanking.rank(
            zip(sevenIds, sevenEnergies).map { id, energy in
                DiscoverGameVenueRanking.Candidate(
                    id: id,
                    venueName: id.uuidString,
                    gameSpecificEnergy: energy,
                    goingCount: 0,
                    distanceMiles: nil,
                    isLiveNow: false,
                    venueEventID: nil
                )
            },
            limit: 5
        )
        expect("ex4_top5_count", top5.count == 5)
        expect("ex4_top5_energies", top5.map(\.gameSpecificEnergy) == [90, 80, 70, 60, 50])

        // Zero energy still ranks via tie-breakers
        let z1 = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let z2 = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        let zeroRank = DiscoverGameVenueRanking.rank([
            .init(id: z2, venueName: "Zeta", gameSpecificEnergy: 0, goingCount: 0, distanceMiles: 3, isLiveNow: false, venueEventID: nil),
            .init(id: z1, venueName: "Alpha", gameSpecificEnergy: 0, goingCount: 2, distanceMiles: 9, isLiveNow: false, venueEventID: nil)
        ])
        expect("zero_energy_going_tiebreak", zeroRank.map(\.id) == [z1, z2])
        expect("zero_energy_normal_tier", zeroRank[0].tier == .normal)

        // Proximity/distance tie-break when energy+going equal
        let d1 = UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
        let d2 = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
        let distRank = DiscoverGameVenueRanking.rank([
            .init(id: d2, venueName: "Far", gameSpecificEnergy: 20, goingCount: 1, distanceMiles: 8, isLiveNow: false, venueEventID: nil),
            .init(id: d1, venueName: "Near", gameSpecificEnergy: 20, goingCount: 1, distanceMiles: 2, isLiveNow: false, venueEventID: nil)
        ])
        expect("distance_tiebreak", distRank.map(\.id) == [d1, d2])

        // Name / id stable when all else equal
        let n1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let n2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let nameRank = DiscoverGameVenueRanking.rank([
            .init(id: n2, venueName: "Bravo", gameSpecificEnergy: 10, goingCount: 0, distanceMiles: nil, isLiveNow: false, venueEventID: nil),
            .init(id: n1, venueName: "Alpha", gameSpecificEnergy: 10, goingCount: 0, distanceMiles: nil, isLiveNow: false, venueEventID: nil)
        ])
        expect("name_tiebreak", nameRank.map(\.venueName) == ["Alpha", "Bravo"])

        // 1–4 venues: no padding
        expect(
            "no_pad_to_five",
            DiscoverGameVenueRanking.rank([
                .init(id: idA, venueName: "A", gameSpecificEnergy: 40, goingCount: 0, distanceMiles: nil, isLiveNow: false, venueEventID: nil)
            ]).count == 1
        )

        // Empty
        expect("empty_rank", DiscoverGameVenueRanking.rank([]).isEmpty)

        // LIVE bonus can reorder
        let beforeLive = DiscoverGameVenueRanking.gameSpecificEnergy(
            goingCount: 6, vibeCounts: [:], uniqueCommenterCount: 0, isLiveNow: false
        )
        let afterLive = DiscoverGameVenueRanking.gameSpecificEnergy(
            goingCount: 6, vibeCounts: [:], uniqueCommenterCount: 0, isLiveNow: true
        )
        expect("live_bonus_15", afterLive - beforeLive == VenueMapEnergyScore.pointsLiveBonus)

        // Captions match canonical tiers
        expect("caption_trending", DiscoverGameVenueRanking.tierCaption(forEnergy: 80) == "👑 Trending")
        expect("caption_hot", DiscoverGameVenueRanking.tierCaption(forEnergy: 45) == "🚀 Hot")
        expect("caption_active", DiscoverGameVenueRanking.tierCaption(forEnergy: 18) == "🔥 Active")
        expect("caption_starting", DiscoverGameVenueRanking.tierCaption(forEnergy: 5) == "✨ Starting")
        expect("caption_normal_empty", DiscoverGameVenueRanking.tierCaption(forEnergy: 0).isEmpty)

        if failures.isEmpty {
            print("[DiscoverGameVenueRankingTest] PASS")
        } else {
            print("[DiscoverGameVenueRankingTest] FAILED count=\(failures.count) names=\(failures.joined(separator: ","))")
        }
    }
}
#endif
