import CoreLocation
import Foundation
import Supabase

let pickupGamesSelectColumns =
    "id,creator_user_id,creator_email,title,sport,sport_subtype,description,game_format,competition_level,skill_level,game_start_at,end_time,arrival_time,address,city,state,latitude,longitude,is_visible,players_needed,play_environment,participant_preference,age_min,age_max,is_free,entry_fee_amount,max_players,status,approved_join_count,cleanup_delay_hours,remove_after_at,created_at,updated_at,poll_create_permission,opponent_name"
/// Includes `arrival_time` after `20260973_0001_pickup_games_arrival_time.sql` (applied in production).
/// Optional on read (`decodeIfPresent` / nil). Writes: Insert omits nil; FullUpdate encodes JSON null to clear.

private let pickupOrganizerSettingsHistoryUserClearedIdsKeyPrefix = "gameon.settings.pickupOrganizerHistoryClearedIds."
private let pickupGamesDiscoverCacheTTL: TimeInterval = 150
private let pickupGamesDiscoverCacheMaxEntries = 16

private struct PickupGameCalendarRow: Decodable {
    let id: UUID?
    let title: String?
    let sport: String?
    let game_start_at: String
    let remove_after_at: String?
    let status: String?
    let is_visible: Bool?
    let latitude: Double?
    let longitude: Double?
}

/// DEBUG-only: minimal columns for ``logPickupGamesAnonDiagnosticProbeUnfiltered`` (not used for UI).
private struct PickupGameAnonDiagnosticProbeRow: Decodable {
    let id: UUID?
    let title: String?
    let sport: String?
    let game_start_at: String?
    let status: String?
    let is_visible: Bool?
    let remove_after_at: String?
}

private struct PickupDiscoverVisibilityEvaluation {
    let included: Bool
    let rejectionReason: String
    let gameDate: Date?
    let withinVisibleRegion: Bool
    let filteredByBounds: Bool
    let filteredByDate: Bool
    let filteredBySport: Bool
}

private func pickupDebugYMD(_ d: Date) -> String {
    let c = Calendar.current
    let y = c.component(.year, from: d)
    let m = c.component(.month, from: d)
    let day = c.component(.day, from: d)
    return String(format: "%04d-%02d-%02d", y, m, day)
}

/// PostgREST `or` filter: public pickup reads include rows with no `remove_after_at` or a future cleanup timestamp.
private func pickupGamesDiscoverRemoveAfterOrFilter(nowISO: String) -> String {
    "remove_after_at.is.null,remove_after_at.gt.\(nowISO)"
}

extension MapViewModel {

    private static let myPickupGamesForSettingsFreshnessInterval: TimeInterval = 60

    private static let pickupHistoryClearLogISO8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func pickupGamesDiscoverCacheKey(
        dayStart: Date,
        sport: String,
        bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)?
    ) -> String {
        let regionKey: String
        if let bounds {
            regionKey = [
                FanGeoFixedFloatFormat.d3(bounds.minLat),
                FanGeoFixedFloatFormat.d3(bounds.maxLat),
                FanGeoFixedFloatFormat.d3(bounds.minLon),
                FanGeoFixedFloatFormat.d3(bounds.maxLon)
            ].joined(separator: ",")
        } else {
            regionKey = "no-region"
        }
        return "pickupGames|\(pickupDebugYMD(dayStart))|\(sport)|\(regionKey)"
    }

#if DEBUG
    private func pickupMapRefreshPerfLog(_ message: String) {
        print("[PickupMapRefreshPerf] \(message)")
    }

    private func pickupMapRefreshBoundsBucket(
        _ bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)?
    ) -> String {
        guard let bounds else { return "nb" }
        return [
            FanGeoFixedFloatFormat.d3(bounds.minLat),
            FanGeoFixedFloatFormat.d3(bounds.maxLat),
            FanGeoFixedFloatFormat.d3(bounds.minLon),
            FanGeoFixedFloatFormat.d3(bounds.maxLon)
        ].joined(separator: "|")
    }
