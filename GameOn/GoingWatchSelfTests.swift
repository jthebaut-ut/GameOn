import CoreLocation
import Foundation

#if DEBUG
enum GoingWatchSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[GoingWatchTest] PASS \(name)")
            } else {
                failures += 1
                print("[GoingWatchTest] FAIL \(name)")
            }
        }

        let gameA = stubGame(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "Lakers @ Jazz")
        let gameB = stubGame(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "Real Madrid vs Barcelona")
        let spot = stubSpot(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!, name: "Buffalo Wild Wings")

        let unified = GoingWatchProjection.unified(games: [gameA, gameB], spots: [spot])
        expect(unified.count == 3, "1 All has 3 unique items")
        expect(unified.filter { $0.source == .game }.count == 2, "5 games source")
        expect(unified.filter { $0.source == .favoriteSpot }.count == 1, "6 spots source")
        expect(unified.first?.source == .game, "13 games sort before spots")
        expect(unified.last?.source == .favoriteSpot, "14 spots follow games")

        let dupGames = GoingWatchProjection.unified(games: [gameA, gameA], spots: [spot, spot])
        expect(dupGames.count == 2, "15 no duplicate Watch item")

        let counts = GoingWatchProjection.filterCounts(unified)
        expect(counts.all == 3, "9 All count")
        expect(counts.games == 2, "9 games count")
        expect(counts.favoriteSpots == 1, "9 spots count")

        expect(GoingWatchProjection.filtered(unified, filter: .all).count == 3, "6 All filter")
        expect(GoingWatchProjection.filtered(unified, filter: .games).allSatisfy { $0.source == .game }, "7 games filter")
        expect(GoingWatchProjection.filtered(unified, filter: .favoriteSpots).allSatisfy { $0.source == .favoriteSpot }, "8 spots filter")

        let loc = GoingWatchProjection.locationLine(
            bar: stubSpot(id: UUID(), name: "Delta Center", address: "Salt Lake City, UT, Salt Lake City, UT"),
            languageCode: "en"
        )
        expect(!loc.lowercased().contains("salt lake city, ut, salt lake city"), "23 no repeated city")

        expect(L10n.t("going_watch_empty_title", languageCode: "en") == "Nothing planned yet", "25 empty title")
        expect(L10n.t("games_im_going_to", languageCode: "en") == "Games I'm Going To", "25 games filter canonical")
        expect(L10n.t("going_watch_chip_im_going", languageCode: "en") == "I'm Going", "Watch chip I'm Going")
        expect(L10n.t("saved_spots", languageCode: "en") == "Favorite Spots", "25 spots filter")
        expect(L10n.t("going_play_filter_all", languageCode: "en") == "All", "Watch chip All")
        expect(GoingWatchFilter.games.chipTitleKey == "going_watch_chip_im_going", "chip label is short I'm Going")
        expect(GoingWatchFilter.all.chipTitleKey == "going_play_filter_all", "All chip uses All")
        expect(GoingWatchFilter.favoriteSpots.chipTitleKey == "saved_spots", "Favorite Spots chip uses saved_spots")
        expect(GoingWatchFilter.games.titleKey == "games_im_going_to", "enum storage meaning unchanged")
        expect(GoingWatchFilter.allCases == [.all, .games, .favoriteSpots], "Watch filters All / I'm Going / Favorite Spots")
        expect(GoingWatchFilter.allCases.first == .all, "default Watch filter is All")
        expect(GoingWatchFilter.all.systemImage == "tv.fill", "All chip uses TV icon")
        expect(GoingWatchFilter.games.systemImage == "calendar", "I'm Going chip uses calendar")
        expect(GoingWatchFilter.favoriteSpots.systemImage == "heart.fill", "Favorite Spots chip uses heart")
        expect(GoingPlayFilter.allCases == [.all, .hosting, .invites, .pickups, .teamEvents], "Play filter still exists")
        expect(GoingProGamesFilter.allCases == [.all, .saved, .favoriteTeams], "Pro Games chips unchanged")
        expect(L10n.t("going_play_filter", languageCode: "en") == "Filter", "Play still owns Filter")
        expect(
            L10n.t("going_watch_chip_a11y_one", languageCode: "en") == "%@, %d item",
            "a11y one"
        )
        expect(
            L10n.t("going_watch_chip_a11y_other", languageCode: "en") == "%@, %d items",
            "a11y other"
        )
        expect(L10n.t("going_play_upcoming", languageCode: "en") == "Upcoming", "25 Upcoming")
        expect(L10n.t("going_watch_chip_im_going", languageCode: "en") != "going_watch_chip_im_going", "I'm Going not raw key")
        expect(GoingWatchFilter.usesAlwaysVisibleChips, "Watch uses chips, not a dropdown")
        expect(GoingPlayFilter.allCases.contains(.invites), "Play Filter still exists")
        expect(GoingWatchFilterChipMetrics.height == 44, "Watch chip height 44")
        expect(GoingWatchFilterChipMetrics.minimumTapTarget == 44, "Watch chip tap target 44")
        expect(GoingWatchFilterChipMetrics.labelPointSize == 14, "Watch chip label 14")
        expect(GoingWatchFilterChipMetrics.countPointSize == 12, "Watch chip count 12")
        expect(GoingWatchFilterChipMetrics.countPointSize < GoingWatchFilterChipMetrics.labelPointSize, "count smaller than label")
        expect(GoingWatchFilterChipMetrics.iconPointSize == 12, "Watch chip icon 12")
        expect(GoingWatchFilterChipMetrics.horizontalPadding == 9, "Watch chip horizontal padding 9")
        expect(GoingWatchFilterChipMetrics.contentSpacing == 4, "Watch chip content spacing 4")
        expect(GoingWatchFilterChipMetrics.rowSpacing == 8, "Watch chip row spacing 8")
        expect(L10n.t("saved_spots", languageCode: "en").contains("…") == false, "Favorite Spots copy is not ellipsized")
        expect(L10n.t("saved_spots", languageCode: "en") == "Favorite Spots", "Favorite Spots copy unchanged")

        let catalogLanguages = ["en", "es", "fr", "pt", "de", "it", "pl", "ru", "sq", "zh-Hans", "nl"]
        for lang in catalogLanguages {
            for key in [
                "going_play_filter_all",
                "going_watch_chip_im_going",
                "saved_spots",
                "going_watch_chip_a11y_one",
                "going_watch_chip_a11y_other"
            ] {
                let value = L10n.t(key, languageCode: lang)
                expect(value != key, "\(lang) \(key) not raw key")
                expect(!value.isEmpty, "\(lang) \(key) non-empty")
            }
        }

        if failures == 0 {
            print("[GoingWatchTest] ALL PASSED")
        } else {
            print("[GoingWatchTest] FAILURES=\(failures)")
            assertionFailure("GoingWatchSelfTests failed: \(failures)")
        }
    }

    private static func stubGame(id: UUID, title: String) -> FollowingGoingDisplayItem {
        FollowingGoingDisplayItem(
            id: id,
            venueEvent: VenueEventRow(
                id: id,
                venue_id: nil,
                owner_email: nil,
                venue_name: "Delta Center",
                event_title: title,
                sport: "Basketball",
                home_team: nil,
                away_team: nil,
                external_league: nil,
                event_date: "2026-08-13",
                event_time: "19:30",
                external_game_id: nil,
                external_source: nil,
                imported_from_api: nil,
                sound_on: nil,
                drink_special: nil,
                cover_charge: nil,
                expected_crowd: nil,
                available_seating: nil,
                reservations_available: nil,
                waitlist_available: nil,
                audio_type: nil,
                admin_status: "active",
                scheduled_start_at: nil,
                cleanup_delay_hours: nil,
                purge_after_at: nil,
                created_at: nil
            ),
            bar: stubSpot(id: UUID(), name: "Delta Center"),
            attendeeCount: 1,
            isServerGoing: true,
            isInterestedOnlyLocal: false
        )
    }

    private static func stubSpot(id: UUID, name: String, address: String = "Sandy, UT") -> BarVenue {
        BarVenue(
            id: id,
            name: name,
            address: address,
            phone: "",
            primarySport: "Basketball",
            distance: "",
            rating: 0,
            tags: [],
            games: [],
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            goingCounts: [:]
        )
    }
}
#endif
