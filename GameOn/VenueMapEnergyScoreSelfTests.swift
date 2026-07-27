import Foundation

#if DEBUG
enum VenueMapEnergyScoreSelfTests {
    static func runAll() {
        var failures: [String] = []
        func expect(_ name: String, _ ok: @autoclosure () -> Bool) {
            if !ok() {
                failures.append(name)
                print("[VenueMapEnergyTest] FAIL \(name)")
            }
        }

        expect("going_1_is_5", VenueMapEnergyScore.eventContribution(
            .init(goingCount: 1, atmosphereCount: 0, crowdedCount: 0, tvCount: 0, soundCount: 0, seatingCount: 0, uniqueCommenterCount: 0, isLiveNow: false),
            includeLiveBonus: false
        ).goingPoints == 5)

        expect("going_cap_100", VenueMapEnergyScore.eventContribution(
            .init(goingCount: 25, atmosphereCount: 0, crowdedCount: 0, tvCount: 0, soundCount: 0, seatingCount: 0, uniqueCommenterCount: 0, isLiveNow: false),
            includeLiveBonus: false
        ).goingPoints == 100)

        expect("atmosphere_4_and_cap", {
            let one = VenueMapEnergyScore.eventContribution(
                .init(goingCount: 0, atmosphereCount: 1, crowdedCount: 0, tvCount: 0, soundCount: 0, seatingCount: 0, uniqueCommenterCount: 0, isLiveNow: false),
                includeLiveBonus: false
            )
            let capped = VenueMapEnergyScore.eventContribution(
                .init(goingCount: 0, atmosphereCount: 20, crowdedCount: 0, tvCount: 0, soundCount: 0, seatingCount: 0, uniqueCommenterCount: 0, isLiveNow: false),
                includeLiveBonus: false
            )
            return one.atmospherePoints == 4 && capped.atmospherePoints == 40
        }())

        expect("crowded_4_and_cap", {
            let one = VenueMapEnergyScore.eventContribution(
                .init(goingCount: 0, atmosphereCount: 0, crowdedCount: 1, tvCount: 0, soundCount: 0, seatingCount: 0, uniqueCommenterCount: 0, isLiveNow: false),
                includeLiveBonus: false
            )
            let capped = VenueMapEnergyScore.eventContribution(
                .init(goingCount: 0, atmosphereCount: 0, crowdedCount: 20, tvCount: 0, soundCount: 0, seatingCount: 0, uniqueCommenterCount: 0, isLiveNow: false),
                includeLiveBonus: false
            )
            return one.crowdedPoints == 4 && capped.crowdedPoints == 40
        }())

        expect("tv_3_and_cap", {
            let one = VenueMapEnergyScore.eventContribution(
                .init(goingCount: 0, atmosphereCount: 0, crowdedCount: 0, tvCount: 1, soundCount: 0, seatingCount: 0, uniqueCommenterCount: 0, isLiveNow: false),
                includeLiveBonus: false
            )
            let capped = VenueMapEnergyScore.eventContribution(
                .init(goingCount: 0, atmosphereCount: 0, crowdedCount: 0, tvCount: 20, soundCount: 0, seatingCount: 0, uniqueCommenterCount: 0, isLiveNow: false),
                includeLiveBonus: false
            )
            return one.tvPoints == 3 && capped.tvPoints == 30
        }())

        expect("sound_3_and_cap", {
            let one = VenueMapEnergyScore.eventContribution(
                .init(goingCount: 0, atmosphereCount: 0, crowdedCount: 0, tvCount: 0, soundCount: 1, seatingCount: 0, uniqueCommenterCount: 0, isLiveNow: false),
                includeLiveBonus: false
            )
            let capped = VenueMapEnergyScore.eventContribution(
                .init(goingCount: 0, atmosphereCount: 0, crowdedCount: 0, tvCount: 0, soundCount: 20, seatingCount: 0, uniqueCommenterCount: 0, isLiveNow: false),
                includeLiveBonus: false
            )
            return one.soundPoints == 3 && capped.soundPoints == 30
        }())

        expect("seating_2_and_cap", {
            let one = VenueMapEnergyScore.eventContribution(
                .init(goingCount: 0, atmosphereCount: 0, crowdedCount: 0, tvCount: 0, soundCount: 0, seatingCount: 1, uniqueCommenterCount: 0, isLiveNow: false),
                includeLiveBonus: false
            )
            let capped = VenueMapEnergyScore.eventContribution(
                .init(goingCount: 0, atmosphereCount: 0, crowdedCount: 0, tvCount: 0, soundCount: 0, seatingCount: 20, uniqueCommenterCount: 0, isLiveNow: false),
                includeLiveBonus: false
            )
            return one.seatingPoints == 2 && capped.seatingPoints == 20
        }())

        expect("commenter_2_and_cap", {
            let one = VenueMapEnergyScore.eventContribution(
                .init(goingCount: 0, atmosphereCount: 0, crowdedCount: 0, tvCount: 0, soundCount: 0, seatingCount: 0, uniqueCommenterCount: 1, isLiveNow: false),
                includeLiveBonus: false
            )
            let capped = VenueMapEnergyScore.eventContribution(
                .init(goingCount: 0, atmosphereCount: 0, crowdedCount: 0, tvCount: 0, soundCount: 0, seatingCount: 0, uniqueCommenterCount: 30, isLiveNow: false),
                includeLiveBonus: false
            )
            return one.commenterPoints == 2 && capped.commenterPoints == 20
        }())

        expect("same_fan_30_comments_still_one_commenter", {
            // Scoring input is uniqueCommenterCount — 1 fan → +2 regardless of raw comment volume.
            VenueMapEnergyScore.eventContribution(
                .init(goingCount: 0, atmosphereCount: 0, crowdedCount: 0, tvCount: 0, soundCount: 0, seatingCount: 0, uniqueCommenterCount: 1, isLiveNow: false),
                includeLiveBonus: false
            ).commenterPoints == 2
        }())

        expect("live_15", VenueMapEnergyScore.score(events: [
            .init(goingCount: 0, atmosphereCount: 0, crowdedCount: 0, tvCount: 0, soundCount: 0, seatingCount: 0, uniqueCommenterCount: 0, isLiveNow: true)
        ]).liveBonus == 15)

        expect("multi_live_one_bonus", VenueMapEnergyScore.score(events: [
            .init(goingCount: 0, atmosphereCount: 0, crowdedCount: 0, tvCount: 0, soundCount: 0, seatingCount: 0, uniqueCommenterCount: 0, isLiveNow: true),
            .init(goingCount: 0, atmosphereCount: 0, crowdedCount: 0, tvCount: 0, soundCount: 0, seatingCount: 0, uniqueCommenterCount: 0, isLiveNow: true)
        ]).liveBonus == 15)

        expect("example_a_5going_3tv_live", {
            let total = VenueMapEnergyScore.scoreTotal(events: [
                .init(goingCount: 5, atmosphereCount: 0, crowdedCount: 0, tvCount: 3, soundCount: 0, seatingCount: 0, uniqueCommenterCount: 0, isLiveNow: true)
            ])
            // 5*5 + 3*3 + 15 = 25+9+15 = 49
            return total == 49
        }())

        expect("example_b_mixed", {
            let total = VenueMapEnergyScore.scoreTotal(events: [
                .init(goingCount: 10, atmosphereCount: 5, crowdedCount: 4, tvCount: 0, soundCount: 0, seatingCount: 0, uniqueCommenterCount: 3, isLiveNow: false)
            ])
            // 50 + 20 + 16 + 6 = 92
            return total == 92
        }())

        expect("no_commercial_in_formula", VenueMapEnergyScore.pointsLiveBonus == 15)

        expect("tier_0_normal", VenueMapEnergyScore.tier(for: 0) == .normal)
        expect("tier_1_starting", VenueMapEnergyScore.tier(for: 1) == .starting)
        expect("tier_9_starting", VenueMapEnergyScore.tier(for: 9) == .starting)
        expect("tier_10_active", VenueMapEnergyScore.tier(for: 10) == .active)
        expect("tier_29_active", VenueMapEnergyScore.tier(for: 29) == .active)
        expect("tier_30_hot", VenueMapEnergyScore.tier(for: 30) == .hot)
        expect("tier_59_hot", VenueMapEnergyScore.tier(for: 59) == .hot)
        expect("tier_60_trending", VenueMapEnergyScore.tier(for: 60) == .trending)
        expect("hot_pulses", VenueMapEnergyScore.tier(for: 30).shouldPulse)
        expect("trending_pulses", VenueMapEnergyScore.tier(for: 60).shouldPulse)
        expect("active_no_pulse", !VenueMapEnergyScore.tier(for: 10).shouldPulse)

        expect("vibe_keys_canonical", {
            VenueMapEnergyScore.vibeAtmosphere == "packed"
                && VenueMapEnergyScore.vibeCrowded == "crowd"
                && VenueMapEnergyScore.vibeTV == "tv_visible"
                && VenueMapEnergyScore.vibeSound == "audio_on"
                && VenueMapEnergyScore.vibeSeating == "seats_open"
        }())

        if failures.isEmpty {
            print("[VenueMapEnergyTest] PASS")
        } else {
            print("[VenueMapEnergyTest] FAILED count=\(failures.count) names=\(failures.joined(separator: ","))")
        }
    }
}
#endif
