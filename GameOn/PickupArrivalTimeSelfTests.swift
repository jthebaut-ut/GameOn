import Foundation

enum PickupArrivalTimeSelfTests {
    static func runAll() {
        testSelectColumnsIncludeArrivalTime()
        testNullableTimestamptzEncodesNullAndValue()
        testRowDecodesMissingOrNullArrival()
    }

    private static func testSelectColumnsIncludeArrivalTime() {
        precondition(
            pickupGamesSelectColumns.contains("arrival_time"),
            "pickupGamesSelectColumns must include arrival_time for edit hydration"
        )
        // Keep column adjacent to end_time for readability / stable ordering.
        precondition(
            pickupGamesSelectColumns.contains("end_time,arrival_time,address"),
            "arrival_time should follow end_time in select list"
        )
        precondition(
            pickupGamesSelectColumns.contains("sport,sport_subtype,description"),
            "sport_subtype should follow sport in select list"
        )
    }

    private static func testNullableTimestamptzEncodesNullAndValue() {
        let encoder = JSONEncoder()
        let nullData = try! encoder.encode(PickupNullableTimestamptz(nil))
        let nullJSON = String(data: nullData, encoding: .utf8)!
        precondition(nullJSON == "null", "nil arrival must encode as JSON null, got \(nullJSON)")

        let stamp = "2026-08-17T17:30:00+00:00"
        let valueData = try! encoder.encode(PickupNullableTimestamptz(stamp))
        let valueJSON = String(data: valueData, encoding: .utf8)!
        precondition(valueJSON.contains("2026-08-17"), "value arrival must encode ISO string, got \(valueJSON)")
        precondition(!valueJSON.contains("null"), "non-nil arrival must not encode as null")
    }

    private static func testRowDecodesMissingOrNullArrival() {
        let decoder = JSONDecoder()
        let base: [String: Any] = [
            "id": UUID().uuidString,
            "creator_user_id": UUID().uuidString,
            "creator_email": NSNull(),
            "title": "Test",
            "sport": "Soccer",
            "description": NSNull(),
            "game_format": "league_game",
            "competition_level": NSNull(),
            "skill_level": "casual",
            "game_start_at": "2026-08-17T18:00:00+00:00",
            "end_time": "2026-08-17T20:00:00+00:00",
            "address": "Field",
            "city": "Lehi",
            "state": "UT",
            "latitude": 40.0,
            "longitude": -111.0,
            "is_visible": false,
            "players_needed": 1,
            "play_environment": "outdoor",
            "participant_preference": "everyone",
            "age_min": NSNull(),
            "age_max": NSNull(),
            "is_free": true,
            "entry_fee_amount": NSNull(),
            "max_players": NSNull(),
            "status": "active",
            "approved_join_count": 0,
            "cleanup_delay_hours": 12,
            "remove_after_at": "2026-08-18T06:00:00+00:00",
            "created_at": "2026-08-01T00:00:00+00:00",
            "updated_at": "2026-08-01T00:00:00+00:00",
            "poll_create_permission": "organizer_only",
            "opponent_name": NSNull(),
        ]

        func decode(_ extra: [String: Any]) -> PickupGameRow {
            var merged = base
            for (k, v) in extra { merged[k] = v }
            let data = try! JSONSerialization.data(withJSONObject: merged)
            return try! decoder.decode(PickupGameRow.self, from: data)
        }

        let missing = decode([:])
        precondition(missing.arrival_time == nil)

        let explicitNull = decode(["arrival_time": NSNull()])
        precondition(explicitNull.arrival_time == nil)

        let present = decode(["arrival_time": "2026-08-17T17:30:00+00:00"])
        precondition(present.arrival_time == "2026-08-17T17:30:00+00:00")
        precondition(PickupGameModels.parseSupabaseTimestamptz(present.arrival_time!) != nil)
    }
}
