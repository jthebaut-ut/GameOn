import Foundation
import SwiftUI

#if DEBUG
enum CalendarPlayPickupCardSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[CalendarPlayPickupCardTest] PASS \(name)")
            } else {
                failures += 1
                print("[CalendarPlayPickupCardTest] FAIL \(name)")
            }
        }

        let gameId = UUID()
        let teamId = UUID()
        let identity = PickupDiscoverTeamIdentity(
            pickupGameId: gameId,
            teamId: teamId,
            teamName: "JT",
            teamSport: "tennis",
            colorHex: "#22C25A",
            logoURL: "https://example.com/logo.png",
            logoThumbnailURL: nil,
            displayRefreshToken: nil
        )
        let league = makeRow(title: "JT", format: "league_game")
        let practice = makeRow(title: "JT", format: "practice")
        let tournament = makeRow(title: "JT", format: "tournament_game")
        let tryout = makeRow(title: "JT", format: "tryout")
        let meeting = makeRow(title: "JT", format: "team_meeting")
        let other = makeRow(title: "JT", format: "other")
        let pickup = makeRow(title: "Soccer Pickup", format: "pickup")

        expect(PickupDiscoverTeamPresentation.isTeamLinked(identity), "identity is Team-linked")
        expect(!PickupDiscoverTeamPresentation.isTeamLinked(nil), "nil identity is standalone")

        expect(
            CalendarPlayPickupCardPresentation.eventTypeLabel(for: league, languageCode: "en") == "League Game",
            "League Game label"
        )
        expect(
            CalendarPlayPickupCardPresentation.eventTypeLabel(for: practice, languageCode: "en") == "Practice",
            "Practice label"
        )
        expect(
            CalendarPlayPickupCardPresentation.eventTypeLabel(for: tournament, languageCode: "en") == "Tournament Game",
            "Tournament Game label"
        )
        expect(
            CalendarPlayPickupCardPresentation.eventTypeLabel(for: tryout, languageCode: "en") == "Tryout",
            "Tryout label"
        )
        expect(
            CalendarPlayPickupCardPresentation.eventTypeLabel(for: meeting, languageCode: "en") == "Team Meeting",
            "Team Meeting label"
        )
        expect(
            CalendarPlayPickupCardPresentation.eventTypeLabel(for: other, languageCode: "en") == "Other",
            "Other label"
        )
        expect(
            CalendarPlayPickupCardPresentation.eventTypeLabel(for: pickup, languageCode: "en") == "Pickup Game",
            "Pickup Game label preserved"
        )

        expect(
            CalendarPlayPickupCardPresentation.primaryTitle(eventTitle: "JT Practice", identity: identity) == "JT",
            "primary title prefers Team name"
        )
        expect(
            CalendarPlayPickupCardPresentation.primaryTitle(eventTitle: "Soccer Pickup", identity: nil) == "Soccer Pickup",
            "standalone keeps event title"
        )

        let a11y = CalendarPlayPickupCardPresentation.accessibilityLabel(
            eventTitle: "JT",
            identity: identity,
            game: league,
            dateTimeLine: "Tue, Aug 11 · 6:58 PM",
            addressLine: "Galena Hills Trail, Draper, UT",
            capacityMeta: "Full",
            languageCode: "en"
        )
        expect(a11y.contains("JT"), "a11y includes Team name")
        expect(a11y.contains("League Game"), "a11y includes event type")
        expect(a11y.contains("Tue, Aug 11"), "a11y includes date/time")
        expect(a11y.contains("Galena Hills Trail"), "a11y includes address")
        expect(!a11y.lowercased().contains("pickup game"), "Team League Game is not labeled Pickup Game")

        let standaloneA11y = CalendarPlayPickupCardPresentation.accessibilityLabel(
            eventTitle: "Soccer Pickup",
            identity: nil,
            game: pickup,
            dateTimeLine: "Tue, Aug 11 · 6:58 PM",
            addressLine: "Galena Hills Trail",
            capacityMeta: "Open",
            languageCode: "en"
        )
        expect(standaloneA11y.hasPrefix("Soccer Pickup"), "standalone a11y starts with title")
        expect(!standaloneA11y.contains("League Game"), "standalone a11y omits Team event type")

        let withColor = CalendarPlayPickupCardPresentation.teamAccent(identity: identity, colorScheme: .light)
        let withoutColor = CalendarPlayPickupCardPresentation.teamAccent(
            identity: PickupDiscoverTeamIdentity(
                pickupGameId: gameId,
                teamId: teamId,
                teamName: "JT",
                teamSport: "tennis",
                colorHex: nil,
                logoURL: nil,
                logoThumbnailURL: nil,
                displayRefreshToken: nil
            ),
            colorScheme: .light
        )
        expect(withColor != withoutColor, "custom Team color differs from fallback")
        expect(withoutColor == FGColor.intentPlay, "missing Team color falls back to FanGeo Play accent")

        if failures == 0 {
            print("[CalendarPlayPickupCardTest] ALL PASSED")
        } else {
            print("[CalendarPlayPickupCardTest] FAILURES=\(failures)")
            assertionFailure("CalendarPlayPickupCardSelfTests failed: \(failures)")
        }
    }

    private static func makeRow(title: String, format: String) -> PickupGameRow {
        let start = "2026-08-11T18:58:00+00:00"
        let end = "2026-08-11T20:58:00+00:00"
        return PickupGameRow(
            id: UUID(),
            creator_user_id: UUID(),
            creator_email: nil,
            title: title,
            sport: "tennis",
            description: nil,
            game_format: format,
            competition_level: nil,
            skill_level: "casual",
            game_start_at: start,
            end_time: end,
            address: "Galena Hills Trail",
            city: "Draper",
            state: "UT 84020",
            latitude: 40.52,
            longitude: -111.86,
            is_visible: true,
            players_needed: 4,
            play_environment: "outdoor",
            participant_preference: "anyone",
            age_min: nil,
            age_max: nil,
            is_free: true,
            entry_fee_amount: nil,
            max_players: 8,
            status: "active",
            approved_join_count: 8,
            cleanup_delay_hours: 12,
            remove_after_at: nil,
            created_at: start,
            updated_at: start,
            poll_create_permission: nil
        )
    }
}
#endif
