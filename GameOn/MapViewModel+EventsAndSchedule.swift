import CoreLocation
import Foundation

extension MapViewModel {

    func showSocialActionToast(_ text: String, isError: Bool = true) {
        socialActionToastDismissTask?.cancel()
        socialActionToastText = text
        socialActionToastIsError = isError
        socialActionToastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard let self, !Task.isCancelled else { return }
            self.socialActionToastText = nil
            self.socialActionToastIsError = false
            self.socialActionToastDismissTask = nil
        }
    }

    private static let calendarEventsListCacheTTL: TimeInterval = 45
    private static let calendarEventsListCacheMaxKeys = 14

    /// Debounced Discover search string; avoids recomputing pins/events on every keystroke (see ``scheduleDiscoverSearchDebounce()``).
    var effectiveDiscoverSearchQuery: String {
        debouncedDiscoverSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func bumpScheduleDataGeneration() {
        scheduleDataGeneration &+= 1
        lastCalendarDotRecomputeKey = nil
        calendarEventsListCache.removeAll(keepingCapacity: true)
    }

    func invalidateCalendarTabEventsListCache() {
        calendarEventsListCache.removeAll(keepingCapacity: true)
    }

    /// Calendar tab + MainTabView: refresh **public** pickup discover rows only (no fan join-request loads).
    func refreshCalendarTabPickupSources(forceRefresh: Bool = false, reason: String = "automatic") async {
        guard canFanUsePickupGamesUI else { return }
        let cal = Calendar.current
        let calendarDay = cal.startOfDay(for: calendarTabSelectedDate)
        let key = "\(Int(calendarDay.timeIntervalSince1970))|\(selectedSport)|\(calendarTabGameFilter.rawValue)"

        if !forceRefresh,
           lastCalendarTabPickupSourcesRefreshKey == key,
           let lastCalendarTabPickupSourcesRefreshAt {
            let age = Date().timeIntervalSince(lastCalendarTabPickupSourcesRefreshAt)
            if age < 90 {
                AppPerfDebug.networkFetchFinished(
                    tab: "calendar",
                    source: "pickupSources",
                    durationMs: 0,
                    cacheHit: true
                )
#if DEBUG
                TabPerfDebug.log("[TabPerfDebug] cacheAge=\(String(format: "%.1f", age)) tab=calendar source=pickupSources")
                TabPerfDebug.log("[TabPerfDebug] usedCachedData=true tab=calendar source=pickupSources")
                TabPerfDebug.log("[TabPerfDebug] refreshSkippedReason=fresh tab=calendar source=pickupSources reason=\(reason)")
#endif
                SchedulePerf.refreshSkippedFresh(source: "pickupSources:\(reason)", ageSec: age)
                return
            }
        }

        if !forceRefresh, let existing = calendarTabPickupSourcesRefreshTask {
#if DEBUG
            TabPerfDebug.log("[TabPerfDebug] refreshCoalesced=true tab=calendar source=pickupSources reason=\(reason)")
#endif
            SchedulePerf.refreshCoalesced(source: "pickupSources:\(reason)")
            await existing.value
            return
        }

        if cal.startOfDay(for: selectedDate) != calendarDay {
            selectedDate = calendarDay
        }

        let startedAt = Date()
        AppPerfDebug.networkFetchStarted(tab: "calendar", source: "pickupSources:\(reason)")
        SchedulePerf.refreshStarted(source: "pickupSources:\(reason)", force: forceRefresh)
#if DEBUG
        print("[CalendarPickupPublicMode] personalStateHidden=true reason=refreshCalendarTabPickupSources")
        TabPerfDebug.log("[TabPerfDebug] refreshStarted=calendar source=pickupSources force=\(forceRefresh) reason=\(reason)")
#endif
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshPickupGamesForDiscoverMap(force: true, preservePickupCalendarDotDatesCache: true)
        }
        calendarTabPickupSourcesRefreshTask = task
        await task.value
        calendarTabPickupSourcesRefreshTask = nil
        lastCalendarTabPickupSourcesRefreshAt = Date()
        lastCalendarTabPickupSourcesRefreshKey = key
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        AppPerfDebug.networkFetchFinished(tab: "calendar", source: "pickupSources:\(reason)", durationMs: ms)
#if DEBUG
        TabPerfDebug.log("[TabPerfDebug] refreshDurationMs=\(ms) tab=calendar source=pickupSources reason=\(reason)")
#endif
        SchedulePerf.refreshCompleted(source: "pickupSources:\(reason)", ms: ms, rows: pickupGamesForDiscoverMap.count)
    }

#if DEBUG
    func logPickupActivityBadgeDebug() {
        print("[PickupActivityBadgeDebug] followingBadgeCount=\(pickupActivityCount)")
        print("[PickupActivityBadgeDebug] calendarPickupBadgeCount=0")
    }
#else
    @inline(__always)
    func logPickupActivityBadgeDebug() {}