#endif

    private func storePickupGamesDiscoverCache(_ rows: [PickupGameRow], cacheKey: String) {
        pickupGamesDiscoverCache[cacheKey] = (rows: rows, fetchedAt: Date())
        prunePickupGamesDiscoverCacheIfNeeded()
    }

    private func prunePickupGamesDiscoverCacheIfNeeded() {
        guard pickupGamesDiscoverCache.count > pickupGamesDiscoverCacheMaxEntries else { return }
        let sorted = pickupGamesDiscoverCache
            .map { ($0.key, $0.value.fetchedAt) }
            .sorted { $0.1 < $1.1 }
        let dropCount = pickupGamesDiscoverCache.count - pickupGamesDiscoverCacheMaxEntries
        for index in 0..<max(0, dropCount) {
            pickupGamesDiscoverCache.removeValue(forKey: sorted[index].0)
        }
    }

    private static func readPickupOrganizerSettingsHistoryUserClearedIds(userId: UUID) -> Set<UUID> {
        let raw = UserDefaults.standard.string(forKey: pickupOrganizerSettingsHistoryUserClearedIdsKeyPrefix + userId.uuidString.lowercased()) ?? ""
        return Set(
            raw.split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .compactMap { UUID(uuidString: $0) }
        )
    }

    private static func writePickupOrganizerSettingsHistoryUserClearedIds(userId: UUID, ids: Set<UUID>) {
        let capped = ids.sorted { $0.uuidString < $1.uuidString }.prefix(240)
        let raw = capped.map { $0.uuidString.lowercased() }.joined(separator: ",")
        UserDefaults.standard.set(raw, forKey: pickupOrganizerSettingsHistoryUserClearedIdsKeyPrefix + userId.uuidString.lowercased())
    }

    /// Fan Following card / organizer History: human-readable auto-clear line (matches ``PickupGameRow/pickupHistoryClientCleanupDeadline()``).
    func pickupHistoryAutoClearCaption(forPickupGameId id: UUID, languageCode: String) -> String {
        guard let row = resolvedPickupGameRow(for: id),
              let deadline = row.pickupHistoryClientCleanupDeadline() else {
            return String(
                format: L10n.t("pickup_auto_clears_after_start_format", languageCode: languageCode),
                12
            )
        }
        let code = L10n.normalizedLanguageCode(languageCode)
        let stamp = deadline.formatted(
            Date.FormatStyle.dateTime
                .month(.abbreviated)
                .day()
                .year()
                .hour()
                .minute()
                .locale(Locale(identifier: code.replacingOccurrences(of: "-", with: "_")))
        )
        return String(
            format: L10n.t("pickup_auto_clears_on_format", languageCode: code),
            stamp
        )
    }

    /// Organizer Settings → History: hide this removed game locally (does not delete ratings or server rows).
    func markPickupOrganizerSettingsHistoryUserCleared(pickupGameId: UUID) {
        guard let uid = currentUserAuthId else { return }
        let cleanupAt = myRemovedPickupGamesForSettings.first(where: { $0.id == pickupGameId })?.pickupHistoryClientCleanupDeadline()
        var s = Self.readPickupOrganizerSettingsHistoryUserClearedIds(userId: uid)
        s.insert(pickupGameId)
        Self.writePickupOrganizerSettingsHistoryUserClearedIds(userId: uid, ids: s)
        myRemovedPickupGamesForSettings.removeAll { $0.id == pickupGameId }
#if DEBUG
        let cleanupStr = cleanupAt.map { Self.pickupHistoryClearLogISO8601.string(from: $0) } ?? "nil"
        print("[PickupHistoryClear] gameId=\(pickupGameId.uuidString.lowercased())")
        print("[PickupHistoryClear] cleanupAt=\(cleanupStr)")
        print("[PickupHistoryClear] userTappedClear=true")
        print("[PickupHistoryClear] autoExpired=false")
        print("[PickupHistoryClear] visible=false")
#endif
        showSocialActionToast("Removed from history", isError: false)
    }

    private func shouldShowRemovedPickupInOrganizerHistory(row: PickupGameRow, now: Date, clearedIds: Set<UUID>) -> Bool {
        let gid = row.id
        let cleanupAt = row.pickupHistoryClientCleanupDeadline()
        let userCleared = clearedIds.contains(gid)
        let autoExpired = cleanupAt.map { now >= $0 } ?? false
        let visible = !userCleared && !autoExpired
#if DEBUG
        let cleanupStr = cleanupAt.map { Self.pickupHistoryClearLogISO8601.string(from: $0) } ?? "nil"
        print("[PickupHistoryClear] gameId=\(gid.uuidString.lowercased())")
        print("[PickupHistoryClear] cleanupAt=\(cleanupStr)")
        print("[PickupHistoryClear] userTappedClear=false")
        print("[PickupHistoryClear] autoExpired=\(autoExpired)")
        print("[PickupHistoryClear] visible=\(visible)")
#endif
        return visible
    }

    func findOverlappingPickupGameAtLocation(
        newStart: Date,
        newEnd: Date,
        latitude: Double?,
        longitude: Double?,
        address: String?,
        city: String?,
        state: String?,
        excluding excludedId: UUID? = nil
    ) async throws -> PickupGameRow? {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: newStart)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
        let startISO = PickupGameModels.encodeSupabaseTimestamptz(dayStart)
        let endISO = PickupGameModels.encodeSupabaseTimestamptz(dayEnd)
        let nowISO = PickupGameModels.encodeSupabaseTimestamptz(Date())

        let rows: [PickupGameRow] = try await supabase
            .from("pickup_games")
            .select(pickupGamesSelectColumns)
            .gte("game_start_at", value: startISO)
            .lt("game_start_at", value: endISO)
            .or(pickupGamesDiscoverRemoveAfterOrFilter(nowISO: nowISO))
            .eq("status", value: "active")
            .eq("is_visible", value: true)
            .limit(300)
            .execute()
            .value

        return rows.first { row in
            if row.id == excludedId { return false }
            guard Self.pickupLocationMatches(
                row: row,
                latitude: latitude,
                longitude: longitude,
                address: address,
                city: city,
                state: state
            ) else {
                return false
            }
            guard let existingStart = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at),
                  let existingEnd = PickupGameModels.endDate(for: row) else {
                return false
            }
            return newStart < existingEnd && newEnd > existingStart
        }
    }

    private static func pickupLocationMatches(
        row: PickupGameRow,
        latitude: Double?,
        longitude: Double?,
        address: String?,
        city: String?,
        state: String?
    ) -> Bool {
        if let latitude,
           let longitude,
           let rowLat = row.latitude,
           let rowLon = row.longitude {
            let candidate = CLLocation(latitude: latitude, longitude: longitude)
            let existing = CLLocation(latitude: rowLat, longitude: rowLon)
            return candidate.distance(from: existing) <= 80
        }

        let lhs = [
            normalizedPickupLocationComponent(address),
            normalizedPickupLocationComponent(city),
            normalizedPickupLocationComponent(state)
        ].joined(separator: "|")
        let rhs = [
            normalizedPickupLocationComponent(row.address),
            normalizedPickupLocationComponent(row.city),
            normalizedPickupLocationComponent(row.state)
        ].joined(separator: "|")
        return !lhs.replacingOccurrences(of: "|", with: "").isEmpty && lhs == rhs
    }

    private static func normalizedPickupLocationComponent(_ raw: String?) -> String {
        raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased() ?? ""
    }

    func clearPickupMapSelection() {
        selectedPickupGameForMap = nil
        selectedPickupPlaceForMap = nil
        selectedDiscoverableFanTeamForMap = nil
    }

    func selectPickupGameOnMap(_ row: PickupGameRow) {
        PickupDetailCrashTrace.log("pickupMapAnnotationTapped", gameId: row.id, title: row.title)
        selectedBar = nil
        selectedEvent = nil
        selectedPickupPlaceForMap = nil
        selectedDiscoverableFanTeamForMap = nil
        discoverRemotePreviewHoldVenueId = nil
        selectedPickupGameForMap = row
        PickupDetailCrashTrace.log("selectedGameAssigned", gameId: row.id, title: row.title)
    }

    /// Discover display timezone for pickup day identity (must match the date-picker grid).
    func pickupDiscoverDisplayTimeZone() -> TimeZone {
        TimeZone.autoupdatingCurrent
    }

    /// Shared Discover eligibility context for map pins + calendar orange dots.
    func pickupDiscoverAvailabilityContext(
        requireMapBounds: Bool,
        now: Date = Date(),
        bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)? = nil
    ) -> PickupGameAvailabilityContext {
        let timeZone = pickupDiscoverDisplayTimeZone()
        let cal = PickupGameDateNormalizer.displayCalendar(timeZone: timeZone)
        let guestFloor: Date? = {
            guard isGuestDiscoverMode else { return nil }
            let raw = cal.date(byAdding: .day, value: -1, to: now) ?? now
            return cal.startOfDay(for: raw)
        }()
        return PickupGameAvailabilityContext(
            timeZone: timeZone,
            now: now,
            selectedSport: selectedSport,
            mapBounds: bounds ?? currentMapRegionBounds(),
            requireMapBounds: requireMapBounds,
            requireValidCoordinates: requireMapBounds,
            guestRecentFloor: guestFloor,
            allowAuthorizedPrivateGames: !isGuestDiscoverMode
        )
    }

    /// Pickup pins require latitude/longitude; games are created only with resolved coordinates.
    /// When `bounds` is provided, only viewport-eligible pins are returned — same geographic
    /// meaning as calendar orange dots (`requireMapBounds` path).
    /// Applies Discover My Teams membership scope after day/sport SQL + availability filtering.
    func pickupGamesVisibleAsMapPins(for bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)?) -> [PickupGameRow] {
        let coordinated = pickupGamesForDiscoverMap.filter { $0.latitude != nil && $0.longitude != nil }
        let scoped = DiscoverPickupTeamScopeFilter.apply(
            rows: coordinated,
            scope: discoverPickupTeamScope,
            myActiveTeamIds: discoverMyActiveFanTeamIds,
            teamIdentityByGameId: pickupDiscoverTeamIdentityByGameId
        )
        guard let bounds else { return scoped }
        return scoped.filter { row in
            guard let lat = row.latitude, let lon = row.longitude else { return false }
            return PickupGameAvailabilityResolver.isCoordinate(lat, lon, inside: bounds)
        }
    }

    /// Toggle My Teams scope (orthogonal to sport/date). Guests cannot enable membership scope.
    func setDiscoverPickupTeamScope(_ scope: DiscoverPickupTeamScope) {
        let next: DiscoverPickupTeamScope = {
            if isGuestDiscoverMode { return .all }
            return scope
        }()
        guard discoverPickupTeamScope != next else {
            if next == .myTeams {
                Task { await ensureDiscoverMyActiveFanTeamIdsLoaded() }
            }
            return
        }
        discoverPickupTeamScope = next
        if next == .myTeams {
            syncDiscoverMyActiveFanTeamIdsFromCoordinator()
            Task { await ensureDiscoverMyActiveFanTeamIdsLoaded() }
        }
        pruneDiscoverPickupSelectionOutsideMyTeamsScopeIfNeeded()
    }

    func syncDiscoverMyActiveFanTeamIdsFromCoordinator() {
        let next = FanTeamIdentityRealtimeCoordinator.shared.knownFanTeamIds
        if discoverMyActiveFanTeamIds != next {
            discoverMyActiveFanTeamIds = next
        }
        pruneDiscoverPickupSelectionOutsideMyTeamsScopeIfNeeded()
    }

    /// Ensures membership ids are warm for My Teams scope (single `list_my_fan_teams` when empty).
    func ensureDiscoverMyActiveFanTeamIdsLoaded() async {
        guard !isGuestDiscoverMode else {
            discoverMyActiveFanTeamIds = []
            return
        }
        syncDiscoverMyActiveFanTeamIdsFromCoordinator()
        if !discoverMyActiveFanTeamIds.isEmpty { return }
        do {
            let teams = try await FanTeamsService().listMyTeams()
            FanTeamIdentityRealtimeCoordinator.shared.seed(from: teams)
            syncDiscoverMyActiveFanTeamIdsFromCoordinator()
        } catch {
#if DEBUG
            print("[DiscoverMyTeamsScope] membership load failed error=\(error.localizedDescription)")
#endif
        }
    }

    func clearDiscoverPickupTeamScopeForLogout() {
        discoverPickupTeamScope = .all
        discoverMyActiveFanTeamIds = []
        pickupDiscoverTeamIdentityByGameId = [:]
        pickupDiscoverTeamAccentHexByGameId = [:]
    }

    private func pruneDiscoverPickupSelectionOutsideMyTeamsScopeIfNeeded() {
        guard discoverPickupTeamScope == .myTeams,
              let selected = selectedPickupGameForMap else { return }
        let kept = DiscoverPickupTeamScopeFilter.includes(
            gameId: selected.id,
            scope: discoverPickupTeamScope,
            myActiveTeamIds: discoverMyActiveFanTeamIds,
            teamIdentityByGameId: pickupDiscoverTeamIdentityByGameId
        )
        if !kept {
            selectedPickupGameForMap = nil
        }
    }

    /// Pickup pins in the current map bounds, filtered by the debounced Discover search (title, sport, address fields).
    func pickupGamesVisibleAsMapPinsWithDiscoverSearch(for bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)?) -> [PickupGameRow] {
        let inBounds = pickupGamesVisibleAsMapPins(for: bounds)
        let q = effectiveDiscoverSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return inBounds }
        return inBounds.filter { row in
            if row.title.localizedCaseInsensitiveContains(q) { return true }
            if row.sport.localizedCaseInsensitiveContains(q) { return true }
            if SportFilterCatalog.storedSport(row.sport, matchesSearchQuery: q) { return true }
            if (row.address ?? "").localizedCaseInsensitiveContains(q) { return true }
            if (row.city ?? "").localizedCaseInsensitiveContains(q) { return true }
            if (row.state ?? "").localizedCaseInsensitiveContains(q) { return true }
            return false
        }
    }

    func markPickupDiscoverMapDataDirtyForNextRefresh() {
        pickupDiscoverCoordinatorDirty = true
    }

    func clearDiscoverMapContentSelectionsWhenSwitching(to mode: DiscoverMapContentMode) {
        switch mode {
        case .venues:
            selectedPickupGameForMap = nil
            selectedPickupPlaceForMap = nil
            selectedDiscoverableFanTeamForMap = nil
        case .pickupGames:
            selectedBar = nil
            selectedEvent = nil
            discoverRemotePreviewHoldVenueId = nil
        }
    }

    func onDiscoverMapBecamePickupGamesFromUserToggle() {
        Task { @MainActor in
            guard discoverMapContentMode == .pickupGames else { return }
            guard discoverPickupSubMode == .games else {
                await refreshPickupPlacesForDiscoverMap()
                await refreshDiscoverableFanTeamsForMap()
                return
            }
            guard pickupDiscoverCoordinatorDirty else { return }
            if pickupGamesForDiscoverMap.isEmpty {
                setDiscoverMapStatus(discoverMapRefreshLookingToastText(), isLoading: true)
            } else {
                setDiscoverMapStatus(discoverMapRefreshUpdatingToastText(), isLoading: true)
            }
            let refreshToast = mapStatusText
            await refreshPickupGamesForDiscoverMap()
            if mapStatusText == refreshToast {
                setDiscoverMapStatus(nil, isLoading: false)
            }
        }
    }

    /// Distinct local calendar days with at least one **map-eligible** pickup game in the
    /// captured request context's date window + viewport.
    ///
    /// Uses **only** the immutable ``PickupGameMonthAvailabilityRequestContext`` — never
    /// re-reads live ``currentMapRegionBounds()`` or ``selectedSport``.
    func fetchPickupGameCalendarDotDatesForDiscoverRange(
        context request: PickupGameMonthAvailabilityRequestContext
    ) async throws -> PickupGameMonthDotFetchOutcome {
        let timeZone = request.timeZone
        let cal = PickupGameDateNormalizer.displayCalendar(timeZone: timeZone)
        let rangeStart = cal.startOfDay(for: request.dateMin)
        let lastDayStart = cal.startOfDay(for: request.dateMax)
        guard let endExclusive = cal.date(byAdding: .day, value: 1, to: lastDayStart) else {
            return .success(dates: [], rawRowCount: 0, eligibleRowCount: 0)
        }
        let now = Date()
        let nowISO = PickupGameModels.encodeSupabaseTimestamptz(now)
        let availability = request.availabilityContext(now: now)
        let rangeQueryStart: Date = {
            if let floor = request.guestRecentFloor {
                return max(rangeStart, floor)
            }
            return rangeStart
        }()
        let startISO = PickupGameModels.encodeSupabaseTimestamptz(rangeQueryStart)
        let endISO = PickupGameModels.encodeSupabaseTimestamptz(endExclusive)

        let queryBoundsBucket = PickupGameMonthAvailabilityRequestContext.boundsBucket(for: request.mapBounds)
#if DEBUG
        print("===== PICKUP MONTH DOT REQUEST =====")
        print("requestID=\(request.requestID.uuidString)")
        print("month=\(String(PickupGameDateNormalizer.ymdString(for: request.monthStart, timeZone: timeZone).prefix(7)))")
        print("sport=\(request.sport)")
        print("boundsBucket=\(request.boundsBucket)")
        if let b = request.mapBounds {
            print("bounds=\(b.bucketString)")
        } else {
            print("bounds=nil")
        }
        print("queryBoundsBucket=\(queryBoundsBucket)")
        print("cacheKey=\(request.cacheKey)")
        print(
            "cacheKeyMatchesQuery=\(PickupGameMonthAvailabilityMerge.cacheKeyMatchesQueryBounds(cacheKeyBoundsBucket: request.boundsBucket, queryBoundsBucket: queryBoundsBucket))"
        )
        assert(
            request.boundsBucket == queryBoundsBucket,
            "Pickup month-dot cache key bounds must match query bounds"
        )
#endif

        guard let bounds = request.mapBounds else {
#if DEBUG
            print("[DiscoverPickupDiag] op=calendarDotMonth skipped reason=noMapBounds requestID=\(request.requestID.uuidString)")
            print("===== END PICKUP MONTH DOT REQUEST (skippedNoBounds) =====")
#endif
            return .skippedNoBounds
        }

        var query = supabase
            .from("pickup_games")
            .select("id,title,sport,game_start_at,remove_after_at,status,is_visible,latitude,longitude")
            .gte("game_start_at", value: startISO)
            .lt("game_start_at", value: endISO)
            .or(pickupGamesDiscoverRemoveAfterOrFilter(nowISO: nowISO))
            .eq("status", value: "active")
            // Guest: public-only. Authenticated: omit is_visible filter; RLS returns
            // public + authorized private (creator / joiner / Team member).
            // Same captured viewport as the cache key — filter in SQL so the month set is not
            // dependent on selected-day in-memory rows.
            .gte("latitude", value: bounds.minLat)
            .lte("latitude", value: bounds.maxLat)
            .gte("longitude", value: bounds.minLon)
            .lte("longitude", value: bounds.maxLon)

        if request.guestRecentFloor != nil {
            query = query.eq("is_visible", value: true)
        }

        if request.sport != "All" {
            let tokens = AppSportCatalog.storedTokensMatchingDiscoverFilter(request.sport)
            if tokens.count <= 1 {
                query = query.eq("sport", value: tokens.first ?? request.sport)
            } else {
                query = query.in("sport", values: tokens)
            }
        }

        let rows: [PickupGameCalendarRow] = try await query
            .limit(8000)
            .execute()
            .value

        let candidates: [PickupGameAvailabilityCandidate] = rows.map { row in
            PickupGameAvailabilityCandidate(
                id: row.id,
                sport: row.sport ?? "",
                gameStartAtRaw: row.game_start_at,
                removeAfterAtRaw: row.remove_after_at,
                status: row.status ?? "",
                isVisible: row.is_visible ?? false,
                latitude: row.latitude,
                longitude: row.longitude
            )
        }

        var dates = Set<Date>()
        dates.reserveCapacity(min(candidates.count, 500))
        var droppedClientRemNotFuture = 0
        var droppedMissingCoords = 0
        var droppedOutOfBounds = 0
        var includedInBounds = 0
#if DEBUG
        var evaluations: [(candidate: PickupGameAvailabilityCandidate, evaluation: PickupGameAvailabilityEvaluation)] = []
        evaluations.reserveCapacity(min(candidates.count, 80))
#endif

        for candidate in candidates {
            let evaluation = PickupGameAvailabilityResolver.evaluate(candidate, context: availability)
#if DEBUG
            evaluations.append((candidate: candidate, evaluation: evaluation))
#endif
            guard evaluation.discoverEligible, let day = evaluation.normalizedLocalDay else {
                switch evaluation.exclusionReason {
                case .removeAfterPast: droppedClientRemNotFuture += 1
                case .missingCoordinates: droppedMissingCoords += 1
                case .outsideMapBounds, .missingMapBounds: droppedOutOfBounds += 1
                default: break
                }
                continue
            }
            includedInBounds += 1
            dates.insert(day)
        }

#if DEBUG
        let sportFilter = request.sport == "All" ? "(none)" : request.sport
        print(
            "[DiscoverPickupDiag] op=calendarDotMonth scope=capturedViewport table=pickup_games dateMin=\(PickupGameDateNormalizer.ymdString(for: rangeStart, timeZone: timeZone)) dateMax=\(PickupGameDateNormalizer.ymdString(for: lastDayStart, timeZone: timeZone)) bounds=\(bounds.bucketString) selectedSport=\(request.sport) sqlFilters=status:active is_visible:true game_start_at:[\(startISO),\(endISO)) sport:\(sportFilter) rawRowCount=\(rows.count) includedInBounds=\(includedInBounds) droppedMissingCoords=\(droppedMissingCoords) droppedOutOfBounds=\(droppedOutOfBounds) droppedByClientRemoveAfterPast=\(droppedClientRemNotFuture) dotDatesAfterClientFilter=\(dates.count)"
        )
        print("[DiscoverPickupPublic] monthWindowPickupDotDateCount=\(dates.count) sport=\(request.sport) rangeStartISO=\(startISO) scope=capturedViewport")
        print("----- PICKUP MONTH DOT ROWS -----")
        for item in evaluations {
            let c = item.candidate
            let e = item.evaluation
            let dayLabel = e.normalizedLocalDay.map {
                PickupGameDateNormalizer.ymdString(for: $0, timeZone: timeZone)
            } ?? "nil"
            let inside: String = {
                guard let lat = c.latitude, let lon = c.longitude else { return "nilCoords" }
                return bounds.contains(latitude: lat, longitude: lon) ? "true" : "false"
            }()
            let focusDay = dayLabel.contains("-07-30") || dayLabel.contains("-07-31")
            if focusDay || evaluations.count <= 40 {
                print(
                    "gameId=\(c.id?.uuidString ?? "nil") game_start_at=\(c.gameStartAtRaw) normalizedDay=\(dayLabel) lat=\(c.latitude.map(String.init(describing:)) ?? "nil") lon=\(c.longitude.map(String.init(describing:)) ?? "nil") capturedBounds=\(bounds.bucketString) insideBounds=\(inside) sport=\(c.sport) eligibility=\(e.discoverEligible ? "eligible" : (e.exclusionReason?.rawValue ?? "excluded"))"
                )
            }
        }
        let fetchedLabels = dates.sorted().map { PickupGameDateNormalizer.ymdString(for: $0, timeZone: timeZone) }
        print("rawMonthRows=\(rows.count)")
        print("eligibleMonthRows=\(includedInBounds)")
        print("fetchedMonthDates=[\(fetchedLabels.joined(separator: ","))]")
        print("===== END PICKUP MONTH DOT REQUEST =====")
        PickupGameAvailabilityDebugLog.logComparison(
            games: evaluations,
            discoverAvailableDates: dates,
            calendarAvailableDates: dates,
            timeZone: timeZone
        )
#endif
        return .success(dates: dates, rawRowCount: rows.count, eligibleRowCount: includedInBounds)
    }

    /// Coalesces concurrent refresh calls onto one in-flight task (later callers await the same work).
    func refreshPickupGamesForDiscoverMap(force: Bool = false, preservePickupCalendarDotDatesCache: Bool = false) async {
        if let existing = refreshPickupGamesForDiscoverMapCoalescingTask {
            print("[PickupGamesWarmCache] coalesced=true force=\(force)")
#if DEBUG
            pickupMapRefreshPerfLog("coalescedWithInFlight force=\(force)")
#endif
            await existing.value
            if !force { return }
            // A forced refresh usually follows a mutation. Do not let an older
            // in-flight read satisfy it, because that can republish stale rows.
            while refreshPickupGamesForDiscoverMapCoalescingTask != nil {
                await Task.yield()
            }
        }
        let capturedForce = force
        let capturedPreserve = preservePickupCalendarDotDatesCache
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefreshPickupGamesForDiscoverMap(
                force: capturedForce,
                preservePickupCalendarDotDatesCache: capturedPreserve
            )
        }
        refreshPickupGamesForDiscoverMapCoalescingTask = work
        await work.value
        refreshPickupGamesForDiscoverMapCoalescingTask = nil
    }

    func warmPreloadPickupGamesForCurrentContext() async {
        let dayStart = Calendar.current.startOfDay(for: selectedDate)
        let sport = selectedSport
        let bounds = currentMapRegionBounds()
        let cacheKey = pickupGamesDiscoverCacheKey(dayStart: dayStart, sport: sport, bounds: bounds)
        if let cached = pickupGamesDiscoverCache[cacheKey],
           Date().timeIntervalSince(cached.fetchedAt) < pickupGamesDiscoverCacheTTL {
            print("[PickupGamesWarmCache] warmCacheHit=true key=\(cacheKey) rows=\(cached.rows.count)")
            return
        }
        print("[PickupGamesWarmCache] warmFetchStarted key=\(cacheKey)")
        // force:false so mode/TTL coalescing apply — warm must not bypass Discover mode gates.
        await refreshPickupGamesForDiscoverMap(force: false, preservePickupCalendarDotDatesCache: true)
    }

    func refreshPickupGameAfterDiscoverPickupPlaceCreate(_ row: PickupGameRow) async {
#if DEBUG
        print("[PickupCreateRefreshDebug] source=pickupPlaceCreate")
        print("[PickupCreateRefreshDebug] insertedGameId=\(row.id.uuidString.lowercased())")
#endif
        if let createdStart = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) {
            selectedDate = createdStart
        }

        discoverMapContentMode = .pickupGames
        discoverPickupSubMode = .games
        selectedBar = nil
        selectedPickupPlaceForMap = nil
        selectedDiscoverableFanTeamForMap = nil

        mergePickupInsertedLocally(row)
        let localMerge = pickupGamesForDiscoverMap.contains { $0.id == row.id }
        pickupGameCalendarDotDatesCache.removeAll()
        invalidatePickupGameClusterAnnotationCache()
        invalidateCalendarTabEventsListCache()
        markPickupDiscoverMapDataDirtyForNextRefresh()

