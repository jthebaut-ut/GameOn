import Foundation

#if DEBUG
/// Client-side regression tests for meaningful pickup edit detection + copy.
enum PickupGameMeaningfulChangeSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[PickupGameMeaningfulChangeTest] PASS \(name)")
            } else {
                failures += 1
                print("[PickupGameMeaningfulChangeTest] FAIL \(name)")
            }
        }

        let base = sampleRow(
            title: "Rock Climbing Demo",
            start: "2026-08-10T18:57:00+00:00",
            address: "Jordan River",
            city: "Salt Lake City",
            state: "UT",
            lat: 40.7608,
            lon: -111.8910,
            players: 8
        )

        let dateOnly = sampleRow(
            title: base.title,
            start: "2026-08-11T19:30:00+00:00",
            address: base.address,
            city: base.city,
            state: base.state,
            lat: base.latitude,
            lon: base.longitude,
            players: 8
        )
        let dateDiff = PickupGameMeaningfulChange.diff(before: base, after: dateOnly)
        expect(dateDiff.kinds == [.start], "date_only_kinds")
        expect(!dateDiff.isEmpty, "date_only_meaningful")

        let locationOnly = sampleRow(
            title: base.title,
            start: base.game_start_at,
            address: "Draper Sports Park",
            city: "Draper",
            state: "UT",
            lat: 40.5247,
            lon: -111.8638,
            players: 8
        )
        let locDiff = PickupGameMeaningfulChange.diff(before: base, after: locationOnly)
        expect(locDiff.kinds == [.location], "location_only_kinds")

        let both = sampleRow(
            title: base.title,
            start: dateOnly.game_start_at,
            address: locationOnly.address,
            city: locationOnly.city,
            state: locationOnly.state,
            lat: locationOnly.latitude,
            lon: locationOnly.longitude,
            players: 8
        )
        let bothDiff = PickupGameMeaningfulChange.diff(before: base, after: both)
        expect(Set(bothDiff.kinds) == Set([.start, .location]), "date_and_location_combined")

        let whitespace = sampleRow(
            title: "  Rock   Climbing Demo ",
            start: base.game_start_at,
            address: "  Jordan   River ",
            city: " Salt Lake City ",
            state: "ut",
            lat: base.latitude,
            lon: base.longitude,
            players: 8
        )
        let noise = PickupGameMeaningfulChange.diff(before: base, after: whitespace)
        expect(noise.isEmpty, "whitespace_case_only_ignored")

        let geocodeJitter = sampleRow(
            title: base.title,
            start: base.game_start_at,
            address: base.address,
            city: base.city,
            state: base.state,
            lat: (base.latitude ?? 0) + 0.00005,
            lon: (base.longitude ?? 0) - 0.00004,
            players: 8
        )
        let jitterDiff = PickupGameMeaningfulChange.diff(before: base, after: geocodeJitter)
        expect(jitterDiff.isEmpty, "geocode_jitter_ignored_when_place_unchanged")

        let capacity = sampleRow(
            title: base.title,
            start: base.game_start_at,
            address: base.address,
            city: base.city,
            state: base.state,
            lat: base.latitude,
            lon: base.longitude,
            players: 10
        )
        let capacityDiff = PickupGameMeaningfulChange.diff(before: base, after: capacity)
        expect(capacityDiff.kinds == [.capacity], "capacity_change")

        let cancelled = sampleRow(
            title: base.title,
            start: base.game_start_at,
            address: base.address,
            city: base.city,
            state: base.state,
            lat: base.latitude,
            lon: base.longitude,
            players: 8,
            status: "removed"
        )
        let cancelDiff = PickupGameMeaningfulChange.diff(before: base, after: cancelled)
        expect(cancelDiff.isCancellation, "cancellation_flag")
        expect(cancelDiff.kinds.contains(.status), "cancellation_status_kind")
        let pushCancel = PickupGameMeaningfulChange.pushBody(for: cancelDiff, languageCode: "en")
        expect(pushCancel.lowercased().contains("cancelled"), "push_cancel_mentions_cancelled")
        expect(pushCancel.lowercased().contains("rock climbing"), "push_cancel_mentions_title")
        expect(base.canOrganizerCancelPickupGame(viewerUserId: base.creator_user_id), "active_creator_can_cancel")
        expect(!cancelled.canOrganizerCancelPickupGame(viewerUserId: cancelled.creator_user_id), "removed_cannot_cancel_again")
        expect(!base.canOrganizerCancelPickupGame(viewerUserId: UUID()), "non_creator_cannot_cancel")
        expect(cancelled.isPickupGameSoftCancelled, "removed_is_soft_cancelled")

        let sigBase = PickupGameMeaningfulChange.activitySignatureFragment(for: base)
        let sigLoc = PickupGameMeaningfulChange.activitySignatureFragment(for: locationOnly)
        expect(sigBase != sigLoc, "activity_signature_includes_location")

        let pushDate = PickupGameMeaningfulChange.pushBody(for: dateDiff, languageCode: "en")
        expect(pushDate.lowercased().contains("rock climbing"), "push_date_mentions_title")
        let pushBoth = PickupGameMeaningfulChange.pushBody(for: bothDiff, languageCode: "en")
        expect(
            pushBoth.lowercased().contains("time") && pushBoth.lowercased().contains("location"),
            "push_date_location_combined"
        )

        if failures == 0 {
            print("[PickupGameMeaningfulChangeTest] ALL PASSED")
        } else {
            print("[PickupGameMeaningfulChangeTest] FAILURES=\(failures)")
        }
    }

    private static func sampleRow(
        title: String,
        start: String,
        address: String?,
        city: String?,
        state: String?,
        lat: Double?,
        lon: Double?,
        players: Int,
        status: String = "scheduled"
    ) -> PickupGameRow {
        PickupGameRow(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            creator_user_id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            creator_email: nil,
            title: title,
            sport: "Climbing",
            description: nil,
            game_format: "pickup",
            skill_level: "casual",
            game_start_at: start,
            end_time: nil,
            address: address,
            city: city,
            state: state,
            latitude: lat,
            longitude: lon,
            is_visible: true,
            players_needed: players,
            play_environment: "outdoor",
            participant_preference: "anyone",
            age_min: nil,
            age_max: nil,
            is_free: true,
            entry_fee_amount: nil,
            max_players: players,
            status: status,
            approved_join_count: 0,
            cleanup_delay_hours: 12,
            remove_after_at: nil,
            created_at: nil,
            updated_at: nil
        )
    }
}
#endif