#endif

    /// Uncached same-day list for Discover (and internal use).
    func computeEventsForSelectedDateUncached() -> [SportsEvent] {
        let cal = Calendar.current
        return events.filter { event in
            cal.isDate(event.date, inSameDayAs: selectedDate) &&
                (selectedSport == "All" || event.sport == selectedSport) &&
                matchesSearch(event)
        }
    }

    /// Events shown on Discover map pins and venue cards: selected day + sport + search (event text or venue name/address).
    var eventsForSelectedDate: [SportsEvent] {
        computeEventsForSelectedDateUncached()
    }

    /// Titles allowed for venue calendar dots when ``calendarUsesVisibleMapRegionOnly`` (map bar game titles plus owner-venue extras). Single shared construction for dot filtering and cache keys.
    private func venueGameTitleAllowlistForCalendarDotsWhenRegionOnly() -> Set<String> {
        var venueGameTitles = Set(bars.flatMap(\.games))
        if let ownerVid = ownerVenueDatabaseId, hasAuthenticatedVenueOwnerSession {
            let extra = venueEventRows.compactMap { row -> String? in
                guard row.venue_id == ownerVid, let t = row.event_title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
                    return nil
                }
                return t
            }
            venueGameTitles.formUnion(extra)
        }
        return venueGameTitles
    }

    /// Sport-filtered events used for Discover calendar dots; when region-only, ``regionVenueGameTitles`` should be the precomputed allowlist (pass `nil` when not region-only, or omit and pass `nil` to build allowlist once in ``recomputeCalendarDotDates``).
    private func filteredEventsForCalendarDots(regionVenueGameTitles: Set<String>?) -> [SportsEvent] {
        var list = events
        if selectedSport != "All" {
            list = list.filter { $0.sport == selectedSport }
        }
        guard calendarUsesVisibleMapRegionOnly else { return list }
        let titles = regionVenueGameTitles ?? venueGameTitleAllowlistForCalendarDotsWhenRegionOnly()
        return list.filter { event in
            event.league == "Venue Event" && titles.contains(event.title)
        }
    }

    /// Calendar green dots: sport-filtered; when ``calendarUsesVisibleMapRegionOnly`` is on, only venue-backed games on currently loaded map bars.
    var eventsForCalendarDots: [SportsEvent] {
        let regionTitles = calendarUsesVisibleMapRegionOnly ? venueGameTitleAllowlistForCalendarDotsWhenRegionOnly() : nil
        return filteredEventsForCalendarDots(regionVenueGameTitles: regionTitles)
    }

    /// Fingerprint for ``eventsForCalendarDots`` inputs so we can skip full-array rescans when unchanged.
    /// - Parameter regionVenueGameTitles: When region-only, pass the same allowlist used for filtering so ``recomputeCalendarDotDates`` avoids building it twice.
    private func calendarDotRecomputeCacheKeyString(regionVenueGameTitles: Set<String>?) -> String {
        let regionOnly = calendarUsesVisibleMapRegionOnly
        let titlesTag: Int = {
            guard regionOnly else { return 0 }
            let titles = regionVenueGameTitles ?? venueGameTitleAllowlistForCalendarDotsWhenRegionOnly()
            return titles.hashValue
        }()
        return "\(selectedSport)|\(regionOnly)|\(events.count)|\(bars.count)|\(titlesTag)|\(scheduleDataGeneration)"
    }

    func calendarDotRecomputeCacheKey() -> String {
        let regionTitles = calendarUsesVisibleMapRegionOnly ? venueGameTitleAllowlistForCalendarDotsWhenRegionOnly() : nil
        return calendarDotRecomputeCacheKeyString(regionVenueGameTitles: regionTitles)
    }

    /// Legacy client-side dot set (DEBUG shadow only); skipped while Calendar tab is hidden unless `force`.
    func recomputeCalendarDotDates(force: Bool = false) {
        guard force || isCalendarTabSelected else {
#if DEBUG
            print("[PerfPhase1D] deferredCalendarWork reason=recomputeCalendarDotDates")
#endif
            return
        }
        let regionVenueGameTitles = calendarUsesVisibleMapRegionOnly ? venueGameTitleAllowlistForCalendarDotsWhenRegionOnly() : nil
        let key = calendarDotRecomputeCacheKeyString(regionVenueGameTitles: regionVenueGameTitles)
        if key == lastCalendarDotRecomputeKey {
            #if DEBUG
            print("[Phase1Perf] recomputeCalendarDotDates SKIP key=\(key)")
            #endif
            return
        }
        #if DEBUG
        let t0 = Date()
        #endif
        let cal = Calendar.current
        let dotSourceEvents = filteredEventsForCalendarDots(regionVenueGameTitles: regionVenueGameTitles)
        calendarDotDates = Set(dotSourceEvents.map { cal.startOfDay(for: $0.date) })
        lastCalendarDotRecomputeKey = key
        #if DEBUG
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("[Phase1Perf] recomputeCalendarDotDates ms=\(ms) n=\(calendarDotDates.count) regionOnly=\(calendarUsesVisibleMapRegionOnly) sport=\(selectedSport)")
        print("[DiscoverPerf] calendar dots recompute ms=\(ms) n=\(calendarDotDates.count) regionOnly=\(calendarUsesVisibleMapRegionOnly) sport=\(selectedSport)")
        let clientDotsSnapshot = calendarDotDates
        let tokenGen = scheduleDataGeneration
        let venueIdsSnapshot = Array(Set(bars.map(\.id)))
        let ownerEmailsSnapshot = Array(
            Set(bars.compactMap { $0.ownerEmail?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        )
        let venueNamesSnapshot = Array(
            Set(bars.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        )
        scheduleCalendarDotRPCShadowCompareAfterRecompute(
            tokenKey: key,
            tokenGen: tokenGen,
            clientDots: clientDotsSnapshot,
            sport: selectedSport,
            regionOnly: calendarUsesVisibleMapRegionOnly,
            barsCount: bars.count,
            venueIds: venueIdsSnapshot,
            ownerEmails: ownerEmailsSnapshot,
            venueNames: venueNamesSnapshot
        )
        #endif
    }

    private func calendarEventsListCacheKey(selectedDay: Date, searchQuery: String, filter: CalendarTabGameFilter) -> String {
        let cal = Calendar.current
        let day = cal.startOfDay(for: selectedDay)
        let y = cal.component(.year, from: selectedDay)
        let m = cal.component(.month, from: selectedDay)
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let pd = pickupDiscoverCalendarDayPublicFingerprint(selectedDay: selectedDay, searchQuery: q, filter: filter)
        let viewportScope = filter == .venueGames ? calendarTabMapViewportScopeFingerprint() : 0
        let teamScope = discoverPickupTeamScope.rawValue
        let myTeams = discoverMyActiveFanTeamIds.map { $0.uuidString.lowercased() }.sorted().joined(separator: ",")
        return "\(y)-\(m)|\(Int(day.timeIntervalSince1970))|\(selectedSport)|\(calendarUsesVisibleMapRegionOnly)|\(scheduleDataGeneration)|ctf:\(filter.rawValue)|q:\(q)|pd:\(pd)|vps:\(viewportScope)|ts:\(teamScope)|mt:\(myTeams)"
    }

    /// Fingerprint for pickup rows shown on Calendar (Discover map list + My Teams scope; ignores personal join-request caches).
    private func pickupDiscoverCalendarDayPublicFingerprint(selectedDay: Date, searchQuery: String, filter: CalendarTabGameFilter) -> Int {
        guard filter == .pickupGames else { return 0 }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: selectedDay)
        var h = Hasher()
        h.combine(discoverPickupTeamScope.rawValue)
        h.combine(discoverMyActiveFanTeamIds)
        for row in pickupGamesForDiscoverMap {
            guard calendarTabPickupRowPassesListingFilters(row) else { continue }
            guard calendarTabPickupRowPassesTeamScope(row) else { continue }
            guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else { continue }
            guard cal.isDate(start, inSameDayAs: dayStart) else { continue }
            guard selectedSport == "All" || row.sport == selectedSport else { continue }
            guard calendarTabLocalQueryMatchesPickupRow(row, query: searchQuery) else { continue }
            h.combine(row.id)
            h.combine(row.updated_at ?? "")
            h.combine(row.approved_join_count ?? -1)
            h.combine(row.players_needed)
            h.combine(row.status)
            h.combine(row.is_visible)
            h.combine(pickupDiscoverTeamIdentityByGameId[row.id]?.teamId)
        }
        return h.finalize()
    }

    private func pruneCalendarEventsListCacheIfNeeded() {
        guard calendarEventsListCache.count > Self.calendarEventsListCacheMaxKeys else { return }
        let pairs = calendarEventsListCache.map { ($0.key, $0.value.storedAt) }.sorted { $0.1 < $1.1 }
        let drop = max(0, pairs.count - Self.calendarEventsListCacheMaxKeys)
        for i in 0..<drop {
            calendarEventsListCache.removeValue(forKey: pairs[i].0)
        }
    }

    /// Synthetic league label for pickup rows in the Calendar tab list.
    static let calendarTabPickupLeagueMarker = "Pickup Game"

    /// Bottom-tab Calendar: reset to today, refresh dots + schedule loads (does not mutate Discover ``selectedDate``).
    func noteCalendarTabBecameActive() {
        if let last = lastCalendarTabBecameActiveAt,
           Date().timeIntervalSince(last) < 8 {
            TabPerf.refreshSkipped(name: "calendarTabActivation", reason: "freshCache")
            SchedulePerf.refreshSkippedFresh(source: "calendarTabActivation", ageSec: Date().timeIntervalSince(last))
            return
        }
        lastCalendarTabBecameActiveAt = Date()
        SchedulePerf.activation(
            source: "noteCalendarTabBecameActive",
            cachedProRows: 0,
            inventoryRows: liveMatches.count
        )
        AppPerfDebug.deferredWork(tab: "calendar", work: "calendarTabActivation", source: "noteCalendarTabBecameActive")
        Task { @MainActor in
            await Task.yield()
            loadGamesFromSupabaseIfCalendarScheduleStale(reason: "calendar_tab_active")
            loadCalendarTabCalendarDotsAroundMonth(calendarTabSelectedDate, reason: "calendar_tab_active")
        }
    }

    func loadGamesFromSupabaseIfCalendarScheduleStale(reason: String) {
        let age = lastDiscoverCoreRefreshAt.map { Date().timeIntervalSince($0) }
        if let age, age < 90, !events.isEmpty {
#if DEBUG
            TabPerfDebug.log("[TabPerfDebug] cacheAge=\(String(format: "%.1f", age)) tab=calendar source=schedule")
            TabPerfDebug.log("[TabPerfDebug] usedCachedData=true tab=calendar source=schedule")
            TabPerfDebug.log("[TabPerfDebug] refreshSkippedReason=fresh tab=calendar source=schedule reason=\(reason)")
#endif
            return
        }
#if DEBUG
        TabPerfDebug.log("[TabPerfDebug] refreshStarted=calendar source=schedule reason=\(reason)")
#endif
        loadGamesFromSupabase()
    }

    /// Calendar tab list: venue (`Venue Event`) + optional pickup synthesis; never shows days before today.
    func calendarScreenDisplayedEvents(selectedDate: Date, searchQuery: String, filter: CalendarTabGameFilter) -> [SportsEvent] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: selectedDate)
        let todayStart = cal.startOfDay(for: Date())
        guard dayStart >= todayStart else { return [] }

        let key = calendarEventsListCacheKey(selectedDay: selectedDate, searchQuery: searchQuery, filter: filter)
        if let entry = calendarEventsListCache[key],
           Date().timeIntervalSince(entry.storedAt) < Self.calendarEventsListCacheTTL {
            SchedulePerf.dateCache(hit: true, filtered: entry.events.count, revision: scheduleDataGeneration)
            return entry.events
        }

        let buildStarted = CFAbsoluteTimeGetCurrent()
        let built = buildCalendarTabDisplayedEvents(selectedDate: selectedDate, searchQuery: searchQuery, filter: filter)
        let buildMs = (CFAbsoluteTimeGetCurrent() - buildStarted) * 1000
        SchedulePerf.snapshotBuild(
            ms: buildMs,
            filtered: built.count,
            inventory: events.count,
            reason: "venuePickupList:\(filter.rawValue)"
        )
        if let prior = calendarEventsListCache[key], prior.events == built {
            calendarEventsListCache[key] = (storedAt: Date(), events: prior.events)
            SchedulePerf.publishSkippedIdentical(rows: built.count, reason: "venuePickupList")
            return prior.events
        }
        calendarEventsListCache[key] = (storedAt: Date(), events: built)
        pruneCalendarEventsListCacheIfNeeded()
        SchedulePerf.dateCache(hit: false, filtered: built.count, revision: scheduleDataGeneration)
        return built
    }

    private func buildCalendarTabDisplayedEvents(selectedDate: Date, searchQuery: String, filter: CalendarTabGameFilter) -> [SportsEvent] {
        switch filter {
        case .pickupGames:
            return calendarTabPickupSportsEvents(for: selectedDate, searchQuery: searchQuery).sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                if $0.time != $1.time { return $0.time < $1.time }
                return $0.title < $1.title
            }
        case .venueGames:
            return calendarTabVenueSportsEvents(for: selectedDate, searchQuery: searchQuery).sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                if $0.time != $1.time { return $0.time < $1.time }
                return $0.title < $1.title
            }
        case .proGames:
            return []
        }
    }

    private func calendarTabLocalQueryMatchesEvent(_ event: SportsEvent, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return event.title.localizedCaseInsensitiveContains(q)
            || event.league.localizedCaseInsensitiveContains(q)
            || event.sport.localizedCaseInsensitiveContains(q)
            || SportFilterCatalog.storedSport(event.sport, matchesSearchQuery: q)
    }

    private func calendarTabLocalQueryMatchesPickupRow(_ row: PickupGameRow, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        if row.title.localizedCaseInsensitiveContains(q) { return true }
        if row.sport.localizedCaseInsensitiveContains(q) { return true }
        if SportFilterCatalog.storedSport(row.sport, matchesSearchQuery: q) { return true }
        if (row.address ?? "").localizedCaseInsensitiveContains(q) { return true }
        if (row.city ?? "").localizedCaseInsensitiveContains(q) { return true }
        if (row.state ?? "").localizedCaseInsensitiveContains(q) { return true }
        return false
    }

    private func calendarTabPickupRowPassesListingFilters(_ row: PickupGameRow, now: Date = Date()) -> Bool {
        guard row.status.lowercased() == "active" else { return false }
        if let remStr = row.remove_after_at,
           let rem = PickupGameModels.parseSupabaseTimestamptz(remStr),
           rem <= now {
            return false
        }
        if row.is_visible { return true }
        // Private Team games already returned by Discover RLS for active members.
        guard !isGuestDiscoverMode else { return false }
        return DiscoverPickupTeamScopeFilter.includes(
            gameId: row.id,
            scope: .myTeams,
            myActiveTeamIds: discoverMyActiveFanTeamIds,
            teamIdentityByGameId: pickupDiscoverTeamIdentityByGameId
        )
    }

    /// Schedule Play My Teams scope (shared state with Discover map).
    private func calendarTabPickupRowPassesTeamScope(_ row: PickupGameRow) -> Bool {
        DiscoverPickupTeamScopeFilter.includes(
            gameId: row.id,
            scope: discoverPickupTeamScope,
            myActiveTeamIds: discoverMyActiveFanTeamIds,
            teamIdentityByGameId: pickupDiscoverTeamIdentityByGameId
        )
    }

    /// Whether a Schedule/search pickup row passes listing + My Teams scope.
    func calendarTabPickupRowPassesScheduleFilters(_ row: PickupGameRow, now: Date = Date()) -> Bool {
        calendarTabPickupRowPassesListingFilters(row, now: now)
            && calendarTabPickupRowPassesTeamScope(row)
    }

    /// Public Discover-map pickup rows for the Calendar tab (same-day, sport/search/My Teams). No personal join-request merge.
    private func calendarTabPickupPublicRows(for selectedDate: Date, searchQuery: String, logDebug: Bool = false) -> [PickupGameRow] {
        let cal = Calendar.current
        let now = Date()
        var rows: [PickupGameRow] = []
        for row in pickupGamesForDiscoverMap {
            guard calendarTabPickupRowPassesListingFilters(row, now: now) else { continue }
            guard calendarTabPickupRowPassesTeamScope(row) else { continue }
            guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else { continue }
            guard cal.isDate(start, inSameDayAs: selectedDate) else { continue }
            guard selectedSport == "All" || row.sport == selectedSport else { continue }
            guard calendarTabLocalQueryMatchesPickupRow(row, query: searchQuery) else { continue }
            rows.append(row)
        }
        rows.sort { a, b in
            let da = PickupGameModels.parseSupabaseTimestamptz(a.game_start_at) ?? .distantPast
            let db = PickupGameModels.parseSupabaseTimestamptz(b.game_start_at) ?? .distantPast
            if da != db { return da < db }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
        if logDebug {
#if DEBUG
            let dayLabel = Self.calendarPickupDebugDayFormatter.string(from: selectedDate)
            print("[CalendarPickupRequestsDebug] selectedDate=\(dayLabel)")
            print("[CalendarPickupRequestsDebug] publicPickupListCount=\(rows.count)")
            print("[CalendarPickupPublicMode] personalStateHidden=true mode=publicCalendarList")
#endif
        }
        return rows
    }

    private static let calendarPickupDebugDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Schedule > Venues: map-viewport scope only (``mapVisibleBars`` or ``bars``), mirroring Discover calendar dots.
    private func calendarTabMapViewportVenueScope() -> (ids: Set<UUID>, loweredNames: Set<String>) {
        let basis = mapVisibleBars.isEmpty ? bars : mapVisibleBars
        guard !basis.isEmpty else { return ([], []) }
        var ids = Set<UUID>()
        var loweredNames = Set<String>()
        ids.reserveCapacity(basis.count)
        loweredNames.reserveCapacity(basis.count)
        for bar in basis {
            ids.insert(bar.id)
            let name = bar.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                loweredNames.insert(name.lowercased())
            }
        }
        return (ids, loweredNames)
    }

    private func calendarTabMapViewportScopeFingerprint() -> Int {
        let scope = calendarTabMapViewportVenueScope()
        var hasher = Hasher()
        hasher.combine(scope.ids.count)
        hasher.combine(scope.loweredNames.count)
        for id in scope.ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            hasher.combine(id)
        }
        for name in scope.loweredNames.sorted() {
            hasher.combine(name)
        }
        hasher.combine(mapVisibleBars.count)
        hasher.combine(bars.count)
        return hasher.finalize()
    }

    private func calendarTabVenueEventIsInMapViewport(_ event: SportsEvent) -> Bool {
        guard event.league == "Venue Event" else { return false }
        let scope = calendarTabMapViewportVenueScope()
        guard !scope.ids.isEmpty || !scope.loweredNames.isEmpty else { return false }

        if let row = matchingCalendarVenueEventRow(for: event) {
            if let venueID = row.venue_id, scope.ids.contains(venueID) {
                return true
            }
            if let venueName = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines),
               !venueName.isEmpty,
               scope.loweredNames.contains(venueName.lowercased()) {
                return true
            }
            return false
        }

        if let bar = barVenueForCalendarVenueEvent(event) {
            return scope.ids.contains(bar.id) || scope.loweredNames.contains(bar.name.lowercased())
        }
        return false
    }

    /// Same predicates as ``calendarTabVenueSportsEvents`` (sport + Discover-area viewport), without day/search.
    /// Used so Schedule calendar dots match the visible Watch list.
    func calendarTabListConsistentVenueDotDates() -> Set<Date> {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var days = Set<Date>()
        for event in events {
            guard event.league == "Venue Event" else { continue }
            let day = cal.startOfDay(for: event.date)
            guard day >= today else { continue }
            guard selectedSport == "All" || event.sport == selectedSport else { continue }
            guard calendarTabVenueEventIsInMapViewport(event) else { continue }
            days.insert(day)
        }
        return days
    }

    /// Schedule Play orange dots: **month availability** from ``pickupGameCalendarDotDates``.
    ///
    /// Must NOT derive from ``pickupGamesForDiscoverMap`` — that array is **selected-day scoped**,
    /// so rebuilding dots from it collapses `{Jul30, Jul31}` → `{selectedDate}` on every date tap.
    func calendarTabListConsistentPickupDotDates() -> Set<Date> {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return Set(
            pickupGameCalendarDotDates
                .map { cal.startOfDay(for: $0) }
                .filter { $0 >= today }
        )
    }

    /// Same predicates as ``calendarProGamesDisplayed`` across all loaded matches (no search), for Schedule Pro dots.
    func calendarTabListConsistentProDotDates(
        sportFilter: String,
        worldCupOnly: Bool = false,
        selectedLeagueCountries: Set<String> = [],
        featuredEvent: FeaturedEvent? = nil
    ) -> Set<Date> {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let sport = sportFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        var days = Set<Date>()
        for match in liveMatches {
            let day = cal.startOfDay(for: match.startTime)
            guard day >= today else { continue }
            if featuredEvent == nil {
                let sportOk = sport.isEmpty
                    || sport.localizedCaseInsensitiveCompare("All") == .orderedSame
                    || match.sport.localizedCaseInsensitiveCompare(sport) == .orderedSame
                    || SportFilterCatalog.storedSport(match.sport, matchesSearchQuery: sport)
                guard sportOk else { continue }
            }
            if let featuredEvent {
                guard LiveMatchFilters.matchesFeaturedEvent(match, featuredEvent: featuredEvent) else { continue }
            } else if worldCupOnly {
                guard LiveMatchFilters.isFifaWorldCupMatch(match) else { continue }
            }
            if featuredEvent == nil {
                guard LiveMatchFilters.matchesLeagueCountry(match, selectedCountries: selectedLeagueCountries) else {
                    continue
                }
            }
            days.insert(day)
        }
        return days
    }

    /// Single-pass strip inventory for the Schedule date strip.
    ///
    /// Semantically equivalent to checking `!calendarScreenDisplayedEvents(...).isEmpty` /
    /// `!calendarProGamesDisplayed(...).isEmpty` for each strip day, but avoids rebuilding and
    /// sorting a full day list seven times during every Calendar body evaluation (the dominant
    /// first-open MainActor cost).
    func calendarTabStripDaysWithListInventory(
        stripDates: [Date],
        filter: CalendarTabGameFilter,
        proSportFilter: String = "All",
        proLeagueCountries: Set<String> = [],
        proFeaturedEvent: FeaturedEvent? = nil
    ) -> Set<Date> {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var stripDays = Set<Date>()
        stripDays.reserveCapacity(stripDates.count)
        for date in stripDates {
            let day = cal.startOfDay(for: date)
            guard day >= today else { continue }
            stripDays.insert(day)
        }
        guard !stripDays.isEmpty else { return [] }

        switch filter {
        case .venueGames:
            var result = Set<Date>()
            for event in events {
                guard event.league == "Venue Event" else { continue }
                let day = cal.startOfDay(for: event.date)
                guard stripDays.contains(day) else { continue }
                guard selectedSport == "All" || event.sport == selectedSport else { continue }
                guard calendarTabVenueEventIsInMapViewport(event) else { continue }
                result.insert(day)
                if result.count == stripDays.count { break }
            }
            return result
        case .pickupGames:
            let now = Date()
            var result = Set<Date>()
            for row in pickupGamesForDiscoverMap {
                guard calendarTabPickupRowPassesListingFilters(row, now: now) else { continue }
                guard calendarTabPickupRowPassesTeamScope(row) else { continue }
                guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else { continue }
                let day = cal.startOfDay(for: start)
                guard stripDays.contains(day) else { continue }
                guard selectedSport == "All" || row.sport == selectedSport else { continue }
                result.insert(day)
                if result.count == stripDays.count { break }
            }
            return result
        case .proGames:
            let sport = proSportFilter.trimmingCharacters(in: .whitespacesAndNewlines)
            var result = Set<Date>()
            for match in liveMatches {
                let day = cal.startOfDay(for: match.startTime)
                guard stripDays.contains(day) else { continue }
                if proFeaturedEvent == nil {
                    let sportOk = sport.isEmpty
                        || sport.localizedCaseInsensitiveCompare("All") == .orderedSame
                        || match.sport.localizedCaseInsensitiveCompare(sport) == .orderedSame
                        || SportFilterCatalog.storedSport(match.sport, matchesSearchQuery: sport)
                    guard sportOk else { continue }
                }
                if let featuredEvent = proFeaturedEvent {
                    guard LiveMatchFilters.matchesFeaturedEvent(match, featuredEvent: featuredEvent) else { continue }
                }
                if proFeaturedEvent == nil {
                    guard LiveMatchFilters.matchesLeagueCountry(match, selectedCountries: proLeagueCountries) else {
                        continue
                    }
                }
                result.insert(day)
                if result.count == stripDays.count { break }
            }
            return result
        }
    }

    /// Warm Schedule caches without selecting the Calendar tab (data only — no UI mount).
    /// Safe to call from launch warm preload; joins existing in-flight work and respects TTLs.
    func warmCalendarTabCachesInBackground(reason: String) async {
        CalendarActivationPerf.log("warmStarted reason=\(reason)")
        if canFanUsePickupGamesUI {
            await refreshCalendarTabPickupSources(forceRefresh: false, reason: "warm:\(reason)")
        }
        // Populate month-dot caches silently even while Calendar is not selected.
        loadCalendarTabCalendarDotsAroundMonth(
            calendarTabSelectedDate,
            reason: "warm_preload_\(reason)",
            allowWhenNotSelected: true
        )
        // Pre-seed the 7-day strip list cache so first Calendar body hits warm entries.
        preseedCalendarEventsListCacheForVisibleStrip(reason: reason)
        CalendarActivationPerf.log("warmFinished reason=\(reason)")
    }

    /// Builds (and caches) venue/pickup lists for the visible date-strip window without publishing UI.
    private func preseedCalendarEventsListCacheForVisibleStrip(reason: String) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let selectedDay = calendar.startOfDay(for: calendarTabSelectedDate)
        let sixDaysFromToday = calendar.date(byAdding: .day, value: 6, to: today) ?? today
        let startDay = (today...sixDaysFromToday).contains(selectedDay) ? today : selectedDay
        let stripDates = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: startDay) }
        let started = CFAbsoluteTimeGetCurrent()
        for date in stripDates {
            _ = calendarScreenDisplayedEvents(selectedDate: date, searchQuery: "", filter: .venueGames)
            _ = calendarScreenDisplayedEvents(selectedDate: date, searchQuery: "", filter: .pickupGames)
        }
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        CalendarActivationPerf.stripInventoryBuilt(ms: ms, days: stripDates.count, cacheHit: false)
        SchedulePerf.snapshotBuild(
            ms: ms,
            filtered: stripDates.count,
            inventory: events.count,
            reason: "warmStripPreseed:\(reason)"
        )
    }

    private func calendarTabVenueSportsEvents(for selectedDate: Date, searchQuery: String) -> [SportsEvent] {
        let cal = Calendar.current
        let base = events.filter { event in
            guard cal.isDate(event.date, inSameDayAs: selectedDate) else { return false }
            guard event.league == "Venue Event" else { return false }
            guard selectedSport == "All" || event.sport == selectedSport else { return false }
            return calendarTabVenueEventIsInMapViewport(event)
        }
        return base.filter { calendarTabLocalQueryMatchesEvent($0, query: searchQuery) }
    }

    private static let calendarTabPickupListTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private func calendarTabPickupSportsEvents(for selectedDate: Date, searchQuery: String) -> [SportsEvent] {
        let cal = Calendar.current
        let rows = calendarTabPickupPublicRows(for: selectedDate, searchQuery: searchQuery, logDebug: true)
        let events: [SportsEvent] = rows.compactMap { row -> SportsEvent? in
            guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else { return nil }
            let day = cal.startOfDay(for: start)
            let timeLabel = Self.calendarTabPickupListTimeFormatter.string(from: start)
            return SportsEvent(
                id: row.id,
                title: row.title,
                sport: row.sport,
                league: MapViewModel.calendarTabPickupLeagueMarker,
                date: day,
                time: timeLabel,
                country: "",
                calendarPickupJoinStatus: nil
            )
        }
        return events.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.time != $1.time { return $0.time < $1.time }
            return $0.title < $1.title
        }
    }

    var datesWithEvents: Set<DateComponents> {
        Set(events.map {
            Calendar.current.dateComponents([.year, .month, .day], from: $0.date)
        })
    }

    func selectEvent(_ event: SportsEvent) {
        selectedEvent = event
        selectedSport = event.sport
        selectedBar = nil
    }

    func gamesForSelectedDate(at bar: BarVenue) -> [SportsEvent] {
        matchingEventsForDiscoverFilter(bar: bar)
    }

    /// Games at this venue that match the Discover date, sport chip, and search rules.
    func matchingEventsForDiscoverFilter(bar: BarVenue) -> [SportsEvent] {
        let q = effectiveDiscoverSearchQuery
        let daySportGames = events.filter { event in
            Calendar.current.isDate(event.date, inSameDayAs: selectedDate) &&
                bar.games.contains(event.title) &&
                (selectedSport == "All" || event.sport == selectedSport)
        }
        if q.isEmpty {
            return daySportGames
        }
        let byEventText = daySportGames.filter { matchesSearch($0) }
        if !byEventText.isEmpty { return byEventText }
        if bar.name.localizedCaseInsensitiveContains(q)
            || bar.address.localizedCaseInsensitiveContains(q) {
            return daySportGames
        }
        return []
    }

    func venueHasVisibleGameToday(_ venue: BarVenue) -> Bool {
        !selectedDayEventsForMap(venue).isEmpty
    }

    func shouldShowVenueOnMap(_ venue: BarVenue) -> Bool {
        guard venueIsActiveForMap(venue) else { return false }
        guard !venue.isPickupPlayPlace else { return false }

        if let venueFilter = discoverSearchVenueIDFilter {
            return venueFilter.contains(venue.id)
        }

        let sportScopedEvents = selectedDayEventsForMap(venue)
        let allSportEvents = selectedDayEventsForMap(venue, sportFilter: "All")
        let searchScopedEvents = selectedSport == "All"
            ? selectedDayEventsForMap(venue, sportFilter: "All")
            : sportScopedEvents

        guard venueMatchesMapSearch(venue, candidateEvents: searchScopedEvents) else { return false }

        if mapDisplayMode == .gamesOnly {
            return selectedSport == "All" ? !allSportEvents.isEmpty : !sportScopedEvents.isEmpty
        }

        if selectedSport == "All" {
            return true
        }
        return !sportScopedEvents.isEmpty
    }

    var mapVisibleBars: [BarVenue] {
        bars.filter { shouldShowVenueOnMap($0) }
    }

    func pickupPlaceBarsForDiscoverMap() -> [BarVenue] {
        bars.filter { shouldShowPickupPlaceOnMap($0) }
    }

    func shouldShowPickupPlaceOnMap(_ venue: BarVenue) -> Bool {
        guard venueIsActiveForMap(venue) else { return false }
        guard venue.isPickupPlayPlace else { return false }
        guard pickupPlaceMatchesSelectedSport(venue) else { return false }
        return pickupPlaceMatchesMapSearch(venue)
    }

    private func pickupPlaceMatchesSelectedSport(_ venue: BarVenue) -> Bool {
        let selected = selectedSport.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selected != "All" else { return true }
        return venue.sportTags.contains { tag in
            tag.localizedCaseInsensitiveContains(selected)
                || selected.localizedCaseInsensitiveContains(tag)
                || SportFilterCatalog.storedSport(tag, matchesSearchQuery: selected)
        }
    }

    private func pickupPlaceMatchesMapSearch(_ venue: BarVenue) -> Bool {
        let q = effectiveDiscoverSearchQuery
        guard !q.isEmpty else { return true }
        if venue.name.localizedCaseInsensitiveContains(q) || venue.address.localizedCaseInsensitiveContains(q) {
            return true
        }
        if venue.placeType?.localizedCaseInsensitiveContains(q) == true { return true }
        return venue.sportTags.contains { SportFilterCatalog.storedSport($0, matchesSearchQuery: q) || $0.localizedCaseInsensitiveContains(q) }
    }

    /// Venues that host at least one matching event for the current Discover filters.
    var filteredBars: [BarVenue] {
        bars.filter { !matchingEventsForDiscoverFilter(bar: $0).isEmpty }
    }

    /// Clears map preview selection when the venue is no longer present in loaded map data (e.g. region reload).
    /// Keeps ``selectedBar`` when the venue still exists in ``bars`` but has no games for the current date/sport filter (e.g. Following → saved venue).
    func pruneSelectionIfNeededAfterFilterChange() {
        if discoverMapContentMode == .pickupGames {
            if discoverPickupSubMode == .places {
                pruneSelectedPickupPlaceIfNeeded()
                pruneSelectedDiscoverableFanTeamIfNeeded()
                return
            }
            if let row = selectedPickupGameForMap {
                let pins = pickupGamesVisibleAsMapPinsWithDiscoverSearch(for: currentMapRegionBounds())
                if !pins.contains(where: { $0.id == row.id }) {
                    clearPickupMapSelection()
                }
                return
            }
        }
        guard let bar = selectedBar else { return }
        if !bars.contains(where: { $0.id == bar.id }) {
            if discoverRemotePreviewHoldVenueId == bar.id {
                return
            }
            selectedBar = nil
            selectedEvent = nil
            discoverRemotePreviewHoldVenueId = nil
        }
    }

    func clearSelectedEvent() {
        selectedEvent = nil
        selectedBar = nil
        discoverRemotePreviewHoldVenueId = nil
        selectedPickupGameForMap = nil
        selectedPickupPlaceForMap = nil
        selectedDiscoverableFanTeamForMap = nil
    }

    func selectedDayEventsForMap(_ venue: BarVenue, sportFilter: String? = nil) -> [SportsEvent] {
        let effectiveSport = sportFilter ?? selectedSport
        let cal = Calendar.current
        return events.filter { event in
            cal.isDate(event.date, inSameDayAs: selectedDate) &&
                venue.games.contains(event.title) &&
                (effectiveSport == "All" || event.sport == effectiveSport)
        }
    }

    private func venueMatchesMapSearch(_ venue: BarVenue, candidateEvents: [SportsEvent]) -> Bool {
        let q = effectiveDiscoverSearchQuery
        guard !q.isEmpty else { return true }
        if venue.name.localizedCaseInsensitiveContains(q) || venue.address.localizedCaseInsensitiveContains(q) {
            return true
        }
        return candidateEvents.contains { matchesSearch($0) }
    }

    private func venueIsActiveForMap(_ venue: BarVenue) -> Bool {
        let normalized = venue.adminStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return normalized.isEmpty || normalized == "active"
    }

    func loadEventsFromInternet() async {

        isLoadingEvents = true

        eventLoadError = nil

        do {

            let onlineEvents = try await SportsAPIService.shared.fetchEvents(

                for: selectedDate,

                sport: selectedSport

            )

            if onlineEvents.isEmpty {
                events = []
                bumpScheduleDataGeneration()
            } else {
                events = onlineEvents
                bumpScheduleDataGeneration()
            }

        } catch {

            print(error)
            eventLoadError = "Could not load events from internet."
            events = []
            bumpScheduleDataGeneration()
        }
        isLoadingEvents = false

    }

    func dateChanged() {
        selectedEvent = nil
        selectedBar = nil
        discoverRemotePreviewHoldVenueId = nil
        clearDiscoverVenueEventSearchFilter()
        loadGamesFromSupabase()
    }

    func setDiscoverMapStatus(
        _ text: String?,
        isLoading: Bool,
        isError: Bool = false,
        autoClearAfter delay: TimeInterval? = nil
    ) {
        mapStatusDismissTask?.cancel()
        mapStatusDismissTask = nil
        isUpdatingMapGames = isLoading
        mapStatusIsError = isError && !(text?.isEmpty ?? true)
        mapStatusText = text

        guard let delay, delay > 0, let text, !text.isEmpty else { return }
        mapStatusDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            guard self.mapStatusText == text, !self.isUpdatingMapGames else { return }
            self.mapStatusText = nil
            self.mapStatusIsError = false
            self.mapStatusDismissTask = nil
        }
    }

    /// User-facing Discover toast language for background refresh (no cache/stale jargon).
    func discoverMapRefreshStatusLanguageCode() -> String {
        L10n.normalizedLanguageCode(UserDefaults.standard.string(forKey: L10n.appLanguageKey))
    }

    func discoverMapRefreshSportDisplayName() -> String? {
        let trimmed = selectedSport.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "All" else { return nil }
        switch trimmed {
        case "NBA": return "Basketball"
        case "NFL": return "Football"
        case "NHL": return "Hockey"
        case "MLB": return "Baseball"
        default:
            if let pair = AppSportCatalog.discoverMapDefaultPopularPairs.first(where: { $0.0 == trimmed }) {
                return pair.1
            }
            return AppSportCatalog.displayLabel(forSportToken: trimmed)
        }
    }

    /// Transient toast while results are already on screen and a refresh is running.
    func discoverMapRefreshUpdatingToastText() -> String {
        let languageCode = discoverMapRefreshStatusLanguageCode()
        switch discoverMapContentMode {
        case .pickupGames:
            if discoverPickupSubMode == .places {
                return L10n.t("discover_refresh_updating_places", languageCode: languageCode)
            }
            return L10n.t("discover_refresh_updating_pickup", languageCode: languageCode)
        case .venues:
            if mapDisplayMode == .gamesOnly {
                if let sport = discoverMapRefreshSportDisplayName() {
                    return String(
                        format: L10n.t("discover_refresh_updating_hosting_sport_format", languageCode: languageCode),
                        locale: Locale(identifier: languageCode),
                        sport
                    )
                }
                return L10n.t("discover_refresh_updating_hosting", languageCode: languageCode)
            }
            if let sport = discoverMapRefreshSportDisplayName() {
                return String(
                    format: L10n.t("discover_refresh_updating_watch_sport_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    sport
                )
            }
            return L10n.t("discover_refresh_updating_watch", languageCode: languageCode)
        }
    }

    /// Transient toast / dock copy when no pins are visible yet and a refresh is running.
    func discoverMapRefreshLookingToastText() -> String {
        let languageCode = discoverMapRefreshStatusLanguageCode()
        switch discoverMapContentMode {
        case .pickupGames:
            if discoverPickupSubMode == .places {
                return L10n.t("discover_refresh_looking_places", languageCode: languageCode)
            }
            return L10n.t("discover_refresh_looking_pickup", languageCode: languageCode)
        case .venues:
            if mapDisplayMode == .gamesOnly {
                if let sport = discoverMapRefreshSportDisplayName() {
                    return String(
                        format: L10n.t("discover_refresh_looking_hosting_sport_format", languageCode: languageCode),
                        locale: Locale(identifier: languageCode),
                        sport
                    )
                }
                return L10n.t("discover_refresh_looking_hosting", languageCode: languageCode)
            }
            if let sport = discoverMapRefreshSportDisplayName() {
                return String(
                    format: L10n.t("discover_refresh_looking_watch_sport_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    sport
                )
            }
            return L10n.t("discover_refresh_looking_watch", languageCode: languageCode)
        }
    }

    func discoverMapRefreshUpdatedJustNowText() -> String {
        L10n.t("discover_refresh_updated_just_now", languageCode: discoverMapRefreshStatusLanguageCode())
    }

    func discoverMapRefreshShowingAvailableText() -> String {
        L10n.t("discover_refresh_showing_available", languageCode: discoverMapRefreshStatusLanguageCode())
    }

    func discoverMapRefreshCouldNotUpdateText() -> String {
        L10n.t("discover_refresh_couldnt_update", languageCode: discoverMapRefreshStatusLanguageCode())
    }

    /// Local start-of-day floor for Discover map date selection (Calendar tab uses its own picker without this floor).
    func discoverMapCalendarSelectionMinimumDayStart() -> Date {
        Calendar.current.startOfDay(for: Date())
    }

    @discardableResult
    func clampDiscoverMapSelectedDateToMinimumCalendarDayIfNeeded() -> Bool {
        let cal = Calendar.current
        let minDay = discoverMapCalendarSelectionMinimumDayStart()
        let cur = cal.startOfDay(for: selectedDate)
        guard cur < minDay else { return false }
        selectedDate = minDay
        #if DEBUG
        print("[DiscoverCalendar] selected date clamped to today")
        #endif
        return true
    }

    func beginDiscoverDateChange(to date: Date) -> UUID {
        let cal = Calendar.current
        let minDay = cal.startOfDay(for: Date())
        let requested = cal.startOfDay(for: date)
        let nextDate = max(requested, minDay)
        #if DEBUG
        if requested < minDay {
            print("[DiscoverCalendar] selected date clamped to today")
        }
        #endif
        selectedEvent = nil
        discoverRemotePreviewHoldVenueId = nil
        selectedDate = nextDate
        eventLoadError = nil
        discoverSelectedDayRefreshTask?.cancel()
        discoverSelectedDayRefreshTask = nil
        let requestID = UUID()
        discoverSelectedDayRefreshRequestID = requestID
        markPickupDiscoverMapDataDirtyForNextRefresh()
        if discoverMapContentMode == .pickupGames, discoverPickupSubMode == .games {
            let hasExisting = !pickupGamesForDiscoverMap.isEmpty
            setDiscoverMapStatus(
                hasExisting ? discoverMapRefreshUpdatingToastText() : discoverMapRefreshLookingToastText(),
                isLoading: true
            )
        } else if discoverCurrentVisibleVenueRows.isEmpty {
            setDiscoverMapStatus(discoverMapRefreshLookingToastText(), isLoading: true)
        } else {
            setDiscoverMapStatus(discoverMapRefreshUpdatingToastText(), isLoading: true)
        }
        return requestID
    }

    func scheduleDiscoverSelectedDayRefresh(requestID: UUID) {
        discoverSelectedDayRefreshTask?.cancel()
        discoverSelectedDayRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshDiscoverSelectedDayVenueEventsForCurrentContext(requestID: requestID)
        }
    }

    func discoverDateChanged() {
        #if DEBUG
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        let selectedDay = formatter.string(from: selectedDate)
        print("[DiscoverDatePerf] date selected=\(selectedDay)")
        #endif
        let requestID = beginDiscoverDateChange(to: selectedDate)
        scheduleDiscoverSelectedDayRefresh(requestID: requestID)
    }

    func noteDiscoverCalendarGuestDatePinnedByUser() {
        guard isGuestDiscoverMode else { return }
        discoverCalendarGuestUserPinnedDateThisSession = true
    }

    /// Guest Discover: when the map calendar has loaded dot dates, move off an empty selected day to the nearest upcoming day that has games (venues or pickup per current map mode).
    func applyDiscoverGuestNearestEventDateIfNeeded(reason: String) {
        guard isGuestDiscoverMode else { return }
        guard !discoverCalendarGuestUserPinnedDateThisSession else { return }
        let cal = Calendar.current
        let minDay = cal.startOfDay(for: Date())
        let sel = cal.startOfDay(for: selectedDate)
        let venueDots = venueGameCalendarDotDates
        let pickupDots = pickupGameCalendarDotDates
        let unionDots = venueDots.union(pickupDots)
        guard !unionDots.isEmpty else { return }
        let emptyForCurrentMode: Bool = {
            switch discoverMapContentMode {
            case .venues: return !venueDots.contains(sel)
            case .pickupGames: return !pickupDots.contains(sel)
            }
        }()
        guard emptyForCurrentMode else { return }
        let upcoming = unionDots.filter { $0 >= minDay }.sorted()
        guard let target = upcoming.first, target != sel else { return }
        let requestID = beginDiscoverDateChange(to: target)
        scheduleDiscoverSelectedDayRefresh(requestID: requestID)
        #if DEBUG
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        print("[DiscoverGuestCalendar] auto-selected=\(f.string(from: target)) was=\(f.string(from: sel)) reason=\(reason)")
        #endif
    }

    func sportChanged(to sport: String) {

        selectedSport = sport
        selectedEvent = nil
        selectedBar = nil
        selectedPickupGameForMap = nil
        selectedPickupPlaceForMap = nil
        selectedDiscoverableFanTeamForMap = nil
        discoverRemotePreviewHoldVenueId = nil
        clearDiscoverVenueEventSearchFilter()

        markPickupDiscoverMapDataDirtyForNextRefresh()
        if discoverMapContentMode == .venues {
            let requestID = beginDiscoverDateChange(to: selectedDate)
            #if DEBUG
            print("[DiscoverNarrowRefreshDebug] sportChangedUsingSelectedDayRefresh=true")
            print("[DiscoverNarrowRefreshDebug] skippedBroadLoadGames=true")
            #endif
            scheduleDiscoverSelectedDayRefresh(requestID: requestID)
        }
        Task {
            if discoverMapContentMode == .pickupGames, discoverPickupSubMode == .games {
                // Sport is part of month-dot cache identity; preserving avoids wipe→selected-day replace collapse.
                await refreshPickupGamesForDiscoverMap(preservePickupCalendarDotDatesCache: true)
            } else if discoverMapContentMode == .pickupGames, discoverPickupSubMode == .places {
                await refreshPickupPlacesForDiscoverMap(force: pickupPlacesForDiscoverMap.isEmpty)
                await refreshDiscoverableFanTeamsForMap(force: discoverableFanTeamsForMap.isEmpty)
            }
        }
    }

    func matchesSearch(_ event: SportsEvent) -> Bool {
        let q = effectiveDiscoverSearchQuery
        return q.isEmpty ||
            event.title.localizedCaseInsensitiveContains(q) ||
            event.sport.localizedCaseInsensitiveContains(q) ||
            SportFilterCatalog.storedSport(event.sport, matchesSearchQuery: q) ||
            event.league.localizedCaseInsensitiveContains(q)
    }

    private func discoverPreviewSQLDayString(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    /// Titles from ``venueEventRows`` for this venue on `date`, union ``BarVenue/games`` (sport chip applied to rows).
    private func venueGameTitleAllowlistForPreview(bar: BarVenue, date: Date, sportFilter: String) -> Set<String> {
        let dayStr = discoverPreviewSQLDayString(for: date)
        let barName = bar.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var titles = Set(bar.games)
        for row in venueEventRows {
            guard let ed = row.event_date, ed == dayStr else { continue }
            if sportFilter != "All" {
                guard let rs = row.sport?.trimmingCharacters(in: .whitespacesAndNewlines), rs == sportFilter else { continue }
            }
            let matchesBar: Bool
            if let vid = row.venue_id {
                matchesBar = (vid == bar.id)
            } else if let vn = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) {
                matchesBar = vn.caseInsensitiveCompare(barName) == .orderedSame
            } else {
                matchesBar = false
            }
            guard matchesBar else { continue }
            if let t = row.event_title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                titles.insert(t)
            }
        }
        return titles
    }

    /// Shared Discover venue preview game list: merged `events` for `date` + `sportFilter`, keyed by titles from ``venueEventRows`` and ``BarVenue/games``, then the same text-search rules as ``matchingEventsForDiscoverFilter``.
    func gamesForVenuePreview(bar: BarVenue, date: Date, sportFilter: String) -> [SportsEvent] {
        let cal = Calendar.current
        let q = effectiveDiscoverSearchQuery
        let titleAllowlist = venueGameTitleAllowlistForPreview(bar: bar, date: date, sportFilter: sportFilter)
        let daySportGames = events.filter { event in
            cal.isDate(event.date, inSameDayAs: date) &&
                (sportFilter == "All" || event.sport == sportFilter) &&
                titleAllowlist.contains(event.title)
        }
        if q.isEmpty {
            return daySportGames
        }
        let byEventText = daySportGames.filter { matchesSearch($0) }
        if !byEventText.isEmpty { return byEventText }
        if bar.name.localizedCaseInsensitiveContains(q)
            || bar.address.localizedCaseInsensitiveContains(q) {
            return daySportGames
        }
        return []
    }

    /// Calendar tab: venue event row matching a merged ``SportsEvent`` (`league` `Venue Event`).
    func matchingCalendarVenueEventRow(for event: SportsEvent) -> VenueEventRow? {
        guard event.league == "Venue Event" else { return nil }
        let ymd = discoverPreviewSQLDayString(for: event.date)
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sport = event.sport.trimmingCharacters(in: .whitespacesAndNewlines)
        return venueEventRows.first(where: { ev in
            guard ev.event_title?.trimmingCharacters(in: .whitespacesAndNewlines) == title else { return false }
            guard ev.event_date?.trimmingCharacters(in: .whitespacesAndNewlines) == ymd else { return false }
            let rs = ev.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return rs.isEmpty || rs == sport
        })
    }

    /// Calendar tab: resolve a ``BarVenue`` for a merged venue event (`SportsEvent` league `Venue Event`).
    func barVenueForCalendarVenueEvent(_ event: SportsEvent) -> BarVenue? {
        guard event.league == "Venue Event" else { return nil }
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)

        if let row = matchingCalendarVenueEventRow(for: event) {
            if let vid = row.venue_id, let b = bars.first(where: { $0.id == vid }) {
                return b
            }
            if let vn = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines), !vn.isEmpty,
               let b = bars.first(where: { $0.name.caseInsensitiveCompare(vn) == .orderedSame }) {
                return b
            }
        }

        return bars.first { bar in
            bar.games.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame })
        }
    }

    /// Calendar tab → Discover: bar from cache or a minimal snapshot for ``consumeFollowingVenueNavigationIfPending``.
    func snapshotBarVenueForCalendarVenueEventFocus(_ event: SportsEvent) -> BarVenue? {
        if let bar = barVenueForCalendarVenueEvent(event) {
            return bar
        }
        guard let row = matchingCalendarVenueEventRow(for: event),
              let venueId = row.venue_id else {
            return nil
        }
        let venueName = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sport = row.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? event.sport
        let eventTitle = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return BarVenue(
            id: venueId,
            name: venueName.isEmpty ? "Venue" : venueName,
            address: "",
            phone: "",
            primarySport: sport,
            distance: "",
            rating: 0,
            tags: [],
            games: eventTitle.isEmpty ? [] : [eventTitle],
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            goingCounts: [:],
            ownerEmail: row.owner_email,
            adminStatus: row.admin_status,
            venueOwnerEmailRaw: row.owner_email
        )
    }
}
