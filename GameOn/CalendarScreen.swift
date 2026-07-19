import SwiftUI

struct CalendarScreen: View {
    /// Minimum height for the scrollable events region so empty vs populated lists do not resize the header stack.
    private static let eventsListMinHeight: CGFloat = 220
    private static let calendarSearchDebounceMilliseconds: UInt64 = 350
    private static let calendarSearchResultLimit = 50
    private static let teamScheduleRecentSearchesKey = "gameon.schedule.teamSchedule.recentSearches.v1"
    private static let teamScheduleCacheDuration: TimeInterval = 20 * 60
    private static let teamScheduleResultLimit = 50

    @ObservedObject var viewModel: MapViewModel
    @Binding var selectedTab: MainTabView.AppTab
    /// False while Calendar is preserved off-screen (defers tab-only pickup refresh at launch).
    var isCalendarTabSelected: Bool = false
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @AppStorage(LiveLeagueCountryFilterPreference.appStorageKey) private var calendarLeagueCountryFilterRaw: String = ""
    @Environment(\.colorScheme) private var calendarColorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDatePicker = false
    @State private var showTeamScheduleSheet = false
    @State private var showCalendarSportMoreSheet = false
    @State private var showCalendarLeagueCountryFilterSheet = false
    @State private var calendarDatePickerDetent: PresentationDetent = .large
    @State private var gameSearchText = ""
    @State private var calendarProGamesSportFilter = "All"
    @State private var calendarProGamePredictionSheet: ProGamePredictionSheetContext?
    @State private var calendarAddToVenueChooser: CalendarAddToVenueChooserContext?
    @State private var calendarAddToVenueImportPrefill: VenueOwnerScheduleImportPrefill?
    @State private var calendarFeaturedEventFilterSlug: String?
    @State private var calendarPickupDetailToken: PickupDetailNavigationToken?
    @State private var debouncedGameSearchText = ""
    @State private var gameSearchDebounceTask: Task<Void, Never>?
    @State private var calendarSearchFilteredEvents: [SportsEvent] = []
    @State private var calendarSearchFilteredProMatches: [LiveMatch] = []
    @State private var calendarSearchResultGroups: [CalendarSearchDateGroup] = []
    @State private var calendarSearchSuggestions: [CalendarSearchSuggestion] = []
    @State private var calendarSearchIndex: [CalendarSearchIndexEntry] = []
    @State private var calendarSearchIndexFingerprint = ""
    @State private var teamScheduleSearchText = ""
    @State private var teamScheduleSelectedSport: TeamScheduleSport = .soccer
    @State private var teamScheduleSubmittedQuery = ""
    @State private var teamScheduleResults: [LiveMatch] = []
    @State private var teamScheduleIsLoading = false
    @State private var teamScheduleErrorMessage: String?
    @State private var teamScheduleRecentSearches: [String] = []
    @State private var teamScheduleLookupCache: [String: TeamScheduleCacheEntry] = [:]
    @State private var calendarProGamesPerf = CalendarProGamesPerfState()
    /// Holds the last stable venue Watch Parties list across day taps to avoid empty-state flicker.
    @State private var calendarWatchPartiesLastStableEvents: [SportsEvent] = []
    @State private var calendarWatchPartiesHeldEvents: [SportsEvent] = []
    @State private var calendarWatchPartiesDayTransitionActive = false
    @State private var calendarWatchPartiesDayTransitionGeneration: UInt64 = 0
    @State private var calendarWatchPartiesDayTransitionTask: Task<Void, Never>?
    @FocusState private var isGameSearchFocused: Bool
    @FocusState private var isTeamScheduleSearchFocused: Bool

    private struct CalendarProGamesPerfState {
        var cachedDisplayedProMatches: [LiveMatch] = []
        var cachedDisplayedProMatchesKey: String = ""
        var displayCacheByKey: [String: [LiveMatch]] = [:]
        var lastNetworkRefreshRequestedAt: Date?
        var deferredInteractionWorkTask: Task<Void, Never>?
        var pendingInteractionToken: String = ""
        var cachedSegmentBadgeCounts: [CalendarTabGameFilter: Int] = [:]
        var deferredDisplayCachePrewarmTask: Task<Void, Never>?
        var displayCacheRebuildInFlight = false
        var networkRefreshInFlight = false
        var statusIndicatorVisible = false
        var statusIndicatorShowTask: Task<Void, Never>?
        var statusIndicatorHideTask: Task<Void, Never>?
        var sportsDataUpdateGlobalFailsafeTask: Task<Void, Never>?
        var deferredLiveMatchesScheduleProRebuildTask: Task<Void, Never>?
        var pendingLiveMatchesScheduleProRebuildToken: String = ""
        var scheduleLastInteractionAt: Date?
        static let networkCoalesceInterval: TimeInterval = 25
        static let deferredNetworkRefreshDelayNs: UInt64 = 200_000_000
        static let liveMatchesScheduleProRebuildDelayNs: UInt64 = 400_000_000
        static let liveMatchesScheduleProRebuildInteractionDelayNs: UInt64 = 500_000_000
        static let scheduleRecentInteractionWindow: TimeInterval = 0.5
        static let statusIndicatorMinVisibleDelayNs: UInt64 = 300_000_000
        static let statusIndicatorMaxVisibleDuration: TimeInterval = 9
        static let displayCacheByKeyLimit = 21
        static let stripDateCachePrewarmDelayNs: UInt64 = 100_000_000
        /// Extra settle after deferred day-change work before allowing empty Watch Parties state.
        static let watchPartiesDayTransitionSettleNs: UInt64 = 180_000_000
    }

    private var isBusinessCalendarAccess: Bool {
        viewModel.currentUserIsBusinessAccount || viewModel.isVenueOwnerLoggedIn || viewModel.hasAuthenticatedVenueOwnerSession
    }

    private var calendarVisibleGameFilters: [CalendarTabGameFilter] {
        isBusinessCalendarAccess ? [.venueGames, .proGames] : [.venueGames, .pickupGames, .proGames]
    }

    private var effectiveCalendarGameFilter: CalendarTabGameFilter {
        isBusinessCalendarAccess && viewModel.calendarTabGameFilter == .pickupGames
            ? .venueGames
            : viewModel.calendarTabGameFilter
    }

    private var calendarGameFilterBinding: Binding<CalendarTabGameFilter> {
        Binding(
            get: { effectiveCalendarGameFilter },
            set: { newValue in
                viewModel.calendarTabGameFilter = isBusinessCalendarAccess && newValue == .pickupGames
                    ? .venueGames
                    : newValue
            }
        )
    }

    private let calendarProVisibleSportFilters: [(selection: String, display: String?)] = [
        ("All", nil),
        ("Soccer", nil),
        ("Basketball", nil),
        ("Football", nil),
        ("Baseball", nil),
        ("Hockey", nil),
        ("MMA", "Combat"),
        ("Racing", nil),
        ("Golf", nil),
        ("Tennis", nil),
        ("badminton", "Badminton")
    ]

    private var displayedEvents: [SportsEvent] {
        if isCalendarSearchModeActive {
            return calendarSearchFilteredEvents
        }
        return calendarBaseDisplayedEvents()
    }

    private func calendarBaseDisplayedEvents() -> [SportsEvent] {
        viewModel.calendarScreenDisplayedEvents(
            selectedDate: viewModel.calendarTabSelectedDate,
            searchQuery: "",
            filter: effectiveCalendarGameFilter
        )
    }

    private var venueEventsForSelectedDateNoSearch: [SportsEvent] {
        viewModel.calendarScreenDisplayedEvents(
            selectedDate: viewModel.calendarTabSelectedDate,
            searchQuery: "",
            filter: .venueGames
        )
    }

    private var pickupEventsForSelectedDateNoSearch: [SportsEvent] {
        viewModel.calendarScreenDisplayedEvents(
            selectedDate: viewModel.calendarTabSelectedDate,
            searchQuery: "",
            filter: .pickupGames
        )
    }

    private var displayedProMatches: [LiveMatch] {
        if isCalendarSearchModeActive {
            return calendarSearchFilteredProMatches
        }
        return calendarProGamesPerf.cachedDisplayedProMatches
    }

    private func calendarProGamesDisplayCacheKey(for date: Date? = nil) -> String {
        let resolvedDate = date ?? viewModel.calendarTabSelectedDate
        let dayStart = Int(
            Calendar.current.startOfDay(for: resolvedDate).timeIntervalSince1970
        )
        return [
            "\(dayStart)",
            calendarProGamesSportFilter,
            calendarFeaturedEventFilterSlug ?? "",
            calendarLeagueCountryFilterRaw,
            "\(viewModel.liveMatches.count)",
            "\(viewModel.activeFeaturedEvents.count)"
        ].joined(separator: "|")
    }

    private func logScheduleTapPerf(_ message: @autoclosure () -> String) {
#if DEBUG
        print(message())
#endif
    }

#if DEBUG
    private func logScheduleDateRefresh(
        _ message: String,
        previousDate: Date? = nil,
        cacheHit: Bool? = nil,
        sourceCount: Int? = nil,
        filteredCount: Int? = nil,
        renderedCount: Int? = nil,
        networkSkipped: Bool? = nil
    ) {
        let day = Self.calendarProGamesRefreshDebugDateFormatter.string(from: viewModel.calendarTabSelectedDate)
        let prev: String = {
            guard let previousDate else { return "-" }
            return Self.calendarProGamesRefreshDebugDateFormatter.string(from: previousDate)
        }()
        let featured = calendarFeaturedEventFilterSlug ?? "nil"
        var parts = [
            "[ScheduleDateRefresh] \(message)",
            "selectedDate=\(day)",
            "previousDate=\(prev)",
            "mode=\(effectiveCalendarGameFilter.rawValue)",
            "sport=\(calendarProGamesSportFilter)",
            "featured=\(featured)",
            "sourceLiveMatches=\(sourceCount ?? viewModel.liveMatches.count)",
            "filtered=\(filteredCount ?? -1)",
            "rendered=\(renderedCount ?? calendarProGamesPerf.cachedDisplayedProMatches.count)",
            "cacheKey=\(calendarProGamesDisplayCacheKey())"
        ]
        if let cacheHit { parts.append("cacheHit=\(cacheHit)") }
        if let networkSkipped { parts.append("networkSkipped=\(networkSkipped)") }
        print(parts.joined(separator: " "))
    }
#endif

    private func logScheduleTapProtectedIfNeeded() {
        if viewModel.liveSportsDataRefreshInFlight || viewModel.isLiveMatchesNetworkRefreshInFlight {
            print("[LiveSchedulePerf] scheduleTapProtected=true")
        }
    }

    private func noteScheduleRecentInteraction() {
        calendarProGamesPerf.scheduleLastInteractionAt = Date()
    }

    private func calendarInteractionToken() -> String {
        [
            calendarProGamesDayKey(for: viewModel.calendarTabSelectedDate),
            effectiveCalendarGameFilter.rawValue,
            calendarProGamesSportFilter,
            calendarFeaturedEventFilterSlug ?? "",
            calendarLeagueCountryFilterRaw
        ].joined(separator: "|")
    }

    private func scheduleCalendarInteractionDeferredWork(
        reason: String,
        forceNetworkRefresh: Bool = false,
        delayNanoseconds: UInt64 = CalendarProGamesPerfState.deferredNetworkRefreshDelayNs
    ) {
        let latest = calendarInteractionToken()

        if !calendarProGamesPerf.pendingInteractionToken.isEmpty,
           calendarProGamesPerf.pendingInteractionToken != latest {
            calendarProGamesPerf.deferredInteractionWorkTask?.cancel()
            logScheduleTapPerf("[ScheduleTapPerf] deferredWorkCancelled old=\(calendarProGamesPerf.pendingInteractionToken)")
        }

        calendarProGamesPerf.pendingInteractionToken = latest
        noteScheduleRecentInteraction()
        logScheduleTapPerf("[ScheduleTapPerf] cachePaintScheduled latest=\(latest)")

        calendarProGamesPerf.deferredInteractionWorkTask?.cancel()
        calendarProGamesPerf.deferredInteractionWorkTask = Task { @MainActor in
            viewModel.noteScheduleTabInteractionBegan()
            defer { viewModel.noteScheduleTabInteractionEnded() }
            await Task.yield()
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else {
                syncCalendarProGamesStatusIndicatorIfIdle(reason: "cancelled")
                return
            }
            guard calendarProGamesPerf.pendingInteractionToken == latest else { return }
            logScheduleTapPerf("[ScheduleTapPerf] deferredWorkStarted latest=\(latest)")
            await performCalendarInteractionDeferredWork(
                reason: reason,
                forceNetworkRefresh: forceNetworkRefresh
            )
            calendarProGamesPerf.deferredInteractionWorkTask = nil
            if calendarProGamesPerf.pendingInteractionToken == latest {
                calendarProGamesPerf.pendingInteractionToken = ""
            }
        }
    }

    private func performCalendarInteractionDeferredWork(
        reason: String,
        forceNetworkRefresh: Bool
    ) async {
        refreshCurrentDayCalendarSearchForLoadedDataChange()
        guard isCalendarTabSelected else { return }
        sanitizeBusinessCalendarFilterIfNeeded()

        if reason == "calendar_tab_filter_change" {
            viewModel.calendarEventsListCache.removeAll()
            viewModel.loadCalendarTabCalendarDotsAroundMonth(
                viewModel.calendarTabSelectedDate,
                reason: reason
            )
        }

        if isProGamesSelected {
#if DEBUG
            ProSchedulePerf.loadStarted()
#endif
            updateCalendarProGamesDisplayCache(reason: reason)
            if !shouldSkipCalendarProGamesNetworkRefresh(reason: reason, forceRefresh: forceNetworkRefresh) {
                await performCalendarProGamesNetworkRefresh(reason: reason, forceRefresh: forceNetworkRefresh)
            }
        }

        if reason == "calendar_selected_date_change" {
            refreshCalendarPickupSourcesIfNeeded(forceRefresh: true, reason: reason)
        }

        refreshCalendarSegmentBadgeCounts(reason: reason)
    }

    private func liveMatchesScheduleProRebuildDelayNanoseconds() -> UInt64 {
        if viewModel.scheduleTabInteractionProtected {
            return CalendarProGamesPerfState.liveMatchesScheduleProRebuildInteractionDelayNs
        }
        if let lastInteraction = calendarProGamesPerf.scheduleLastInteractionAt,
           Date().timeIntervalSince(lastInteraction) < CalendarProGamesPerfState.scheduleRecentInteractionWindow {
            return CalendarProGamesPerfState.liveMatchesScheduleProRebuildInteractionDelayNs
        }
        return CalendarProGamesPerfState.liveMatchesScheduleProRebuildDelayNs
    }

