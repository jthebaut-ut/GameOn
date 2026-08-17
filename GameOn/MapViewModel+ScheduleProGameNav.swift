import CoreLocation
import Foundation
import Supabase

/// Pending Discover → Schedule handoff for one professional game.
struct ScheduleProGameNavIntent: Equatable, Sendable {
    let matchId: String
    let stableKey: String
    let startTime: Date
}

/// Authoritative Discover focus for a professional game.
/// Identity: ``externalGameId`` == ``LiveMatch/id`` == ``VenueEventRow/external_game_id``.
struct DiscoverFocusedProGame: Equatable, Sendable, Identifiable {
    var id: String { externalGameId }
    let externalGameId: String
    let stableKey: String
    let displayTitle: String
    let startTime: Date?

    static func from(match: LiveMatch) -> DiscoverFocusedProGame? {
        let externalGameId = match.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !externalGameId.isEmpty else { return nil }
        let title = matchTitle(match)
        return DiscoverFocusedProGame(
            externalGameId: externalGameId,
            stableKey: SavedProGame.stableKey(for: match),
            displayTitle: title,
            startTime: match.startTime
        )
    }

    private static func matchTitle(_ match: LiveMatch) -> String {
        let home = match.homeTeam.trimmingCharacters(in: .whitespacesAndNewlines)
        let away = match.awayTeam.trimmingCharacters(in: .whitespacesAndNewlines)
        if !home.isEmpty, !away.isEmpty {
            return "\(away) vs \(home)"
        }
        let league = match.league.trimmingCharacters(in: .whitespacesAndNewlines)
        return league.isEmpty ? "Selected game" : league
    }
}

extension MapViewModel {
    /// Enqueue Schedule Pro Games navigation for a Discover match-detail CTA.
    @MainActor
    func enqueueScheduleProGameNav(match: LiveMatch) {
        let matchId = match.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableKey = SavedProGame.stableKey(for: match)
        let intent = ScheduleProGameNavIntent(
            matchId: matchId,
            stableKey: stableKey,
            startTime: match.startTime
        )
        pendingScheduleProGameNav = intent
        scheduleProGameHighlightStableKey = nil
        calendarTabSelectedDate = Calendar.current.startOfDay(for: match.startTime)
        requestScheduleHubSurface(.pro)
        requestedMainTabRaw = MainTabView.AppTab.calendar.rawValue
#if DEBUG
        print(
            "[ScheduleProGameNav] enqueue matchId=\(matchId.isEmpty ? "nil" : matchId) stableKey=\(stableKey) start=\(match.startTime)"
        )
#endif
    }

    @MainActor
    func clearPendingScheduleProGameNav() {
        pendingScheduleProGameNav = nil
    }

    @MainActor
    func clearScheduleProGameHighlight() {
        scheduleProGameHighlightStableKey = nil
    }

    /// Resolve a live match for Schedule deep-link using strongest available identity.
    @MainActor
    func resolveLiveMatchForScheduleProGameNav(_ intent: ScheduleProGameNavIntent) -> LiveMatch? {
        let matchId = intent.matchId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !matchId.isEmpty,
           let byId = liveMatches.first(where: {
               $0.id.trimmingCharacters(in: .whitespacesAndNewlines) == matchId
           }) {
            return byId
        }
        let key = intent.stableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return liveMatches.first(where: { SavedProGame.stableKey(for: $0) == key })
    }

    // MARK: - Discover focused pro game

    @MainActor
    func setDiscoverFocusedProGame(from match: LiveMatch, alignSelectedDate: Bool = true) {
        guard let focus = DiscoverFocusedProGame.from(match: match) else {
            clearDiscoverFocusedProGame(reason: "emptyMatchId")
            return
        }
        if alignSelectedDate, let start = focus.startTime {
            selectedDate = Calendar.current.startOfDay(for: start)
        }
        discoverFocusedProGame = focus
#if DEBUG
        print(
            "[DiscoverFocusedProGame] set id=\(focus.externalGameId) title=\(focus.displayTitle)"
        )
#endif
    }