#if DEBUG
        print("[PickupCreateRefreshDebug] localMerge=\(localMerge)")
        print("[PickupCreateRefreshDebug] cacheInvalidated=true")
        print("[PickupCreateRefreshDebug] selectedDate=\(pickupDebugYMD(Calendar.current.startOfDay(for: selectedDate)))")
        print("[PickupCreateRefreshDebug] mapRefreshStarted=true")
#endif
        await refreshPickupGamesForDiscoverMap(force: true, preservePickupCalendarDotDatesCache: false)

        // Keep the just-created game visible even if Supabase read-after-write
        // replication or an older refresh briefly misses it.
        mergePickupInsertedLocally(row)
        if let currentUserAuthId, row.creator_user_id == currentUserAuthId {
            await loadMyPickupGamesForSettings(forceRefresh: true, reason: "pickupPlaceCreate")
        }

        recomputeCalendarDotDates(force: true)
#if DEBUG
        print("[PickupCreateRefreshDebug] calendarRefreshStarted=true")
#endif
        loadDiscoverCalendarDots(around: selectedDate, reason: "pickup_place_create")

        let visibleRow = pickupGamesVisibleAsMapPins(for: currentMapRegionBounds())
            .first { $0.id == row.id }
        if let visibleRow {
            selectPickupGameOnMap(visibleRow)
        }
#if DEBUG
        print("[PickupCreateRefreshDebug] visibleOnMapAfterRefresh=\(visibleRow != nil)")