    private func handleLiveMatchesCountChangedWhileScheduleVisible() {
        guard isCalendarTabSelected else { return }
        print("[LiveSchedulePerf] liveMatchesChangedWhileScheduleVisible=true")

        let latest = calendarInteractionToken()
        if !calendarProGamesPerf.pendingLiveMatchesScheduleProRebuildToken.isEmpty,
           calendarProGamesPerf.pendingLiveMatchesScheduleProRebuildToken != latest {
            calendarProGamesPerf.deferredLiveMatchesScheduleProRebuildTask?.cancel()
        }
        calendarProGamesPerf.pendingLiveMatchesScheduleProRebuildToken = latest

        let delayNs = liveMatchesScheduleProRebuildDelayNanoseconds()
        let delayMs = Int(delayNs / 1_000_000)
        print("[LiveSchedulePerf] scheduleProRebuildDeferred=true delayMs=\(delayMs)")

        calendarProGamesPerf.deferredLiveMatchesScheduleProRebuildTask?.cancel()
        calendarProGamesPerf.deferredLiveMatchesScheduleProRebuildTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled else {
                syncCalendarProGamesStatusIndicatorIfIdle(reason: "cancelled")
                return
            }
            guard calendarProGamesPerf.pendingLiveMatchesScheduleProRebuildToken == latest else { return }
            guard isCalendarTabSelected else { return }
            if viewModel.scheduleTabInteractionProtected {
                handleLiveMatchesCountChangedWhileScheduleVisible()
                return
            }
            await performLiveMatchesChangedScheduleProRebuild(reason: "liveMatchesCountChanged")
            calendarProGamesPerf.deferredLiveMatchesScheduleProRebuildTask = nil
            if calendarProGamesPerf.pendingLiveMatchesScheduleProRebuildToken == latest {
                calendarProGamesPerf.pendingLiveMatchesScheduleProRebuildToken = ""
            }
        }
    }

    private func performLiveMatchesChangedScheduleProRebuild(reason: String) async {
        viewModel.flushPendingCalendarTabEventsListCacheInvalidationIfNeeded()
        refreshCurrentDayCalendarSearchForLoadedDataChange()
        guard isCalendarTabSelected else { return }

        if isProGamesSelected {
#if DEBUG
            ProSchedulePerf.loadStarted()
#endif
            updateCalendarProGamesDisplayCache(reason: reason)
        }
        refreshCalendarSegmentBadgeCounts(reason: reason)
        scheduleCalendarProGamesStripDateCachePrewarm(reason: reason)
    }

    private func refreshCalendarSegmentBadgeCounts(reason: String) {
        calendarProGamesPerf.cachedSegmentBadgeCounts = [
            .venueGames: venueEventsForSelectedDateNoSearch.count,
            .pickupGames: pickupEventsForSelectedDateNoSearch.count,
            .proGames: proMatchesForSelectedDateNoSearch.count
        ]
#if DEBUG
        print("[CalendarProGamesPerf] segmentBadgesUpdated reason=\(reason)")
#endif
    }

    private func logScheduleTapPerfDisplayedCacheUpdated(count: Int, reason: String) {
#if DEBUG
        print("[ScheduleTapPerf] displayedCacheUpdated count=\(count) reason=\(reason)")
#endif
    }

    private func storeCalendarProGamesDisplayCacheEntry(key: String, matches: [LiveMatch]) {
        calendarProGamesPerf.displayCacheByKey[key] = matches
        if calendarProGamesPerf.displayCacheByKey.count > CalendarProGamesPerfState.displayCacheByKeyLimit {
            let keepKeys = Set(calendarDateStripDates.map { calendarProGamesDisplayCacheKey(for: $0) })
                .union([calendarProGamesDisplayCacheKey()])
            calendarProGamesPerf.displayCacheByKey = calendarProGamesPerf.displayCacheByKey.filter { keepKeys.contains($0.key) }
        }
    }

    @discardableResult
    private func applyCalendarProGamesDisplayCacheIfAvailable(reason: String) -> Bool {
        guard isProGamesSelected, !isCalendarSearchModeActive else { return false }
        let key = calendarProGamesDisplayCacheKey()
        // Empty entries are not authoritative — they often mean "not fetched yet" and must not
        // block an immediate rebuild or a later network merge from painting the list.
        if let cached = calendarProGamesPerf.displayCacheByKey[key], !cached.isEmpty {
            calendarProGamesPerf.cachedDisplayedProMatchesKey = key
            calendarProGamesPerf.cachedDisplayedProMatches = cached
            logScheduleTapPerfDisplayedCacheUpdated(count: cached.count, reason: reason)
#if DEBUG
            logScheduleDateRefresh(
                "cacheApplyHit reason=\(reason)",
                cacheHit: true,
                filteredCount: cached.count,
                renderedCount: cached.count
            )
            ProSchedulePerf.totalGamesFetched(viewModel.liveMatches.count)
            ProSchedulePerf.logHydrationDeferredCount(
                cached.filter(\.supportsProGamePredictions).count
            )
#endif
            return true
        }
        if calendarProGamesPerf.cachedDisplayedProMatchesKey != key {
            calendarProGamesPerf.cachedDisplayedProMatchesKey = key
            calendarProGamesPerf.cachedDisplayedProMatches = []
#if DEBUG
            logScheduleDateRefresh(
                "cacheApplyMissClearedDisplay reason=\(reason)",
                cacheHit: false,
                filteredCount: 0,
                renderedCount: 0
            )
#endif
        }
        return false
    }

    private func updateCalendarProGamesDisplayCache(reason: String) {
        guard isProGamesSelected, !isCalendarSearchModeActive else { return }
        let key = calendarProGamesDisplayCacheKey()
        // Only skip when we already painted a non-empty list for this exact key.
        if calendarProGamesPerf.cachedDisplayedProMatchesKey == key,
           let existing = calendarProGamesPerf.displayCacheByKey[key],
           !existing.isEmpty,
           calendarProGamesPerf.cachedDisplayedProMatches.count == existing.count {
            return
        }
        calendarProGamesPerf.displayCacheRebuildInFlight = true
        syncCalendarProGamesStatusIndicator()
        defer {
            calendarProGamesPerf.displayCacheRebuildInFlight = false
            syncCalendarProGamesStatusIndicator()
        }
        let matches = calendarBaseDisplayedProMatches()
        storeCalendarProGamesDisplayCacheEntry(key: key, matches: matches)
        calendarProGamesPerf.cachedDisplayedProMatchesKey = key
        calendarProGamesPerf.cachedDisplayedProMatches = matches
        logScheduleTapPerfDisplayedCacheUpdated(count: matches.count, reason: reason)
#if DEBUG
        logScheduleDateRefresh(
            "displayCacheRebuilt reason=\(reason)",
            cacheHit: false,
            filteredCount: matches.count,
            renderedCount: matches.count
        )
        print("[CalendarProGamesPerf] displayCacheUpdated reason=\(reason) count=\(matches.count)")
        ProSchedulePerf.totalGamesFetched(viewModel.liveMatches.count)
        ProSchedulePerf.logHydrationDeferredCount(
            matches.filter(\.supportsProGamePredictions).count
        )
#endif
    }

    private func scheduleCalendarProGamesStripDateCachePrewarm(reason: String) {
        guard isProGamesSelected, isCalendarTabSelected else { return }
        prewarmCalendarProGamesDisplayCacheForSelectedDate(reason: reason)
        _ = applyCalendarProGamesDisplayCacheIfAvailable(reason: "prewarmSelected:\(reason)")
        calendarProGamesPerf.deferredDisplayCachePrewarmTask?.cancel()
        calendarProGamesPerf.deferredDisplayCachePrewarmTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: CalendarProGamesPerfState.stripDateCachePrewarmDelayNs)
            guard !Task.isCancelled else {
                syncCalendarProGamesStatusIndicatorIfIdle(reason: "cancelled")
                return
            }
            prewarmCalendarProGamesDisplayCacheForRemainingStripDates(reason: reason)
            calendarProGamesPerf.deferredDisplayCachePrewarmTask = nil
        }
    }

    private func prewarmCalendarProGamesDisplayCacheForSelectedDate(reason: String) {
        guard isProGamesSelected else { return }
        let selectedDate = viewModel.calendarTabSelectedDate
        let key = calendarProGamesDisplayCacheKey(for: selectedDate)
        guard calendarProGamesPerf.displayCacheByKey[key] == nil else { return }
        let matches = calendarBaseDisplayedProMatches(for: selectedDate)
        storeCalendarProGamesDisplayCacheEntry(key: key, matches: matches)
#if DEBUG
        print("[CalendarProGamesPerf] prewarmSelectedDate reason=\(reason) count=\(matches.count)")
#endif
    }

    private func prewarmCalendarProGamesDisplayCacheForRemainingStripDates(reason: String) {
        guard isProGamesSelected else { return }
        let selectedDate = viewModel.calendarTabSelectedDate
        let calendar = Calendar.current
        for date in calendarDateStripDates {
            guard !calendar.isDate(date, inSameDayAs: selectedDate) else { continue }
            let key = calendarProGamesDisplayCacheKey(for: date)
            guard calendarProGamesPerf.displayCacheByKey[key] == nil else { continue }
            let matches = calendarBaseDisplayedProMatches(for: date)
            storeCalendarProGamesDisplayCacheEntry(key: key, matches: matches)
        }
        applyCalendarProGamesDisplayCacheIfAvailable(reason: "prewarm:\(reason)")
    }

    private var calendarProGamesBackgroundWorkActive: Bool {
        calendarProGamesPerf.displayCacheRebuildInFlight || calendarProGamesPerf.networkRefreshInFlight
    }

    private var scheduleProListBackgroundWorkActive: Bool {
        calendarProGamesBackgroundWorkActive
            || viewModel.isLoadingLiveMatches
            || viewModel.liveSportsDataRefreshInFlight
            || viewModel.isLiveMatchesNetworkRefreshInFlight
    }

    private var scheduleProGamesListStatusMessage: String? {
        guard isProGamesSelected, !isCalendarSearchModeActive else { return nil }
        guard scheduleProListBackgroundWorkActive else { return nil }
        return scheduleProHasCachedGamesVisible
            ? "Updating games…"
            : "Loading game information…"
    }

    private var shouldShowCalendarProGamesStatusIndicatorSurface: Bool {
        isCalendarTabSelected && isProGamesSelected && !isCalendarSearchModeActive
    }

    private var scheduleProHasCachedGamesVisible: Bool {
        guard isProGamesSelected else { return false }
        if !displayedProMatches.isEmpty { return true }
        if let cached = calendarProGamesPerf.displayCacheByKey[calendarProGamesDisplayCacheKey()],
           !cached.isEmpty {
            return true
        }
        return false
    }

    private var calendarProGamesStatusIndicatorMessage: String {
        calendarProGamesPerf.networkRefreshInFlight
            ? "Refreshing schedule…"
            : "Updating games…"
    }

    private func hideCalendarProGamesStatusIndicator(reason: String) {
        calendarProGamesPerf.statusIndicatorShowTask?.cancel()
        calendarProGamesPerf.statusIndicatorShowTask = nil
        calendarProGamesPerf.statusIndicatorHideTask?.cancel()
        calendarProGamesPerf.statusIndicatorHideTask = nil
        guard calendarProGamesPerf.statusIndicatorVisible else { return }
        calendarProGamesPerf.statusIndicatorVisible = false
        print("[SportsDataUpdateUI] hidden reason=\(reason)")
    }

    private func syncCalendarProGamesStatusIndicatorIfIdle(reason: String) {
        guard !calendarProGamesBackgroundWorkActive else { return }
        hideCalendarProGamesStatusIndicator(reason: reason)
    }

    private func scheduleCalendarProGamesStatusIndicatorFailsafeIfNeeded() {
        calendarProGamesPerf.statusIndicatorHideTask?.cancel()
        calendarProGamesPerf.statusIndicatorHideTask = nil
        guard calendarProGamesPerf.statusIndicatorVisible else { return }
        guard scheduleProHasCachedGamesVisible else { return }

        calendarProGamesPerf.statusIndicatorHideTask = Task { @MainActor in
            let delayNs = UInt64(CalendarProGamesPerfState.statusIndicatorMaxVisibleDuration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled else { return }
            guard calendarProGamesPerf.statusIndicatorVisible else { return }
            print("[SportsDataUpdateUI] stuckTimeoutHide=true reason=maxDuration")
            hideCalendarProGamesStatusIndicator(reason: "maxDuration")
        }
    }

    private func syncCalendarProGamesStatusIndicator() {
        guard shouldShowCalendarProGamesStatusIndicatorSurface else {
            hideCalendarProGamesStatusIndicator(reason: "tabHidden")
            return
        }

        if calendarProGamesBackgroundWorkActive {
            calendarProGamesPerf.statusIndicatorShowTask?.cancel()
            calendarProGamesPerf.statusIndicatorShowTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: CalendarProGamesPerfState.statusIndicatorMinVisibleDelayNs)
                guard !Task.isCancelled else { return }
                guard shouldShowCalendarProGamesStatusIndicatorSurface else {
                    hideCalendarProGamesStatusIndicator(reason: "tabHidden")
                    return
                }
                guard calendarProGamesBackgroundWorkActive else {
                    hideCalendarProGamesStatusIndicator(reason: "workFinished")
                    return
                }
                calendarProGamesPerf.statusIndicatorVisible = true
                calendarProGamesPerf.statusIndicatorShowTask = nil
                scheduleCalendarProGamesStatusIndicatorFailsafeIfNeeded()
            }
        } else {
            hideCalendarProGamesStatusIndicator(reason: "workFinished")
        }
    }

    private func handleCalendarProGamesIndicatorSurfaceHidden(reason: String) {
        calendarProGamesPerf.sportsDataUpdateGlobalFailsafeTask?.cancel()
        calendarProGamesPerf.sportsDataUpdateGlobalFailsafeTask = nil
        hideCalendarProGamesStatusIndicator(reason: reason)
        viewModel.forceHideSportsDataUpdateIndicator(reason: reason)
    }

    private func handleScheduleSportsDataUpdateIndicatorVisibilityChanged(_ visible: Bool) {
        calendarProGamesPerf.sportsDataUpdateGlobalFailsafeTask?.cancel()
        calendarProGamesPerf.sportsDataUpdateGlobalFailsafeTask = nil
        guard visible, shouldShowCalendarProGamesStatusIndicatorSurface else { return }
        guard scheduleProHasCachedGamesVisible else { return }

        calendarProGamesPerf.sportsDataUpdateGlobalFailsafeTask = Task { @MainActor in
            let delayNs = UInt64(CalendarProGamesPerfState.statusIndicatorMaxVisibleDuration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled else { return }
            guard viewModel.sportsDataUpdateIndicatorVisible else { return }
            print("[SportsDataUpdateUI] stuckTimeoutHide=true reason=maxDuration")
            viewModel.forceHideSportsDataUpdateIndicator(reason: "maxDuration")
        }
    }

    private func calendarProGamesDayKey(for date: Date) -> String {
        let day = Calendar.current.startOfDay(for: date)
        return String(Int(day.timeIntervalSince1970 / 86_400))
    }

    private func calendarProGamesSelectedDayHasLoadedMatches(
        on day: Date,
        calendar: Calendar = .current
    ) -> Bool {
        viewModel.liveMatches.contains { calendar.isDate($0.startTime, inSameDayAs: day) }
    }

#if DEBUG
    private static let calendarProGamesRefreshDebugDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func logCalendarProGamesNetworkRefreshDecision(
        reason: String,
        selectedDay: Date,
        selectedDayHasLoadedMatches: Bool,
        skipped: Bool
    ) {
        let selectedDate = Self.calendarProGamesRefreshDebugDateFormatter.string(from: selectedDay)
        print(
            "[CalendarProGamesRefreshDebug] selectedDate=\(selectedDate) reason=\(reason) selectedDayHasLoadedMatches=\(selectedDayHasLoadedMatches) fetchSkipped=\(skipped)"
        )
    }
#endif

    private func shouldSkipCalendarProGamesNetworkRefresh(reason: String, forceRefresh: Bool) -> Bool {
        if forceRefresh { return false }
        guard isProGamesSelected else { return true }

        let cal = Calendar.current
        let day = cal.startOfDay(for: viewModel.calendarTabSelectedDate)
        let selectedDayHasLoadedMatches = calendarProGamesSelectedDayHasLoadedMatches(on: day, calendar: cal)

        if let lastRequest = calendarProGamesPerf.lastNetworkRefreshRequestedAt,
           Date().timeIntervalSince(lastRequest) < CalendarProGamesPerfState.networkCoalesceInterval {
            // Date changes to a day with no loaded matches must still fetch — dots can exist
            // while `liveMatches` has never been day-scoped for that date.
            let mustFetchUnloadedDay = reason == "calendar_selected_date_change" && !selectedDayHasLoadedMatches
            if !mustFetchUnloadedDay {
#if DEBUG
                logCalendarProGamesNetworkRefreshDecision(
                    reason: reason,
                    selectedDay: day,
                    selectedDayHasLoadedMatches: selectedDayHasLoadedMatches,
                    skipped: true
                )
                logScheduleDateRefresh(
                    "networkCoalesceSkip reason=\(reason)",
                    filteredCount: calendarProGamesPerf.cachedDisplayedProMatches.count,
                    networkSkipped: true
                )
#endif
                return true
            }
#if DEBUG
            logScheduleDateRefresh(
                "networkCoalesceBypassedForUnloadedDay reason=\(reason)",
                networkSkipped: false
            )
#endif
        }

        let dayKey = calendarProGamesDayKey(for: day)

        if let lastDayRefresh = viewModel.calendarProGamesRefreshAtByDay[dayKey],
           Date().timeIntervalSince(lastDayRefresh) < 90,
           !viewModel.liveMatches.contains(where: { match in
               match.matchStatus.isHappeningNow && cal.isDate(match.startTime, inSameDayAs: day)
           }) {
#if DEBUG
            logCalendarProGamesNetworkRefreshDecision(
                reason: reason,
                selectedDay: day,
                selectedDayHasLoadedMatches: selectedDayHasLoadedMatches,
                skipped: true
            )
#endif
            return true
        }

        if reason == "calendar_selected_date_change" {
            if selectedDayHasLoadedMatches {
#if DEBUG
                logCalendarProGamesNetworkRefreshDecision(
                    reason: reason,
                    selectedDay: day,
                    selectedDayHasLoadedMatches: true,
                    skipped: true
                )
#endif
                return true
            }
        } else if reason == "calendar_tab_filter_change" {
            if viewModel.liveMatchesAreFreshForTabPreload(within: 90), !viewModel.liveMatches.isEmpty {
#if DEBUG
                logCalendarProGamesNetworkRefreshDecision(
                    reason: reason,
                    selectedDay: day,
                    selectedDayHasLoadedMatches: selectedDayHasLoadedMatches,
                    skipped: true
                )
#endif
                return true
            }
        }

        if reason == "calendar_tab_selected" || reason == "calendar_tab_appear" || reason == "calendar_scene_active" {
            if viewModel.liveMatchesAreFreshForTabPreload(within: 90), !viewModel.liveMatches.isEmpty {
#if DEBUG
                logCalendarProGamesNetworkRefreshDecision(
                    reason: reason,
                    selectedDay: day,
                    selectedDayHasLoadedMatches: selectedDayHasLoadedMatches,
                    skipped: true
                )
#endif
                return true
            }
        }

        if viewModel.liveSportsDataRefreshInFlight || viewModel.isLiveMatchesNetworkRefreshInFlight {
#if DEBUG
            logCalendarProGamesNetworkRefreshDecision(
                reason: reason,
                selectedDay: day,
                selectedDayHasLoadedMatches: selectedDayHasLoadedMatches,
                skipped: true
            )
#endif
            return true
        }

#if DEBUG
        logCalendarProGamesNetworkRefreshDecision(
            reason: reason,
            selectedDay: day,
            selectedDayHasLoadedMatches: selectedDayHasLoadedMatches,
            skipped: false
        )
#endif
        return false
    }

    private func scheduleCalendarProGamesDeferredRefresh(reason: String, forceRefresh: Bool = false) {
        guard isProGamesSelected else { return }
        scheduleCalendarInteractionDeferredWork(reason: reason, forceNetworkRefresh: forceRefresh)
    }

    private func performCalendarProGamesNetworkRefresh(reason: String, forceRefresh: Bool) async {
        if shouldSkipCalendarProGamesNetworkRefresh(reason: reason, forceRefresh: forceRefresh) {
#if DEBUG
            // Decision details logged from shouldSkipCalendarProGamesNetworkRefresh.
#else
            print("[CalendarProGamesPerf] networkRefreshSkipped reason=\(reason) cached=true")
#endif
            return
        }
        calendarProGamesPerf.networkRefreshInFlight = true
        syncCalendarProGamesStatusIndicator()
        defer {
            calendarProGamesPerf.networkRefreshInFlight = false
            syncCalendarProGamesStatusIndicator()
        }
        calendarProGamesPerf.lastNetworkRefreshRequestedAt = Date()
#if DEBUG
        print("[CalendarProGamesDebug] refreshReason=\(reason)")
#endif
        await viewModel.refreshLiveMatchesForCalendar(
            selectedDate: viewModel.calendarTabSelectedDate,
            forceRefresh: forceRefresh
        )
        updateCalendarProGamesDisplayCache(reason: "networkRefreshFinished:\(reason)")
    }

    private func calendarBaseDisplayedProMatches(for selectedDate: Date? = nil) -> [LiveMatch] {
        let date = selectedDate ?? viewModel.calendarTabSelectedDate
        return viewModel.calendarProGamesDisplayed(
            selectedDate: date,
            searchQuery: "",
            sportFilter: calendarProGamesSportFilter,
            worldCupOnly: false,
            selectedLeagueCountries: selectedCalendarFeaturedEvent == nil ? selectedCalendarLeagueCountries : [],
            featuredEvent: selectedCalendarFeaturedEvent
        )
    }

    private var proMatchesForSelectedDateNoSearch: [LiveMatch] {
        viewModel.calendarProGamesDisplayed(
            selectedDate: viewModel.calendarTabSelectedDate,
            searchQuery: "",
            sportFilter: "All",
            worldCupOnly: false,
            selectedLeagueCountries: [],
            featuredEvent: nil
        )
    }

    private var selectedCalendarLeagueCountries: Set<String> {
        LiveLeagueCountryFilterPreference.decode(from: calendarLeagueCountryFilterRaw)
    }

    private var calendarLeagueCountryFilterCount: Int {
        selectedCalendarLeagueCountries.count
    }

    private var calendarLeagueCountryFilterIsActive: Bool {
        !selectedCalendarLeagueCountries.isEmpty
    }

    private var calendarLeagueCountryChipTitle: String {
        calendarLeagueCountryFilterCount == 0 ? "Countries" : "Countries \(calendarLeagueCountryFilterCount)"
    }

    private var calendarLeagueCountryOptions: [String] {
        let cal = Calendar.current
        let detected = viewModel.liveMatches
            .filter { cal.isDate($0.startTime, inSameDayAs: viewModel.calendarTabSelectedDate) }
            .compactMap(\.leagueCountry)
        return Array(Set(LiveLeagueCountryResolver.presetCountries + detected + Array(selectedCalendarLeagueCountries))).sorted()
    }

    private var calendarFeaturedEvents: [FeaturedEvent] {
        viewModel.activeFeaturedEvents
    }

    private var selectedCalendarFeaturedEvent: FeaturedEvent? {
        guard let calendarFeaturedEventFilterSlug else { return nil }
        return calendarFeaturedEvents.first { $0.slug == calendarFeaturedEventFilterSlug }
    }

    private var isProGamesSelected: Bool {
        effectiveCalendarGameFilter == .proGames
    }

    private var immediateCalendarSearchQuery: String {
        gameSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var debouncedCalendarSearchQuery: String {
        debouncedGameSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isCalendarSearchModeActive: Bool {
        !immediateCalendarSearchQuery.isEmpty
    }

    private var shouldShowCalendarSearchSuggestions: Bool {
        false
    }

    private var calendarSearchResultCount: Int {
        isProGamesSelected ? calendarSearchFilteredProMatches.count : calendarSearchFilteredEvents.count
    }

    private var calendarTabSelectedDayIsTodayOrFuture: Bool {
        let cal = Calendar.current
        return cal.startOfDay(for: viewModel.calendarTabSelectedDate) >= cal.startOfDay(for: Date())
    }

    var body: some View {
        fanCalendarRoot
    }

    private var fanCalendarRoot: some View {
        calendarNavigationRoot
    }

    private var calendarSheetRoot: some View {
        calendarRootContent
            .sheet(isPresented: $showDatePicker) {
                calendarDatePickerSheet
            }
            .sheet(isPresented: $showTeamScheduleSheet) {
                teamScheduleSheet
            }
            .onChange(of: showDatePicker) { _, isPresented in
                if isPresented {
                    calendarDatePickerDetent = .large
                }
            }
    }

    @ViewBuilder
    private var calendarRootContent: some View {
        if isCalendarTabSelected {
            fanCalendarContent
        } else {
            calendarOffTabPlaceholder
        }
    }

    /// Preserved-tab shell: skip calendar lists, filters, and search UI while off-screen.
    private var calendarOffTabPlaceholder: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }

    private var calendarFilterRoot: some View {
        calendarSheetRoot
            .onChange(of: viewModel.calendarUsesVisibleMapRegionOnly) { _, _ in
                handleCalendarRegionModeChange()
            }
            .onChange(of: viewModel.selectedSport) { _, _ in
                handleCalendarSelectedSportChange()
            }
            .onChange(of: viewModel.calendarTabGameFilter) { _, _ in
                handleCalendarGameFilterChange()
            }
            .sheet(isPresented: $showCalendarSportMoreSheet) {
                DiscoverSportFilterMoreSheet(selectedSport: isProGamesSelected ? calendarProGamesSportFilter : viewModel.selectedSport) { sport in
                    showCalendarSportMoreSheet = false
                    withAnimation(.spring()) {
                        if isProGamesSelected {
                            calendarProGamesSportFilter = sport
                        } else {
                            viewModel.sportChanged(to: sport)
                        }
                    }
                }
            }
            .sheet(isPresented: $showCalendarLeagueCountryFilterSheet) {
                CalendarLeagueCountryFilterSheet(
                    countries: calendarLeagueCountryOptions,
                    suggestedNearYouCountry: calendarNearYouSuggestedCountry,
                    selectedCountries: Binding(
                        get: { selectedCalendarLeagueCountries },
                        set: { updateSelectedCalendarLeagueCountries($0) }
                    )
                )
            }
    }

    private var calendarSearchStateRoot: some View {
        calendarFilterRoot
            .onAppear(perform: handleCalendarAppear)
            .onDisappear(perform: cancelCalendarSearchDebounce)
            .onChange(of: gameSearchText) { _, _ in
                handleCalendarSearchTextChange()
            }
            .onChange(of: viewModel.events.count) { _, _ in
                refreshCurrentDayCalendarSearchForLoadedDataChange()
            }
            .onChange(of: viewModel.liveMatches.count) { _, _ in
                handleLiveMatchesCountChangedWhileScheduleVisible()
            }
            .onChange(of: viewModel.pickupGamesForDiscoverMap.count) { _, _ in
                refreshCurrentDayCalendarSearchForLoadedDataChange()
            }
            .onChange(of: viewModel.venueEventRows.count) { _, _ in
                refreshCurrentDayCalendarSearchForLoadedDataChange()
            }
            .onChange(of: viewModel.activeFeaturedEvents.count) { _, _ in
                refreshCurrentDayCalendarSearchForLoadedDataChange()
            }
            .onChange(of: calendarProGamesSportFilter) { _, _ in
                scheduleCalendarInteractionDeferredWork(reason: "calendarProGamesSportFilterChanged")
            }
            .onChange(of: calendarLeagueCountryFilterRaw) { _, _ in
                applyCalendarProGamesDisplayCacheIfAvailable(reason: "leagueCountryInstant")
                scheduleCalendarInteractionDeferredWork(reason: "calendarLeagueCountryFilterChanged")
            }
            .onChange(of: calendarFeaturedEventFilterSlug) { _, _ in
                scheduleCalendarInteractionDeferredWork(reason: "calendarFeaturedEventFilterChanged")
            }
    }

    private var calendarLifecycleRoot: some View {
        calendarSearchStateRoot
            .onChange(of: isCalendarTabSelected) { _, active in
                handleCalendarTabSelectionChange(active: active)
            }
            .onChange(of: scenePhase) { _, phase in
                handleCalendarScenePhaseChange(phase)
            }
            .onChange(of: viewModel.calendarTabSelectedDate) { _, _ in
                handleCalendarSelectedDateChange()
            }
            .onChange(of: displayedEvents.map(\.id)) { _, _ in
                handleCalendarDisplayedEventsIdentityChanged()
            }
            .onChange(of: viewModel.isLoadingEvents) { _, loading in
                if !loading { completeCalendarWatchPartiesDayTransitionIfReady(reason: "loadingEnded") }
            }
            .onChange(of: viewModel.isRefreshingDiscoverEvents) { _, refreshing in
                if !refreshing { completeCalendarWatchPartiesDayTransitionIfReady(reason: "refreshEnded") }
            }
            .onChange(of: isBusinessCalendarAccess) { _, _ in
                sanitizeBusinessCalendarFilterIfNeeded()
            }
            .onChange(of: viewModel.sportsDataUpdateIndicatorVisible) { _, visible in
                handleScheduleSportsDataUpdateIndicatorVisibilityChanged(visible)
            }
            .onChange(of: effectiveCalendarGameFilter) { _, filter in
                if filter != .proGames {
                    handleCalendarProGamesIndicatorSurfaceHidden(reason: "tabChanged")
                }
            }
            .onChange(of: viewModel.pendingScheduleProGameNav) { _, _ in
                applyPendingScheduleProGameNavIfNeeded()
            }
            .onAppear {
                applyPendingScheduleProGameNavIfNeeded()
            }
    }

    private var calendarNavigationRoot: some View {
        calendarLifecycleRoot
            .sheet(item: $calendarPickupDetailToken) { token in
                DiscoverPickupGameDetailSheet(viewModel: viewModel, gameId: token.id)
            }
            .sheet(item: $calendarProGamePredictionSheet) { context in
                ProGamePredictionSheet(viewModel: viewModel, game: context.game)
            }
            .sheet(item: $calendarAddToVenueChooser) { context in
                CalendarAddToVenueChooserSheet(
                    viewModel: viewModel,
                    match: context.match,
                    venues: calendarAddToVenueChooserVenues,
                    onSelect: { venueId in
                        let match = context.match
                        calendarAddToVenueChooser = nil
                        // Dismiss chooser before presenting Manage Games (avoids stacked-sheet glitches).
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 320_000_000)
                            presentAddToVenueImport(match: match, venueId: venueId)
                        }
                    },
                    onCancel: {
                        calendarAddToVenueChooser = nil
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(FGAdaptiveSurface.sheetRoot)
            }
            .sheet(item: $calendarAddToVenueImportPrefill) { prefill in
                VenueOwnerDashboardView(
                    viewModel: viewModel,
                    entryPoint: .gamesManager,
                    scheduleImportPrefill: prefill
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(FGAdaptiveSurface.sheetRoot)
            }
    }

    private var fanCalendarContent: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            fanCalendarContentStack
        }
    }

    private var fanCalendarContentStack: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            gameTypeFilter
            calendarTopControls
            calendarSearchSuggestionsSlot
            eventsHeader
            scheduleProGamesListStatusRow
            if effectiveCalendarGameFilter == .venueGames && !isCalendarSearchModeActive {
                calendarVenueGamesRegionNotice
            }
            eventsList
        }
        .padding(.top, 14)
    }

    @ViewBuilder
    private var calendarTopControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            calendarSearchRow
            calendarSecondaryFilterBar
            calendarDateStrip
        }
    }

    @ViewBuilder
    private var calendarSearchSuggestionsSlot: some View {
        if shouldShowCalendarSearchSuggestions {
            calendarSearchSuggestionsPanel
        }
    }

    private var calendarDatePickerSheet: some View {
        LiquidGlassCalendarPicker(
            events: viewModel.events,
            bars: viewModel.filteredBars,
            useVisibleMapRegionOnly: viewModel.calendarUsesVisibleMapRegionOnly,
            eventDotDates: viewModel.calendarTabEventDotDatesForPicker(),
            dotsLoading: viewModel.calendarTabCalendarDotsLoading,
            dotStatusText: nil,
            selectedDate: $viewModel.calendarTabSelectedDate,
            minimumSelectableDay: Calendar.current.startOfDay(for: Date()),
            chrome: .calendarTab,
            calendarDotPalette: viewModel.calendarTabCalendarDotPaletteForFilter(),
            onDone: handleCalendarDatePickerDone,
            onDisplayedMonthChange: handleCalendarDisplayedMonthChange
        )
        .liquidGlassCalendarSheetPresentation(selection: $calendarDatePickerDetent, backdrop: .frostedDim)
    }

    private var teamScheduleSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    teamScheduleSearchField
                    teamScheduleSportSelector

                    if teamScheduleSubmittedQuery.isEmpty {
                        teamScheduleSuggestionsSection
                    } else {
                        teamScheduleResultsSection
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Find Team Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showTeamScheduleSheet = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .background(Color(.secondarySystemGroupedBackground), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close Team Schedule")
                }
            }
            .onAppear {
                teamScheduleRecentSearches = Self.loadTeamScheduleRecentSearches()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var teamScheduleSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search team, country, or club", text: $teamScheduleSearchText)
                .textInputAutocapitalization(.words)
                .font(.subheadline)
                .focused($isTeamScheduleSearchFocused)
                .submitLabel(.search)
                .onSubmit {
                    submitTeamScheduleLookup(teamScheduleSearchText)
                }

            if !teamScheduleSearchText.isEmpty {
                Button {
                    teamScheduleSearchText = ""
                    teamScheduleSubmittedQuery = ""
                    teamScheduleResults = []
                    teamScheduleErrorMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear team search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(FGColor.divider(calendarColorScheme).opacity(0.55), lineWidth: 1)
        }
    }

    private var teamScheduleSportSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(TeamScheduleSport.allCases) { sport in
                    Button {
                        teamScheduleSelectedSport = sport
                        teamScheduleSubmittedQuery = ""
                        teamScheduleResults = []
                        teamScheduleErrorMessage = nil
                        teamScheduleIsLoading = false
                    } label: {
                        HStack(spacing: 6) {
                            Text(sport.emoji)
                            Text(sport.title)
                                .font(.caption.weight(.heavy))
                        }
                        .foregroundStyle(teamScheduleSelectedSport == sport ? FGColor.accentGreen : FGColor.secondaryText(calendarColorScheme))
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(
                            Capsule(style: .continuous)
                                .fill(teamScheduleSelectedSport == sport ? FGColor.accentGreen.opacity(calendarColorScheme == .dark ? 0.20 : 0.12) : Color(.secondarySystemGroupedBackground))
                        )
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    teamScheduleSelectedSport == sport
                                        ? FGColor.accentGreen.opacity(calendarColorScheme == .dark ? 0.48 : 0.34)
                                        : FGColor.divider(calendarColorScheme).opacity(0.55),
                                    lineWidth: 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var teamScheduleSuggestionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            teamScheduleSuggestionGroup(title: "Popular Teams", items: teamSchedulePopularTeams)

            if !teamScheduleRecentSearches.isEmpty {
                teamScheduleSuggestionGroup(title: "Recent Searches", items: teamScheduleRecentSearches)
            }
        }
    }

    private func teamScheduleSuggestionGroup(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(FGColor.primaryText(calendarColorScheme))

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element) { index, item in
                    Button {
                        submitTeamScheduleLookup(item)
                    } label: {
                        HStack(spacing: 12) {
                            Text(teamScheduleLeadingSymbol(for: item))
                                .font(.title3)
                                .frame(width: 28)
                            Text(item)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(FGColor.primaryText(calendarColorScheme))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < items.count - 1 {
                        Divider()
                            .padding(.leading, 52)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(FGColor.divider(calendarColorScheme).opacity(0.55), lineWidth: 1)
            }
        }
    }

    private var teamScheduleResultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            teamScheduleResultsHeader

            if teamScheduleIsLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Finding upcoming games…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if let teamScheduleErrorMessage {
                calendarEmptyState(teamScheduleErrorMessage)
            } else if teamScheduleResults.isEmpty {
                calendarEmptyState("No upcoming games found for \(teamScheduleSubmittedQuery) \(teamScheduleSelectedSport.title).\nTry another team, sport, or date range.")
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(teamScheduleResults) { match in
                        teamScheduleResultRow(match)
                    }
                }
            }
        }
    }

    private var teamScheduleResultsHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(teamScheduleSubmittedQuery) \(teamScheduleSelectedSport.title)")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(FGColor.primaryText(calendarColorScheme))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Label(teamScheduleDateRangeText, systemImage: "calendar")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
                    .lineLimit(1)
            }

            Text("Next 30 Days")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
        }
    }

    private func teamScheduleResultRow(_ match: LiveMatch) -> some View {
        let isSaved = viewModel.isProGameSaved(match)
        let savedGame = teamScheduleSavedGame(for: match)
        let accent = match.matchStatus.isHappeningNow ? FGColor.dangerRed : viewModel.colorForSport(match.liveSportVisualType.sportFilterCatalogKey)

        return HStack(alignment: .center, spacing: 12) {
            teamScheduleDateTile(match.startTime)

            VStack(alignment: .leading, spacing: 5) {
                Text("\(match.awayTeam) vs \(match.homeTeam)")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(FGColor.primaryText(calendarColorScheme))
                    .lineLimit(1)

                Text(calendarProGameStartTimeText(match))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(calendarColorScheme))

                HStack(spacing: 5) {
                    Text(match.league)
                    if let eventName = match.eventName?.trimmingCharacters(in: .whitespacesAndNewlines), !eventName.isEmpty {
                        Text("·")
                        Text(eventName)
                    }
                    Text("·")
                    Text(calendarProGameStatusText(match))
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            VStack(spacing: 8) {
                calendarProGameSaveButton(match, isSaved: isSaved, accent: accent)

                if let savedGame, !savedGame.isFinal {
                    teamScheduleScoreUpdateButton(savedGame, accent: accent)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(FGColor.divider(calendarColorScheme).opacity(0.55), lineWidth: 1)
        }
    }

    private func teamScheduleDateTile(_ date: Date) -> some View {
        VStack(spacing: 3) {
            Text(teamScheduleRowWeekdayFormatter.string(from: date))
                .font(.caption2.weight(.heavy))
                .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
            Text(teamScheduleRowDayFormatter.string(from: date))
                .font(.caption.weight(.black))
                .foregroundStyle(FGColor.primaryText(calendarColorScheme))
        }
        .frame(width: 54, height: 54)
        .background(Color(.systemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func teamScheduleScoreUpdateButton(_ game: SavedProGame, accent: Color) -> some View {
        let isEnabled = viewModel.savedProGameScoreUpdatesEnabled(for: game)
        return Button {
            viewModel.setSavedProGameScoreUpdatesEnabled(!isEnabled, for: game)
        } label: {
            Image(systemName: isEnabled ? "bell.fill" : "bell.slash")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isEnabled ? accent : FGColor.mutedText(calendarColorScheme))
                .frame(width: 34, height: 30)
                .background(
                    Capsule(style: .continuous)
                        .fill((isEnabled ? accent : FGColor.mutedText(calendarColorScheme)).opacity(calendarColorScheme == .dark ? 0.16 : 0.09))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Live alerts for this game \(isEnabled ? "on" : "off")")
        .accessibilityHint("Goals, halftime, cards and other live updates.")
    }

    private func presentTeamScheduleSheet() {
        teamScheduleSelectedSport = TeamScheduleSport.resolved(from: selectedCalendarFeaturedEvent?.sport)
            ?? TeamScheduleSport.resolved(from: calendarProGamesSportFilter)
            ?? .soccer
        teamScheduleRecentSearches = Self.loadTeamScheduleRecentSearches()
        showTeamScheduleSheet = true
    }

    private func submitTeamScheduleLookup(_ rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        teamScheduleSearchText = query
        teamScheduleSubmittedQuery = query
        teamScheduleErrorMessage = nil
        isTeamScheduleSearchFocused = false
        persistTeamScheduleRecentSearch(query)

        let selectedSport = teamScheduleSelectedSport
        let cacheKey = teamScheduleCacheKey(query: query, sport: selectedSport)
        if let cached = teamScheduleLookupCache[cacheKey],
           Date().timeIntervalSince(cached.fetchedAt) < Self.teamScheduleCacheDuration {
            teamScheduleResults = cached.results
            teamScheduleIsLoading = false
#if DEBUG
            print("[TeamScheduleDebug] cacheHit key=\(cacheKey) count=\(cached.results.count)")
#endif
            return
        }

        teamScheduleResults = []
        teamScheduleIsLoading = true
#if DEBUG
        print("[TeamScheduleDebug] lookupStarted key=\(cacheKey)")
#endif
        Task { @MainActor in
            do {
                let fetched = try await LiveSportsService.shared.fetchLiveMatches(
                    windowDays: 31,
                    sportFilter: selectedSport.lookupSportFilter
                )
                let results = teamScheduleFilteredResults(
                    from: fetched,
                    query: query
                )
                teamScheduleLookupCache[cacheKey] = TeamScheduleCacheEntry(fetchedAt: Date(), results: results)
                guard teamScheduleSubmittedQuery == query, teamScheduleSelectedSport == selectedSport else { return }
                teamScheduleResults = results
                teamScheduleErrorMessage = nil
#if DEBUG
                print("[TeamScheduleDebug] lookupFinished key=\(cacheKey) fetched=\(fetched.count) results=\(results.count)")
#endif
            } catch {
                guard teamScheduleSubmittedQuery == query, teamScheduleSelectedSport == selectedSport else { return }
                teamScheduleResults = []
                teamScheduleErrorMessage = "Couldn’t load upcoming games for \(query) \(selectedSport.title).\nTry again in a moment."
#if DEBUG
                print("[TeamScheduleDebug] lookupFailed key=\(cacheKey) error=\(error.localizedDescription)")
#endif
            }
            guard teamScheduleSubmittedQuery == query, teamScheduleSelectedSport == selectedSport else { return }
            teamScheduleIsLoading = false
        }
    }

    private func teamScheduleFilteredResults(
        from matches: [LiveMatch],
        query: String
    ) -> [LiveMatch] {
        let normalizedQuery = calendarNormalizedSearchText(query)
        guard !normalizedQuery.isEmpty else { return [] }
        let start = teamScheduleRangeStart
        let end = teamScheduleRangeEndExclusive
        return matches
            .filter { match in
                match.startTime >= start
                    && match.startTime < end
                    && teamScheduleMatch(match, matchesNormalizedQuery: normalizedQuery)
            }
            .sorted { lhs, rhs in
                if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
                return "\(lhs.awayTeam) \(lhs.homeTeam)".localizedCaseInsensitiveCompare("\(rhs.awayTeam) \(rhs.homeTeam)") == .orderedAscending
            }
            .prefix(Self.teamScheduleResultLimit)
            .map { $0 }
    }

    private func teamScheduleMatch(_ match: LiveMatch, matchesNormalizedQuery normalizedQuery: String) -> Bool {
        let fields = [
            match.homeTeam,
            match.awayTeam,
            "\(match.awayTeam) vs \(match.homeTeam)",
            "\(match.homeTeam) vs \(match.awayTeam)",
            match.league,
            match.sourceLeagueName,
            match.leagueAlternate,
            match.eventName,
            match.leagueCountry
        ]
        let searchableText = fields
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(calendarNormalizedSearchText)
            .joined(separator: " ")
        if searchableText.contains(normalizedQuery) { return true }
        let tokens = normalizedQuery.split(separator: " ").map(String.init)
        return !tokens.isEmpty && tokens.allSatisfy { searchableText.contains($0) }
    }

    private func teamScheduleSavedGame(for match: LiveMatch) -> SavedProGame? {
        let key = SavedProGame.stableKey(for: match)
        return viewModel.savedProGames.first { $0.stableKey == key }
    }

    private var teamSchedulePopularTeams: [String] {
        teamScheduleSelectedSport.popularTeams
    }

    private var teamScheduleRangeStart: Date {
        Calendar.current.startOfDay(for: Date())
    }

    private var teamScheduleRangeEndExclusive: Date {
        Calendar.current.date(byAdding: .day, value: 31, to: teamScheduleRangeStart)
            ?? teamScheduleRangeStart.addingTimeInterval(31 * 24 * 60 * 60)
    }

    private var teamScheduleDateRangeText: String {
        let endInclusive = Calendar.current.date(byAdding: .day, value: 30, to: teamScheduleRangeStart)
            ?? teamScheduleRangeEndExclusive
        return "\(teamScheduleRangeFormatter.string(from: teamScheduleRangeStart)) – \(teamScheduleRangeFormatter.string(from: endInclusive))"
    }

    private func teamScheduleCacheKey(query: String, sport: TeamScheduleSport) -> String {
        let day = calendarSearchDayFormatter.string(from: teamScheduleRangeStart)
        return [
            "teamSchedule",
            sport.cacheKey,
            calendarNormalizedSearchText(query),
            day,
            "30"
        ].joined(separator: "|")
    }

    private func persistTeamScheduleRecentSearch(_ query: String) {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var recent = Self.loadTeamScheduleRecentSearches()
        recent.removeAll { calendarNormalizedSearchText($0) == calendarNormalizedSearchText(clean) }
        recent.insert(clean, at: 0)
        recent = Array(recent.prefix(5))
        UserDefaults.standard.set(recent, forKey: Self.teamScheduleRecentSearchesKey)
        teamScheduleRecentSearches = recent
    }

    private static func loadTeamScheduleRecentSearches() -> [String] {
        UserDefaults.standard.stringArray(forKey: teamScheduleRecentSearchesKey) ?? []
    }

    private func teamScheduleLeadingSymbol(for item: String) -> String {
        CountryFlagHelper.flag(for: item) ?? teamScheduleSelectedSport.emoji
    }

    private func sanitizeBusinessCalendarFilterIfNeeded() {
        guard isBusinessCalendarAccess, viewModel.calendarTabGameFilter == .pickupGames else { return }
        viewModel.calendarTabGameFilter = .venueGames
        viewModel.calendarEventsListCache.removeAll()
    }

    private func handleCalendarAppear() {
        sanitizeBusinessCalendarFilterIfNeeded()
        applyCalendarLeagueCountryFilterFirstUseDefaultIfNeeded()
        refreshCurrentDayCalendarSearchForLoadedDataChange()
        applyCalendarProGamesDisplayCacheIfAvailable(reason: "appearInstant")
        scheduleCalendarProGamesStripDateCachePrewarm(reason: "calendar_tab_appear")
        applyPendingScheduleProGameNavIfNeeded()
        guard isCalendarTabSelected else {
#if DEBUG
            print("[PerfPhase1D] deferredCalendarWork reason=calendarScreenOnAppearPickupRefresh")
#endif
            return
        }
        Task { @MainActor in
            await Task.yield()
            scheduleCalendarProGamesDeferredRefresh(reason: "calendar_tab_appear")
            applyPendingScheduleProGameNavIfNeeded()
            guard viewModel.canFanUsePickupGamesUI else { return }
            guard !shouldDeferCalendarPickupRefreshAfterTabPreload() else {
                AppPerfDebug.refreshSkipped(
                    tab: "calendar",
                    source: "pickupSources",
                    reason: "tabPreloadRecentOrInFlight"
                )
                return
            }
            await viewModel.refreshCalendarTabPickupSources(reason: "calendar_tab_appear")
        }
    }

    private func applyPendingScheduleProGameNavIfNeeded() {
        guard let intent = viewModel.pendingScheduleProGameNav else { return }
        viewModel.clearPendingScheduleProGameNav()

        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        gameSearchText = ""
        debouncedGameSearchText = ""
        calendarProGamesSportFilter = "All"
        calendarFeaturedEventFilterSlug = nil

        viewModel.calendarTabSelectedDate = Calendar.current.startOfDay(for: intent.startTime)
        viewModel.calendarTabGameFilter = .proGames
        applyCalendarProGamesDisplayCacheIfAvailable(reason: "scheduleProGameNav")

        if let resolved = viewModel.resolveLiveMatchForScheduleProGameNav(intent) {
            let key = SavedProGame.stableKey(for: resolved)
            viewModel.scheduleProGameHighlightStableKey = key
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.8))
                if viewModel.scheduleProGameHighlightStableKey == key {
                    viewModel.clearScheduleProGameHighlight()
                }
            }
#if DEBUG
            print("[ScheduleProGameNav] resolved stableKey=\(key)")
#endif
        } else {
            viewModel.scheduleProGameHighlightStableKey = nil
            viewModel.showSocialActionToast(
                L10n.t("discover_pro_game_schedule_unavailable", languageCode: languageCode),
                isError: false
            )
#if DEBUG
            print("[ScheduleProGameNav] unresolved matchId=\(intent.matchId) stableKey=\(intent.stableKey)")
#endif
        }
    }

    private func cancelCalendarSearchDebounce() {
        gameSearchDebounceTask?.cancel()
        gameSearchDebounceTask = nil
    }

    private func handleCalendarSearchTextChange() {
        scheduleCalendarSearchRefresh()
    }

    private func handleCalendarRegionModeChange() {
        guard isCalendarTabSelected else { return }
        viewModel.calendarEventsListCache.removeAll()
        viewModel.recomputeCalendarDotDates(force: true)
        viewModel.loadCalendarTabCalendarDotsAroundMonth(
            viewModel.calendarTabSelectedDate,
            reason: "calendar_tab_region_mode_change"
        )
    }

    private func handleCalendarSelectedSportChange() {
        refreshCurrentDayCalendarSearchForLoadedDataChange()
        guard isCalendarTabSelected else { return }
        viewModel.calendarEventsListCache.removeAll()
        viewModel.recomputeCalendarDotDates(force: true)
        viewModel.loadCalendarTabCalendarDotsAroundMonth(
            viewModel.calendarTabSelectedDate,
            reason: "calendar_tab_sport_change"
        )
    }

    private func handleCalendarGameFilterChange() {
        noteScheduleRecentInteraction()
        logScheduleTapProtectedIfNeeded()
        logScheduleTapPerf("[ScheduleTapPerf] tapReceived type=proTab value=\(effectiveCalendarGameFilter.rawValue)")
#if DEBUG
        if isProGamesSelected {
            ProSchedulePerf.loadStarted()
        }
#endif
        applyCalendarProGamesDisplayCacheIfAvailable(reason: "gameFilterInstant")
        scheduleCalendarInteractionDeferredWork(reason: "calendar_tab_filter_change")
    }

    private func handleCalendarTabSelectionChange(active: Bool) {
        if !active {
            calendarProGamesPerf.deferredLiveMatchesScheduleProRebuildTask?.cancel()
            calendarProGamesPerf.deferredLiveMatchesScheduleProRebuildTask = nil
            handleCalendarProGamesIndicatorSurfaceHidden(reason: "tabHidden")
            return
        }
        AppPerfDebug.screenLoadStart(tab: "calendar", source: "tabSelected")
        sanitizeBusinessCalendarFilterIfNeeded()
#if DEBUG
        if isProGamesSelected {
            ProSchedulePerf.loadStarted()
        }
#endif
        applyCalendarProGamesDisplayCacheIfAvailable(reason: "tabSelectedInstant")
        scheduleCalendarProGamesStripDateCachePrewarm(reason: "calendar_tab_selected")
        scheduleCalendarInteractionDeferredWork(reason: "calendar_tab_selected")
        applyPendingScheduleProGameNavIfNeeded()
        Task { @MainActor in
            await Task.yield()
            applyPendingScheduleProGameNavIfNeeded()
            guard shouldDeferCalendarPickupRefreshAfterTabPreload() else {
                refreshCalendarPickupSourcesIfNeeded(reason: "calendar_tab_selected")
                return
            }
            AppPerfDebug.refreshSkipped(
                tab: "calendar",
                source: "pickupSources",
                reason: "tabPreloadRecentOrInFlight"
            )
        }
    }

    private func shouldDeferCalendarPickupRefreshAfterTabPreload() -> Bool {
        viewModel.isTabIntentPreloadInFlight("calendar")
            || viewModel.didCompleteTabIntentPreloadRecently("calendar", within: 12)
    }

    private func handleCalendarScenePhaseChange(_ phase: ScenePhase) {
        guard phase == .active else { return }
        guard isCalendarTabSelected else { return }
        sanitizeBusinessCalendarFilterIfNeeded()
        scheduleCalendarProGamesDeferredRefresh(reason: "calendar_scene_active")
        guard !shouldDeferCalendarPickupRefreshAfterTabPreload() else {
            AppPerfDebug.refreshSkipped(
                tab: "calendar",
                source: "pickupSources",
                reason: "foregroundTabPreloadRecentOrInFlight"
            )
            return
        }
        refreshCalendarPickupSourcesIfNeeded(reason: "calendar_scene_active")
    }

    private func handleCalendarSelectedDateChange() {
        let previousRendered = calendarProGamesPerf.cachedDisplayedProMatches.count
        beginCalendarWatchPartiesDayTransition(reason: "selectedDateChanged", preserveVisibleCards: true)
        let cacheHit = applyCalendarProGamesDisplayCacheIfAvailable(reason: "selectedDateInstant")
#if DEBUG
        logScheduleDateRefresh(
            "selectedDateCommitted cacheHit=\(cacheHit)",
            cacheHit: cacheHit,
            filteredCount: calendarBaseDisplayedProMatches().count,
            renderedCount: calendarProGamesPerf.cachedDisplayedProMatches.count
        )
#endif
        if isProGamesSelected, !isCalendarSearchModeActive {
            // Paint immediately from any already-loaded matches for this day/filters.
            // Do not wait for deferred work or network when the source already has the games.
            updateCalendarProGamesDisplayCache(reason: "selectedDateImmediateRebuild")
#if DEBUG
            logScheduleDateRefresh(
                "selectedDateImmediateRebuildDone previousRendered=\(previousRendered)",
                filteredCount: calendarProGamesPerf.cachedDisplayedProMatches.count,
                renderedCount: calendarProGamesPerf.cachedDisplayedProMatches.count
            )
#endif
        }
        scheduleCalendarInteractionDeferredWork(reason: "calendar_selected_date_change")
    }

    private func handleCalendarDateStripTap(_ date: Date) {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: viewModel.calendarTabSelectedDate) {
            logScheduleTapPerf("[ScheduleTapPerf] tapBlocked reason=alreadySelected")
            return
        }
        let dayKey = calendarProGamesDayKey(for: date)
        noteScheduleRecentInteraction()
        logScheduleTapProtectedIfNeeded()
        logScheduleTapPerf("[ScheduleTapPerf] tapReceived type=date value=\(dayKey)")
        let started = CFAbsoluteTimeGetCurrent()
        // Capture the currently visible Watch Parties before the selected day changes.
        commitCalendarWatchPartiesStableSnapshotIfNeeded()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            viewModel.calendarTabSelectedDate = date
        }
        applyCalendarProGamesDisplayCacheIfAvailable(reason: "dateStripInstant")
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        logScheduleTapPerf("[ScheduleTapPerf] selectedStateUpdatedMs=\(String(format: "%.2f", ms))")
    }

    private func beginCalendarWatchPartiesDayTransition(reason: String, preserveVisibleCards: Bool) {
        guard effectiveCalendarGameFilter == .venueGames else { return }
        guard !isCalendarSearchModeActive else { return }
        guard calendarTabSelectedDayIsTodayOrFuture else { return }

        // Hold the previous day's visible cards. Do NOT snapshot calendarBaseDisplayedEvents()
        // here — the selected date has already changed, so that list is often empty and would
        // wipe the stable hold we committed on the date strip tap.
        let holdSnapshot: [SportsEvent]
        if preserveVisibleCards {
            if !calendarWatchPartiesLastStableEvents.isEmpty {
                holdSnapshot = calendarWatchPartiesLastStableEvents
            } else if !calendarWatchPartiesHeldEvents.isEmpty {
                holdSnapshot = calendarWatchPartiesHeldEvents
            } else {
                holdSnapshot = []
            }
        } else {
            holdSnapshot = []
        }

        calendarWatchPartiesDayTransitionTask?.cancel()
        calendarWatchPartiesDayTransitionGeneration &+= 1
        let generation = calendarWatchPartiesDayTransitionGeneration
        calendarWatchPartiesDayTransitionActive = true
        calendarWatchPartiesHeldEvents = holdSnapshot
#if DEBUG
        print(
            "[CalendarWatchPartiesUX] dayTransitionBegan reason=\(reason) held=\(holdSnapshot.count)"
        )
#endif

        calendarWatchPartiesDayTransitionTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: CalendarProGamesPerfState.deferredNetworkRefreshDelayNs)
            while !Task.isCancelled,
                  (viewModel.isLoadingEvents || viewModel.isRefreshingDiscoverEvents) {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            try? await Task.sleep(nanoseconds: CalendarProGamesPerfState.watchPartiesDayTransitionSettleNs)
            guard !Task.isCancelled else { return }
            guard generation == calendarWatchPartiesDayTransitionGeneration else { return }
            endCalendarWatchPartiesDayTransition(reason: "\(reason):settled")
        }
    }

    private func endCalendarWatchPartiesDayTransition(reason: String) {
        calendarWatchPartiesDayTransitionTask?.cancel()
        calendarWatchPartiesDayTransitionTask = nil
        calendarWatchPartiesDayTransitionActive = false
        calendarWatchPartiesHeldEvents = []
        commitCalendarWatchPartiesStableSnapshotIfNeeded()
#if DEBUG
        print("[CalendarWatchPartiesUX] dayTransitionEnded reason=\(reason)")
#endif
    }

    private func completeCalendarWatchPartiesDayTransitionIfReady(reason: String) {
        guard calendarWatchPartiesDayTransitionActive else { return }
        guard !viewModel.isLoadingEvents, !viewModel.isRefreshingDiscoverEvents else { return }
        // Keep holding until the new day has content, or settle completes naturally on empty.
        if !displayedEvents.isEmpty {
            endCalendarWatchPartiesDayTransition(reason: reason)
        }
    }

    private func handleCalendarDisplayedEventsIdentityChanged() {
        if calendarWatchPartiesDayTransitionActive, !displayedEvents.isEmpty {
            endCalendarWatchPartiesDayTransition(reason: "liveEventsReady")
            return
        }
        commitCalendarWatchPartiesStableSnapshotIfNeeded()
    }

    private func commitCalendarWatchPartiesStableSnapshotIfNeeded() {
        guard effectiveCalendarGameFilter == .venueGames else { return }
        guard !isCalendarSearchModeActive else { return }
        guard !calendarWatchPartiesDayTransitionActive else { return }
        calendarWatchPartiesLastStableEvents = calendarBaseDisplayedEvents()
    }

    /// Venue Watch Parties list for rendering: prefer live day results, else held cards during day transition.
    private var calendarVenueEventsConsideringDayTransition: [SportsEvent] {
        guard effectiveCalendarGameFilter == .venueGames, !isCalendarSearchModeActive else {
            return displayedEvents
        }
        if !displayedEvents.isEmpty {
            return displayedEvents
        }
        if calendarWatchPartiesDayTransitionActive, !calendarWatchPartiesHeldEvents.isEmpty {
            return calendarWatchPartiesHeldEvents
        }
        return displayedEvents
    }

    private var calendarVenueEventsAreHeldOverFromPreviousDay: Bool {
        effectiveCalendarGameFilter == .venueGames
            && !isCalendarSearchModeActive
            && calendarWatchPartiesDayTransitionActive
            && displayedEvents.isEmpty
            && !calendarWatchPartiesHeldEvents.isEmpty
    }

    private func refreshCalendarPickupSourcesIfNeeded(forceRefresh: Bool = false, reason: String) {
        guard viewModel.canFanUsePickupGamesUI else { return }
        Task {
            await Task.yield()
            await viewModel.refreshCalendarTabPickupSources(forceRefresh: forceRefresh, reason: reason)
        }
    }

    private func handleCalendarDatePickerDone() {
#if DEBUG
        logScheduleDateRefresh("datePickerDoneDismiss")
#endif
        withAnimation(.spring()) {
            viewModel.selectedBar = nil
            viewModel.selectedEvent = nil
            viewModel.calendarEventsListCache.removeAll()
            sanitizeBusinessCalendarFilterIfNeeded()
            viewModel.loadCalendarTabCalendarDotsAroundMonth(
                viewModel.calendarTabSelectedDate,
                reason: "calendar_tab_sheet_done"
            )
            viewModel.loadGamesFromSupabase()
            Task {
                await viewModel.refreshCalendarTabPickupSources(forceRefresh: true, reason: "calendar_tab_sheet_done")
            }
            // Pro Games date was already committed on day tap; ensure list is painted for the
            // committed day even if the sheet dismissed without another date onChange.
            if isProGamesSelected, !isCalendarSearchModeActive {
                updateCalendarProGamesDisplayCache(reason: "datePickerDoneImmediateRebuild")
                scheduleCalendarInteractionDeferredWork(reason: "calendar_selected_date_change")
            }
            showDatePicker = false
        }
    }

    private func handleCalendarDisplayedMonthChange(_ month: Date) {
        Task { @MainActor in
            viewModel.loadCalendarTabCalendarDotsAroundMonth(month, reason: "calendar_tab_month_change")
        }
    }

    private var header: some View {
        FanGeoPagePurposeHeader(
            title: L10n.t("Schedule", languageCode: appLanguageRaw),
            subtitle: ""
        )
        .padding(.horizontal)
    }

    private var gameTypeFilter: some View {
        GameOnSegmentedControl(
            tabs: calendarVisibleGameFilters.map { filter in
                let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
                let accessibility: String = {
                    switch filter {
                    case .venueGames:
                        return L10n.t("schedule_a11y_watch", languageCode: languageCode)
                    case .pickupGames:
                        return L10n.t("schedule_a11y_play", languageCode: languageCode)
                    case .proGames:
                        return L10n.t("schedule_a11y_pro_games", languageCode: languageCode)
                    }
                }()
                let tint: Color = filter.intentTint
                return GameOnSegmentedTab(
                    id: filter,
                    title: filter.segmentTitle,
                    systemImage: calendarSegmentSystemImage(for: filter),
                    badge: calendarSegmentBadge(for: filter),
                    tint: tint,
                    accessibilityLabel: accessibility
                )
            },
            selection: calendarGameFilterBinding,
            animatesSelectionChanges: false,
            titleMinimumScaleFactor: 0.62,
            tabHorizontalPadding: 5
        )
        .padding(.horizontal)
    }

    private func calendarSegmentSystemImage(for filter: CalendarTabGameFilter) -> String {
        switch filter {
        case .venueGames:
            return "sportscourt.fill"
        case .pickupGames:
            return "figure.run"
        case .proGames:
            return "trophy.fill"
        }
    }

    private func calendarSegmentBadge(for filter: CalendarTabGameFilter) -> String? {
        guard let count = calendarProGamesPerf.cachedSegmentBadgeCounts[filter] else { return nil }
        return count > 0 ? "\(count)" : nil
    }

    private var calendarSearchRow: some View {
        HStack(spacing: 10) {
            gameSearchBar
                .frame(maxWidth: .infinity)

            if isProGamesSelected {
                teamScheduleButton
            }
        }
        .padding(.horizontal)
    }

    private var teamScheduleButton: some View {
        let title = L10n.t("Team Schedule", languageCode: appLanguageRaw)
        return Button {
            presentTeamScheduleSheet()
        } label: {
            Label(title, systemImage: "magnifyingglass")
                .font(.caption.weight(.heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .foregroundStyle(FGColor.accentGreen)
                .padding(.horizontal, 10)
                .frame(height: 44)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(FGColor.accentGreen.opacity(calendarColorScheme == .dark ? 0.44 : 0.28), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var calendarDateStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button {
                    showDatePicker = true
                } label: {
                    Image(systemName: "calendar")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(FGColor.accentGreen)
                        .frame(width: 44, height: 52)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(FGColor.divider(calendarColorScheme).opacity(0.55), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open calendar picker")

                ForEach(calendarDateStripDates, id: \.timeIntervalSince1970) { date in
                    calendarDateStripButton(date)
                }
            }
            .padding(.horizontal)
        }
        .scrollClipDisabled(false)
    }

    private var calendarDateStripDates: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let selectedDay = calendar.startOfDay(for: viewModel.calendarTabSelectedDate)
        let sixDaysFromToday = calendar.date(byAdding: .day, value: 6, to: today) ?? today
        let startDay = (today...sixDaysFromToday).contains(selectedDay)
            ? today
            : selectedDay

        return (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: startDay)
        }
    }

    private func calendarDateStripButton(_ date: Date) -> some View {
        let calendar = Calendar.current
        let isSelected = calendar.isDate(date, inSameDayAs: viewModel.calendarTabSelectedDate)
        let isToday = calendar.isDateInToday(date)
        let hasVenueEvents = calendarDateStripHasVenueEvents(on: date)
        let hasPickupGames = calendarDateStripHasPickupGames(on: date)
        return Button {
            handleCalendarDateStripTap(date)
        } label: {
            VStack(spacing: 4) {
                Text(isToday ? "Today" : calendarDateStripWeekdayFormatter.string(from: date))
                    .font(.caption.weight(.heavy))
                    .lineLimit(1)
                Text(calendarDateStripDayFormatter.string(from: date))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? FGColor.accentGreen : FGColor.secondaryText(calendarColorScheme))
            .frame(width: 68, height: 52)
            .overlay(alignment: .bottom) {
                calendarDateStripEventIndicators(
                    hasVenueEvents: hasVenueEvents,
                    hasPickupGames: hasPickupGames
                )
                .padding(.bottom, 5)
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? FGColor.accentGreen.opacity(calendarColorScheme == .dark ? 0.20 : 0.12) : Color(.secondarySystemGroupedBackground))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? FGColor.accentGreen.opacity(calendarColorScheme == .dark ? 0.48 : 0.34)
                            : FGColor.divider(calendarColorScheme).opacity(0.55),
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(calendarDateStripAccessibilityLabel(
            date: date,
            hasVenueEvents: hasVenueEvents,
            hasPickupGames: hasPickupGames
        ))
    }

    /// Reuses Calendar-tab venue/pickup day-dot sets already loaded for the month picker — no new queries.
    private func calendarDateStripHasVenueEvents(on date: Date) -> Bool {
        let day = Calendar.current.startOfDay(for: date)
        return viewModel.venueGameCalendarDotDates.contains(day)
    }

    private func calendarDateStripHasPickupGames(on date: Date) -> Bool {
        let day = Calendar.current.startOfDay(for: date)
        return viewModel.pickupGameCalendarDotDates.contains(day)
    }

    @ViewBuilder
    private func calendarDateStripEventIndicators(hasVenueEvents: Bool, hasPickupGames: Bool) -> some View {
        if hasVenueEvents || hasPickupGames {
            HStack(spacing: 3.5) {
                if hasVenueEvents {
                    Circle()
                        .fill(FGColor.accentGreen.opacity(calendarColorScheme == .dark ? 0.92 : 0.88))
                        .frame(width: 4.5, height: 4.5)
                }
                if hasPickupGames {
                    Circle()
                        .fill(FGColor.accentBlue.opacity(calendarColorScheme == .dark ? 0.92 : 0.88))
                        .frame(width: 4.5, height: 4.5)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private func calendarDateStripAccessibilityLabel(
        date: Date,
        hasVenueEvents: Bool,
        hasPickupGames: Bool
    ) -> String {
        var label = calendarDateStripAccessibilityFormatter.string(from: date)
        if hasVenueEvents { label += ", watch parties" }
        if hasPickupGames { label += ", pickup games" }
        return label
    }

    private var compactCalendarDateTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: viewModel.calendarTabSelectedDate)
    }

    private var calendarVenueGamesRegionNotice: some View {
        Text(L10n.t("watch_parties_discover_area_region_notice", languageCode: calendarScheduleLanguageCode))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal)
    }

    private var eventsHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(eventsHeaderTitle)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let summary = calendarScheduleHeaderCountrySummary {
                    Text(summary)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(calendarScheduleHeaderAccessibilityLabel)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            if !isProGamesSelected {
                if viewModel.isLoadingEvents
                    || viewModel.isRefreshingDiscoverEvents
                    || calendarWatchPartiesDayTransitionActive {
                    ProgressView()
                        .controlSize(
                            (viewModel.isLoadingEvents || calendarWatchPartiesDayTransitionActive)
                                && calendarVenueEventsConsideringDayTransition.isEmpty
                                ? .regular
                                : .small
                        )
                }
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var scheduleProGamesListStatusRow: some View {
        if let message = scheduleProGamesListStatusMessage {
            let isUpdatingWithCache = scheduleProHasCachedGamesVisible
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(message)
                    .font(isUpdatingWithCache ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
            }
            .padding(.horizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message)
        }
    }

    @ViewBuilder
    private var calendarProGamesUpdatingStatusBanner: some View {
        if calendarProGamesPerf.statusIndicatorVisible {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(calendarProGamesStatusIndicatorMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
            .padding(.horizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .animation(.easeInOut(duration: 0.2), value: calendarProGamesPerf.statusIndicatorVisible)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(calendarProGamesStatusIndicatorMessage)
        }
    }

    private var eventsHeaderTitle: String {
        if isCalendarSearchModeActive {
            return "Search Results"
        }

        return calendarSelectedDateMatchesTitle
    }

    private var calendarScheduleLanguageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    /// Same Option 3 place mode as Live: inline single place, compact summary for multi-select.
    private var calendarScheduleHeaderPlaceMode: LiveLeagueCountryFilterPresentation.LiveHeaderPlaceMode {
        guard isProGamesSelected else { return .none }
        return LiveLeagueCountryFilterPresentation.liveHeaderPlaceMode(
            for: selectedCalendarLeagueCountries,
            languageCode: calendarScheduleLanguageCode
        )
    }

    private var calendarScheduleHeaderCountrySummary: String? {
        guard !isCalendarSearchModeActive else { return nil }
        if case .summary(let summary) = calendarScheduleHeaderPlaceMode {
            return summary
        }
        return nil
    }

    private var calendarNearYouSuggestedCountry: String? {
        LiveLeagueCountryFilterPresentation.suggestedNearYouCountry(
            homeCountry: viewModel.currentUserHomeCountry,
            homeRegion: viewModel.currentUserHomeRegion,
            localeRegionCode: LiveLeagueCountryFilterPresentation.deviceLocaleRegionCode()
        )
    }

    /// Sport label for Schedule headings when a specific sport chip is selected (not All / featured).
    private var calendarProGamesHeadingSportLabel: String? {
        guard isProGamesSelected, selectedCalendarFeaturedEvent == nil else { return nil }
        let selection = calendarProGamesSportFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty, !DiscoverSportFilterRowLayout.selectionTokensMatch(selection, "All") else {
            return nil
        }
        if let display = calendarProVisibleSportFilters.first(where: {
            DiscoverSportFilterRowLayout.selectionTokensMatch($0.selection, selection)
        })?.display {
            return display
        }
        return selection.prefix(1).uppercased() + selection.dropFirst()
    }

    private var calendarSelectedDateMatchesTitle: String {
        let languageCode = calendarScheduleLanguageCode
        let locale = Locale(identifier: languageCode)
        let calendar = Calendar.current
        let selectedDay = calendar.startOfDay(for: viewModel.calendarTabSelectedDate)
        let today = calendar.startOfDay(for: Date())
        let sport = calendarProGamesHeadingSportLabel
        let noun = calendarSectionTitleNoun
        let inlinePlace: String? = {
            guard effectiveCalendarGameFilter == .proGames else { return nil }
            if case .inline(let place) = calendarScheduleHeaderPlaceMode {
                return place
            }
            return nil
        }()

        if selectedDay == today {
            if let place = inlinePlace {
                if let sport {
                    return String(
                        format: L10n.t("schedule_todays_sport_matches_in_place_format", languageCode: languageCode),
                        locale: locale,
                        sport,
                        place
                    )
                }
                return String(
                    format: L10n.t("schedule_todays_matches_in_place_format", languageCode: languageCode),
                    locale: locale,
                    place
                )
            }
            if let sport, effectiveCalendarGameFilter == .proGames {
                return String(
                    format: L10n.t("schedule_todays_sport_matches_format", languageCode: languageCode),
                    locale: locale,
                    sport
                )
            }
            return String(
                format: L10n.t("schedule_todays_noun_format", languageCode: languageCode),
                locale: locale,
                noun
            )
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
           selectedDay == tomorrow {
            if let place = inlinePlace {
                if let sport {
                    return String(
                        format: L10n.t("schedule_tomorrows_sport_matches_in_place_format", languageCode: languageCode),
                        locale: locale,
                        sport,
                        place
                    )
                }
                return String(
                    format: L10n.t("schedule_tomorrows_matches_in_place_format", languageCode: languageCode),
                    locale: locale,
                    place
                )
            }
            if let sport, effectiveCalendarGameFilter == .proGames {
                return String(
                    format: L10n.t("schedule_tomorrows_sport_matches_format", languageCode: languageCode),
                    locale: locale,
                    sport
                )
            }
            return String(
                format: L10n.t("schedule_tomorrows_noun_format", languageCode: languageCode),
                locale: locale,
                noun
            )
        }

        let dateLabel = compactCalendarDateTitle
        if let place = inlinePlace {
            if let sport {
                return String(
                    format: L10n.t("schedule_date_sport_matches_in_place_format", languageCode: languageCode),
                    locale: locale,
                    dateLabel,
                    sport,
                    place
                )
            }
            return String(
                format: L10n.t("schedule_date_matches_in_place_format", languageCode: languageCode),
                locale: locale,
                dateLabel,
                place
            )
        }
        if let sport, effectiveCalendarGameFilter == .proGames {
            return String(
                format: L10n.t("schedule_date_sport_matches_format", languageCode: languageCode),
                locale: locale,
                dateLabel,
                sport
            )
        }
        return String(
            format: L10n.t("schedule_date_noun_format", languageCode: languageCode),
            locale: locale,
            dateLabel,
            noun
        )
    }

    private var calendarScheduleHeaderAccessibilityLabel: String {
        if isCalendarSearchModeActive {
            return eventsHeaderTitle
        }
        let languageCode = calendarScheduleLanguageCode
        let locale = Locale(identifier: languageCode)
        let title = eventsHeaderTitle
        switch calendarScheduleHeaderPlaceMode {
        case .summary:
            let spokenPlaces = LiveLeagueCountryFilterPresentation.multiCountryAccessibilitySummary(
                for: selectedCalendarLeagueCountries,
                languageCode: languageCode
            )
            return String(
                format: L10n.t("schedule_header_a11y_with_selection_format", languageCode: languageCode),
                locale: locale,
                title,
                spokenPlaces
            )
        case .none, .inline:
            return title
        }
    }

    private var calendarSectionTitleNoun: String {
        switch effectiveCalendarGameFilter {
        case .venueGames:
            return L10n.t("schedule_noun_watch_parties", languageCode: calendarScheduleLanguageCode)
        case .pickupGames:
            return L10n.t("schedule_noun_pickup_games", languageCode: calendarScheduleLanguageCode)
        case .proGames:
            return L10n.t("professional_games", languageCode: calendarScheduleLanguageCode)
        }
    }

    private var calendarProGamesEmptyStateMessage: String {
        if selectedCalendarFeaturedEvent != nil {
            return "📅 No games found for this date.\nTry another date."
        }
        if calendarLeagueCountryFilterIsActive {
            return "📅 No games found for this date.\nTry another date."
        }
        return "📅 No games found for this date.\nTry another date."
    }

    private var calendarEventsEmptyStateMessage: String {
        switch effectiveCalendarGameFilter {
        case .pickupGames:
            return ""
        case .proGames:
            return calendarProGamesEmptyStateMessage
        case .venueGames:
            return ""
        }
    }

    @ViewBuilder
    private var calendarEventsEmptyState: some View {
        switch effectiveCalendarGameFilter {
        case .venueGames:
            calendarWatchPartiesEmptyState
        case .pickupGames:
            calendarPickupGamesEmptyState
        case .proGames:
            calendarEmptyState(calendarEventsEmptyStateMessage)
        }
    }

    private var calendarPickupGamesEmptyStateTitle: String {
        L10n.t("no_pickup_games_found", languageCode: calendarScheduleLanguageCode)
    }

    private var calendarWatchPartiesEmptyStateTitle: String {
        L10n.t("no_watch_parties_in_discover_area", languageCode: calendarScheduleLanguageCode)
    }

    private var calendarPickupGamesEmptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(calendarPickupGamesEmptyStateTitle)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(calendarColorScheme))

                Text(L10n.t("no_pickup_games_found_supporting", languageCode: calendarScheduleLanguageCode))
                    .font(.subheadline)
                    .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                openDiscoverForPickupGames()
            } label: {
                Text(L10n.t("open_discover", languageCode: calendarScheduleLanguageCode))
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(FGColor.intentPlay, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: .infinity, minHeight: Self.eventsListMinHeight, alignment: .center)
    }

    private var calendarWatchPartiesEmptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(calendarWatchPartiesEmptyStateTitle)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(calendarColorScheme))

                Text(L10n.t("watch_parties_discover_area_description", languageCode: calendarScheduleLanguageCode))
                    .font(.subheadline)
                    .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                openDiscoverForVenueGames()
            } label: {
                Text(L10n.t("open_discover", languageCode: calendarScheduleLanguageCode))
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(FGColor.intentWatch, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: .infinity, minHeight: Self.eventsListMinHeight, alignment: .center)
    }

    private func updateSelectedCalendarLeagueCountries(_ countries: Set<String>) {
        calendarLeagueCountryFilterRaw = LiveLeagueCountryFilterPreference.encode(countries)
        LiveLeagueCountryFilterPreference.markInitialized()
    }

    private func applyCalendarLeagueCountryFilterFirstUseDefaultIfNeeded() {
        let resolved = LiveLeagueCountryFilterPresentation.suggestedNearYouCountry(
            homeCountry: viewModel.currentUserHomeCountry,
            homeRegion: viewModel.currentUserHomeRegion,
            localeRegionCode: LiveLeagueCountryFilterPresentation.deviceLocaleRegionCode()
        )
        guard let encoded = LiveLeagueCountryFilterPreference.firstUseDefaultEncodedSelection(
            currentRaw: calendarLeagueCountryFilterRaw,
            resolvedCountry: resolved
        ) else { return }
        calendarLeagueCountryFilterRaw = encoded
    }

    private var gameSearchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search teams, leagues, or games…", text: $gameSearchText)
                .textInputAutocapitalization(.words)
                .font(.subheadline)
                .focused($isGameSearchFocused)
                .submitLabel(.search)
                .onSubmit {
                    applyCalendarSearchText(gameSearchText)
                }

            if !gameSearchText.isEmpty {
                Button {
                    clearCalendarSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(FGColor.divider(calendarColorScheme).opacity(0.55), lineWidth: 1)
        }
    }

    private var calendarSearchSuggestionsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggestions")
                .font(.caption.weight(.heavy))
                .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
                .textCase(.uppercase)
                .tracking(0.5)

            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(calendarSearchSuggestions) { suggestion in
                    Button {
                        applyCalendarSearchText(suggestion.title)
                    } label: {
                        calendarSearchSuggestionRow(suggestion)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(FGColor.divider(calendarColorScheme).opacity(0.55), lineWidth: 1)
        }
        .padding(.horizontal)
    }

    private func calendarSearchSuggestionRow(_ suggestion: CalendarSearchSuggestion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: suggestion.kind.systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(suggestion.kind.tint)
                .frame(width: 28, height: 28)
                .background(suggestion.kind.tint.opacity(calendarColorScheme == .dark ? 0.18 : 0.10), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(calendarColorScheme))
                    .lineLimit(1)

                if let subtitle = suggestion.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var eventsList: some View {
        Group {
            if !calendarTabSelectedDayIsTodayOrFuture {
                Text("Past dates are not available. Choose today or a future day.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(.horizontal)
                    .frame(maxWidth: .infinity, minHeight: Self.eventsListMinHeight, alignment: .top)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                    Group {
                        if isProGamesSelected {
                            let proMatches = displayedProMatches
                            if proMatches.isEmpty {
                                if scheduleProListBackgroundWorkActive {
                                    Color.clear
                                        .frame(maxWidth: .infinity, minHeight: Self.eventsListMinHeight)
                                } else {
                                    calendarEmptyState(calendarProGamesEmptyStateMessage)
                                }
                            } else {
                                LazyVStack(spacing: 18) {
                                    ForEach(proMatches) { match in
                                        CalendarProGameLazyCard { deferExpensiveSections in
                                            calendarProGameCard(match, deferExpensiveSections: deferExpensiveSections)
                                        }
                                        .id(SavedProGame.stableKey(for: match))
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: Self.eventsListMinHeight, alignment: .top)
                            }
                        } else if shouldShowCalendarEventsLoadingState {
                            calendarLoadingState(calendarEventsLoadingCopy)
                        } else if calendarVenueEventsConsideringDayTransition.isEmpty {
                            calendarEventsEmptyState
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                if calendarVenueEventsAreHeldOverFromPreviousDay
                                    || ((viewModel.isRefreshingDiscoverEvents || calendarWatchPartiesDayTransitionActive)
                                        && effectiveCalendarGameFilter == .venueGames) {
                                    calendarWatchPartiesRefreshingBanner
                                }

                                VStack(spacing: 18) {
                                    ForEach(calendarVenueEventsConsideringDayTransition) { event in
                                        calendarEventCard(event)
                                    }
                                }
                                .opacity(calendarVenueEventsAreHeldOverFromPreviousDay ? 0.58 : 1)
                                .allowsHitTesting(!calendarVenueEventsAreHeldOverFromPreviousDay)
                            }
                            .frame(maxWidth: .infinity, minHeight: Self.eventsListMinHeight, alignment: .top)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 100)
                    }
                    .onChange(of: viewModel.scheduleProGameHighlightStableKey) { _, key in
                        guard let key, !key.isEmpty else { return }
                        DispatchQueue.main.async {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                                proxy.scrollTo(key, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }

    private var calendarSearchResultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if calendarSearchResultGroups.isEmpty {
                    calendarEmptyState(calendarSearchEmptyStateText)
                } else {
                    ForEach(calendarSearchResultGroups) { group in
                        calendarSearchDateSection(group)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 100)
            .frame(maxWidth: .infinity, minHeight: Self.eventsListMinHeight, alignment: .top)
        }
    }

    private func calendarSearchDateSection(_ group: CalendarSearchDateGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(calendarSearchDateHeader(for: group.date))
                .font(.caption.weight(.heavy))
                .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
                .textCase(.uppercase)
                .tracking(0.55)
                .padding(.horizontal, 2)

            LazyVStack(spacing: 18) {
                ForEach(group.items) { item in
                    calendarSearchResultCard(item)
                }
            }
        }
    }

    @ViewBuilder
    private func calendarSearchResultCard(_ item: CalendarSearchResultItem) -> some View {
        switch item {
        case .venue(let event), .pickup(let event):
            calendarEventCard(event)
        case .pro(let match):
            CalendarProGameLazyCard { deferExpensiveSections in
                calendarProGameCard(match, deferExpensiveSections: deferExpensiveSections)
            }
        }
    }

    private var calendarSearchEmptyStateText: String {
        if debouncedCalendarSearchQuery.isEmpty {
            return "Search loaded games by team, country, league, competition, or matchup."
        }
        return "No loaded games match “\(debouncedCalendarSearchQuery)” yet."
    }

    private func calendarEmptyState(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
            .multilineTextAlignment(.leading)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .frame(maxWidth: .infinity, minHeight: Self.eventsListMinHeight, alignment: .center)
    }

    /// Show explicit loading while Watch Parties / pickup lists are empty but still settling or refreshing.
    private var shouldShowCalendarEventsLoadingState: Bool {
        guard !isProGamesSelected else { return false }
        if effectiveCalendarGameFilter == .venueGames, !isCalendarSearchModeActive {
            if !calendarVenueEventsConsideringDayTransition.isEmpty { return false }
            if calendarWatchPartiesDayTransitionActive { return true }
            if viewModel.isLoadingEvents || viewModel.isRefreshingDiscoverEvents { return true }
            return false
        }
        guard displayedEvents.isEmpty else { return false }
        return viewModel.isLoadingEvents || viewModel.isRefreshingDiscoverEvents
    }

    private var calendarEventsLoadingCopy: String {
        switch effectiveCalendarGameFilter {
        case .venueGames:
            if viewModel.isLoadingEvents {
                return "Loading watch parties..."
            }
            if calendarDateStripHasVenueEvents(on: viewModel.calendarTabSelectedDate) {
                return "Finding nearby watch parties..."
            }
            return "Refreshing watch parties..."
        case .pickupGames:
            return viewModel.isLoadingEvents
                ? "Loading pickup games…"
                : "Refreshing pickup games…"
        case .proGames:
            return "Loading events…"
        }
    }

    private var calendarWatchPartiesRefreshingBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(
                calendarVenueEventsAreHeldOverFromPreviousDay
                    ? "Refreshing watch parties..."
                    : calendarEventsLoadingCopy
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func calendarLoadingState(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: Self.eventsListMinHeight, alignment: .center)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    @ViewBuilder
    private var calendarSecondaryFilterBar: some View {
        if isProGamesSelected {
            proGamesFilterStack
        } else {
            sportFilterBar
        }
    }

    private var proGamesFilterStack: some View {
        proGamesSportFilterBar
    }

    private var proGamesSportFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(calendarProVisibleSportFilters, id: \.selection) { item in
                    proGamesSportChip(selection: item.selection, displayTitle: item.display)
                    if item.selection == "All" {
                        proGamesLeagueCountryChip
                        ForEach(calendarFeaturedEvents) { featuredEvent in
                            calendarFeaturedEventChip(featuredEvent)
                        }
                    }
                }

                SportFilterChip(sport: "More", isSelected: false, isCompact: true) {
                    showCalendarSportMoreSheet = true
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal)
    }

    private var proGamesWorldCupFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                proGamesLeagueCountryChip
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal)
    }

    private var proGamesLeagueCountryChip: some View {
        Button {
            showCalendarLeagueCountryFilterSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe.americas.fill")
                    .font(.system(size: 13, weight: .semibold))

                Text(calendarLeagueCountryChipTitle)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .foregroundStyle(calendarLeagueCountryFilterIsActive ? Color.white : FGColor.accentGreen)
            .background {
                Capsule(style: .continuous)
                    .fill(calendarLeagueCountryFilterIsActive ? FGColor.accentGreen : FGColor.accentGreen.opacity(calendarColorScheme == .dark ? 0.18 : 0.10))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(FGColor.accentGreen.opacity(calendarColorScheme == .dark ? 0.44 : 0.28), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(calendarLeagueCountryFilterCount == 0 ? "Countries" : "Countries, \(calendarLeagueCountryFilterCount) selected")
    }

    private var sportFilterBar: some View {
        ScalableSportFilterChipRow(
            viewModel: viewModel,
            showMoreSheet: $showCalendarSportMoreSheet,
            rowSpacing: 10,
            isCompact: true
        )
    }

    private func proGamesSportChip(selection: String, displayTitle: String? = nil) -> some View {
        SportFilterChip(
            sport: selection,
            displayTitle: displayTitle,
            isSelected: selectedCalendarFeaturedEvent == nil && DiscoverSportFilterRowLayout.selectionTokensMatch(calendarProGamesSportFilter, selection),
            isCompact: true
        ) {
            handleProGamesSportChipTap(selection: selection)
        }
    }

    private func handleProGamesSportChipTap(selection: String) {
        if selectedCalendarFeaturedEvent == nil,
           DiscoverSportFilterRowLayout.selectionTokensMatch(calendarProGamesSportFilter, selection) {
            logScheduleTapPerf("[ScheduleTapPerf] tapBlocked reason=alreadySelected")
            return
        }
        logScheduleTapProtectedIfNeeded()
        logScheduleTapPerf("[ScheduleTapPerf] tapReceived type=sportChip value=\(selection)")
        noteScheduleRecentInteraction()
        let started = CFAbsoluteTimeGetCurrent()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            calendarFeaturedEventFilterSlug = nil
            calendarProGamesSportFilter = selection
        }
        applyCalendarProGamesDisplayCacheIfAvailable(reason: "sportChipInstant")
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        logScheduleTapPerf("[ScheduleTapPerf] selectedStateUpdatedMs=\(String(format: "%.2f", ms))")
    }

    private func calendarFeaturedEventChip(_ featuredEvent: FeaturedEvent) -> some View {
        SportFilterChip(
            sport: featuredEvent.sport ?? "Soccer",
            displayTitle: featuredEvent.leagueChipLabel,
            isSelected: selectedCalendarFeaturedEvent?.slug == featuredEvent.slug,
            isCompact: true,
            preferSystemSymbol: false
        ) {
            handleCalendarFeaturedEventChipTap(featuredEvent)
        }
    }

    private func handleCalendarFeaturedEventChipTap(_ featuredEvent: FeaturedEvent) {
        let togglingOff = selectedCalendarFeaturedEvent?.slug == featuredEvent.slug
        logScheduleTapProtectedIfNeeded()
        logScheduleTapPerf("[ScheduleTapPerf] tapReceived type=featuredChip value=\(togglingOff ? "nil" : featuredEvent.slug)")
        noteScheduleRecentInteraction()
        let started = CFAbsoluteTimeGetCurrent()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            calendarProGamesSportFilter = "All"
            updateSelectedCalendarLeagueCountries([])
            calendarFeaturedEventFilterSlug = togglingOff ? nil : featuredEvent.slug
        }
        applyCalendarProGamesDisplayCacheIfAvailable(reason: "featuredChipInstant")
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        logScheduleTapPerf("[ScheduleTapPerf] selectedStateUpdatedMs=\(String(format: "%.2f", ms))")
    }

    private func handleVenueCalendarEventTap(_ event: SportsEvent) {
        if viewModel.isGuestDiscoverMode {
            viewModel.discoverNavigateToAccountForUserAuth = true
            return
        }
        openVenueEventInDiscover(event)
    }

    private func openDiscoverForVenueGames() {
        if viewModel.discoverMapContentMode != .venues {
            viewModel.clearDiscoverMapContentSelectionsWhenSwitching(to: .venues)
            viewModel.discoverMapContentMode = .venues
        }
        selectedTab = .discover
    }

    private func openDiscoverForPickupGames() {
        if viewModel.discoverMapContentMode != .pickupGames {
            viewModel.clearDiscoverMapContentSelectionsWhenSwitching(to: .pickupGames)
            viewModel.discoverMapContentMode = .pickupGames
        }
        if viewModel.discoverPickupSubMode != .games {
            viewModel.discoverPickupSubMode = .games
        }
        selectedTab = .discover
    }

    private func openVenueEventInDiscover(_ event: SportsEvent) {
        if viewModel.discoverMapContentMode != .venues {
            viewModel.clearDiscoverMapContentSelectionsWhenSwitching(to: .venues)
            viewModel.discoverMapContentMode = .venues
        }
        let requestID = viewModel.beginDiscoverDateChange(to: event.date)
        viewModel.scheduleDiscoverSelectedDayRefresh(requestID: requestID)
        guard let bar = viewModel.snapshotBarVenueForCalendarVenueEventFocus(event) else {
            viewModel.showSocialActionToast("Couldn't find this venue on the map.", isError: true)
            return
        }
        viewModel.requestDiscoverFocusForSavedVenue(bar)
        selectedTab = .discover
    }

    @ViewBuilder
    private func calendarEventCard(_ event: SportsEvent) -> some View {
        if event.league == MapViewModel.calendarTabPickupLeagueMarker {
            if !isBusinessCalendarAccess {
                pickupCalendarEventCard(event)
            }
        } else {
            venueCalendarEventCard(event)
        }
    }

    private func calendarProGameIsInactiveCompleted(_ match: LiveMatch) -> Bool {
        match.matchStatus == .fullTime
    }

    private func calendarProGameCard(_ match: LiveMatch, deferExpensiveSections: Bool = false) -> some View {
        let sportKey = match.liveSportVisualType.sportFilterCatalogKey
        let isInactiveCompleted = calendarProGameIsInactiveCompleted(match)
        let accent = match.matchStatus.isHappeningNow
            ? FGColor.dangerRed
            : (isInactiveCompleted
                ? FGColor.secondaryText(calendarColorScheme)
                : viewModel.colorForSport(sportKey))
        let featuredEvent = calendarFeaturedEvent(for: match)
        let isSaved = viewModel.isProGameSaved(match)
        let watchPartyCount = watchPartyCount(for: match)
        let stableKey = SavedProGame.stableKey(for: match)
        let isHighlighted = viewModel.scheduleProGameHighlightStableKey == stableKey
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(calendarProGameStartTimeText(match))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(accent)

                if match.matchStatus.isHappeningNow || match.matchStatus == .fullTime {
                    ProGameLeagueChip(
                        sportType: match.liveSportVisualType,
                        featuredEvent: featuredEvent,
                        league: match.league
                    )
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        calendarTeamLine(match.awayTeam, score: nil, badgeURL: match.awayTeamBadgeURL)
                        calendarTeamLine(match.homeTeam, score: nil, badgeURL: match.homeTeamBadgeURL)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text(featuredEvent?.emptyStateTitle ?? match.league)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(calendarColorScheme))
                    .lineLimit(2)
                Text(match.league)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if watchPartyCount > 0 {
                    Text(watchPartyCount == 1 ? "1 watch party" : "\(watchPartyCount) watch parties")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(FGColor.accentGreen)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(FGColor.accentGreen.opacity(calendarColorScheme == .dark ? 0.18 : 0.10), in: Capsule())
                }
            }
            .frame(width: 112, alignment: .leading)

            ZStack(alignment: .topTrailing) {
                ProGameSportBadgeView(
                    sportType: match.liveSportVisualType,
                    diameter: 64,
                    featuredEvent: featuredEvent,
                    featuredEventSlug: match.featuredEventSlug
                )
                calendarProGameSaveButton(match, isSaved: isSaved, accent: accent)
                    .offset(x: 8, y: -8)
            }
            }

            if calendarProGameShouldShowScore(match) {
                ProGameScoreBlock(
                    awayTeam: match.awayTeam,
                    homeTeam: match.homeTeam,
                    awayScore: match.scoreAway,
                    homeScore: match.scoreHome,
                    awayBadgeURL: match.awayTeamBadgeURL,
                    homeBadgeURL: match.homeTeamBadgeURL,
                    source: "Calendar",
                    isFinal: match.matchStatus == .fullTime,
                    isLive: match.matchStatus.isHappeningNow,
                    accentColor: accent,
                    style: ProGameScoreboardStyle(
                        scoreFont: .headline.weight(.black).monospacedDigit(),
                        separatorFont: .headline.weight(.bold),
                        teamNameFont: .caption.weight(.semibold),
                        emblemSize: 22
                    ),
                    timelineSummary: match.resolvedGoalDisplaySummary,
                    cardTimelineSummary: match.resolvedCardTimelineSummary,
                    gameId: SavedProGame.stableKey(for: match),
                    showsFramedFinalBackground: false,
                    flagSource: "Calendar"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if match.supportsProGamePredictions {
                calendarProGamePredictionFooter(for: match, prefetchEnabled: !deferExpensiveSections)
            }

            if calendarShouldShowAddToVenue(for: match) {
                calendarProGameAddToVenueButton(match)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isInactiveCompleted
                ? Color(.tertiarySystemGroupedBackground)
                : Color(.secondarySystemGroupedBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    isHighlighted
                        ? FGColor.intentProGames.opacity(calendarColorScheme == .dark ? 0.95 : 0.88)
                        : FGColor.divider(calendarColorScheme).opacity(
                            isInactiveCompleted
                                ? (calendarColorScheme == .dark ? 0.42 : 0.56)
                                : (calendarColorScheme == .dark ? 0.28 : 0.38)
                        ),
                    lineWidth: isHighlighted ? 2.25 : 1
                )
        }
        .scaleEffect(isHighlighted ? 1.015 : 1)
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: isHighlighted)
        .saturation(isInactiveCompleted ? 0.84 : 1)
        .opacity(isInactiveCompleted ? 0.94 : 1)
        .shadow(
            color: Color.black.opacity(
                isInactiveCompleted
                    ? (calendarColorScheme == .dark ? 0.09 : 0.035)
                    : (calendarColorScheme == .dark ? 0.20 : 0.065)
            ),
            radius: isInactiveCompleted ? 5 : 10,
            y: isInactiveCompleted ? 2 : 4
        )
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .accessibilityHint(
            isHighlighted
                ? L10n.t(
                    "discover_pro_game_schedule_highlight_a11y_hint",
                    languageCode: L10n.normalizedLanguageCode(appLanguageRaw)
                )
                : ""
        )
        .onAppear {
            guard !deferExpensiveSections else { return }
            logCalendarScoringEventDebug(match)
        }
    }

    private var calendarCanUseAddToVenueShortcut: Bool {
        viewModel.hasAuthenticatedVenueOwnerSession || viewModel.isVenueOwnerLoggedIn
    }

    /// Owner-visible venues for the chooser (active selectable; plan_locked shown locked).
    private var calendarAddToVenueChooserVenues: [VenueProfileRow] {
        viewModel.managedVenuesForOwner().filter { MapViewModel.venueIsOwnerVisibleManagedStatus($0) }
    }

    private var calendarAddToVenueSelectableVenues: [VenueProfileRow] {
        viewModel.managedVenuesForOwner().filter { MapViewModel.venueIsActiveForBusinessLimit($0) }
    }

    private func calendarProGameCanImportToVenue(_ match: LiveMatch) -> Bool {
        let id = match.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = match.homeTeam.trimmingCharacters(in: .whitespacesAndNewlines)
        let away = match.awayTeam.trimmingCharacters(in: .whitespacesAndNewlines)
        return !id.isEmpty && !home.isEmpty && !away.isEmpty
    }

    private func calendarShouldShowAddToVenue(for match: LiveMatch) -> Bool {
        calendarCanUseAddToVenueShortcut
            && !calendarAddToVenueSelectableVenues.isEmpty
            && calendarProGameCanImportToVenue(match)
    }

    private func calendarProGameAddToVenueButton(_ match: LiveMatch) -> some View {
        Button {
            handleCalendarAddToVenueTapped(match)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "building.2.fill")
                    .font(.caption.weight(.bold))
                Text(L10n.t("Add to Venue", languageCode: appLanguageRaw))
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
            }
            .foregroundStyle(FGColor.accentBlue)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FGColor.accentBlue.opacity(calendarColorScheme == .dark ? 0.16 : 0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(FGColor.accentBlue.opacity(calendarColorScheme == .dark ? 0.32 : 0.18), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("Add to Venue", languageCode: appLanguageRaw))
    }

    private func handleCalendarAddToVenueTapped(_ match: LiveMatch) {
        let selectable = calendarAddToVenueSelectableVenues
        guard calendarProGameCanImportToVenue(match) else { return }
        guard !selectable.isEmpty else { return }

        if selectable.count == 1, let venueId = selectable.first?.id {
            presentAddToVenueImport(match: match, venueId: venueId)
            return
        }

        calendarAddToVenueChooser = CalendarAddToVenueChooserContext(match: match)
    }

    private func presentAddToVenueImport(match: LiveMatch, venueId: UUID) {
        calendarAddToVenueImportPrefill = VenueOwnerScheduleImportPrefill(match: match, venueId: venueId)
    }

    private func calendarProGamePredictionFooter(for match: LiveMatch, prefetchEnabled: Bool) -> some View {
        let game = SavedProGame.forPredictions(match: match, savedGames: viewModel.savedProGames)
        return ProGamePredictionFooterRow(
            game: game,
            summary: viewModel.proGamePredictionSummaries[game.stableKey]
        ) {
            calendarProGamePredictionSheet = ProGamePredictionSheetContext(game: game)
        }
        .task(id: prefetchEnabled ? game.stableKey : nil) {
            guard prefetchEnabled else { return }
#if DEBUG
            ProSchedulePerf.noteHydrationStarted()
#endif
            await viewModel.prefetchProGamePredictionSummaries(for: [game])
        }
    }

    @ViewBuilder
    private func calendarTeamLine(_ team: String, score: Int?, badgeURL: String?) -> some View {
        if let score {
            ProGameScoreRowView(
                identity: ProGameTeamScoreIdentity.resolve(teamName: team, badgeURL: badgeURL, source: "Calendar"),
                score: score,
                scoreFont: .headline.weight(.black).monospacedDigit(),
                nameFont: .headline.weight(.bold),
                leadingSpacing: 8,
                scoreMinWidth: 24
            )
        } else {
            HStack(spacing: 8) {
                calendarTeamLeadingContent(for: team, badgeURL: badgeURL)
                Text(ProGameTeamScoreIdentity.cleanTeamName(team))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    @ViewBuilder
    private func calendarTeamLeadingContent(for team: String, badgeURL: String?) -> some View {
        switch ProGameTeamScoreIdentity.resolve(teamName: team, badgeURL: badgeURL, source: "Calendar").leading {
        case let .flag(flag):
            Text(flag)
                .font(.title3)
        case let .logoURL(url):
            DiscoverCachedRemoteImage(url: url, contentMode: .fit) {
                Color.clear
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        case .none:
            EmptyView()
        }
    }

    private func calendarProGameShouldShowScore(_ match: LiveMatch) -> Bool {
        if match.matchStatus.isHappeningNow || match.matchStatus == .fullTime { return true }
        return match.matchStatus == .scheduled && match.scoresAreAvailable
    }

    private func logCalendarScoringEventDebug(_ match: LiveMatch) {
        LiveScoringEventDebug.log(
            gameId: match.id,
            eventId: match.externalId,
            sport: match.sport,
            sportType: match.liveSportVisualType,
            matchStatus: match.matchStatus,
            rawMatchStatus: match.rawMatchStatus,
            homeTeam: match.homeTeam,
            awayTeam: match.awayTeam,
            timelineEvents: match.timelineEvents,
            timelineFetched: !match.timelineEvents.isEmpty
        )
#if DEBUG
        ScoringTimelineDebug.log(
            gameId: match.id,
            scoreHome: match.scoreHome,
            scoreAway: match.scoreAway,
            homeTeam: match.homeTeam,
            awayTeam: match.awayTeam,
            sportType: match.liveSportVisualType,
            timelineEvents: match.timelineEvents
        )
#endif
    }

    private func calendarProGameSaveButton(_ match: LiveMatch, isSaved: Bool, accent: Color) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                viewModel.toggleSavedProGame(match)
            }
        } label: {
            Image(systemName: isSaved ? "heart.fill" : "heart")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(isSaved ? Color.red.opacity(0.95) : accent)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill((isSaved ? Color.red : accent).opacity(calendarColorScheme == .dark ? 0.18 : 0.10))
                )
                .overlay {
                    Circle()
                        .strokeBorder((isSaved ? Color.red : accent).opacity(calendarColorScheme == .dark ? 0.40 : 0.24), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSaved ? L10n.t("unsave_pro_sports_game_a11y", languageCode: appLanguageRaw) : L10n.t("save_pro_sports_game_a11y", languageCode: appLanguageRaw))
    }

    private func calendarFeaturedEvent(for match: LiveMatch) -> FeaturedEvent? {
        if let featuredEventSlug = match.featuredEventSlug {
            let normalizedSlug = LiveMatchFilters.normalizedSearchText(featuredEventSlug)
            if let direct = calendarFeaturedEvents.first(where: { LiveMatchFilters.normalizedSearchText($0.slug) == normalizedSlug }) {
                return direct
            }
        }
        return calendarFeaturedEvents.first {
            LiveMatchFilters.matchesFeaturedEvent(match, featuredEvent: $0)
        }
    }

    private func calendarProGameTitle(_ match: LiveMatch) -> String {
        "\(calendarTeamDisplayName(match.awayTeam)) at \(calendarTeamDisplayName(match.homeTeam))"
    }

    private func calendarTeamDisplayName(_ teamName: String) -> String {
        let trimmed = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              CountryFlagHelper.isCountry(trimmed),
              let flag = CountryFlagHelper.flag(for: trimmed),
              !flag.isEmpty else {
            return trimmed
        }
        return "\(flag) \(trimmed)"
    }

    private func calendarProGameStartTimeText(_ match: LiveMatch) -> String {
        CompactGameTimeFormatter.timeWithZone(
            for: match.startTime,
            timeZoneOption: viewModel.selectedTimeZone
        )
    }

    private func calendarProGameStatusText(_ match: LiveMatch) -> String {
        switch match.matchStatus {
        case .live:
            if let minute = match.minute {
                return "LIVE \(minute)'"
            }
            return "LIVE"
        case .halfTime:
            return "HT"
        case .fullTime:
            return "Final"
        case .scheduled:
            return "Scheduled"
        }
    }

    private func pickupCalendarCapacityPillText(for row: PickupGameRow?) -> String {
        guard let row else { return "Open" }
        return row.isPickupFullForDiscover ? "Full" : "Open"
    }

    private func pickupCalendarEventCard(_ event: SportsEvent) -> some View {
        let now = Date()
        let pickupRow = viewModel.resolvedPickupGameRow(for: event.id)
        let pickupStarted = pickupRow?.hasPickupGameStarted(now: now) ?? false
        let addressLine = pickupRow.map { viewModel.pickupGameCalendarAddressLine($0) } ?? ""
        let spotsLine = pickupRow.flatMap { viewModel.pickupGameCalendarSpotsLine($0) }
        let capacityMeta = pickupCalendarCapacityPillText(for: pickupRow)
        let rosterState = pickupRow.map { $0.isPickupFullForDiscover ? "full" : "open" } ?? "unknown"

        return Button {
            if viewModel.isGuestDiscoverMode {
                viewModel.discoverNavigateToAccountForUserAuth = true
                return
            }
            calendarPickupDetailToken = PickupDetailNavigationToken(id: event.id)
        } label: {
            HStack(alignment: .center, spacing: 14) {
                PickupGameStartedSportGlyphFrame(showStarted: pickupStarted) {
                    SportArtworkIconView(sport: event.sport, diameter: 46)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(event.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(1)

                    if let row = pickupRow {
                        Text(viewModel.pickupGameCalendarDateTimeLine(row))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if !addressLine.isEmpty {
                            Text(addressLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if let spots = spotsLine {
                            Text(spots)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                    } else {
                        Text("Pickup details loading…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if pickupStarted {
                        PickupGameStartedLineCaption()
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 8) {
                    Text(capacityMeta)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(capacityMeta == "Full" ? FGColor.secondaryText(calendarColorScheme) : FGColor.accentGreen)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill((capacityMeta == "Full" ? Color.primary : FGColor.accentGreen).opacity(calendarColorScheme == .dark ? 0.16 : 0.10))
                        )
                        .accessibilityLabel(capacityMeta == "Full" ? "Roster full" : "Spots available")

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(calendarColorScheme == .dark ? 0.12 : 0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(calendarColorScheme == .dark ? 0.14 : 0.04), radius: 7, y: 3)
        }
        .buttonStyle(.plain)
        .onAppear {
#if DEBUG
            print("[CalendarPickupPublicMode] personalStateHidden=true")
            print("[CalendarPickupPublicMode] badgeRemoved=true")
            print("[CalendarPickupPublicMode] gameId=\(event.id.uuidString.lowercased())")
            print("[CalendarPickupPublicMode] rosterState=\(rosterState)")
#endif
            if let r = pickupRow {
                PickupGameStartedStateDebug.log(row: r, now: now, allowedActions: "calendar_tab_public_row")
            }
            if let row = pickupRow {
                Task {
                    await viewModel.loadPickupCreatorDisplayNameIfNeeded(creatorUserId: row.creator_user_id)
                }
            }
        }
    }

    private func venueCalendarEventCard(_ event: SportsEvent) -> some View {
        let isVenueEvent = event.league == "Venue Event"
        let venueBar = isVenueEvent ? viewModel.barVenueForCalendarVenueEvent(event) : nil
        let venueRow = isVenueEvent ? viewModel.matchingCalendarVenueEventRow(for: event) : nil
        let presentation = CalendarVenueEventPresentation.resolve(event: event, bar: venueBar, row: venueRow)
        let featuredEvent = calendarVenueFeaturedEvent(for: venueRow, sport: presentation.sportToken)
        let watchPartyCount = watchPartyCount(forVenueEventTitle: event.title)
        let venueFeatureChips = venueBar.map { compactVenueFeaturesForCards($0, limit: 2) } ?? []

        return Button {
            handleVenueCalendarEventTap(event)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                calendarVenueCardThumbnail(
                    bar: venueBar,
                    sportToken: presentation.sportToken,
                    featuredEvent: featuredEvent,
                    watchPartyCount: watchPartyCount
                )

                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(viewModel.displayTime(for: event))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(FGColor.accentGreen)

                        calendarVenueCardTitleRow(event: event, presentation: presentation)

                        calendarVenueCardSportCompetitionRow(
                            presentation: presentation,
                            featuredEvent: featuredEvent
                        )

                        if let venueName = presentation.venueDisplayName {
                            HStack(spacing: 5) {
                                Image(systemName: "building.2.fill")
                                    .font(.caption.weight(.semibold))
                                    .accessibilityHidden(true)
                                Text(venueName)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.primary)
                        }

                        if let address = presentation.addressLine {
                            HStack(alignment: .top, spacing: 5) {
                                Image(systemName: "mappin.and.ellipse")
                                    .font(.caption)
                                    .accessibilityHidden(true)
                                Text(address)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }

                        calendarVenueCardDetailChips(
                            watchPartyCount: watchPartyCount,
                            featureChips: venueFeatureChips
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                        .accessibilityHidden(true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(calendarColorScheme == .dark ? 0.12 : 0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(calendarColorScheme == .dark ? 0.14 : 0.04), radius: 7, y: 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear {
            if isVenueEvent, let b = venueBar {
                VenueGameBusinessEmail.logDebug(bar: b)
            }
        }
    }

    @ViewBuilder
    private func calendarVenueCardThumbnail(
        bar: BarVenue?,
        sportToken: String,
        featuredEvent: FeaturedEvent?,
        watchPartyCount: Int
    ) -> some View {
        let width: CGFloat = 92
        let height: CGFloat = 112
        let sportKey = sportToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (bar?.primarySport ?? "Soccer")
            : sportToken
        let sportVisual = SportFilterCatalog.resolve(sportKey)

        ZStack(alignment: .bottomLeading) {
            Group {
                if let bar,
                   let urlString = ImageDisplayURL.forList(
                       thumbnail: bar.coverPhotoThumbnailURL,
                       full: bar.coverPhotoURL
                   ),
                   let url = URL(string: urlString) {
                    DiscoverCachedRemoteImage(url: url, contentMode: .fill) {
                        calendarVenueCardThumbnailFallback(sportVisual: sportVisual)
                    }
                } else {
                    calendarVenueCardThumbnailFallback(sportVisual: sportVisual)
                }
            }
            .frame(width: width, height: height)
            .clipped()

            if watchPartyCount > 0 {
                Text(watchPartyCount == 1 ? "1 watch party" : "\(watchPartyCount) watch parties")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(FGColor.accentGreen.opacity(0.92), in: Capsule(style: .continuous))
                    .padding(6)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
    }

    private func calendarVenueCardThumbnailFallback(sportVisual: SportFilterCatalog.ChipVisual) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    sportVisual.accent.opacity(calendarColorScheme == .dark ? 0.34 : 0.22),
                    sportVisual.accent.opacity(calendarColorScheme == .dark ? 0.16 : 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: sportVisual.systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(sportVisual.accent)
        }
    }

    @ViewBuilder
    private func calendarVenueCardTitleRow(event: SportsEvent, presentation: CalendarVenueEventPresentation) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(presentation.gameTitle(fallback: event.title))
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if presentation.hasTeamMatchup {
                HStack(spacing: 4) {
                    calendarTeamLeadingContent(for: presentation.awayTeam ?? "", badgeURL: nil)
                    Text("vs")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    calendarTeamLeadingContent(for: presentation.homeTeam ?? "", badgeURL: nil)
                }
                .layoutPriority(1)
            }
        }
    }

    @ViewBuilder
    private func calendarVenueCardSportCompetitionRow(
        presentation: CalendarVenueEventPresentation,
        featuredEvent: FeaturedEvent?
    ) -> some View {
        let sportVisual = SportFilterCatalog.resolve(presentation.sportToken)
        let competitionLabel = presentation.competitionBadgeLabel(featuredEvent: featuredEvent)

        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: sportVisual.systemImage)
                    .font(.caption2.weight(.bold))
                    .accessibilityHidden(true)
                Text(AppSportCatalog.displayLabel(forSportToken: presentation.sportToken))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(sportVisual.accent)

            if let competitionLabel {
                Text(competitionLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(FGColor.accentGreen)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(FGColor.accentGreen.opacity(calendarColorScheme == .dark ? 0.18 : 0.10))
                    )
            }
        }
    }

    @ViewBuilder
    private func calendarVenueCardDetailChips(
        watchPartyCount: Int,
        featureChips: [VenueFeatureDisplayItem]
    ) -> some View {
        let chips = calendarVenueCardDetailChipModels(
            watchPartyCount: watchPartyCount,
            featureChips: featureChips
        )
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chips) { chip in
                        calendarVenueDetailChip(icon: chip.iconName, label: chip.label)
                    }
                }
            }
        }
    }

    private struct CalendarVenueDetailChipModel: Identifiable {
        let id: String
        let iconName: String
        let label: String
    }

    private func calendarVenueCardDetailChipModels(
        watchPartyCount: Int,
        featureChips: [VenueFeatureDisplayItem]
    ) -> [CalendarVenueDetailChipModel] {
        var chips: [CalendarVenueDetailChipModel] = []
        if watchPartyCount > 0 {
            chips.append(
                CalendarVenueDetailChipModel(
                    id: "watch-party",
                    iconName: "person.2.fill",
                    label: watchPartyCount == 1 ? "1 watch party" : "\(watchPartyCount) watch parties"
                )
            )
        }
        for feature in featureChips.prefix(3 - chips.count) {
            chips.append(
                CalendarVenueDetailChipModel(
                    id: feature.id,
                    iconName: feature.iconName,
                    label: feature.label
                )
            )
        }
        return chips
    }

    private func calendarVenueDetailChip(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
                .accessibilityHidden(true)
            Text(label)
                .lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(calendarColorScheme == .dark ? 0.10 : 0.06))
        )
    }

    private func calendarVenueFeaturedEvent(for row: VenueEventRow?, sport: String) -> FeaturedEvent? {
        let league = row?.external_league?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !league.isEmpty else { return nil }
        let normalizedLeague = LiveMatchFilters.normalizedSearchText(league)
        if let direct = calendarFeaturedEvents.first(where: { featuredEvent in
            let candidates = [
                LiveMatchFilters.normalizedSearchText(featuredEvent.slug),
                LiveMatchFilters.normalizedSearchText(featuredEvent.title),
                featuredEvent.shortTitle.map(LiveMatchFilters.normalizedSearchText) ?? ""
            ]
            return candidates.contains(normalizedLeague)
        }) {
            return direct
        }
        return calendarFeaturedEvents.first { featuredEvent in
            featuredEvent.includeKeywords.contains { keyword in
                let normalizedKeyword = LiveMatchFilters.normalizedSearchText(keyword)
                return normalizedLeague.contains(normalizedKeyword) || normalizedKeyword.contains(normalizedLeague)
            }
        }
    }

    private func watchPartyCount(forVenueEventTitle title: String) -> Int {
        let key = normalizedCalendarMatchText(title)
        guard !key.isEmpty else { return 0 }
        return max(
            1,
            venueEventsForSelectedDateNoSearch.filter {
                normalizedCalendarMatchText($0.title) == key
            }.count
        )
    }

    private func watchPartyCount(for match: LiveMatch) -> Int {
        let away = normalizedCalendarMatchText(match.awayTeam)
        let home = normalizedCalendarMatchText(match.homeTeam)
        let title = normalizedCalendarMatchText("\(match.awayTeam) \(match.homeTeam)")
        guard !away.isEmpty || !home.isEmpty else { return 0 }

        return venueEventsForSelectedDateNoSearch.filter { event in
            let eventText = normalizedCalendarMatchText(event.title)
            if !away.isEmpty, !home.isEmpty, eventText.contains(away), eventText.contains(home) {
                return true
            }
            return !title.isEmpty && eventText.contains(title)
        }.count
    }

    private func normalizedCalendarMatchText(_ raw: String) -> String {
        raw
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func scheduleCalendarSearchRefresh() {
        gameSearchDebounceTask?.cancel()
        gameSearchDebounceTask = nil
        refreshCurrentDayCalendarSearchResults(reason: "typing")
    }

    private func refreshCurrentDayCalendarSearchForLoadedDataChange() {
        guard isCalendarSearchModeActive else { return }
        refreshCurrentDayCalendarSearchResults(reason: "loadedDataChange")
    }

    private func refreshCurrentDayCalendarSearchResults(reason: String) {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let query = immediateCalendarSearchQuery
        debouncedGameSearchText = query
        calendarSearchResultGroups = []
        calendarSearchSuggestions = []
        guard !query.isEmpty else {
            calendarSearchFilteredEvents = []
            calendarSearchFilteredProMatches = []
            logScheduleSearchPerf(
                query: query,
                mode: effectiveCalendarGameFilter,
                beforeCount: 0,
                resultCount: 0,
                startedAt: startedAt,
                reason: reason
            )
            return
        }

        let normalizedQuery = calendarNormalizedSearchText(query)
        if isProGamesSelected {
            let baseMatches = calendarBaseDisplayedProMatches()
            calendarSearchFilteredProMatches = baseMatches.filter {
                calendarCurrentDayProMatch($0, matchesNormalizedQuery: normalizedQuery)
            }
            calendarSearchFilteredEvents = []
            logScheduleSearchPerf(
                query: query,
                mode: effectiveCalendarGameFilter,
                beforeCount: baseMatches.count,
                resultCount: calendarSearchFilteredProMatches.count,
                startedAt: startedAt,
                reason: reason
            )
        } else {
            let baseEvents = calendarBaseDisplayedEvents()
            calendarSearchFilteredEvents = baseEvents.filter {
                calendarCurrentDayEvent($0, matchesNormalizedQuery: normalizedQuery)
            }
            calendarSearchFilteredProMatches = []
            logScheduleSearchPerf(
                query: query,
                mode: effectiveCalendarGameFilter,
                beforeCount: baseEvents.count,
                resultCount: calendarSearchFilteredEvents.count,
                startedAt: startedAt,
                reason: reason
            )
        }
    }

    private func applyCalendarSearchText(_ rawText: String) {
        let query = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        gameSearchDebounceTask?.cancel()
        gameSearchDebounceTask = nil
        gameSearchText = query
        debouncedGameSearchText = query
        calendarSearchSuggestions = []
        isGameSearchFocused = false
        refreshCurrentDayCalendarSearchResults(reason: "submit")
    }

    private func clearCalendarSearch() {
        gameSearchDebounceTask?.cancel()
        gameSearchDebounceTask = nil
        gameSearchText = ""
        debouncedGameSearchText = ""
        calendarSearchSuggestions = []
        calendarSearchResultGroups = []
        calendarSearchFilteredEvents = []
        calendarSearchFilteredProMatches = []
    }

    private func calendarCurrentDayEvent(_ event: SportsEvent, matchesNormalizedQuery normalizedQuery: String) -> Bool {
        calendarCurrentDaySearchTextMatches(
            fields: [
                event.title,
                event.sport,
                event.league,
                event.country,
                event.venueName,
                event.venueCity
            ],
            normalizedQuery: normalizedQuery
        )
    }

    private func calendarCurrentDayProMatch(_ match: LiveMatch, matchesNormalizedQuery normalizedQuery: String) -> Bool {
        calendarCurrentDaySearchTextMatches(
            fields: [
                match.homeTeam,
                match.awayTeam,
                "\(match.awayTeam) vs \(match.homeTeam)",
                "\(match.homeTeam) vs \(match.awayTeam)",
                "\(match.awayTeam) at \(match.homeTeam)",
                match.sport,
                match.league,
                match.sourceLeagueName,
                match.leagueAlternate,
                match.eventName,
                match.leagueCountry
            ],
            normalizedQuery: normalizedQuery
        )
    }

    private func calendarCurrentDaySearchTextMatches(fields: [String?], normalizedQuery: String) -> Bool {
        guard !normalizedQuery.isEmpty else { return true }
        let searchableText = fields
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(calendarNormalizedSearchText)
            .joined(separator: " ")
        guard !searchableText.isEmpty else { return false }
        if searchableText.contains(normalizedQuery) { return true }
        let tokens = normalizedQuery.split(separator: " ").map(String.init)
        return !tokens.isEmpty && tokens.allSatisfy { searchableText.contains($0) }
    }

    private func logScheduleSearchPerf(
        query: String,
        mode: CalendarTabGameFilter,
        beforeCount: Int,
        resultCount: Int,
        startedAt: CFAbsoluteTime,
        reason: String
    ) {
#if DEBUG
        let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        let selectedDate = calendarSearchDayFormatter.string(from: viewModel.calendarTabSelectedDate)
        print(
            "[ScheduleSearchPerf] " +
            "reason=\(reason) " +
            "searchText=\"\(query)\" " +
            "selectedDate=\(selectedDate) " +
            "mode=\(calendarSearchModeLabel(mode)) " +
            "beforeCount=\(beforeCount) " +
            "resultCount=\(resultCount) " +
            "durationMs=\(durationMs)"
        )
#endif
    }

    private func calendarSearchModeLabel(_ mode: CalendarTabGameFilter) -> String {
        switch mode {
        case .venueGames:
            return "Watch"
        case .pickupGames:
            return "Play"
        case .proGames:
            return "ProGames"
        }
    }

    private func rebuildCalendarSearchIndexIfNeeded(force: Bool = false) {
        calendarSearchIndex = []
        calendarSearchIndexFingerprint = ""
    }

    private func calendarSearchIndexCurrentFingerprint() -> String {
        ""
    }

    private func buildCalendarSearchIndex() -> [CalendarSearchIndexEntry] {
        []
    }

    private func buildCalendarSearchResultGroups(query: String) -> [CalendarSearchDateGroup] {
        let normalizedQuery = calendarNormalizedSearchText(query)
        guard !normalizedQuery.isEmpty else { return [] }

        let sortedItems = calendarSearchIndex
            .filter { entry in
                calendarSearchItemPassesActiveFilters(entry.item)
                    && calendarSearchTextMatches(entry.searchableText, normalizedQuery: normalizedQuery)
            }
            .map(\.item)
            .sorted { lhs, rhs in
                if lhs.date != rhs.date { return lhs.date < rhs.date }
                if lhs.sortTitle != rhs.sortTitle {
                    return lhs.sortTitle.localizedCaseInsensitiveCompare(rhs.sortTitle) == .orderedAscending
                }
                return lhs.id < rhs.id
            }
            .prefix(Self.calendarSearchResultLimit)
            .map { $0 }

        let calendar = Calendar.current
        return Dictionary(grouping: sortedItems) { item in
            calendar.startOfDay(for: item.date)
        }
        .map { CalendarSearchDateGroup(date: $0.key, items: $0.value) }
        .sorted { $0.date < $1.date }
    }

    private func loadedVenueSearchEvents() -> [SportsEvent] {
        viewModel.events.filter { event in
            event.league == "Venue Event"
        }
    }

    private func loadedPickupSearchEvents() -> [SportsEvent] {
        guard !isBusinessCalendarAccess, viewModel.canFanUsePickupGamesUI else { return [] }
        let calendar = Calendar.current
        return viewModel.pickupGamesForDiscoverMap.compactMap { row in
            guard calendarSearchPickupRowPassesListingFilters(row),
                  let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else {
                return nil
            }
            return SportsEvent(
                id: row.id,
                title: row.title,
                sport: row.sport,
                league: MapViewModel.calendarTabPickupLeagueMarker,
                date: calendar.startOfDay(for: start),
                time: calendarSearchTimeFormatter.string(from: start),
                country: "",
                calendarPickupJoinStatus: nil
            )
        }
    }

    private func calendarSearchItemPassesActiveFilters(_ item: CalendarSearchResultItem) -> Bool {
        switch item {
        case .venue(let event):
            guard effectiveCalendarGameFilter == .venueGames else { return false }
            return calendarSport(event.sport, matchesFilter: viewModel.selectedSport)
        case .pickup(let event):
            guard effectiveCalendarGameFilter == .pickupGames else { return false }
            return calendarSport(event.sport, matchesFilter: viewModel.selectedSport)
        case .pro(let match):
            guard effectiveCalendarGameFilter == .proGames else { return false }
            if let selectedCalendarFeaturedEvent {
                return LiveMatchFilters.matchesFeaturedEvent(match, featuredEvent: selectedCalendarFeaturedEvent)
            }
            guard calendarSport(match.sport, matchesFilter: calendarProGamesSportFilter) else { return false }
            return LiveMatchFilters.matchesLeagueCountry(match, selectedCountries: selectedCalendarLeagueCountries)
        }
    }

    private func calendarSport(_ sport: String, matchesFilter filter: String) -> Bool {
        let trimmedFilter = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFilter.isEmpty,
              trimmedFilter.localizedCaseInsensitiveCompare("All") != .orderedSame else {
            return true
        }
        return sport.localizedCaseInsensitiveCompare(trimmedFilter) == .orderedSame
            || SportFilterCatalog.storedSport(sport, matchesSearchQuery: trimmedFilter)
    }

    private func calendarSearchPickupRowPassesListingFilters(_ row: PickupGameRow, now: Date = Date()) -> Bool {
        guard row.is_visible, row.status.lowercased() == "active" else { return false }
        if let removeAfterRaw = row.remove_after_at,
           let removeAfter = PickupGameModels.parseSupabaseTimestamptz(removeAfterRaw),
           removeAfter <= now {
            return false
        }
        return true
    }

    private func calendarVenueEvent(_ event: SportsEvent, matchesNormalizedQuery normalizedQuery: String) -> Bool {
        let row = calendarVenueEventRow(for: event)
        return calendarSearchFieldsMatch(
            [
                event.title,
                event.sport,
                event.league,
                event.country,
                event.venueName,
                event.venueCity,
                row?.event_title,
                row?.home_team,
                row?.away_team,
                row?.external_league,
                row?.venue_name,
                row.flatMap { calendarVenueMatchupTitle(for: $0) }
            ],
            normalizedQuery: normalizedQuery
        )
    }

    private func calendarPickupEvent(_ event: SportsEvent, matchesNormalizedQuery normalizedQuery: String) -> Bool {
        let row = viewModel.resolvedPickupGameRow(for: event.id)
        return calendarSearchFieldsMatch(
            [
                event.title,
                event.sport,
                event.league,
                row?.title,
                row?.description,
                row?.sport,
                row?.game_format,
                row?.skill_level,
                row?.address,
                row?.city,
                row?.state
            ],
            normalizedQuery: normalizedQuery
        )
    }

    private func calendarProMatch(_ match: LiveMatch, matchesNormalizedQuery normalizedQuery: String) -> Bool {
        let featuredEvent = calendarFeaturedEvent(for: match)
        return calendarSearchFieldsMatch(
            [
                match.homeTeam,
                match.awayTeam,
                "\(match.awayTeam) vs \(match.homeTeam)",
                "\(match.homeTeam) vs \(match.awayTeam)",
                "\(match.awayTeam) at \(match.homeTeam)",
                match.sport,
                match.sourceSportName,
                match.league,
                match.sourceLeagueName,
                match.leagueAlternate,
                match.eventName,
                match.leagueCountry,
                match.featuredEventSlug,
                featuredEvent?.title,
                featuredEvent?.shortTitle,
                featuredEvent?.slug,
                featuredEvent?.chipTitle
            ],
            normalizedQuery: normalizedQuery
        )
    }

    private func calendarSearchFieldsMatch(_ fields: [String?], normalizedQuery: String) -> Bool {
        let searchableText = calendarSearchableText(for: fields)
        return calendarSearchTextMatches(searchableText, normalizedQuery: normalizedQuery)
    }

    private func calendarSearchTextMatches(_ searchableText: String, normalizedQuery: String) -> Bool {
        guard !searchableText.isEmpty else { return false }
        if searchableText.contains(normalizedQuery) { return true }

        let queryTokens = normalizedQuery.split(separator: " ").map(String.init)
        return !queryTokens.isEmpty && queryTokens.allSatisfy { searchableText.contains($0) }
    }

    private func calendarSearchableText(for fields: [String?]) -> String {
        calendarExpandedSearchFields(fields)
            .map(calendarNormalizedSearchText)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func calendarExpandedSearchFields(_ fields: [String?]) -> [String] {
        var expanded: [String] = []
        for field in fields {
            guard let raw = field?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            expanded.append(raw)
            expanded.append(contentsOf: calendarCountryAliases(for: raw))
            expanded.append(contentsOf: calendarFavoriteTeamAliases(for: raw))
        }
        return expanded
    }

    private func calendarCountryAliases(for raw: String) -> [String] {
        let normalized = calendarNormalizedSearchText(raw)
        guard !normalized.isEmpty else { return [] }
        if ["usa", "us", "u s", "united states", "united states of america", "america"].contains(normalized) {
            return ["USA", "US", "United States", "United States of America", "America"]
        }
        guard CountryFlagHelper.isCountry(raw) else { return [] }
        return ["\(raw) National Team"]
    }

    private func calendarFavoriteTeamAliases(for raw: String) -> [String] {
        let normalized = calendarNormalizedSearchText(raw)
        guard !normalized.isEmpty else { return [] }
        guard let team = FavoriteTeamCatalog.all.first(where: { team in
            if calendarNormalizedSearchText(team.name) == normalized { return true }
            if calendarNormalizedSearchText(team.shortCode ?? "") == normalized { return true }
            return team.searchAliases.contains { calendarNormalizedSearchText($0) == normalized }
        }) else {
            return []
        }

        return ([team.name, team.shortCode, team.league].compactMap { $0 } + team.searchAliases)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func calendarVenueSuggestionCandidates(event: SportsEvent, row: VenueEventRow?) -> [CalendarSearchSuggestionCandidate] {
        var candidates: [CalendarSearchSuggestionCandidate] = []
        candidates += calendarSuggestionCandidates(title: row?.home_team, subtitle: "Team", kind: .team, rank: 0)
        candidates += calendarSuggestionCandidates(title: row?.away_team, subtitle: "Team", kind: .team, rank: 0)
        candidates += calendarSuggestionCandidates(title: event.title, subtitle: event.venueName ?? event.league, kind: .game, rank: 2)
        candidates += calendarSuggestionCandidates(title: event.league, subtitle: event.sport, kind: .competition, rank: 1)
        candidates += calendarSuggestionCandidates(title: row?.external_league, subtitle: event.sport, kind: .competition, rank: 1)
        candidates += calendarSuggestionCandidates(title: event.country, subtitle: "Country", kind: .team, rank: 0)
        return candidates
    }

    private func calendarPickupSuggestionCandidates(event: SportsEvent) -> [CalendarSearchSuggestionCandidate] {
        calendarSuggestionCandidates(title: event.title, subtitle: "Pickup game", kind: .game, rank: 3)
            + calendarSuggestionCandidates(title: event.sport, subtitle: "Sport", kind: .competition, rank: 4)
    }

    private func calendarProSuggestionCandidates(match: LiveMatch, featuredEvent: FeaturedEvent?) -> [CalendarSearchSuggestionCandidate] {
        var candidates: [CalendarSearchSuggestionCandidate] = []
        candidates += calendarSuggestionCandidates(title: match.homeTeam, subtitle: "Team", kind: .team, rank: 0)
        candidates += calendarSuggestionCandidates(title: match.awayTeam, subtitle: "Team", kind: .team, rank: 0)
        candidates += calendarSuggestionCandidates(title: "\(match.awayTeam) vs \(match.homeTeam)", subtitle: match.league, kind: .game, rank: 2)
        candidates += calendarSuggestionCandidates(title: match.league, subtitle: match.leagueCountry ?? match.sport, kind: .competition, rank: 1)
        candidates += calendarSuggestionCandidates(title: match.sourceLeagueName, subtitle: match.sport, kind: .competition, rank: 1)
        candidates += calendarSuggestionCandidates(title: match.leagueAlternate, subtitle: match.sport, kind: .competition, rank: 1)
        candidates += calendarSuggestionCandidates(title: match.eventName, subtitle: match.league, kind: .competition, rank: 1)
        candidates += calendarSuggestionCandidates(title: match.leagueCountry, subtitle: "Country", kind: .team, rank: 0)
        candidates += calendarSuggestionCandidates(title: featuredEvent?.title, subtitle: featuredEvent?.sport ?? "Competition", kind: .competition, rank: 1)
        candidates += calendarSuggestionCandidates(title: featuredEvent?.shortTitle, subtitle: featuredEvent?.title, kind: .competition, rank: 1)
        return candidates
    }

    private func calendarFeaturedEventSuggestionCandidates() -> [CalendarSearchSuggestionCandidate] {
        calendarFeaturedEvents.flatMap { featuredEvent in
            calendarSuggestionCandidates(title: featuredEvent.title, subtitle: featuredEvent.sport ?? "Competition", kind: .competition, rank: 1)
                + calendarSuggestionCandidates(title: featuredEvent.shortTitle, subtitle: featuredEvent.title, kind: .competition, rank: 1)
        }
    }

    private func calendarSuggestionCandidates(
        title: String?,
        subtitle: String?,
        kind: CalendarSearchSuggestionKind,
        rank: Int
    ) -> [CalendarSearchSuggestionCandidate] {
        guard let rawTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTitle.isEmpty else {
            return []
        }

        var candidates = [
            calendarSuggestionCandidate(title: rawTitle, subtitle: subtitle, kind: kind, rank: rank)
        ]

        let normalizedTitle = calendarNormalizedSearchText(rawTitle)
        let aliases = calendarCountryAliases(for: rawTitle) + calendarFavoriteTeamAliases(for: rawTitle)
        for alias in aliases {
            let cleanAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanAlias.isEmpty,
                  calendarNormalizedSearchText(cleanAlias) != normalizedTitle else {
                continue
            }
            candidates.append(calendarSuggestionCandidate(title: cleanAlias, subtitle: rawTitle, kind: kind, rank: rank))
        }

        return candidates.compactMap { $0 }
    }

    private func calendarSuggestionCandidate(
        title: String,
        subtitle: String?,
        kind: CalendarSearchSuggestionKind,
        rank: Int
    ) -> CalendarSearchSuggestionCandidate? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return nil }
        let cleanSubtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchableText = calendarSearchableText(for: [cleanTitle, cleanSubtitle])
        guard !searchableText.isEmpty else { return nil }
        return CalendarSearchSuggestionCandidate(
            title: cleanTitle,
            subtitle: cleanSubtitle?.isEmpty == false ? cleanSubtitle : nil,
            kind: kind,
            rank: rank,
            searchableText: searchableText
        )
    }

    private func buildCalendarSearchSuggestions(query: String) -> [CalendarSearchSuggestion] {
        let normalizedQuery = calendarNormalizedSearchText(query)
        guard normalizedQuery.count >= 2 else { return [] }

        var suggestions: [CalendarSearchSuggestion] = []
        var seen = Set<String>()

        func add(_ candidate: CalendarSearchSuggestionCandidate) {
            guard calendarSearchTextMatches(candidate.searchableText, normalizedQuery: normalizedQuery) else { return }
            let key = "\(candidate.kind.rawValue):\(calendarNormalizedSearchText(candidate.title))"
            guard seen.insert(key).inserted else { return }
            suggestions.append(
                CalendarSearchSuggestion(
                    title: candidate.title,
                    subtitle: candidate.subtitle,
                    kind: candidate.kind,
                    rank: candidate.rank
                )
            )
        }

        calendarSearchIndex.flatMap(\.suggestions).forEach(add)
        calendarFeaturedEventSuggestionCandidates().forEach(add)

        return suggestions
            .sorted {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            .prefix(8)
            .map { $0 }
    }

    private func loadedTeamNamesForSuggestions() -> [String] {
        var names: [String] = []
        for match in viewModel.liveMatches {
            names.append(match.homeTeam)
            names.append(match.awayTeam)
            if let country = match.leagueCountry {
                names.append(country)
            }
        }
        for event in loadedVenueSearchEvents() {
            if let row = calendarVenueEventRow(for: event) {
                names.append(row.home_team ?? "")
                names.append(row.away_team ?? "")
            } else {
                names.append(contentsOf: calendarTeamNames(fromMatchupTitle: event.title))
            }
        }
        return names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func calendarVenueEventRow(for event: SportsEvent) -> VenueEventRow? {
        let eventDay = calendarSearchDayFormatter.string(from: event.date)
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sport = event.sport.trimmingCharacters(in: .whitespacesAndNewlines)
        return viewModel.venueEventRows.first { row in
            guard row.event_title?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(title) == .orderedSame else {
                return false
            }
            if let rowDay = row.event_date?.trimmingCharacters(in: .whitespacesAndNewlines), !rowDay.isEmpty, rowDay != eventDay {
                return false
            }
            let rowSport = row.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return rowSport.isEmpty || sport.isEmpty || rowSport.caseInsensitiveCompare(sport) == .orderedSame
        }
    }

    private func calendarVenueMatchupTitle(for row: VenueEventRow) -> String? {
        let home = row.home_team?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let away = row.away_team?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !home.isEmpty, !away.isEmpty else { return nil }
        return "\(away) vs \(home)"
    }

    private func calendarTeamNames(fromMatchupTitle title: String) -> [String] {
        let separators = [" vs ", " at ", " @ ", " v "]
        for separator in separators {
            let parts = title.components(separatedBy: separator)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if parts.count == 2 {
                return parts
            }
        }
        return []
    }

    private func calendarSearchDateHeader(for date: Date) -> String {
        calendarSearchSectionDateFormatter.string(from: date)
    }

    private func calendarNormalizedSearchText(_ raw: String) -> String {
        LiveMatchFilters.normalizedSearchText(raw)
    }

    private var calendarSearchTimeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }

    private var calendarSearchDayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private var calendarSearchSectionDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }

    private var calendarDateStripWeekdayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE"
        return formatter
    }

    private var calendarDateStripDayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }

    private var calendarDateStripAccessibilityFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }

    private var teamScheduleRowWeekdayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE"
        return formatter
    }

    private var teamScheduleRowDayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }

    private var teamScheduleRangeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }
}

private struct CalendarProGameLazyCard<Content: View>: View {
    @ViewBuilder let content: (_ deferExpensiveSections: Bool) -> Content

    @State private var expensiveWorkEnabled = false

    var body: some View {
        content(!expensiveWorkEnabled)
            .onAppear {
                guard !expensiveWorkEnabled else { return }
                expensiveWorkEnabled = true
#if DEBUG
                ProSchedulePerf.noteVisibleGameRendered()
#endif
            }
    }
}

private enum TeamScheduleSport: String, CaseIterable, Identifiable {
    case soccer
    case basketball
    case football
    case baseball
    case hockey

    var id: String { rawValue }
    var cacheKey: String { rawValue }

    var title: String {
        switch self {
        case .soccer:
            return "Soccer"
        case .basketball:
            return "Basketball"
        case .football:
            return "Football"
        case .baseball:
            return "Baseball"
        case .hockey:
            return "Hockey"
        }
    }

    var emoji: String {
        switch self {
        case .soccer:
            return "⚽"
        case .basketball:
            return "🏀"
        case .football:
            return "🏈"
        case .baseball:
            return "⚾"
        case .hockey:
            return "🏒"
        }
    }

    var lookupSportFilter: String {
        switch self {
        case .soccer:
            return "Soccer"
        case .basketball:
            return "Basketball"
        case .football:
            return "Football"
        case .baseball:
            return "Baseball"
        case .hockey:
            return "Hockey"
        }
    }

    var popularTeams: [String] {
        switch self {
        case .soccer:
            return ["France", "PSG", "Argentina", "Real Madrid", "Mexico"]
        case .basketball:
            return ["Lakers", "Celtics", "Nuggets", "Heat", "Warriors"]
        case .football:
            return ["Chiefs", "Eagles", "Cowboys", "49ers", "Bills"]
        case .baseball:
            return ["Dodgers", "Yankees", "Mets", "Cubs", "Red Sox"]
        case .hockey:
            return ["Avalanche", "Rangers", "Maple Leafs", "Oilers", "Canadiens"]
        }
    }

    static func resolved(from raw: String?) -> TeamScheduleSport? {
        let normalized = LiveMatchFilters.normalizedSearchText(raw ?? "")
        guard !normalized.isEmpty, normalized != "all" else { return nil }
        if normalized.contains("soccer") { return .soccer }
        if normalized.contains("basketball") || normalized.contains("nba") { return .basketball }
        if normalized.contains("football") || normalized.contains("nfl") { return .football }
        if normalized.contains("baseball") || normalized.contains("mlb") { return .baseball }
        if normalized.contains("hockey") || normalized.contains("nhl") { return .hockey }
        return nil
    }
}

private struct TeamScheduleCacheEntry {
    let fetchedAt: Date
    let results: [LiveMatch]
}

private enum CalendarSearchResultItem: Identifiable {
    case venue(SportsEvent)
    case pickup(SportsEvent)
    case pro(LiveMatch)

    var id: String {
        switch self {
        case .venue(let event):
            return "venue-\(event.id.uuidString.lowercased())"
        case .pickup(let event):
            return "pickup-\(event.id.uuidString.lowercased())"
        case .pro(let match):
            return "pro-\(match.id)"
        }
    }

    var date: Date {
        switch self {
        case .venue(let event), .pickup(let event):
            return event.date
        case .pro(let match):
            return match.startTime
        }
    }

    var sortTitle: String {
        switch self {
        case .venue(let event), .pickup(let event):
            return event.title
        case .pro(let match):
            return "\(match.awayTeam) \(match.homeTeam)"
        }
    }
}

private struct CalendarSearchDateGroup: Identifiable {
    let date: Date
    let items: [CalendarSearchResultItem]

    var id: String {
        String(Int(date.timeIntervalSince1970))
    }
}

private struct CalendarSearchIndexEntry {
    let item: CalendarSearchResultItem
    let searchableText: String
    let suggestions: [CalendarSearchSuggestionCandidate]
}

private struct CalendarSearchSuggestionCandidate {
    let title: String
    let subtitle: String?
    let kind: CalendarSearchSuggestionKind
    let rank: Int
    let searchableText: String
}

private enum CalendarSearchSuggestionKind: String, Equatable {
    case team
    case competition
    case game

    var systemImage: String {
        switch self {
        case .team:
            return "person.2.fill"
        case .competition:
            return "trophy.fill"
        case .game:
            return "calendar.badge.clock"
        }
    }

    var tint: Color {
        switch self {
        case .team:
            return FGColor.accentBlue
        case .competition:
            return FGColor.accentGreen
        case .game:
            return Color.orange
        }
    }
}

private struct CalendarSearchSuggestion: Identifiable {
    let title: String
    let subtitle: String?
    let kind: CalendarSearchSuggestionKind
    let rank: Int

    var id: String {
        "\(kind.rawValue)-\(LiveMatchFilters.normalizedSearchText(title))"
    }
}

private struct CalendarLeagueCountryFilterSheet: View {
    let countries: [String]
    let suggestedNearYouCountry: String?
    @Binding var selectedCountries: Set<String>

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var languageCode: String { L10n.normalizedLanguageCode(appLanguageRaw) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Calendar Countries")
                            .font(FGTypography.sectionTitle)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                        Text(L10n.t("pro_sports_country_filter_subtitle", languageCode: languageCode))
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    .padding(.vertical, 4)
                }

                if let nearYou = suggestedNearYouCountry {
                    Section {
                        countryRow(
                            title: nearYou,
                            subtitle: L10n.t("near_you", languageCode: languageCode),
                            flag: CountryFlagHelper.flag(for: nearYou),
                            isSelected: selectedCountries.contains(nearYou),
                            accessibilityLabel: String(
                                format: L10n.t("near_you_country_a11y_format", languageCode: languageCode),
                                locale: Locale(identifier: languageCode),
                                nearYou
                            ),
                            accessibilityHint: countryToggleHint(isSelected: selectedCountries.contains(nearYou))
                        ) {
                            applySelection(LiveLeagueCountryFilterPresentation.toggling(nearYou, in: selectedCountries))
                        }
                    }
                }

                Section("Quick Actions") {
                    quickAction(
                        title: L10n.t("country_filter_select_all", languageCode: languageCode),
                        accessibilityHint: L10n.t("country_filter_select_all_a11y_hint", languageCode: languageCode)
                    ) {
                        applySelection(Set(countries))
                    }
                    quickAction(
                        title: L10n.t("country_filter_clear", languageCode: languageCode),
                        accessibilityHint: L10n.t("country_filter_clear_a11y_hint", languageCode: languageCode)
                    ) {
                        applySelection([])
                    }
                    presetRow(
                        title: L10n.t("live_region_north_america", languageCode: languageCode),
                        preset: LiveLeagueCountryFilterPresentation.northAmericaPreset,
                        accessibilityHint: L10n.t("country_filter_preset_a11y_hint", languageCode: languageCode)
                    )
                    presetRow(
                        title: L10n.t("country_filter_top_european", languageCode: languageCode),
                        preset: LiveLeagueCountryFilterPresentation.topEuropePreset,
                        accessibilityHint: L10n.t("country_filter_preset_a11y_hint", languageCode: languageCode)
                    )
                }

                Section("Countries") {
                    ForEach(countries, id: \.self) { country in
                        let isSelected = selectedCountries.contains(country)
                        countryRow(
                            title: country,
                            subtitle: nil,
                            flag: nil,
                            isSelected: isSelected,
                            accessibilityLabel: country,
                            accessibilityHint: countryToggleHint(isSelected: isSelected)
                        ) {
                            applySelection(LiveLeagueCountryFilterPresentation.toggling(country, in: selectedCountries))
                        }
                    }
                }
            }
            .navigationTitle("Calendar Countries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func applySelection(_ next: Set<String>) {
        selectedCountries = next
        LiveLeagueCountryFilterPreference.markInitialized()
    }

    private func countryToggleHint(isSelected: Bool) -> String {
        isSelected
            ? L10n.t("country_filter_deselect_a11y_hint", languageCode: languageCode)
            : L10n.t("country_filter_select_a11y_hint", languageCode: languageCode)
    }

    private func quickAction(title: String, accessibilityHint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(FGTypography.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityHint(accessibilityHint)
    }

    private func presetRow(title: String, preset: Set<String>, accessibilityHint: String) -> some View {
        let state = LiveLeagueCountryFilterPresentation.presetSelectionState(preset, in: selectedCountries)
        return Button {
            applySelection(LiveLeagueCountryFilterPresentation.togglingPreset(preset, in: selectedCountries))
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(FGTypography.body.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 8)
                presetTrailingIcon(state)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .accessibilityValue(presetAccessibilityValue(state))
        .accessibilityHint(accessibilityHint)
    }

    private func countryRow(
        title: String,
        subtitle: String?,
        flag: String?,
        isSelected: Bool,
        accessibilityLabel: String,
        accessibilityHint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if let subtitle {
                        Text(subtitle)
                            .font(FGTypography.caption.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    HStack(spacing: 8) {
                        if let flag, !flag.isEmpty {
                            Text(flag)
                                .font(.system(size: 22))
                                .accessibilityHidden(true)
                        }
                        Text(title)
                            .font(FGTypography.body.weight(subtitle == nil ? .regular : .semibold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(FGColor.accentGreen)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(
            isSelected
                ? L10n.t("country_filter_selected_a11y", languageCode: languageCode)
                : L10n.t("country_filter_not_selected_a11y", languageCode: languageCode)
        )
        .accessibilityHint(accessibilityHint)
    }

    @ViewBuilder
    private func presetTrailingIcon(_ state: LiveLeagueCountryFilterPresentation.PresetSelectionState) -> some View {
        switch state {
        case .full:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(FGColor.accentGreen)
        case .partial:
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(FGColor.accentGreen.opacity(0.85))
        case .none:
            EmptyView()
        }
    }

    private func presetAccessibilityValue(_ state: LiveLeagueCountryFilterPresentation.PresetSelectionState) -> String {
        switch state {
        case .full:
            return L10n.t("country_filter_selected_a11y", languageCode: languageCode)
        case .partial:
            return L10n.t("country_filter_partially_selected_a11y", languageCode: languageCode)
        case .none:
            return L10n.t("country_filter_not_selected_a11y", languageCode: languageCode)
        }
    }
}

private struct CalendarVenueEventPresentation {
    let venueDisplayName: String?
    let addressLine: String?
    let awayTeam: String?
    let homeTeam: String?
    let competitionLabel: String?
    let sportToken: String

    var hasTeamMatchup: Bool {
        Self.trimmedNonEmpty(awayTeam) != nil && Self.trimmedNonEmpty(homeTeam) != nil
    }

    func gameTitle(fallback: String) -> String {
        if hasTeamMatchup,
           let away = Self.trimmedNonEmpty(awayTeam),
           let home = Self.trimmedNonEmpty(homeTeam) {
            return "\(away) vs \(home)"
        }
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFallback.isEmpty ? "Watch Party" : trimmedFallback
    }

    func competitionBadgeLabel(featuredEvent: FeaturedEvent?) -> String? {
        if let featuredEvent {
            return featuredEvent.emptyStateTitle
        }
        return Self.trimmedNonEmpty(competitionLabel)
    }

    static func resolve(event: SportsEvent, bar: BarVenue?, row: VenueEventRow?) -> CalendarVenueEventPresentation {
        let sportToken = Self.trimmedNonEmpty(row?.sport) ?? Self.trimmedNonEmpty(event.sport) ?? "Soccer"
        return CalendarVenueEventPresentation(
            venueDisplayName: Self.trimmedNonEmpty(bar?.name) ?? Self.trimmedNonEmpty(row?.venue_name),
            addressLine: Self.trimmedNonEmpty(bar?.address),
            awayTeam: Self.trimmedNonEmpty(row?.away_team),
            homeTeam: Self.trimmedNonEmpty(row?.home_team),
            competitionLabel: Self.trimmedNonEmpty(row?.external_league),
            sportToken: sportToken
        )
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