    @MainActor
    func clearDiscoverFocusedProGame(reason: String = "clear") {
        guard discoverFocusedProGame != nil else { return }
        discoverFocusedProGame = nil
        discoverTopVenuesForFocusedGame = []
        discoverTopVenuesForFocusedGameState = .idle
        discoverTopVenuesRefreshTask?.cancel()
        discoverTopVenuesRefreshTask = nil
#if DEBUG
        print("[DiscoverFocusedProGame] cleared reason=\(reason)")
#endif
    }

    @MainActor
    func scheduleDiscoverTopVenuesForFocusedGameRefresh(reason: String) {
        guard discoverFocusedProGame != nil else {
            discoverTopVenuesForFocusedGame = []
            discoverTopVenuesForFocusedGameState = .idle
            return
        }
        discoverTopVenuesRefreshTask?.cancel()
        discoverTopVenuesRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 220_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self.refreshDiscoverTopVenuesForFocusedGame(reason: reason)
        }
    }

    @MainActor
    func refreshDiscoverTopVenuesForFocusedGame(reason: String) async {
        guard let focus = discoverFocusedProGame else {
            discoverTopVenuesForFocusedGame = []
            discoverTopVenuesForFocusedGameState = .idle
            return
        }
        discoverTopVenuesForFocusedGameState = .loading
        let result = await loadDiscoverWatchSpots(
            externalGameID: focus.externalGameId,
            mapBounds: currentMapRegionBounds(),
            limit: DiscoverGameVenueRanking.topLimit
        )
        guard !Task.isCancelled else { return }
        guard discoverFocusedProGame?.externalGameId == focus.externalGameId else { return }
        discoverTopVenuesForFocusedGameState = result
        if case .loaded(let spots) = result {
            discoverTopVenuesForFocusedGame = spots
        } else if case .unavailable = result {
            discoverTopVenuesForFocusedGame = []
        }
#if DEBUG
        print(
            "[DiscoverTopVenues] reason=\(reason) game=\(focus.externalGameId) state=\(String(describing: result))"
        )
#endif
    }

    // MARK: - Discover Watch Spots for a professional game (region-bounded)

    struct DiscoverProGameWatchSpot: Identifiable, Equatable {
        let id: UUID
        let bar: BarVenue
        let venueEventID: UUID?
        let eventTitle: String?
        let distanceFromRegionCenterMiles: Double?
        let gameSpecificEnergy: Int
        let goingCount: Int
        let isLiveNow: Bool

        var energyTier: VenueMapEnergyScore.EnergyTier {
            VenueMapEnergyScore.tier(for: gameSpecificEnergy)
        }

        var energyCaption: String {
            DiscoverGameVenueRanking.tierCaption(forEnergy: gameSpecificEnergy)
        }
    }

    enum DiscoverProGameWatchSpotsLoadState: Equatable {
        case idle
        case loading
        case loaded([DiscoverProGameWatchSpot])
        case unavailable
    }

    /// Confirmed watch spots hosting this exact pro game inside the active Discover map/search region.
    /// Matching requires ``VenueEventRow/external_game_id`` == ``LiveMatch/id`` (canonical import identity).
    /// Ranked by game-specific ``VenueMapEnergyScore`` (not general venue-day energy).
    @MainActor
    func loadDiscoverWatchSpots(
        for match: LiveMatch,
        mapBounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)?,
        limit: Int = DiscoverGameVenueRanking.topLimit
    ) async -> DiscoverProGameWatchSpotsLoadState {
        let externalGameID = match.id.trimmingCharacters(in: .whitespacesAndNewlines)
        return await loadDiscoverWatchSpots(
            externalGameID: externalGameID,
            mapBounds: mapBounds,
            limit: limit
        )
    }

    @MainActor
    func loadDiscoverWatchSpots(
        externalGameID: String,
        mapBounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)?,
        limit: Int = DiscoverGameVenueRanking.topLimit
    ) async -> DiscoverProGameWatchSpotsLoadState {
        let externalGameID = externalGameID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !externalGameID.isEmpty else {
#if DEBUG
            print("[DiscoverProGameWatchSpots] skipped reason=emptyMatchId")
#endif
            return .loaded([])
        }

        let regionBars = discoverBarsInMapBounds(mapBounds)
        let regionVenueIDs = Set(regionBars.map(\.id))
        guard !regionVenueIDs.isEmpty else {
#if DEBUG
            print("[DiscoverProGameWatchSpots] empty region venue set matchId=\(externalGameID)")
#endif
            return .loaded([])
        }

        let barsByID = Dictionary(uniqueKeysWithValues: regionBars.map { ($0.id, $0) })
        let regionCenter: CLLocation? = {
            guard let mapBounds else { return nil }
            return CLLocation(
                latitude: (mapBounds.minLat + mapBounds.maxLat) / 2,
                longitude: (mapBounds.minLon + mapBounds.maxLon) / 2
            )
        }()

        // Prefer already-loaded Discover venue-event rows (same region/date pipeline).
        var matchedRows = venueEventRows.filter { row in
            let rowGameID = row.external_game_id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard rowGameID == externalGameID else { return false }
            let status = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if !status.isEmpty, status != "active" { return false }
            guard let venueID = row.venue_id, regionVenueIDs.contains(venueID) else { return false }
            return true
        }

        // If in-memory rows miss this game (e.g. Discover date ≠ match day), fetch only for viewport venue IDs.
        if matchedRows.isEmpty {
            do {
                matchedRows = try await fetchActiveVenueEventsHostingExternalGame(
                    externalGameID: externalGameID,
                    venueIDs: Array(regionVenueIDs)
                )
            } catch {
#if DEBUG
                print("[DiscoverProGameWatchSpots] fetchFailed matchId=\(externalGameID) error=\(error.localizedDescription)")
#endif
                return .unavailable
            }
        }

        var bestRowByVenue: [UUID: VenueEventRow] = [:]
        for row in matchedRows {
            guard let venueID = row.venue_id else { continue }
            if let existing = bestRowByVenue[venueID] {
                let existingScore = gameSpecificEnergy(for: existing)
                let nextScore = gameSpecificEnergy(for: row)
                if nextScore.energy > existingScore.energy
                    || (nextScore.energy == existingScore.energy && nextScore.going > existingScore.going)
                    || (nextScore.energy == existingScore.energy
                        && nextScore.going == existingScore.going
                        && (row.id?.uuidString ?? "") < (existing.id?.uuidString ?? "")) {
                    bestRowByVenue[venueID] = row
                }
            } else {
                bestRowByVenue[venueID] = row
            }
        }

        var candidates: [DiscoverGameVenueRanking.Candidate] = []
        candidates.reserveCapacity(bestRowByVenue.count)
        var spotsByID: [UUID: DiscoverProGameWatchSpot] = [:]

        for (venueID, row) in bestRowByVenue {
            guard let bar = barsByID[venueID] ?? bars.first(where: { $0.id == venueID }) else { continue }
            let scored = gameSpecificEnergy(for: row)
            let distanceMiles: Double? = {
                guard let regionCenter else { return nil }
                let venueLocation = CLLocation(
                    latitude: bar.coordinate.latitude,
                    longitude: bar.coordinate.longitude
                )
                return venueLocation.distance(from: regionCenter) / 1609.344
            }()

            let candidate = DiscoverGameVenueRanking.Candidate(
                id: venueID,
                venueName: bar.name,
                gameSpecificEnergy: scored.energy,
                goingCount: scored.going,
                distanceMiles: distanceMiles,
                isLiveNow: scored.isLive,
                venueEventID: row.id
            )
            candidates.append(candidate)
            spotsByID[venueID] = DiscoverProGameWatchSpot(
                id: venueID,
                bar: bar,
                venueEventID: row.id,
                eventTitle: row.event_title,
                distanceFromRegionCenterMiles: distanceMiles,
                gameSpecificEnergy: scored.energy,
                goingCount: scored.going,
                isLiveNow: scored.isLive
            )
        }

        let ranked = DiscoverGameVenueRanking.rank(candidates, limit: limit)
        let spots = ranked.compactMap { spotsByID[$0.id] }

#if DEBUG
        print(
            "[DiscoverProGameWatchSpots] matchId=\(externalGameID) regionVenues=\(regionVenueIDs.count) spots=\(spots.count) rankedBy=gameSpecificEnergy"
        )
#endif
        return .loaded(spots)
    }

    /// Game-specific Venue Energy for one venue_events row (never aggregates sibling games).
    @MainActor
    func gameSpecificEnergy(for row: VenueEventRow) -> (energy: Int, going: Int, isLive: Bool) {
        guard let eventID = row.id else {
            return (0, 0, false)
        }
        let going = interestCountForVenueEvent(eventID)
        let vibes = venueEventVibeCounts[eventID] ?? [:]
        let commenters = venueEventUniqueCommenterCounts[eventID] ?? 0
        let isLive = isVenueEventRowLiveNow(row)
        let energy = DiscoverGameVenueRanking.gameSpecificEnergy(
            goingCount: going,
            vibeCounts: vibes,
            uniqueCommenterCount: commenters,
            isLiveNow: isLive
        )
        return (energy, going, isLive)
    }

    @MainActor
    func isVenueEventRowLiveNow(_ row: VenueEventRow) -> Bool {
        guard let eventID = row.id,
              let start = FanGeoLiveEnergyTiming.parseScheduledStart(row.scheduled_start_at, eventId: eventID) else {
            return false
        }
        let now = Date()
        let liveEnd = start.addingTimeInterval(TimeInterval(FanGeoLiveEnergyTiming.liveWindowHours * 3600))
        return now >= start && now <= liveEnd
    }

    @MainActor
    private func discoverBarsInMapBounds(
        _ bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)?
    ) -> [BarVenue] {
        let source: [BarVenue]
        if !mapVisibleBars.isEmpty {
            source = mapVisibleBars
        } else {
            source = bars
        }
        guard let bounds else { return source }
        return source.filter { bar in
            let lat = bar.coordinate.latitude
            let lon = bar.coordinate.longitude
            return lat >= bounds.minLat
                && lat <= bounds.maxLat
                && lon >= bounds.minLon
                && lon <= bounds.maxLon
        }
    }

    /// Bounded `venue_events` lookup: `external_game_id` + viewport venue IDs only.
    private func fetchActiveVenueEventsHostingExternalGame(
        externalGameID: String,
        venueIDs: [UUID]
    ) async throws -> [VenueEventRow] {
        guard !venueIDs.isEmpty else { return [] }
        let selectCols =
            "id,venue_id,owner_email,venue_name,event_title,sport,home_team,away_team,event_date,event_time,admin_status,scheduled_start_at,cleanup_delay_hours,purge_after_at,external_league,external_game_id,external_source,imported_from_api,created_at"
        var byID: [UUID: VenueEventRow] = [:]
        let chunkSize = 80
        for chunk in stride(from: 0, to: venueIDs.count, by: chunkSize).map({
            Array(venueIDs[$0..<min($0 + chunkSize, venueIDs.count)])
        }) where !chunk.isEmpty {
            let rows: [VenueEventRow] = try await supabase
                .from("venue_events")
                .select(selectCols)
                .eq("external_game_id", value: externalGameID)
                .eq("admin_status", value: "active")
                .in("venue_id", values: chunk)
                .execute()
                .value
            for row in rows {
                guard let id = row.id else { continue }
                byID[id] = row
            }
        }
        return Array(byID.values)
    }
}