#endif
    }

    private func performRefreshPickupGamesForDiscoverMap(force: Bool, preservePickupCalendarDotDatesCache: Bool) async {
        if !force && discoverMapContentMode != .pickupGames {
#if DEBUG
            print(
                "[DiscoverPickupDiag] op=mapRefresh SKIP earlyExit force=\(force) discoverMapContentMode=\(discoverMapContentMode.rawValue) reason=refreshOnlyRunsForPickupModeUnlessForced"
            )
#endif
            return
        }

        if !discoverGeographicNetworkFetchAllowed() {
#if DEBUG
            print("[DiscoverPickupDiag] op=mapRefresh SKIP reason=viewportTooBroad")
#endif
            print("[PickupGamesWarmCache] skipped reason=viewportTooBroad")
            return
        }

        isLoadingPickupGamesForMap = true

        let timeZone = pickupDiscoverDisplayTimeZone()
        let cal = PickupGameDateNormalizer.displayCalendar(timeZone: timeZone)
        let dayStart = cal.startOfDay(for: selectedDate)
        let requestSport = selectedSport
        let requestID = UUID()
        // Capture once: cache key identity must match SQL geographic predicates.
        let queryBounds = currentMapRegionBounds()
        let cacheKey = pickupGamesDiscoverCacheKey(
            dayStart: dayStart,
            sport: requestSport,
            bounds: queryBounds
        )
        pickupGamesDiscoverRequestID = requestID
        pickupDiscoverEnrichmentRequestID = requestID
#if DEBUG
        pickupMapRefreshPerfLog(
            "requestReceived force=\(force) day=\(pickupDebugYMD(dayStart)) sport=\(requestSport) boundsBucket=\(pickupMapRefreshBoundsBucket(queryBounds)) requestID=\(requestID.uuidString.prefix(8))"
        )
        if force {
            pickupMapRefreshPerfLog("forceRefresh=true")
        }
#endif
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else {
            isLoadingPickupGamesForMap = false
            markPickupDiscoverMapDataDirtyForNextRefresh()
            print("[PickupGamesWarmCache] skipped reason=invalidDay preservedRows=\(pickupGamesForDiscoverMap.count)")
            return
        }
        let cached = pickupGamesDiscoverCache[cacheKey]
        let cachedIsFresh = cached.map { Date().timeIntervalSince($0.fetchedAt) < pickupGamesDiscoverCacheTTL } ?? false
        if !force, let cached {
            pickupGamesForDiscoverMap = cached.rows
            pickupDiscoverCoordinatorDirty = false
            isLoadingPickupGamesForMap = false
            invalidatePickupGameClusterAnnotationCache()
            print("[PickupGamesWarmCache] immediateCachePublish=true key=\(cacheKey) rows=\(cached.rows.count) fresh=\(cachedIsFresh)")
            if cachedIsFresh {
#if DEBUG
                pickupMapRefreshPerfLog(
                    "freshCacheHit rows=\(cached.rows.count) boundsBucket=\(pickupMapRefreshBoundsBucket(queryBounds))"
                )
#endif
                if let sel = selectedPickupGameForMap, !cached.rows.contains(where: { $0.id == sel.id }) {
                    clearPickupMapSelection()
                }
                return
            }
#if DEBUG
            pickupMapRefreshPerfLog("staleCacheRepublishThenNetwork rows=\(cached.rows.count)")
#endif
        } else {
            print("[PickupGamesWarmCache] cacheHit=false key=\(cacheKey)")
#if DEBUG
            pickupMapRefreshPerfLog("cacheMiss force=\(force)")
#endif
        }
        let now = Date()
        let rawRecentFloor = cal.date(byAdding: .day, value: -1, to: now) ?? now
        let recentFloor = cal.startOfDay(for: rawRecentFloor)
        let effectiveLower = isGuestDiscoverMode ? max(dayStart, recentFloor) : dayStart
        let startISO = PickupGameModels.encodeSupabaseTimestamptz(effectiveLower)
        let endISO = PickupGameModels.encodeSupabaseTimestamptz(dayEnd)
        let nowISO = PickupGameModels.encodeSupabaseTimestamptz(now)

        do {
#if DEBUG
            pickupMapRefreshPerfLog(
                "networkFetchStarted boundsScoped=\(queryBounds != nil) boundsBucket=\(pickupMapRefreshBoundsBucket(queryBounds))"
            )
#endif
            var query = supabase
                .from("pickup_games")
                .select(pickupGamesSelectColumns)
                .gte("game_start_at", value: startISO)
                .lt("game_start_at", value: endISO)
                .or(pickupGamesDiscoverRemoveAfterOrFilter(nowISO: nowISO))
                .eq("status", value: "active")

            // Guest Discover stays public-only. Signed-in users rely on RLS for private
            // Team / organizer / joiner visibility (is_visible=false).
            if isGuestDiscoverMode {
                query = query.eq("is_visible", value: true)
            }

            if requestSport != "All" {
                let tokens = AppSportCatalog.storedTokensMatchingDiscoverFilter(requestSport)
                if tokens.count <= 1 {
                    query = query.eq("sport", value: tokens.first ?? requestSport)
                } else {
                    query = query.in("sport", values: tokens)
                }
            }

            // Same AABB convention as month-dot / pickup-places Discover queries.
            // When camera bounds are unavailable, keep prior day-window-only behavior.
            if let bounds = queryBounds {
                query = query
                    .gte("latitude", value: bounds.minLat)
                    .lte("latitude", value: bounds.maxLat)
                    .gte("longitude", value: bounds.minLon)
                    .lte("longitude", value: bounds.maxLon)
            }

            let rows: [PickupGameRow] = try await query
                .limit(400)
                .execute()
                .value

#if DEBUG
            pickupMapRefreshPerfLog("networkFetchFinished rawRowCount=\(rows.count)")
#endif

            // Day-scoped load: eligibility without requiring map bounds (SQL already day-windowed;
            // geographic scope applied in SQL when bounds were available). Pin rendering still
            // applies viewport via ``pickupGamesVisibleAsMapPins`` /
            // ``PickupGameAvailabilityResolver`` with ``requireMapBounds: true``.
            let dayContext = PickupGameAvailabilityContext(
                timeZone: timeZone,
                now: now,
                selectedSport: requestSport,
                mapBounds: nil,
                requireMapBounds: false,
                requireValidCoordinates: false,
                guestRecentFloor: isGuestDiscoverMode ? recentFloor : nil,
                allowAuthorizedPrivateGames: !isGuestDiscoverMode
            )

            var dropParseStart = 0
            var dropWrongDay = 0
            var dropRemoveAfterPast = 0
            var dropNotVisible = 0
            var fullRowsIncluded = 0
            var filtered: [PickupGameRow] = []
            filtered.reserveCapacity(rows.count)
            for row in rows {
                let evaluation = PickupGameAvailabilityResolver.evaluate(
                    PickupGameAvailabilityCandidate(row: row),
                    context: dayContext
                )
                guard let start = evaluation.decodedStart else {
                    dropParseStart += 1
                    continue
                }
                if !PickupGameDateNormalizer.isSameDay(start, dayStart, timeZone: timeZone) {
                    dropWrongDay += 1
                    continue
                }
                if evaluation.exclusionReason == .removeAfterPast {
                    dropRemoveAfterPast += 1
                    continue
                }
                if evaluation.exclusionReason == .notVisible || evaluation.exclusionReason == .inactiveStatus {
                    dropNotVisible += 1
                    continue
                }
                guard evaluation.discoverEligible else { continue }
                if row.isPickupFullForDiscover {
                    fullRowsIncluded += 1
                }
                filtered.append(row)
#if DEBUG
                logPickupVisibilityDebug(
                    row: row,
                    includedInDiscover: true,
                    excludedBecauseFull: false,
                    selectedDay: dayStart,
                    requestStatus: nil
                )
#endif
            }

#if DEBUG
            let sportFilter = requestSport == "All" ? "(none)" : requestSport
            let geoSQL: String = {
                guard let b = queryBounds else { return "none" }
                return "lat:[\(b.minLat),\(b.maxLat)] lon:[\(b.minLon),\(b.maxLon)]"
            }()
            print("[PickupVisibilityDebug] serverRowsLoaded=\(rows.count)")
            print(
                "[DiscoverPickupDiag] op=mapRefreshDay table=pickup_games selectedCalendarDay=\(pickupDebugYMD(dayStart)) dayStartISO=\(startISO) dayEndExclusiveISO=\(endISO) nowISO=\(nowISO) selectedSport=\(requestSport) sqlFilters=status:active is_visible:true game_start_at:[\(startISO),\(endISO)) remove_after_at:(is.null OR gt(\(nowISO))) sport:\(sportFilter) geo:\(geoSQL) rawRowCount=\(rows.count) afterClientFilterCount=\(filtered.count) clientDrop_parseStart=\(dropParseStart) wrongDay=\(dropWrongDay) removeAfterPast=\(dropRemoveAfterPast) notVisible=\(dropNotVisible) fullIncluded=\(fullRowsIncluded)"
            )
            print("[DiscoverPickupDiag] NOTE map query uses same remove_after_at OR-null filter as calendar dots; geo AABB matches cache key when bounds available.")
            for (i, row) in rows.prefix(5).enumerated() {
                let tit = row.title.replacingOccurrences(of: "\n", with: " ")
                print("[DiscoverPickupDiag] mapRawRow[\(i)] id=\(row.id.uuidString) title=\(tit) sport=\(row.sport) game_start_at=\(row.game_start_at) status=\(row.status) is_visible=\(row.is_visible) remove_after_at=\(row.remove_after_at ?? "nil")")
            }
            print("[DiscoverPickupPublic] selectedDayRawPickupRows=\(rows.count) sport=\(requestSport) dayStartISO=\(startISO)")
            if rows.isEmpty {
                do {
                    let probe = try await supabase
                        .from("pickup_games")
                        .select("id", head: true, count: .exact)
                        .eq("status", value: "active")
                        .eq("is_visible", value: true)
                        .execute()
                    let total = probe.count ?? -1
                    print("[DiscoverPickupPublic] dayQueryEmpty activeVisiblePickupGamesVisibleToClientTotal=\(total) (if 0 likely no data or RLS blocks anon reads)")
                } catch {
                    print("[DiscoverPickupPublic] dayQueryEmpty anonCountProbeFailed error=\(error)")
                }
                await logPickupDiagnosticProbeUnfiltered(context: "mapRefresh_selectedDay_emptyWindow")
            }
            print("[DiscoverPickupPublic] pickupMapRowsFiltered=\(filtered.count) forSelectedCalendarDay")
            pickupMapRefreshPerfLog(
                "eligibleAfterClientFilter=\(filtered.count) rawRowCount=\(rows.count) boundsBucket=\(pickupMapRefreshBoundsBucket(queryBounds))"
            )
#endif

            guard pickupGamesDiscoverRequestID == requestID else {
                print("[PickupGamesWarmCache] staleDiscard=true key=\(cacheKey)")
#if DEBUG
                pickupMapRefreshPerfLog("staleResultDiscarded requestID=\(requestID.uuidString.prefix(8))")
#endif
                return
            }
            storePickupGamesDiscoverCache(filtered, cacheKey: cacheKey)
            pickupGamesForDiscoverMap = filtered
            pickupDiscoverCoordinatorDirty = false
            isLoadingPickupGamesForMap = false
            await refreshPickupDiscoverTeamIdentities(for: filtered)
            print("[PickupGamesWarmCache] networkPublish=true key=\(cacheKey) rows=\(filtered.count)")
            print("[PickupPerf] coreRowsPublished count=\(filtered.count)")
            print("[PickupPerf] primaryLoadingClearedBeforeEnrichment=true")
            if !preservePickupCalendarDotDatesCache {
                pickupGameCalendarDotDatesCache.removeAll()
            }
            invalidatePickupGameClusterAnnotationCache()
            if let sel = selectedPickupGameForMap, !filtered.contains(where: { $0.id == sel.id }) {
                clearPickupMapSelection()
            }
            let gameIDs = filtered.map(\.id)
            let creatorIDs = Set(filtered.map(\.creator_user_id))
            Task { @MainActor [weak self] in
                await self?.runPickupDiscoverEnrichmentAfterCorePublish(
                    gameIDs: gameIDs,
                    creatorUserIDs: creatorIDs,
                    requestID: requestID,
                    selectedDay: dayStart,
                    selectedSport: requestSport
                )
            }
            if isGuestDiscoverMode, filtered.isEmpty {
                loadDiscoverCalendarDots(around: selectedDate, reason: "pickup_map_refresh_guest_empty_day")
            }
            invalidateCalendarTabEventsListCache()
        } catch {
            if pickupGamesDiscoverRequestID == requestID {
                isLoadingPickupGamesForMap = false
            }
            print("[PickupGamesWarmCache] networkFailedPreservedRows=\(pickupGamesForDiscoverMap.count) key=\(cacheKey)")
#if DEBUG
            print("[PickupGames] refreshDiscover failed:", error)
            pickupMapRefreshPerfLog("networkFetchFailed")
#endif
            markPickupDiscoverMapDataDirtyForNextRefresh()
        }
    }

    private func pickupDiscoverEnrichmentIsCurrent(
        requestID: UUID,
        selectedDay: Date,
        selectedSport: String
    ) -> Bool {
        pickupDiscoverEnrichmentRequestID == requestID &&
            Calendar.current.isDate(selectedDate, inSameDayAs: selectedDay) &&
            self.selectedSport == selectedSport
    }

    private func runPickupDiscoverEnrichmentAfterCorePublish(
        gameIDs: [UUID],
        creatorUserIDs: Set<UUID>,
        requestID: UUID,
        selectedDay: Date,
        selectedSport: String
    ) async {
        guard pickupDiscoverEnrichmentIsCurrent(
            requestID: requestID,
            selectedDay: selectedDay,
            selectedSport: selectedSport
        ) else {
            print("[PickupPerf] enrichmentDiscarded reason=staleRequest")
            return
        }

        print("[PickupPerf] enrichmentStarted count=\(gameIDs.count)")

        if isAuthenticatedForSocialFeatures {
            do {
                if let latest = try await fetchPickupMyJoinRequestsForDiscoverGames(gameIds: gameIDs) {
                    guard pickupDiscoverEnrichmentIsCurrent(
                        requestID: requestID,
                        selectedDay: selectedDay,
                        selectedSport: selectedSport
                    ) else {
                        print("[PickupPerf] enrichmentDiscarded reason=staleRequest")
                        return
                    }
                    applyPickupMyJoinRequestsForDiscoverGames(gameIds: gameIDs, latest: latest)
                }
            } catch {
                #if DEBUG
                print("[PickupGames] discover enrichment join requests failed:", error)
                #endif
            }

            guard pickupDiscoverEnrichmentIsCurrent(
                requestID: requestID,
                selectedDay: selectedDay,
                selectedSport: selectedSport
            ) else {
                print("[PickupPerf] enrichmentDiscarded reason=staleRequest")
                return
            }
            await loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: false)
        }

        guard pickupDiscoverEnrichmentIsCurrent(
            requestID: requestID,
            selectedDay: selectedDay,
            selectedSport: selectedSport
        ) else {
            print("[PickupPerf] enrichmentDiscarded reason=staleRequest")
            return
        }
        if !isGuestDiscoverMode {
            await loadPickupCreatorProfilesIfNeeded(creatorUserIds: creatorUserIDs)
            await refreshPickupOrganizerSummaries(userIds: Array(creatorUserIDs))
        }

        guard pickupDiscoverEnrichmentIsCurrent(
            requestID: requestID,
            selectedDay: selectedDay,
            selectedSport: selectedSport
        ) else {
            print("[PickupPerf] enrichmentDiscarded reason=staleRequest")
            return
        }
        print("[PickupPerf] enrichmentCompleted")
    }

    func loadMyPickupGamesForSettings(forceRefresh: Bool = false, reason: String = "ordinary") async {
        if let inFlight = myPickupGamesLightweightLoadTask {
#if DEBUG
            print("[StartupPrefetchDebug] pickupMine coalesced=true")
            print("[PickupPerf] screen=Going mode=Hosting rowCount=\(myPickupGamesForSettings.count + myRemovedPickupGamesForSettings.count) renderPath=loadMyPickupGamesForSettings freshnessSkip=false forcedReload=\(forceRefresh) reason=\(reason) coalesced=true")
#endif
            await inFlight.value
            if !forceRefresh { return }
        }

        if forceRefresh {
            lastMyPickupGamesLightweightLoadAt = nil
#if DEBUG
            print("[PickupPerf] screen=Going mode=Hosting rowCount=\(myPickupGamesForSettings.count + myRemovedPickupGamesForSettings.count) renderPath=loadMyPickupGamesForSettings freshnessSkip=false forcedReload=true reason=\(reason)")
#endif
        } else if let lastMyPickupGamesLightweightLoadAt {
            let age = Date().timeIntervalSince(lastMyPickupGamesLightweightLoadAt)
            if age < Self.myPickupGamesForSettingsFreshnessInterval {
#if DEBUG
                print("[PickupPerf] screen=Going mode=Hosting rowCount=\(myPickupGamesForSettings.count + myRemovedPickupGamesForSettings.count) renderPath=loadMyPickupGamesForSettings freshnessSkip=true forcedReload=false reason=\(reason) age=\(String(format: "%.1f", age))")
#endif
                return
            }
        }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.loadMyPickupGamesForSettingsNow(reason: reason)
        }
        myPickupGamesLightweightLoadTask = task
        await task.value
        myPickupGamesLightweightLoadTask = nil
    }

    private func loadMyPickupGamesForSettingsNow(reason: String) async {
        guard canFanUsePickupGamesUI, let uid = currentUserAuthId else {
            myPickupGamesForSettings = []
            myRemovedPickupGamesForSettings = []
            pendingPickupGameJoinRequestCount = 0
            await stopPickupJoinRequestBadgeRealtime()
#if DEBUG
            print("[PickupPerf] screen=Going mode=Hosting rowCount=0 renderPath=loadMyPickupGamesForSettings freshnessSkip=false forcedReload=false reason=\(reason) skipped=featureUnavailable")
#endif
            return
        }

        do {
            let rows: [PickupGameRow] = try await supabase
                .from("pickup_games")
                .select(pickupGamesSelectColumns)
                .eq("creator_user_id", value: uid.uuidString.lowercased())
                .in("status", values: ["active", "removed"])
                .order("game_start_at", ascending: false)
                .limit(400)
                .execute()
                .value
            let activeRows = rows.filter { $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "active" }
            let removedRows = rows.filter { $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "removed" }
                .sorted { a, b in
                    let ua = PickupGameModels.parseSupabaseTimestamptz(a.updated_at ?? "") ?? .distantPast
                    let ub = PickupGameModels.parseSupabaseTimestamptz(b.updated_at ?? "") ?? .distantPast
                    if ua != ub { return ua > ub }
                    return a.id.uuidString > b.id.uuidString
                }
            myPickupGamesForSettings = activeRows
            let clearedHistoryIds = Self.readPickupOrganizerSettingsHistoryUserClearedIds(userId: uid)
            let now = Date()
            myRemovedPickupGamesForSettings = removedRows.filter { row in
                shouldShowRemovedPickupInOrganizerHistory(row: row, now: now, clearedIds: clearedHistoryIds)
            }
            myPickupOrganizerSummaryLoadedForUserId = nil
            let ownedIds = Set(rows.map(\.id))
            pickupOrganizerWithdrawnRequestsByGameId = pickupOrganizerWithdrawnRequestsByGameId.filter { ownedIds.contains($0.key) }
            pickupOrganizerApprovedJoinerUserIdsByGameId = pickupOrganizerApprovedJoinerUserIdsByGameId.filter { ownedIds.contains($0.key) }
            await loadOrganizerPickupRequestSummaries(gameIds: rows.map(\.id))
            await loadOrganizerWithdrawnPickupRequestsForSettings(gameIds: rows.map(\.id))
            await loadOrganizerApprovedPickupJoinersForSettings(gameIds: rows.map(\.id))
            await syncPickupGamesToAppleCalendarIfNeeded(reason: "hostedPickupLoad")
            lastMyPickupGamesLightweightLoadAt = Date()
            await refreshMyPickupOrganizerSummary(force: true)
#if DEBUG
            print("[PickupPerf] screen=Going mode=Hosting rowCount=\(activeRows.count + myRemovedPickupGamesForSettings.count) renderPath=loadMyPickupGamesForSettings freshnessSkip=false forcedReload=false reason=\(reason)")
#endif
        } catch {
#if DEBUG
            print("[PickupGames] loadMine failed:", error)
#endif
        }
        await loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: true)
    }

    private func markMyPickupGamesForSettingsStaleAfterMutation(row: PickupGameRow, reason: String) {
        guard row.creator_user_id == currentUserAuthId else { return }
        lastMyPickupGamesLightweightLoadAt = nil
#if DEBUG
        print("[PickupPerf] screen=Going mode=Hosting rowCount=\(myPickupGamesForSettings.count + myRemovedPickupGamesForSettings.count) renderPath=loadMyPickupGamesForSettings freshnessSkip=false forcedReload=true reason=\(reason)")
#endif
    }

    func insertPickupGame(
        title: String,
        sport: String,
        description: String?,
        skillLevel: String,
        gameStartAt: Date,
        endTime: Date,
        address: String?,
        city: String?,
        state: String?,
        latitude: Double?,
        longitude: Double?,
        playersNeeded: Int,
        playEnvironment: String,
        participantPreference: String,
        ageMin: Int? = nil,
        ageMax: Int? = nil,
        isFree: Bool,
        entryFeeAmount: Double?,
        maxPlayers: Int?,
        gameFormat: GameType = .pickup,
        competitionLevel: PickupCompetitionLevel? = nil,
        pollCreatePermission: PickupPollCreatePermission = .organizerOnly,
        isVisible: Bool = true,
        opponentName: String? = nil,
        arrivalTime: Date? = nil,
        sportSubtype: String? = nil,
        claimsPickupCreateXP: Bool = true
    ) async throws -> PickupGameRow {
        guard let uid = currentUserAuthId else {
            throw PickupGameClientError.notSignedIn
        }
        guard canJoinPickupGames else {
            logBusinessUserGateBlocked(action: "createPickupGame")
            throw PickupGameClientError.businessAccountsCannotUsePickupGames
        }
        let playersNeededClamped = min(20, max(1, playersNeeded))
        let maxPlayersClamped: Int? = {
            guard let m = maxPlayers else { return nil }
            let c = min(100, max(1, m))
            guard c >= playersNeededClamped else { return playersNeededClamped }
            return c
        }()
        let feePayload: Double? = isFree ? nil : entryFeeAmount.map { Self.roundMoney($0) }
        let gameStartISO = PickupGameModels.encodeSupabaseTimestamptz(gameStartAt)
        let endTimeISO = PickupGameModels.encodeSupabaseTimestamptz(endTime)
        let removeISO = PickupGameModels.encodedPickupRemoveAfterAt(forEncodedGameStart: gameStartISO)
        PickupExpirationEditDebug.log(
            oldGameStartAt: nil,
            newGameStartAt: gameStartISO,
            cleanupDelayHours: PickupGameAutoRemoval.hoursAfterGameStart,
            computedRemoveAfterAt: removeISO
        )
        let payload = PickupGameInsert(
            creator_user_id: uid,
            creator_email: normalizedFanEmailForPickup(),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            sport: sport.trimmingCharacters(in: .whitespacesAndNewlines),
            sport_subtype: SportSubtypeCatalog.normalizedSubtype(
                sport: sport,
                subtype: sportSubtype
            ),
            description: emptyStringToNil(description),
            game_format: gameFormat.rawValue,
            competition_level: competitionLevel?.rawValue,
            skill_level: skillLevel,
            game_start_at: gameStartISO,
            end_time: endTimeISO,
            address: emptyStringToNil(address),
            city: emptyStringToNil(city),
            state: emptyStringToNil(state),
            latitude: latitude,
            longitude: longitude,
            is_visible: isVisible,
            players_needed: playersNeededClamped,
            play_environment: playEnvironment,
            participant_preference: participantPreference,
            age_min: ageMin,
            age_max: ageMax,
            is_free: isFree,
            entry_fee_amount: feePayload,
            max_players: maxPlayersClamped,
            cleanup_delay_hours: PickupGameAutoRemoval.hoursAfterGameStart,
            remove_after_at: removeISO,
            poll_create_permission: pollCreatePermission.rawValue,
            opponent_name: FanTeamScheduleMatchup.persistableOpponent(
                format: gameFormat,
                opponentName: opponentName
            ),
            arrival_time: arrivalTime.map { PickupGameModels.encodeSupabaseTimestamptz($0) }
        ).withCanonicalPickupCleanupDelay()

#if DEBUG
        print("[PickupVisibilityDebug] discoverVisible=\(isVisible) format=\(gameFormat.rawValue) level=\(competitionLevel?.rawValue ?? "nil")")
#endif
        let inserted: [PickupGameRow] = try await supabase
            .from("pickup_games")
            .insert(payload)
            .select(pickupGamesSelectColumns)
            .execute()
            .value

        guard let row = inserted.first else {
            throw PickupGameClientError.missingRowAfterWrite
        }
#if DEBUG
        print("[PickupGameExpirationDebug] game_start_at=\(row.game_start_at)")
        print("[PickupGameExpirationDebug] remove_after_at=\(row.remove_after_at ?? "nil")")
        print("[PickupGameExpirationDebug] hoursAfterStart=\(PickupGameAutoRemoval.hoursAfterGameStart)")
        print(
            "[DiscoverDotsSave] table=pickup_games op=insert id=\(row.id.uuidString.lowercased()) game_start_at=\(row.game_start_at) sport=\(row.sport) status=\(row.status) is_visible=\(row.is_visible) remove_after_at=\(row.remove_after_at ?? "nil")"
        )
#endif
        mergePickupInsertedLocally(row)
        FanGeoAnalyticsService.recordGameCreated(
            gameId: row.id,
            city: row.city,
            region: row.state,
            country: nil,
            sport: row.sport
        )
        if claimsPickupCreateXP {
            await awardFanXP(
                source: FanXPSource.pickupCreate,
                sourceId: row.id
            )
        }
        return row
    }

    func updatePickupGame(id: UUID, full: PickupGameFullUpdate) async throws {
        let normalized = full.withCanonicalPickupCleanupDelay()
        let before = resolvedPickupGameRow(for: id)
        let oldStart = before?.game_start_at
        PickupExpirationEditDebug.log(
            oldGameStartAt: oldStart,
            newGameStartAt: normalized.game_start_at,
            cleanupDelayHours: PickupGameAutoRemoval.hoursAfterGameStart,
            computedRemoveAfterAt: normalized.remove_after_at
        )
#if DEBUG
        print("[PickupVisibilityDebug] discoverVisibilityForced=true")
#endif
        // Ensure private pickup chat exists before UPDATE so the DB edit-notify trigger
        // can insert a system message for approved participants.
        await ensurePickupGameChatForEditNotificationsIfNeeded(pickupGameId: id)

        let updated: [PickupGameRow] = try await supabase
            .from("pickup_games")
            .update(normalized)
            .eq("id", value: id.uuidString.lowercased())
            .select(pickupGamesSelectColumns)
            .execute()
            .value

        guard let row = updated.first else {
            throw PickupGameClientError.missingRowAfterWrite
        }
#if DEBUG
        print("[PickupGameExpirationDebug] game_start_at=\(row.game_start_at)")
        print("[PickupGameExpirationDebug] remove_after_at=\(row.remove_after_at ?? "nil")")
        print("[PickupGameExpirationDebug] hoursAfterStart=\(PickupGameAutoRemoval.hoursAfterGameStart)")
        print(
            "[DiscoverDotsSave] table=pickup_games op=update id=\(row.id.uuidString.lowercased()) game_start_at=\(row.game_start_at) sport=\(row.sport) status=\(row.status) is_visible=\(row.is_visible) remove_after_at=\(row.remove_after_at ?? "nil")"
        )
        if let before {
            let changes = PickupGameMeaningfulChange.diff(before: before, after: row)
            print("[PickupEditNotify] meaningfulKinds=\(changes.kinds.map(\.rawValue).joined(separator: ","))")
            print("[TeamEventChangePushDebug] update_submitted pickup_game_id=\(id.uuidString.lowercased())")
            print(
                "[TeamEventChangePushDebug] old_values start=\(before.game_start_at) end=\(before.end_time ?? "nil") " +
                "address=\(before.address ?? "") status=\(before.status)"
            )
            print(
                "[TeamEventChangePushDebug] new_values start=\(row.game_start_at) end=\(row.end_time ?? "nil") " +
                "address=\(row.address ?? "") status=\(row.status)"
            )
            print(
                "[TeamEventChangePushDebug] meaningful_fields detected=\(changes.kinds.map(\.rawValue).joined(separator: ","))"
            )
        }
#endif
        mergePickupInsertedLocally(row)
        await syncPickupGamesToAppleCalendarIfNeeded(
            reason: "pickupGameEdited",
            forceBypassFreshness: true
        )
    }

    /// Opens/creates the private pickup chat when the organizer has approved participants
    /// so the DB edit-notify trigger can post a system message.
    /// Team-linked events use Team Chat — never create/open a per-event pickup conversation.
    private func ensurePickupGameChatForEditNotificationsIfNeeded(pickupGameId: UUID) async {
        if await isPickupGameLinkedToFanTeam(pickupGameId: pickupGameId) {
#if DEBUG
            print(
                "[PickupEditNotify] ensureChat skipped teamLinked=true id=\(pickupGameId.uuidString.lowercased())"
            )
#endif
            return
        }
        do {
            _ = try await GroupChatService().ensurePickupGameConversation(pickupGameId: pickupGameId)
#if DEBUG
            print("[PickupEditNotify] ensureChat ok id=\(pickupGameId.uuidString.lowercased())")
#endif
        } catch {
#if DEBUG
            print(
                "[PickupEditNotify] ensureChat skipped id=\(pickupGameId.uuidString.lowercased()) " +
                "error=\(error.localizedDescription)"
            )
#endif
        }
    }

    /// Organizer-only: updates who may create polls in this pickup chat.
    func updatePickupGamePollCreatePermission(
        id: UUID,
        permission: PickupPollCreatePermission
    ) async throws {
        guard let existing = resolvedPickupGameRow(for: id) else {
            throw PickupGameClientError.pickupGameNotFound
        }
        guard let uid = currentUserAuthId, existing.creator_user_id == uid else {
            throw PickupGameClientError.pickupGameNotOrganizer
        }
        struct PollCreatePermissionUpdate: Encodable {
            let poll_create_permission: String
        }
        let payload = PollCreatePermissionUpdate(poll_create_permission: permission.rawValue)
        let updated: [PickupGameRow] = try await supabase
            .from("pickup_games")
            .update(payload)
            .eq("id", value: id.uuidString.lowercased())
            .select(pickupGamesSelectColumns)
            .execute()
            .value
        guard let row = updated.first else {
            throw PickupGameClientError.missingRowAfterWrite
        }
        mergePickupInsertedLocally(row)
    }

    /// Updates `players_needed` / `max_players` after start; also re-sends `game_start_at` + expiration so `remove_after_at` stays `start + 12h`.
    func updatePickupGameRosterCapacity(id: UUID, playersNeeded: Int, maxPlayers: Int?) async throws {
        guard let existing = resolvedPickupGameRow(for: id) else {
            throw PickupGameClientError.pickupGameNotFound
        }
        let gameStartISO = existing.game_start_at
        let removeISO = PickupGameModels.encodedPickupRemoveAfterAt(forEncodedGameStart: gameStartISO)
        PickupExpirationEditDebug.log(
            oldGameStartAt: gameStartISO,
            newGameStartAt: gameStartISO,
            cleanupDelayHours: PickupGameAutoRemoval.hoursAfterGameStart,
            computedRemoveAfterAt: removeISO
        )
        let payload = PickupGameRosterCapacityUpdate(
            players_needed: min(20, max(1, playersNeeded)),
            max_players: maxPlayers,
            game_start_at: gameStartISO,
            cleanup_delay_hours: PickupGameAutoRemoval.hoursAfterGameStart,
            remove_after_at: removeISO
        )
        await ensurePickupGameChatForEditNotificationsIfNeeded(pickupGameId: id)
        let updated: [PickupGameRow] = try await supabase
            .from("pickup_games")
            .update(payload)
            .eq("id", value: id.uuidString.lowercased())
            .select(pickupGamesSelectColumns)
            .execute()
            .value

        guard let row = updated.first else {
            throw PickupGameClientError.missingRowAfterWrite
        }
#if DEBUG
        print("[PickupGameExpirationDebug] game_start_at=\(row.game_start_at)")
        print("[PickupGameExpirationDebug] remove_after_at=\(row.remove_after_at ?? "nil")")
        print("[PickupGameExpirationDebug] hoursAfterStart=\(PickupGameAutoRemoval.hoursAfterGameStart)")
        print(
            "[DiscoverDotsSave] table=pickup_games op=roster_capacity id=\(row.id.uuidString.lowercased()) game_start_at=\(row.game_start_at) sport=\(row.sport) status=\(row.status) is_visible=\(row.is_visible) remove_after_at=\(row.remove_after_at ?? "nil")"
        )
#endif
        mergePickupInsertedLocally(row)
    }

    func logPickupGamesEditRequested(id: UUID) {
#if DEBUG
        print("[PickupGames] edit requested id=\(id.uuidString.lowercased())")
#endif
    }

    /// Soft-clears hosted games whose auto-clear deadline has passed (Going → Hosting).
    /// Idempotent; safe to call from appear / minute tick / foreground.
    func clearExpiredHostedPickupGamesIfNeeded(now: Date = Date(), reason: String) async {
        let candidates = myPickupGamesForSettings.filter { PickupHostingAutoClear.isPastDeadline(row: $0, now: now) }
        guard !candidates.isEmpty else { return }
#if DEBUG
        print("[PickupHostingAutoClear] reason=\(reason) candidates=\(candidates.count)")
#endif
        for row in candidates {
            do {
                try await clearHostedPickupGame(id: row.id, reason: reason)
            } catch {
#if DEBUG
                print(
                    "[PickupHostingAutoClear] failed id=\(row.id.uuidString.lowercased()) " +
                    "reason=\(reason) error=\(error.localizedDescription)"
                )
#endif
            }
        }
    }

    /// Soft-clears one hosted pickup (auto or manual). Dedupes overlapping attempts via in-flight set.
    func clearHostedPickupGame(id: UUID, reason: String) async throws {
        let started: Bool = await MainActor.run {
            pickupHostingAutoClearInFlightIds.insert(id).inserted
        }
        if !started {
            // Another clear is already running for this game — wait briefly for it to finish.
            for _ in 0..<50 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                let stillPresent = await MainActor.run { myPickupGamesForSettings.contains(where: { $0.id == id }) }
                let stillInFlight = await MainActor.run { pickupHostingAutoClearInFlightIds.contains(id) }
                if !stillPresent { return }
                if !stillInFlight { break }
            }
            let stillPresent = await MainActor.run { myPickupGamesForSettings.contains(where: { $0.id == id }) }
            guard stillPresent else { return }
            let retried = await MainActor.run { pickupHostingAutoClearInFlightIds.insert(id).inserted }
            guard retried else { return }
        }

        defer {
            Task { @MainActor in
                pickupHostingAutoClearInFlightIds.remove(id)
            }
        }

