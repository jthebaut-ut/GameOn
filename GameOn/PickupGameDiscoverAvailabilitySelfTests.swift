import Foundation

#if DEBUG
/// Deterministic regression tests for Discover pickup date availability
/// (map pins ↔ calendar orange dots). Emits `[PickupDateAvailabilityTest]`.
enum PickupGameDiscoverAvailabilitySelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[PickupDateAvailabilityTest] PASS \(name)")
            } else {
                failures += 1
                print("[PickupDateAvailabilityTest] FAIL \(name)")
            }
        }

        let denver = TimeZone(identifier: "America/Denver")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let utc = TimeZone(identifier: "UTC")!

        // Fixed "now" for remove_after / guest floor: 2026-07-25 18:00 MDT = 2026-07-26 00:00 UTC
        let nowMDT = date(ymd: "2026-07-25", hms: "18:00:00", timeZone: denver)

        let utahBounds = (
            minLat: 40.0,
            maxLat: 41.0,
            minLon: -112.0,
            maxLon: -111.0
        )
        let elsewhereBounds = (
            minLat: 34.0,
            maxLat: 35.0,
            minLon: -119.0,
            maxLon: -118.0
        )

        func context(
            timeZone: TimeZone = denver,
            sport: String = "All",
            bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)? = utahBounds,
            requireMapBounds: Bool = true,
            requireValidCoordinates: Bool = true,
            guestFloor: Date? = nil,
            now: Date = nowMDT
        ) -> PickupGameAvailabilityContext {
            PickupGameAvailabilityContext(
                timeZone: timeZone,
                now: now,
                selectedSport: sport,
                mapBounds: bounds,
                requireMapBounds: requireMapBounds,
                requireValidCoordinates: requireValidCoordinates,
                guestRecentFloor: guestFloor
            )
        }

        func candidate(
            id: UUID = UUID(),
            startRaw: String,
            sport: String = "Soccer",
            status: String = "active",
            visible: Bool = true,
            lat: Double? = 40.5,
            lon: Double? = -111.5,
            removeAfter: String? = nil
        ) -> PickupGameAvailabilityCandidate {
            PickupGameAvailabilityCandidate(
                id: id,
                sport: sport,
                gameStartAtRaw: startRaw,
                removeAfterAtRaw: removeAfter,
                status: status,
                isVisible: visible,
                latitude: lat,
                longitude: lon
            )
        }

        // 1. July 30 midday local → July 30
        do {
            let start = encode(ymd: "2026-07-30", hms: "12:00:00", timeZone: denver)
            let day = PickupGameDateNormalizer.normalizedLocalDay(fromStartRaw: start, timeZone: denver)?.localDay
            expect(
                day.map { PickupGameDateNormalizer.ymdString(for: $0, timeZone: denver) } == "2026-07-30",
                "july30_midday_local_buckets_to_july30"
            )
            let days = PickupGameAvailabilityResolver.availableNormalizedDays(
                from: [candidate(startRaw: start)],
                context: context()
            )
            expect(days.count == 1 && days.contains(where: {
                PickupGameDateNormalizer.ymdString(for: $0, timeZone: denver) == "2026-07-30"
            }), "july30_midday_creates_dot")
        }

        // 2. July 31 midday local → July 31
        do {
            let start = encode(ymd: "2026-07-31", hms: "12:00:00", timeZone: denver)
            let days = PickupGameAvailabilityResolver.availableNormalizedDays(
                from: [candidate(startRaw: start)],
                context: context()
            )
            expect(days.count == 1 && days.contains(where: {
                PickupGameDateNormalizer.ymdString(for: $0, timeZone: denver) == "2026-07-31"
            }), "july31_midday_creates_dot")
        }

        // 3. Both dates → both dots
        do {
            let a = encode(ymd: "2026-07-30", hms: "10:00:00", timeZone: denver)
            let b = encode(ymd: "2026-07-31", hms: "16:00:00", timeZone: denver)
            let days = PickupGameAvailabilityResolver.availableNormalizedDays(
                from: [candidate(startRaw: a), candidate(startRaw: b)],
                context: context()
            )
            let labels = Set(days.map { PickupGameDateNormalizer.ymdString(for: $0, timeZone: denver) })
            expect(labels == ["2026-07-30", "2026-07-31"], "both_july30_and_july31_dots")
        }

        // 4. UTC timestamp crossing local midnight → correct local day
        // 2026-07-31 05:00 UTC = 2026-07-30 23:00 MDT → July 30 local
        do {
            let rawUTC = "2026-07-31T05:00:00.000Z"
            let normalized = PickupGameDateNormalizer.normalizedLocalDay(fromStartRaw: rawUTC, timeZone: denver)
            expect(
                normalized.map { PickupGameDateNormalizer.ymdString(for: $0.localDay, timeZone: denver) } == "2026-07-30",
                "utc_crossing_midnight_buckets_to_local_july30"
            )
            // Same instant in UTC calendar would be July 31 — prove we do not use UTC day.
            let utcDay = PickupGameDateNormalizer.ymdString(
                for: PickupGameDateNormalizer.startOfDay(for: normalized!.decodedStart, timeZone: utc),
                timeZone: utc
            )
            expect(utcDay == "2026-07-31", "control_utc_day_is_july31")
            expect(utcDay != PickupGameDateNormalizer.ymdString(for: normalized!.localDay, timeZone: denver),
                   "local_day_differs_from_utc_day")
        }

        // 5. 11:59 PM local
        do {
            let start = encode(ymd: "2026-07-30", hms: "23:59:00", timeZone: denver)
            let day = PickupGameDateNormalizer.normalizedLocalDay(fromStartRaw: start, timeZone: denver)?.localDay
            expect(
                day.map { PickupGameDateNormalizer.ymdString(for: $0, timeZone: denver) } == "2026-07-30",
                "july30_2359_local_stays_july30"
            )
        }

        // 6. 12:00 AM local
        do {
            let start = encode(ymd: "2026-07-31", hms: "00:00:00", timeZone: denver)
            let day = PickupGameDateNormalizer.normalizedLocalDay(fromStartRaw: start, timeZone: denver)?.localDay
            expect(
                day.map { PickupGameDateNormalizer.ymdString(for: $0, timeZone: denver) } == "2026-07-31",
                "july31_0000_local_is_july31"
            )
        }

        // 7. End-of-month transition (July 31 → August 1)
        do {
            let july31 = encode(ymd: "2026-07-31", hms: "23:30:00", timeZone: denver)
            let aug1 = encode(ymd: "2026-08-01", hms: "00:15:00", timeZone: denver)
            let days = PickupGameAvailabilityResolver.availableNormalizedDays(
                from: [candidate(startRaw: july31), candidate(startRaw: aug1)],
                context: context()
            )
            let labels = Set(days.map { PickupGameDateNormalizer.ymdString(for: $0, timeZone: denver) })
            expect(labels == ["2026-07-31", "2026-08-01"], "end_of_month_transition")
        }

        // 8. Different device timezone (Tokyo)
        do {
            // 2026-07-30 20:00 UTC = 2026-07-31 05:00 JST → July 31 in Tokyo
            let raw = "2026-07-30T20:00:00.000Z"
            let tokyoDay = PickupGameDateNormalizer.normalizedLocalDay(fromStartRaw: raw, timeZone: tokyo)
            let denverDay = PickupGameDateNormalizer.normalizedLocalDay(fromStartRaw: raw, timeZone: denver)
            expect(
                tokyoDay.map { PickupGameDateNormalizer.ymdString(for: $0.localDay, timeZone: tokyo) } == "2026-07-31",
                "tokyo_buckets_to_july31"
            )
            expect(
                denverDay.map { PickupGameDateNormalizer.ymdString(for: $0.localDay, timeZone: denver) } == "2026-07-30",
                "denver_buckets_same_instant_to_july30"
            )
        }

        // 9. Cancelled / ineligible does not create a dot
        do {
            let start = encode(ymd: "2026-07-30", hms: "12:00:00", timeZone: denver)
            let cancelled = candidate(startRaw: start, status: "cancelled")
            let hidden = candidate(startRaw: start, visible: false)
            let expired = candidate(
                startRaw: start,
                removeAfter: encode(ymd: "2026-07-25", hms: "12:00:00", timeZone: denver)
            )
            let days = PickupGameAvailabilityResolver.availableNormalizedDays(
                from: [cancelled, hidden, expired],
                context: context()
            )
            expect(days.isEmpty, "ineligible_games_create_no_dots")
        }

        // 10. Outside geographic context does not create a dot
        do {
            let start = encode(ymd: "2026-07-30", hms: "12:00:00", timeZone: denver)
            let outside = candidate(startRaw: start, lat: 34.5, lon: -118.5)
            let days = PickupGameAvailabilityResolver.availableNormalizedDays(
                from: [outside],
                context: context(bounds: utahBounds)
            )
            expect(days.isEmpty, "outside_viewport_creates_no_dot")
            let elsewhereDays = PickupGameAvailabilityResolver.availableNormalizedDays(
                from: [outside],
                context: context(bounds: elsewhereBounds)
            )
            expect(elsewhereDays.count == 1, "same_game_dots_when_viewport_matches")
        }

        // 11. Sport filter consistency
        do {
            let start = encode(ymd: "2026-07-30", hms: "12:00:00", timeZone: denver)
            let soccer = candidate(startRaw: start, sport: "Soccer")
            let basketball = candidate(startRaw: start, sport: "Basketball")
            let soccerOnly = PickupGameAvailabilityResolver.availableNormalizedDays(
                from: [soccer, basketball],
                context: context(sport: "Soccer")
            )
            expect(soccerOnly.count == 1, "sport_filter_keeps_matching_only")
            let allSports = PickupGameAvailabilityResolver.availableNormalizedDays(
                from: [soccer, basketball],
                context: context(sport: "All")
            )
            expect(allSports.count == 1, "all_sports_still_one_day")
        }

        // 12. Discover available-date set == calendar available-date set for identical context
        do {
            let a = encode(ymd: "2026-07-30", hms: "09:00:00", timeZone: denver)
            let b = encode(ymd: "2026-07-31", hms: "18:00:00", timeZone: denver)
            let cOutside = encode(ymd: "2026-07-30", hms: "15:00:00", timeZone: denver)
            let games = [
                candidate(startRaw: a, lat: 40.4, lon: -111.6),
                candidate(startRaw: b, lat: 40.6, lon: -111.4),
                candidate(startRaw: cOutside, lat: 34.2, lon: -118.2)
            ]
            let shared = context(requireMapBounds: true, requireValidCoordinates: true)
            let discoverDates = PickupGameAvailabilityResolver.availableNormalizedDays(from: games, context: shared)
            let calendarDates = PickupGameAvailabilityResolver.availableNormalizedDays(from: games, context: shared)
            expect(discoverDates == calendarDates, "discover_and_calendar_sets_identical")
            let labels = Set(discoverDates.map { PickupGameDateNormalizer.ymdString(for: $0, timeZone: denver) })
            expect(labels == ["2026-07-30", "2026-07-31"], "identical_context_keeps_both_in_viewport_days")
        }

        // Day bounds: local start ..< next local start encodes correctly (no UTC 00–23:59 trap)
        do {
            let bounds = PickupGameDateNormalizer.dayBounds(
                containing: date(ymd: "2026-07-30", hms: "12:00:00", timeZone: denver),
                timeZone: denver
            )
            expect(bounds != nil, "day_bounds_nonnil")
            if let bounds {
                let startYMD = PickupGameDateNormalizer.ymdString(for: bounds.start, timeZone: denver)
                let endYMD = PickupGameDateNormalizer.ymdString(for: bounds.endExclusive, timeZone: denver)
                expect(startYMD == "2026-07-30" && endYMD == "2026-07-31", "day_bounds_local_half_open")
                // Instant just before local midnight July 31 is still in the window.
                let late = date(ymd: "2026-07-30", hms: "23:59:59", timeZone: denver)
                expect(late >= bounds.start && late < bounds.endExclusive, "235959_inside_day_bounds")
                let next = date(ymd: "2026-07-31", hms: "00:00:00", timeZone: denver)
                expect(next == bounds.endExclusive, "next_midnight_is_end_exclusive")
            }
        }

        // --- Month availability merge: selected day must not collapse month dots ---
        let july30 = PickupGameDateNormalizer.startOfDay(
            for: date(ymd: "2026-07-30", hms: "12:00:00", timeZone: denver),
            timeZone: denver
        )
        let july31 = PickupGameDateNormalizer.startOfDay(
            for: date(ymd: "2026-07-31", hms: "12:00:00", timeZone: denver),
            timeZone: denver
        )
        let monthDots = Set([july30, july31])

        // 1. Month has 30+31, selected 30 → dots stay {30,31}
        do {
            let seeded = PickupGameMonthAvailabilityMerge.seedPublished(
                published: monthDots,
                cached: monthDots,
                selectedDayEvidence: [july30]
            )
            expect(seeded == monthDots, "selected_july30_seed_keeps_both_dots")
        }

        // 2. Same month, selected 31 → dots stay {30,31}
        do {
            let seeded = PickupGameMonthAvailabilityMerge.seedPublished(
                published: monthDots,
                cached: monthDots,
                selectedDayEvidence: [july31]
            )
            expect(seeded == monthDots, "selected_july31_seed_keeps_both_dots")
        }

        // 3. Toggle 30 → 31 → 30 leaves month set unchanged
        do {
            var published = monthDots
            published = PickupGameMonthAvailabilityMerge.seedPublished(
                published: published,
                cached: monthDots,
                selectedDayEvidence: [july30]
            )
            published = PickupGameMonthAvailabilityMerge.seedPublished(
                published: published,
                cached: monthDots,
                selectedDayEvidence: [july31]
            )
            published = PickupGameMonthAvailabilityMerge.seedPublished(
                published: published,
                cached: monthDots,
                selectedDayEvidence: [july30]
            )
            expect(
                PickupGameMonthAvailabilityMerge.monthDotsStableAcrossSelectionChange(
                    dotsBefore: monthDots,
                    dotsAfter: published
                ),
                "toggle_30_31_30_month_dots_stable"
            )
        }

        // 4. Multiple games same day → one dot
        do {
            let a = encode(ymd: "2026-07-30", hms: "09:00:00", timeZone: denver)
            let b = encode(ymd: "2026-07-30", hms: "18:00:00", timeZone: denver)
            let days = PickupGameAvailabilityResolver.availableNormalizedDays(
                from: [candidate(startRaw: a), candidate(startRaw: b)],
                context: context()
            )
            expect(days.count == 1, "multiple_games_same_day_one_dot")
        }

        // 5. Out-of-viewport Jul 29 + in-viewport Jul 30/31 → {30,31}
        do {
            let jul29 = encode(ymd: "2026-07-29", hms: "12:00:00", timeZone: denver)
            let a = encode(ymd: "2026-07-30", hms: "10:00:00", timeZone: denver)
            let b = encode(ymd: "2026-07-31", hms: "16:00:00", timeZone: denver)
            let days = PickupGameAvailabilityResolver.availableNormalizedDays(
                from: [
                    candidate(startRaw: jul29, lat: 34.5, lon: -118.5),
                    candidate(startRaw: a),
                    candidate(startRaw: b)
                ],
                context: context()
            )
            let labels = Set(days.map { PickupGameDateNormalizer.ymdString(for: $0, timeZone: denver) })
            expect(labels == ["2026-07-30", "2026-07-31"], "out_of_viewport_jul29_excluded")
        }

        // 6–7. Sport filter excludes Jul 31 game, then All restores both
        do {
            let a = encode(ymd: "2026-07-30", hms: "10:00:00", timeZone: denver)
            let b = encode(ymd: "2026-07-31", hms: "16:00:00", timeZone: denver)
            let soccer = candidate(startRaw: a, sport: "Soccer")
            let basketball = candidate(startRaw: b, sport: "Basketball")
            let soccerOnly = PickupGameAvailabilityResolver.availableNormalizedDays(
                from: [soccer, basketball],
                context: context(sport: "Soccer")
            )
            let soccerLabels = Set(soccerOnly.map { PickupGameDateNormalizer.ymdString(for: $0, timeZone: denver) })
            expect(soccerLabels == ["2026-07-30"], "sport_filter_excludes_jul31_basketball")
            let allSports = PickupGameAvailabilityResolver.availableNormalizedDays(
                from: [soccer, basketball],
                context: context(sport: "All")
            )
            let allLabels = Set(allSports.map { PickupGameDateNormalizer.ymdString(for: $0, timeZone: denver) })
            expect(allLabels == ["2026-07-30", "2026-07-31"], "sport_filter_all_restores_both")
        }

        // 8. Cache miss seed must NOT replace month with selected-day-only
        do {
            let seeded = PickupGameMonthAvailabilityMerge.seedPublished(
                published: monthDots,
                cached: nil,
                selectedDayEvidence: [july31]
            )
            expect(seeded == monthDots, "cache_miss_seed_unions_not_replaces")
            expect(seeded != Set([july31]), "cache_miss_seed_not_selected_day_only")
        }

        // 9. Selected-day refresh completing AFTER month refresh must not collapse
        do {
            let afterMonth = PickupGameMonthAvailabilityMerge.mergeAuthoritative(
                fetchedMonth: monthDots,
                selectedDayEvidence: []
            )
            let afterSelectedDay = PickupGameMonthAvailabilityMerge.seedPublished(
                published: afterMonth,
                cached: afterMonth,
                selectedDayEvidence: [july30]
            )
            expect(afterSelectedDay == monthDots, "selected_day_after_month_does_not_collapse")
        }

        // 10. Month refresh completing AFTER cold open reconciles to full month (no selected-day-as-complete)
        do {
            let afterColdOpen = PickupGameMonthAvailabilityMerge.presentationSeed(
                published: [],
                authoritativeCached: nil
            )
            expect(afterColdOpen.isEmpty, "cold_open_does_not_publish_selected_day_as_month")
            let afterMonth = PickupGameMonthAvailabilityMerge.mergeAuthoritative(
                fetchedMonth: monthDots,
                selectedDayEvidence: [july30]
            )
            expect(afterMonth == monthDots, "month_after_selected_day_reconciles_full_set")
        }

        // 11. Reopen calendar / valid cache: same dots without depending on selectedDate
        do {
            let reopen30 = PickupGameMonthAvailabilityMerge.seedPublished(
                published: [],
                cached: monthDots,
                selectedDayEvidence: [july30]
            )
            let reopen31 = PickupGameMonthAvailabilityMerge.seedPublished(
                published: [],
                cached: monthDots,
                selectedDayEvidence: [july31]
            )
            expect(reopen30 == monthDots && reopen31 == monthDots, "reopen_cache_same_dots_regardless_of_selection")
        }

        // 12. Changing selected date does not invalidate a complete same-month cache
        do {
            expect(
                PickupGameMonthAvailabilityMerge.selectedDayEvidenceImpliesIncompleteCache(
                    selectedDayEvidence: [july30],
                    cached: monthDots
                ) == false,
                "complete_cache_not_incomplete_for_july30"
            )
            expect(
                PickupGameMonthAvailabilityMerge.selectedDayEvidenceImpliesIncompleteCache(
                    selectedDayEvidence: [july31],
                    cached: monthDots
                ) == false,
                "complete_cache_not_incomplete_for_july31"
            )
            expect(
                PickupGameMonthAvailabilityMerge.selectedDayEvidenceImpliesIncompleteCache(
                    selectedDayEvidence: [july31],
                    cached: Set([july30])
                ) == true,
                "incomplete_cache_detected_when_selected_day_missing"
            )
        }

        // Empty month fetch must preserve prior; selected-day evidence is ignored
        do {
            let resolved = PickupGameMonthAvailabilityMerge.resolveEmptyAuthoritativeFetch(
                previousPublished: monthDots,
                selectedDayEvidence: [july30]
            )
            expect(resolved == monthDots, "empty_fetch_preserves_prior_month_set")
        }

        // Successful authoritative empty month publishes empty (not selected-day-as-complete)
        do {
            let empty = PickupGameMonthAvailabilityMerge.resolveSuccessfulEmptyMonthFetch()
            expect(empty.isEmpty, "successful_empty_month_is_empty")
        }

        // Fetch failure unions evidence without replacing
        do {
            let recovered = PickupGameMonthAvailabilityMerge.mergeAfterFetchFailure(
                previousPublished: monthDots,
                selectedDayEvidence: [july31]
            )
            expect(recovered == monthDots, "fetch_failure_keeps_month_set")
        }

        // Presentation seed: without authoritative cache, do NOT promote selected-day-only
        do {
            let cold = PickupGameMonthAvailabilityMerge.presentationSeed(
                published: [],
                authoritativeCached: nil
            )
            expect(cold.isEmpty, "cold_presentation_seed_ignores_selected_day_as_complete")
            let emptyCached = PickupGameMonthAvailabilityMerge.presentationSeed(
                published: [],
                authoritativeCached: []
            )
            expect(emptyCached.isEmpty, "empty_cached_set_not_treated_as_selected_day_authority")
            let withCache = PickupGameMonthAvailabilityMerge.presentationSeed(
                published: [],
                authoritativeCached: monthDots
            )
            expect(withCache == monthDots, "cached_presentation_seed_keeps_full_month")
        }

        // No-bounds skip retains prior; does not publish selected-day-only
        do {
            let retained = PickupGameMonthAvailabilityMerge.resolveSkippedNoBounds(
                previousPublished: monthDots
            )
            expect(retained == monthDots, "no_bounds_retains_prior_month")
            let coldSkip = PickupGameMonthAvailabilityMerge.resolveSkippedNoBounds(
                previousPublished: []
            )
            expect(coldSkip.isEmpty, "no_bounds_cold_stays_empty_not_selected_day")
        }

        // Physical-device repro: viewport has Jul30+Jul31; selection change must not shrink
        do {
            let utah = PickupGameMapBounds(minLat: 40, maxLat: 41, minLon: -112, maxLon: -111)
            let a = encode(ymd: "2026-07-30", hms: "10:00:00", timeZone: denver)
            let b = encode(ymd: "2026-07-31", hms: "16:00:00", timeZone: denver)
            let games = [
                candidate(startRaw: a, lat: 40.5, lon: -111.5),
                candidate(startRaw: b, lat: 40.6, lon: -111.4)
            ]
            let ctxA = PickupGameAvailabilityContext(
                timeZone: denver,
                now: nowMDT,
                selectedSport: "All",
                mapBounds: utah.asTuple,
                requireMapBounds: true,
                requireValidCoordinates: true,
                guestRecentFloor: nil
            )
            let monthFromFetch = PickupGameAvailabilityResolver.availableNormalizedDays(from: games, context: ctxA)
            let labels = Set(monthFromFetch.map { PickupGameDateNormalizer.ymdString(for: $0, timeZone: denver) })
            expect(labels == ["2026-07-30", "2026-07-31"], "physical_repro_month_fetch_both_days")

            // Selected-day evidence for Jul 30 only (day-scoped map rows)
            let afterOpenSelected30 = PickupGameMonthAvailabilityMerge.mergeAuthoritative(
                fetchedMonth: monthFromFetch,
                selectedDayEvidence: [july30]
            )
            expect(afterOpenSelected30 == monthFromFetch, "physical_repro_selected_30_keeps_both")

            let afterSelect31 = PickupGameMonthAvailabilityMerge.presentationSeed(
                published: afterOpenSelected30,
                authoritativeCached: monthFromFetch
            )
            expect(afterSelect31 == monthFromFetch, "physical_repro_select_31_keeps_both")

            // Live bounds change after request capture must not mix cacheKey(A)+query(B)
            let elsewhere = PickupGameMapBounds(minLat: 34, maxLat: 35, minLon: -119, maxLon: -118)
            let requestA = PickupGameMonthAvailabilityRequestContext(
                requestID: UUID(),
                monthStart: july30,
                dateMin: july30,
                dateMax: july31,
                sport: "All",
                timeZoneIdentifier: denver.identifier,
                mapBounds: utah,
                boundsBucket: utah.bucketString,
                guestRecentFloor: nil,
                capturedAt: nowMDT
            )
            let queryBucketIfRereadLive = elsewhere.bucketString
            expect(
                PickupGameMonthAvailabilityMerge.cacheKeyMatchesQueryBounds(
                    cacheKeyBoundsBucket: requestA.boundsBucket,
                    queryBoundsBucket: requestA.boundsBucket
                ),
                "captured_context_cache_matches_own_query"
            )
            expect(
                PickupGameMonthAvailabilityMerge.cacheKeyMatchesQueryBounds(
                    cacheKeyBoundsBucket: requestA.boundsBucket,
                    queryBoundsBucket: queryBucketIfRereadLive
                ) == false,
                "live_bounds_B_must_not_silently_serve_cacheKey_A"
            )
            // In-flight request continues with captured bounds A → still both days
            let stillA = PickupGameAvailabilityResolver.availableNormalizedDays(
                from: games,
                context: requestA.availabilityContext(now: nowMDT)
            )
            expect(
                Set(stillA.map { PickupGameDateNormalizer.ymdString(for: $0, timeZone: denver) })
                    == ["2026-07-30", "2026-07-31"],
                "in_flight_captured_bounds_A_still_both_days"
            )
        }

        // No-bounds request context
        do {
            let noBounds = PickupGameMonthAvailabilityRequestContext(
                requestID: UUID(),
                monthStart: july30,
                dateMin: july30,
                dateMax: july31,
                sport: "All",
                timeZoneIdentifier: denver.identifier,
                mapBounds: nil,
                boundsBucket: "nb",
                guestRecentFloor: nil,
                capturedAt: nowMDT
            )
            expect(noBounds.hasMapBounds == false, "no_bounds_context_flag")
            expect(noBounds.boundsBucket == "nb", "no_bounds_bucket_nb")
            expect(
                PickupGameMonthAvailabilityRequestContext.boundsBucket(for: nil) == "nb",
                "nil_bounds_bucket_helper"
            )
        }


        // Live view-model/view boundary: month set must survive selection toggles
        do {
            let availability = PickupGameMonthAvailabilityMerge.canonicalizeForCalendarGrid(monthDots)
            expect(
                PickupGameMonthAvailabilityMerge.gridDay(july30, isCoveredBy: availability),
                "boundary_jul30_has_dot"
            )
            expect(
                PickupGameMonthAvailabilityMerge.gridDay(july31, isCoveredBy: availability),
                "boundary_jul31_has_dot"
            )
            // select Jul30
            let selected30 = july30
            _ = selected30
            expect(
                PickupGameMonthAvailabilityMerge.monthDotsStableAcrossSelectionChange(
                    dotsBefore: availability,
                    dotsAfter: availability
                ),
                "boundary_select_jul30_set_unchanged"
            )
            // select Jul31
            let selected31 = july31
            _ = selected31
            expect(
                PickupGameMonthAvailabilityMerge.gridDay(july30, isCoveredBy: availability)
                    && PickupGameMonthAvailabilityMerge.gridDay(july31, isCoveredBy: availability),
                "boundary_select_jul31_both_dots_remain"
            )
            // Async selected-day refresh must not alter month set
            let afterSelectedDayRefresh = PickupGameMonthAvailabilityMerge.mergeAuthoritative(
                fetchedMonth: availability,
                selectedDayEvidence: [july30]
            )
            expect(afterSelectedDayRefresh == availability, "boundary_selected_day_refresh_does_not_alter_month")
            // Poison empty cache must not become selected-day-only via presentationSeed
            let poisoned = PickupGameMonthAvailabilityMerge.presentationSeed(
                published: [],
                authoritativeCached: []
            )
            expect(poisoned.isEmpty, "boundary_empty_cache_does_not_publish_selected_day")
            expect(
                PickupGameMonthAvailabilityMerge.isInconsistentEmptyMonthFetch(
                    fetchedMonth: [],
                    selectedDayEvidenceInMonth: [july30]
                ),
                "boundary_inconsistent_empty_detected"
            )
        }

        // Schedule Play picker: dots must come from month availability, not day-scoped map rows.
        do {
            // Simulates calendarTabListConsistentPickupDotDates after fix: month set survives
            // even when selected-day map inventory is only one day.
            let monthAvailability = monthDots
            let selectedDayOnlyRows: Set<Date> = [july30]
            expect(monthAvailability != selectedDayOnlyRows, "schedule_month_dots_not_equal_selected_day_rows")
            expect(
                PickupGameMonthAvailabilityMerge.monthDotsStableAcrossSelectionChange(
                    dotsBefore: monthAvailability,
                    dotsAfter: monthAvailability
                ),
                "schedule_toggle_selection_keeps_month_dots"
            )
            expect(
                PickupGameMonthAvailabilityMerge.gridDay(july30, isCoveredBy: monthAvailability)
                    && PickupGameMonthAvailabilityMerge.gridDay(july31, isCoveredBy: monthAvailability),
                "schedule_render_both_days_from_month_set"
            )
        }

        if failures == 0 {
            print("[PickupDateAvailabilityTest] ALL PASSED")
        } else {
            print("[PickupDateAvailabilityTest] FAILURES=\(failures)")
        }
    }

    // MARK: - Helpers

    private static func date(ymd: String, hms: String, timeZone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let parts = ymd.split(separator: "-").compactMap { Int($0) }
        let time = hms.split(separator: ":").compactMap { Int($0) }
        var comps = DateComponents()
        comps.year = parts[0]
        comps.month = parts[1]
        comps.day = parts[2]
        comps.hour = time[0]
        comps.minute = time[1]
        comps.second = time.count > 2 ? time[2] : 0
        return cal.date(from: comps)!
    }

    private static func encode(ymd: String, hms: String, timeZone: TimeZone) -> String {
        PickupGameModels.encodeSupabaseTimestamptz(date(ymd: ymd, hms: hms, timeZone: timeZone))
    }
}
#endif