#if DEBUG
        print("[PickupHostingAutoClear] clear start id=\(id.uuidString.lowercased()) reason=\(reason)")
#endif
        do {
            try await deletePickupGame(id: id)
            _ = await MainActor.run {
                pickupHostingAutoClearFailedIds.remove(id)
            }
#if DEBUG
            print("[PickupHostingAutoClear] clear success id=\(id.uuidString.lowercased()) reason=\(reason)")
#endif
        } catch {
            _ = await MainActor.run {
                pickupHostingAutoClearFailedIds.insert(id)
            }
            throw error
        }
    }

    /// Organizer cancels the pickup (soft delete). Join requests are cancelled server-side; ratings/history rows are not deleted.
    /// Idempotent: already-`removed` games succeed without a second notify-producing update.
    func deletePickupGame(id: UUID) async throws {
        guard canJoinPickupGames else {
            logBusinessUserGateBlocked(action: "joinPickupGame")
            throw PickupGameClientError.businessAccountsCannotUsePickupGames
        }
        guard let uid = currentUserAuthId else {
            throw PickupGameClientError.notSignedIn
        }
        guard let existing = resolvedPickupGameRow(for: id) else {
            throw PickupGameClientError.pickupGameNotFound
        }
        guard existing.creator_user_id == uid else {
            throw PickupGameClientError.pickupGameNotOrganizer
        }

        let oldStatus = existing.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if oldStatus == "removed" {
            mergePickupGameAfterOrganizerSoftDelete(existing)
            await refreshPickupGamesForDiscoverMap(force: true, preservePickupCalendarDotDatesCache: true)
#if DEBUG
            print("[PickupGameDelete] idempotentAlreadyRemoved id=\(id.uuidString.lowercased())")
#endif
            return
        }
        let nowISO = PickupGameModels.encodeSupabaseTimestamptz(Date())

        let affectedResponse = try await supabase
            .from("pickup_game_requests")
            .select("id", count: .exact)
            .eq("pickup_game_id", value: id.uuidString.lowercased())
            .in("status", values: ["pending", "approved"])
            .limit(1)
            .execute()
        let affectedRequests = affectedResponse.count ?? 0

        // Cancellation system message needs an existing private chat when members are present.
        await ensurePickupGameChatForEditNotificationsIfNeeded(pickupGameId: id)

        let softPayload = PickupGameSoftRemoveUpdate(status: "removed", is_visible: false, remove_after_at: nowISO)
        let updatedRows: [PickupGameRow] = try await supabase
            .from("pickup_games")
            .update(softPayload)
            .eq("id", value: id.uuidString.lowercased())
            .eq("creator_user_id", value: uid.uuidString.lowercased())
            .select(pickupGamesSelectColumns)
            .execute()
            .value
        guard let updated = updatedRows.first else {
            throw PickupGameClientError.missingRowAfterWrite
        }

        do {
            try await supabase
                .from("pickup_game_requests")
                .update(PickupJoinRequestStatusUpdate(status: "cancelled"))
                .eq("pickup_game_id", value: id.uuidString.lowercased())
                .in("status", values: ["pending", "approved"])
                .execute()
        } catch {
#if DEBUG
            print("[PickupGames] soft delete join request bulk cancel failed id=\(id.uuidString.lowercased()) error=\(error)")
#endif
            throw error
        }

        mergePickupGameAfterOrganizerSoftDelete(updated)
        recomputeCalendarDotDates()
        refreshPickupJoinCachesAfterMutation()
        await loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: true)
        await loadMyPickupGameJoinRequestsForFollowing(
            forceRefresh: true,
            reason: "pickupGameDeleted"
        )
        await syncPickupGamesToAppleCalendarIfNeeded(
            reason: "pickupGameCancelled",
            forceBypassFreshness: true
        )
        pickupOrganizerRequestsSyncGeneration &+= 1
        pickupJoinRequestUiRevision &+= 1
        await refreshPickupGamesForDiscoverMap(force: true, preservePickupCalendarDotDatesCache: true)

#if DEBUG
        let vis = updated.is_visible ? "true" : "false"
        let newSt = updated.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        print("[PickupGameDelete] gameId=\(id.uuidString.lowercased())")
        print("[PickupGameDelete] oldStatus=\(oldStatus)")
        print("[PickupGameDelete] newStatus=\(newSt)")
        print("[PickupGameDelete] affectedRequests=\(affectedRequests)")
        print("[PickupGameDelete] visibleAfter=\(vis)")
#endif
    }

    private func mergePickupGameAfterOrganizerSoftDelete(_ row: PickupGameRow) {
        markMyPickupGamesForSettingsStaleAfterMutation(row: row, reason: "mutationSoftDelete")
        myPickupGamesForSettings.removeAll { $0.id == row.id }
        guard let uid = currentUserAuthId else {
            myRemovedPickupGamesForSettings.removeAll { $0.id == row.id }
            pickupGamesForDiscoverMap.removeAll { $0.id == row.id }
            if selectedPickupGameForMap?.id == row.id {
                clearPickupMapSelection()
            }
            clearPickupGameLocalCachesAfterRemoval(id: row.id)
            return
        }
        let clearedHistoryIds = Self.readPickupOrganizerSettingsHistoryUserClearedIds(userId: uid)
        let now = Date()
        guard shouldShowRemovedPickupInOrganizerHistory(row: row, now: now, clearedIds: clearedHistoryIds) else {
            myRemovedPickupGamesForSettings.removeAll { $0.id == row.id }
            pickupGamesForDiscoverMap.removeAll { $0.id == row.id }
            if selectedPickupGameForMap?.id == row.id {
                clearPickupMapSelection()
            }
            clearPickupGameLocalCachesAfterRemoval(id: row.id)
            return
        }
        if let i = myRemovedPickupGamesForSettings.firstIndex(where: { $0.id == row.id }) {
            myRemovedPickupGamesForSettings[i] = row
        } else {
            myRemovedPickupGamesForSettings.insert(row, at: 0)
        }
        myRemovedPickupGamesForSettings.sort { a, b in
            let ua = PickupGameModels.parseSupabaseTimestamptz(a.updated_at ?? "") ?? .distantPast
            let ub = PickupGameModels.parseSupabaseTimestamptz(b.updated_at ?? "") ?? .distantPast
            if ua != ub { return ua > ub }
            return a.id.uuidString > b.id.uuidString
        }
        pickupGamesForDiscoverMap.removeAll { $0.id == row.id }
        if selectedPickupGameForMap?.id == row.id {
            clearPickupMapSelection()
        }
        clearPickupGameLocalCachesAfterRemoval(id: row.id)
    }

    private static func roundMoney(_ x: Double) -> Double {
        (x * 100.0).rounded() / 100.0
    }

    private func normalizedFanEmailForPickup() -> String? {
        let e = OwnerBusinessEmail.normalized(currentUserEmail)
        return e.isEmpty ? nil : e
    }

    private func emptyStringToNil(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    func mergePickupInsertedLocally(_ row: PickupGameRow) {
        let st = row.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if st == "removed" || st == "expired" {
            mergePickupGameAfterOrganizerSoftDelete(row)
            return
        }
        markMyPickupGamesForSettingsStaleAfterMutation(row: row, reason: "mutationUpsert")
        if let i = myPickupGamesForSettings.firstIndex(where: { $0.id == row.id }) {
            myPickupGamesForSettings[i] = row
        } else {
            myPickupGamesForSettings.insert(row, at: 0)
        }
        myPickupGamesForSettings.sort { a, b in
            let da = PickupGameModels.parseSupabaseTimestamptz(a.game_start_at) ?? .distantPast
            let db = PickupGameModels.parseSupabaseTimestamptz(b.game_start_at) ?? .distantPast
            return da > db
        }

        let visibility = pickupDiscoverVisibilityEvaluation(for: row)
#if DEBUG
        logPickupDiscoverVisibility(row: row, evaluation: visibility)
#endif
        if visibility.included {
            if let i = pickupGamesForDiscoverMap.firstIndex(where: { $0.id == row.id }) {
                pickupGamesForDiscoverMap[i] = row
            } else {
                pickupGamesForDiscoverMap.append(row)
            }
            invalidatePickupGameClusterAnnotationCache()
        } else {
            let previousCount = pickupGamesForDiscoverMap.count
            pickupGamesForDiscoverMap.removeAll { $0.id == row.id }
            if pickupGamesForDiscoverMap.count != previousCount {
                invalidatePickupGameClusterAnnotationCache()
            }
        }
    }

    private func shouldIncludePickupRowOnDiscoverMap(_ row: PickupGameRow) -> Bool {
        pickupDiscoverVisibilityEvaluation(for: row).included
    }

    private func pickupDiscoverVisibilityEvaluation(for row: PickupGameRow) -> PickupDiscoverVisibilityEvaluation {
        let bounds = currentMapRegionBounds()
        let withinVisibleRegion: Bool = {
            guard let bounds, let lat = row.latitude, let lon = row.longitude else { return false }
            return lat >= bounds.minLat && lat <= bounds.maxLat && lon >= bounds.minLon && lon <= bounds.maxLon
        }()
        let filteredByBounds = bounds != nil && !withinVisibleRegion
        let status = row.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let privateAllowed = !isGuestDiscoverMode
        guard status == "active", row.is_visible || privateAllowed else {
            return PickupDiscoverVisibilityEvaluation(
                included: false,
                rejectionReason: status == "active" ? "notVisible" : "status:\(status)",
                gameDate: PickupGameModels.parseSupabaseTimestamptz(row.game_start_at),
                withinVisibleRegion: withinVisibleRegion,
                filteredByBounds: filteredByBounds,
                filteredByDate: false,
                filteredBySport: false
            )
        }
        let now = Date()
        if let rem = row.remove_after_at,
           let remd = PickupGameModels.parseSupabaseTimestamptz(rem),
           remd <= now {
            return PickupDiscoverVisibilityEvaluation(
                included: false,
                rejectionReason: "removeAfterPast",
                gameDate: PickupGameModels.parseSupabaseTimestamptz(row.game_start_at),
                withinVisibleRegion: withinVisibleRegion,
                filteredByBounds: filteredByBounds,
                filteredByDate: false,
                filteredBySport: false
            )
        }
        let cal = Calendar.current
        guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else {
            return PickupDiscoverVisibilityEvaluation(
                included: false,
                rejectionReason: "invalidGameDate",
                gameDate: nil,
                withinVisibleRegion: withinVisibleRegion,
                filteredByBounds: filteredByBounds,
                filteredByDate: true,
                filteredBySport: false
            )
        }
        let filteredByDate = !cal.isDate(start, inSameDayAs: selectedDate)
        guard !filteredByDate else {
            return PickupDiscoverVisibilityEvaluation(
                included: false,
                rejectionReason: "date",
                gameDate: start,
                withinVisibleRegion: withinVisibleRegion,
                filteredByBounds: filteredByBounds,
                filteredByDate: true,
                filteredBySport: false
            )
        }
        let filteredBySport = !pickupDiscoverSport(row.sport, matchesSelectedSport: selectedSport)
        guard !filteredBySport else {
            return PickupDiscoverVisibilityEvaluation(
                included: false,
                rejectionReason: "sport",
                gameDate: start,
                withinVisibleRegion: withinVisibleRegion,
                filteredByBounds: filteredByBounds,
                filteredByDate: false,
                filteredBySport: true
            )
        }
        return PickupDiscoverVisibilityEvaluation(
            included: true,
            rejectionReason: "none",
            gameDate: start,
            withinVisibleRegion: withinVisibleRegion,
            filteredByBounds: filteredByBounds,
            filteredByDate: false,
            filteredBySport: false
        )
    }

    private func pickupDiscoverSport(_ gameSport: String, matchesSelectedSport selectedSport: String) -> Bool {
        let selected = selectedSport.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selected.localizedCaseInsensitiveCompare("All") != .orderedSame else { return true }
        let sport = gameSport.trimmingCharacters(in: .whitespacesAndNewlines)
        return sport.localizedCaseInsensitiveCompare(selected) == .orderedSame
            || SportFilterCatalog.storedSport(sport, matchesSearchQuery: selected)
    }

    private func logPickupDiscoverVisibility(row: PickupGameRow, evaluation: PickupDiscoverVisibilityEvaluation) {
#if DEBUG
        print("[PickupDiscoverVisibilityDebug] insertedGameID=\(row.id.uuidString.lowercased())")
        print("[PickupDiscoverVisibilityDebug] included=\(evaluation.included)")
        print("[PickupDiscoverVisibilityDebug] rejectionReason=\(evaluation.rejectionReason)")
        print("[PickupDiscoverVisibilityDebug] selectedDate=\(pickupDebugYMD(Calendar.current.startOfDay(for: selectedDate)))")
        if let gameDate = evaluation.gameDate {
            print("[PickupDiscoverVisibilityDebug] gameDate=\(pickupDebugYMD(Calendar.current.startOfDay(for: gameDate)))")
        } else {
            print("[PickupDiscoverVisibilityDebug] gameDate=nil")
        }
        print("[PickupDiscoverVisibilityDebug] selectedSport=\(selectedSport)")
        print("[PickupDiscoverVisibilityDebug] gameSport=\(row.sport)")
        print("[PickupDiscoverVisibilityDebug] withinVisibleRegion=\(evaluation.withinVisibleRegion)")
        print("[PickupDiscoverVisibilityDebug] filteredByBounds=\(evaluation.filteredByBounds)")
        print("[PickupDiscoverVisibilityDebug] filteredByDate=\(evaluation.filteredByDate)")
        print("[PickupDiscoverVisibilityDebug] filteredBySport=\(evaluation.filteredBySport)")
        logPickupVisibilityDebug(
            row: row,
            includedInDiscover: evaluation.included,
            excludedBecauseFull: false,
            selectedDay: Calendar.current.startOfDay(for: selectedDate),
            requestStatus: nil
        )
#endif
    }

    private func logPickupVisibilityDebug(
        row: PickupGameRow,
        includedInDiscover: Bool,
        excludedBecauseFull: Bool,
        selectedDay: Date,
        requestStatus: String?
    ) {
#if DEBUG
        let gameDay = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at)
            .map { Calendar.current.startOfDay(for: $0) }
        print("[PickupVisibilityDebug] gameId=\(row.id.uuidString.lowercased())")
        print("[PickupVisibilityDebug] rosterFull=\(row.isPickupFullForDiscover)")
        print("[PickupVisibilityDebug] excludedBecauseFull=\(excludedBecauseFull)")
        print("[PickupVisibilityDebug] includedInDiscover=\(includedInDiscover)")
        print("[PickupVisibilityDebug] creatorCanReadGame=\(currentUserAuthId == row.creator_user_id)")
        print("[PickupVisibilityDebug] selectedDate=\(pickupDebugYMD(selectedDay))")
        print("[PickupVisibilityDebug] gameDate=\(gameDay.map(pickupDebugYMD) ?? "nil")")
        if let requestStatus {
            print("[PickupVisibilityDebug] requestStatus=\(requestStatus)")
        }
#endif
    }

    private func applySoftRemovedPickupGameLocally(id: UUID) {
        myPickupGamesForSettings.removeAll { $0.id == id }
        myRemovedPickupGamesForSettings.removeAll { $0.id == id }
        pickupGamesForDiscoverMap.removeAll { $0.id == id }
        if selectedPickupGameForMap?.id == id {
            clearPickupMapSelection()
        }
        clearPickupGameLocalCachesAfterRemoval(id: id)
    }

    private func clearPickupGameLocalCachesAfterRemoval(id: UUID) {
#if DEBUG
        print("[PickupGames] local caches cleared id=\(id.uuidString.lowercased())")
#endif
        invalidatePickupGameClusterAnnotationCache()
        pickupGameCalendarDotDatesCache.removeAll()
        pickupMyLatestJoinRequestByGameId.removeValue(forKey: id)
        pickupOrganizerJoinStatsByGameId.removeValue(forKey: id)
        pickupOrganizerWithdrawnRequestsByGameId.removeValue(forKey: id)
        pickupOrganizerApprovedJoinerUserIdsByGameId.removeValue(forKey: id)
        pickupGamesFollowingTabCache.removeValue(forKey: id)
    }

    private func logPickupDiagnosticProbeUnfiltered(context: String) async {
#if DEBUG
        do {
            let probe: [PickupGameAnonDiagnosticProbeRow] = try await supabase
                .from("pickup_games")
                .select("id,title,sport,game_start_at,status,is_visible,remove_after_at")
                .limit(10)
                .execute()
                .value
            print(
                "[DiscoverPickupDiag] op=anonTableProbe context=\(context) table=pickup_games NO_date_NO_sport_filters diagnosticUnfilteredLimit10_count=\(probe.count) hint=0=>empty_table_or_RLS_blocks_all_reads;>0_but_window_queries_0=>date_or_remove_after_or_status_or_sport_or_visibility_filters"
            )
            for (i, r) in probe.prefix(5).enumerated() {
                let tid = r.id?.uuidString ?? "nil"
                let tit = (r.title ?? "?").replacingOccurrences(of: "\n", with: " ")
                let sp = r.sport ?? "?"
                let gst = r.game_start_at ?? "nil"
                let st = r.status ?? "nil"
                let vis = r.is_visible.map(String.init(describing:)) ?? "nil"
                let rem = r.remove_after_at ?? "nil"
                print("[DiscoverPickupDiag] probeRow[\(i)] id=\(tid) title=\(tit) sport=\(sp) game_start_at=\(gst) status=\(st) is_visible=\(vis) remove_after_at=\(rem)")
            }
        } catch {
            print("[DiscoverPickupDiag] op=anonTableProbe context=\(context) FAILED error=\(error)")
        }
#endif
    }

    /// Whether this pickup is linked to any Team via `fan_team_game_links` (RLS-scoped).
    /// Used to lock Public/Private on edit without a Team-specific editor.
    func isPickupGameLinkedToFanTeam(pickupGameId: UUID) async -> Bool {
        struct LinkRow: Decodable {
            let pickup_game_id: UUID
        }
        do {
            let links: [LinkRow] = try await supabase
                .from("fan_team_game_links")
                .select("pickup_game_id")
                .eq("pickup_game_id", value: pickupGameId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value
            return !links.isEmpty
        } catch {
#if DEBUG
            print(
                "[PickupTeamLink] lookup failed id=\(pickupGameId.uuidString.lowercased()) " +
                "error=\(error.localizedDescription)"
            )
#endif
            return false
        }
    }

    /// Batch-hydrate Team identity for Discover pins/cards (one RPC; RLS fallback if RPC missing).
    private func refreshPickupDiscoverTeamIdentities(for rows: [PickupGameRow]) async {
        let ids = Array(Set(rows.map(\.id))).prefix(400).map { $0 }
        guard !ids.isEmpty else {
            publishPickupDiscoverTeamIdentities([:])
            return
        }

        struct Params: Encodable {
            let p_pickup_game_ids: [UUID]
        }

        do {
            let rpcRows: [PickupDiscoverTeamIdentityRPCRow] = try await supabase
                .rpc(
                    "list_pickup_discover_team_identities",
                    params: Params(p_pickup_game_ids: ids)
                )
                .execute()
                .value
            var next: [UUID: PickupDiscoverTeamIdentity] = [:]
            for row in rpcRows {
                if let identity = row.asIdentity() {
                    next[identity.pickupGameId] = identity
                }
            }
            publishPickupDiscoverTeamIdentities(next)
            return
        } catch {
#if DEBUG
            print(
                "[PickupDiscoverTeamIdentity] RPC unavailable; RLS fallback error=\(error.localizedDescription)"
            )
#endif
        }

        await refreshPickupDiscoverTeamIdentitiesViaRLS(for: ids)
    }

    /// Member-scoped fallback when `list_pickup_discover_team_identities` is not applied yet.
    private func refreshPickupDiscoverTeamIdentitiesViaRLS(for pickupGameIds: [UUID]) async {
        guard !isGuestDiscoverMode else {
            publishPickupDiscoverTeamIdentities([:])
            return
        }
        guard !pickupGameIds.isEmpty else {
            publishPickupDiscoverTeamIdentities([:])
            return
        }

        struct LinkRow: Decodable {
            let pickup_game_id: UUID
            let team_id: UUID
        }
        struct TeamRow: Decodable {
            let id: UUID
            let name: String?
            let sport: String?
            let color_hex: String?
            let logo_url: String?
            let logo_thumbnail_url: String?
        }

        do {
            let links: [LinkRow] = try await supabase
                .from("fan_team_game_links")
                .select("pickup_game_id,team_id")
                .in("pickup_game_id", values: pickupGameIds.map { $0.uuidString.lowercased() })
                .limit(400)
                .execute()
                .value
            guard !links.isEmpty else {
                publishPickupDiscoverTeamIdentities([:])
                return
            }
            let teamIds = Array(Set(links.map(\.team_id)))
            let teams: [TeamRow] = try await supabase
                .from("fan_teams")
                .select("id,name,sport,color_hex,logo_url,logo_thumbnail_url")
                .in("id", values: teamIds.map { $0.uuidString.lowercased() })
                .limit(200)
                .execute()
                .value
            let teamById = Dictionary(uniqueKeysWithValues: teams.map { ($0.id, $0) })
            var next: [UUID: PickupDiscoverTeamIdentity] = [:]
            for link in links {
                guard let team = teamById[link.team_id] else { continue }
                let name = (team.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let sport = (team.sport ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                next[link.pickup_game_id] = PickupDiscoverTeamIdentity(
                    pickupGameId: link.pickup_game_id,
                    teamId: link.team_id,
                    teamName: name,
                    teamSport: sport,
                    colorHex: FanTeamColorPalette.normalized(team.color_hex),
                    logoURL: ImageDisplayURL.canonicalStorageURLString(team.logo_url).nilIfEmpty,
                    logoThumbnailURL: ImageDisplayURL.canonicalStorageURLString(team.logo_thumbnail_url).nilIfEmpty,
                    displayRefreshToken: nil
                )
            }
            publishPickupDiscoverTeamIdentities(next)
        } catch {
            publishPickupDiscoverTeamIdentities([:])
#if DEBUG
            print("[PickupDiscoverTeamIdentity] RLS fallback failed error=\(error.localizedDescription)")
#endif
        }
    }

    func mergePickupDiscoverTeamIdentities(_ extra: [UUID: PickupDiscoverTeamIdentity]) {
        guard !extra.isEmpty else { return }
        var next = pickupDiscoverTeamIdentityByGameId
        for (gameId, identity) in extra {
            next[gameId] = identity
        }
        publishPickupDiscoverTeamIdentities(next)
    }

    /// Fetches Team identities for Going cards and merges without wiping Discover cache.
    func ensurePickupDiscoverTeamIdentities(forGameIds ids: [UUID]) async {
        let unique = Array(Set(ids)).filter { pickupDiscoverTeamIdentityByGameId[$0] == nil }
        guard !unique.isEmpty else { return }
        struct Params: Encodable { let p_pickup_game_ids: [UUID] }
        do {
            let rpcRows: [PickupDiscoverTeamIdentityRPCRow] = try await supabase
                .rpc(
                    "list_pickup_discover_team_identities",
                    params: Params(p_pickup_game_ids: unique)
                )
                .execute()
                .value
            var extra: [UUID: PickupDiscoverTeamIdentity] = [:]
            for row in rpcRows {
                if let identity = row.asIdentity() {
                    extra[identity.pickupGameId] = identity
                }
            }
            mergePickupDiscoverTeamIdentities(extra)
            return
        } catch {
#if DEBUG
            print("[GoingPlay] teamIdentityRPC unavailable error=\(error.localizedDescription)")
#endif
        }
        await mergePickupDiscoverTeamIdentitiesViaRLS(for: unique)
    }

    private func mergePickupDiscoverTeamIdentitiesViaRLS(for pickupGameIds: [UUID]) async {
        guard !isGuestDiscoverMode, !pickupGameIds.isEmpty else { return }
        struct LinkRow: Decodable {
            let pickup_game_id: UUID
            let team_id: UUID
        }
        struct TeamRow: Decodable {
            let id: UUID
            let name: String?
            let sport: String?
            let color_hex: String?
            let logo_url: String?
            let logo_thumbnail_url: String?
        }
        do {
            let links: [LinkRow] = try await supabase
                .from("fan_team_game_links")
                .select("pickup_game_id,team_id")
                .in("pickup_game_id", values: pickupGameIds.map { $0.uuidString.lowercased() })
                .limit(400)
                .execute()
                .value
            guard !links.isEmpty else { return }
            let teamIds = Array(Set(links.map(\.team_id)))
            let teams: [TeamRow] = try await supabase
                .from("fan_teams")
                .select("id,name,sport,color_hex,logo_url,logo_thumbnail_url")
                .in("id", values: teamIds.map { $0.uuidString.lowercased() })
                .limit(200)
                .execute()
                .value
            let teamById = Dictionary(uniqueKeysWithValues: teams.map { ($0.id, $0) })
            var extra: [UUID: PickupDiscoverTeamIdentity] = [:]
            for link in links {
                guard let team = teamById[link.team_id] else { continue }
                let name = (team.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                extra[link.pickup_game_id] = PickupDiscoverTeamIdentity(
                    pickupGameId: link.pickup_game_id,
                    teamId: link.team_id,
                    teamName: name,
                    teamSport: (team.sport ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    colorHex: FanTeamColorPalette.normalized(team.color_hex),
                    logoURL: ImageDisplayURL.canonicalStorageURLString(team.logo_url).nilIfEmpty,
                    logoThumbnailURL: ImageDisplayURL.canonicalStorageURLString(team.logo_thumbnail_url).nilIfEmpty,
                    displayRefreshToken: nil
                )
            }
            mergePickupDiscoverTeamIdentities(extra)
        } catch {
#if DEBUG
            print("[GoingPlay] teamIdentityRLS merge failed error=\(error.localizedDescription)")
#endif
        }
    }

    private func publishPickupDiscoverTeamIdentities(_ next: [UUID: PickupDiscoverTeamIdentity]) {
        pickupDiscoverTeamIdentityByGameId = next
        pickupDiscoverTeamAccentHexByGameId = Dictionary(
            uniqueKeysWithValues: next.compactMap { gameId, identity -> (UUID, String)? in
                guard let hex = identity.colorHex else { return nil }
                return (gameId, hex)
            }
        )
        pruneDiscoverPickupSelectionOutsideMyTeamsScopeIfNeeded()
    }

    /// Patch Discover Team pins, regional cache, selected preview, and pickup-game Team marks.
    func applyFanTeamIdentityChangeToDiscoverCaches(_ change: FanTeamIdentityChange) {
        let patchedTeams = FanTeamArtworkPropagation.patchRows(discoverableFanTeamsForMap, with: change)
        if patchedTeams.didChange {
            discoverableFanTeamsForMap = patchedTeams.rows
        }
        if let selected = selectedDiscoverableFanTeamForMap, selected.id == change.teamId {
            selectedDiscoverableFanTeamForMap = selected.applyingIdentityChange(change)
        }
        var nextRegional = discoverFanTeamsRegionalCache
        var regionalChanged = false
        for (key, entry) in discoverFanTeamsRegionalCache {
            let patched = FanTeamArtworkPropagation.patchRows(entry.rows, with: change)
            if patched.didChange {
                nextRegional[key] = (patched.rows, entry.fetchedAt)
                regionalChanged = true
            }
        }
        if regionalChanged {
            discoverFanTeamsRegionalCache = nextRegional
        }

        guard !pickupDiscoverTeamIdentityByGameId.isEmpty else { return }
        var next = pickupDiscoverTeamIdentityByGameId
        var didChangePickup = false
        for (gameId, identity) in pickupDiscoverTeamIdentityByGameId where identity.teamId == change.teamId {
            let patched = identity.applyingIdentityChange(change)
            if patched != identity {
                next[gameId] = patched
                didChangePickup = true
            }
        }
        guard didChangePickup else { return }
        publishPickupDiscoverTeamIdentities(next)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
